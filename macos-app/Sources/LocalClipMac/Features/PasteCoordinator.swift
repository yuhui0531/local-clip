// 原格式恢复与一次直接粘贴尝试，by AI.Coding。
import Foundation
import LocalClipCore

struct SmartPastePlan {
    let target: TargetToken
    let targetKind: PasteTargetKind
    let editorOptInBundleID: String?
    let contents: CodeFileContents
    let originalPayload: ClipboardPayload
    let originalFingerprint: String
    let textPayload: ClipboardPayload
    let textFingerprint: String
    /// 所有智能转换复查集中于一个点；真实应用接收仍由目标应用决定，by AI.Coding。
    func revalidate(settings: SettingsSnapshot, targetIsSame: Bool, targetIdentityReady: Bool,
                    fileIdentityCurrent: Bool, clipboardUnchanged: Bool) -> Bool {
        guard case .text = targetKind else { return false }
        let editorStillAuthorized = editorOptInBundleID.map { settings.smartPasteEditorBundleIDs.contains($0) } ?? true
        return settings.smartCodeFilePaste && editorStillAuthorized && targetIsSame && targetIdentityReady && fileIdentityCurrent && clipboardUnchanged
    }
}

@MainActor public final class PasteCoordinator {
    private let board: any PasteboardClient
    private let applications: any ApplicationClient
    private let store: any HistoryRepository
    private let capture: CaptureCoordinator
    private let clock: any ClipClock
    private let finder = FinderFileService()
    private var performing = false
    public private(set) var smartPasteNotice: String?
    public var closePanel: (() -> Void)?
    /// Finder 复制暂存登记目录；nil 时保持原有进程内收尾（测试默认）。
    public var copyJournal: URL?
    public init(board: any PasteboardClient, applications: any ApplicationClient, store: any HistoryRepository, capture: CaptureCoordinator, clock: any ClipClock = SystemClock()) {
        self.board = board; self.applications = applications; self.store = store; self.capture = capture; self.clock = clock
    }
    /// 输出格式与操作动作正交；写失败或剪贴板变更不虚报已复制。
    public func perform(_ request: PasteRequest, copyFilesToFinder: Bool = false) async -> PasteResult {
        guard !performing else { return .failed("正在处理，请稍后") }
        performing = true; smartPasteNotice = nil; defer { performing = false }
        do {
            try Task.checkCancellation()
            let initialCount = board.changeCount
            try await OutputBudget.preflight(request.ids, store: store, at: clock.now(), transform: request.transform != nil)
            var records: [ClipboardPayload] = []
            for id in request.ids { try Task.checkCancellation(); records.append(try await store.loadPayload(id: id, at: clock.now())) }
            let started = ContinuousClock.now
            // 目标分类延后到应用焦点恢复后；分类前始终保留原文件表示，by AI.Coding。
            let settings = try await store.settings()
            // 转换不与代码文件智能粘贴叠加；先按纯文本合并再转换，在关闭面板前完成，失败时面板保持打开，by AI.Coding。
            if request.transform != nil, records.contains(where: \.hasFileReferences) { return .failed("文件记录无法转换") }
            let smartFiles = request.transform == nil && request.join == .newline && settings.smartCodeFilePaste && !records.isEmpty && records.allSatisfy { $0.fileURLs != nil }
            let worker = Task.detached { try OutputComposer.combine(records, format: request.transform != nil ? .plainText : smartFiles ? .original : request.format, join: request.join) }
            let combined = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            let raw: ClipboardPayload
            if let transform = request.transform {
                let language = transform == .markdownCodeBlock ? await SyntaxHighlighter.shared.language(of: combined.plainText ?? "") : nil
                raw = try await Task.detached { try OutputComposer.transform(combined, transform, language: language) }.value
            } else { raw = combined }
            let smartPasteEligible = smartFiles && request.action == .directPaste && !copyFilesToFinder
                && applications.permitted && request.target != nil
            var payload = raw
            var sourceIdentity: CodeFileReader.IdentitySnapshot?
            var sourceIdentityError: CodeFileReadError?
            if smartPasteEligible, let urls = raw.fileURLs {
                do { sourceIdentity = try await Task.detached { try CodeFileReader.identitySnapshot(urls) }.value }
                catch let error as CodeFileReadError { sourceIdentityError = error }
                catch { sourceIdentityError = .unavailable }
            }
            var converted = false
            var fingerprint = await Task.detached { raw.fingerprint }.value
            let originalFingerprint = fingerprint
            var smartPlan: SmartPastePlan?
            // 计算期间删除/到期时不允许恢复。取值再次验证，UI不直接触碰存储。
            for id in request.ids { _ = try await store.metadata(id: id, at: clock.now()) }
            guard board.changeCount == initialCount else { return .failed("剪贴板已变化，请重新选择") }
            try Task.checkCancellation()
            var receipt = board.write(payload, fingerprint: originalFingerprint); capture.recordOwnWrite(receipt)
            // 不确定或关闭开关时恢复原文件；只改自己仍持有的剪贴板，不覆盖用户的新复制，by AI.Coding。
            func restoreFiles() -> Bool {
                guard converted else { return true }
                guard !Task.isCancelled, board.matches(receipt) else { return false }
                receipt = board.write(smartPlan?.originalPayload ?? raw, fingerprint: smartPlan?.originalFingerprint ?? originalFingerprint); capture.recordOwnWrite(receipt)
                converted = false; return receipt.successful
            }
            func safeFallback(_ reason: String) -> PasteResult {
                guard restoreFiles() else { return .failed("剪贴板已变化或复制失败，请重新选择") }
                return fallback(reason, receipt: receipt)
            }
            if (try? await store.settings().timingEnabled) == true { StageTiming.record("output_write", since: started, count: payload.items.count) }
            guard receipt.successful else { return .failed("复制失败，请重试") }
            if copyFilesToFinder, let sources = payload.fileURLs {
                return await copyFiles(sources, request: request, receipt: receipt)
            }
            if request.action == .copy { return board.matches(receipt) ? .copied : .failed("剪贴板已变化，请重新选择") }
            // 权限失败留在面板显示原因，不能先关闭面板让用户以为粘贴无响应。
            guard applications.permitted else {
                applications.requestPastePermission()
                return safeFallback("请授予当前LocalClip辅助功能权限，之后在目标应用重新打开历史")
            }
            guard let target = request.target, applications.isAlive(target) else { return safeFallback("请选择目标应用后粘贴") }
            // 用户已经转向其他应用时不把焦点抢回旧目标。
            if let current = applications.target(), current.pid != target.pid || current.bundleID != target.bundleID || current.launchedAt != target.launchedAt {
                return safeFallback("目标已变化，请确认输入位置后手动粘贴")
            }
            try Task.checkCancellation()
            closePanel?()
            guard applications.isFrontmost(target) || applications.activate(target) else { return safeFallback("请确认目标位置后手动粘贴") }
            let deadline = ContinuousClock.now + .milliseconds(500)
            while !applications.isFrontmost(target) && ContinuousClock.now < deadline {
                // 激活等待只允许原面板或目标；用户转向另一个真实应用立即停止。
                if let current = applications.target(), current.pid != target.pid { return safeFallback("请确认目标位置后手动粘贴") }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard board.matches(receipt) else { return .failed("剪贴板已变化，请重新选择") }
            guard applications.permitted, applications.isAlive(target), applications.isFrontmost(target) else { return safeFallback("请确认目标位置后手动粘贴") }
            // 应用成为前台不代表原焦点已恢复；目标可以是编辑器/文档/画布，不限定文本框。
            _ = applications.restorePasteFocus(target)
            let focusDeadline = ContinuousClock.now + .milliseconds(700)
            var readySince: ContinuousClock.Instant?
            var focusReady = false
            while ContinuousClock.now < focusDeadline {
                try Task.checkCancellation()
                guard board.matches(receipt) else { return .failed("剪贴板已变化，请重新选择") }
                guard applications.permitted, applications.isAlive(target), applications.isFrontmost(target) else {
                    return safeFallback("目标已变化，请确认输入位置后手动粘贴")
                }
                if applications.isPasteFocusReady(target) {
                    if let readySince, ContinuousClock.now - readySince >= .milliseconds(40) { focusReady = true; break }
                    if readySince == nil { readySince = ContinuousClock.now }
                } else { readySince = nil }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard focusReady else { return safeFallback((applications.pasteFailureReason ?? "原目标焦点未恢复") + "，请手动粘贴") }
            // 焦点恢复后只分类一次；后续异步边界只复查焦点身份与前台应用，by AI.Coding。
            let pasteSettings = try await store.settings()
            if smartPasteEligible, let urls = raw.fileURLs,
               pasteSettings.smartCodeFilePaste,
               case .text = applications.pasteTargetKind(target, smartPasteEditorBundleIDs: pasteSettings.smartPasteEditorBundleIDs) {
                do {
                    if let sourceIdentity, sourceIdentity.isCurrent() {
                        let contents = try await Task.detached(priority: .userInitiated) { try CodeFileReader.snapshot(urls) }.value
                        guard sourceIdentity.matches(contents) else { throw CodeFileReadError.changed }
                        let textPayload = ClipboardPayload([.init([.init(SupportedType.string, Data(contents.text.utf8))], plainText: contents.text)])
                        let textFingerprint = await Task.detached { textPayload.fingerprint }.value
                        let plan = SmartPastePlan(target: target, targetKind: .text,
                                                  editorOptInBundleID: pasteSettings.smartPasteEditorBundleIDs.contains(target.bundleID) ? target.bundleID : nil,
                                                  contents: contents,
                                                  originalPayload: raw, originalFingerprint: originalFingerprint,
                                                  textPayload: textPayload, textFingerprint: textFingerprint)
                        smartPlan = plan
                        let currentFiles = await Task.detached { contents.isCurrent() && sourceIdentity.isCurrent() }.value
                        for id in request.ids { _ = try await store.metadata(id: id, at: clock.now()) }
                        let currentSettings = try await store.settings()
                        guard board.matches(receipt) else { return .failed("剪贴板已变化，请重新选择") }
                        let currentTarget = applications.target()
                        let sameTarget = currentTarget.map { $0.pid == plan.target.pid && $0.bundleID == plan.target.bundleID && $0.launchedAt == plan.target.launchedAt } ?? false
                        let identityReady = applications.permitted && applications.isAlive(target) && applications.isFrontmost(target) && applications.isPasteFocusReady(target)
                        if !identityReady { return safeFallback("目标已变化，请确认输入位置后手动粘贴") }
                        if plan.revalidate(settings: currentSettings, targetIsSame: sameTarget,
                                           targetIdentityReady: identityReady, fileIdentityCurrent: currentFiles,
                                           clipboardUnchanged: board.matches(receipt)) {
                            payload = plan.textPayload; fingerprint = plan.textFingerprint; converted = true
                            try Task.checkCancellation()
                            receipt = board.write(payload, fingerprint: fingerprint); capture.recordOwnWrite(receipt)
                            guard receipt.successful else { return .failed("复制失败，请重试") }
                        } else if !currentFiles { smartPasteNotice = CodeFileReadError.changed.message }
                    } else if let sourceIdentityError { throw sourceIdentityError }
                    else { throw CodeFileReadError.changed }
                }
                catch let error as CodeFileReadError { smartPasteNotice = error.message }
                catch is CancellationError { throw CancellationError() }
                catch { smartPasteNotice = "已保留原文件：文件无法读取" }
            } else if smartPasteEligible, let sourceIdentityError { smartPasteNotice = sourceIdentityError.message }
            // 焦点等待期间删除的记录不能重新发往目标，by AI.Coding。
            for id in request.ids { _ = try await store.metadata(id: id, at: clock.now()) }
            if let plan = smartPlan {
                let currentFiles = await Task.detached { plan.contents.isCurrent() && (sourceIdentity?.isCurrent() == true) }.value
                let currentSettings = try await store.settings()
                guard board.matches(receipt) else { return .failed("剪贴板已变化，请重新选择") }
                let currentTarget = applications.target()
                let sameTarget = currentTarget.map { $0.pid == plan.target.pid && $0.bundleID == plan.target.bundleID && $0.launchedAt == plan.target.launchedAt } ?? false
                let identityReady = applications.permitted && applications.isAlive(target) && applications.isFrontmost(target) && applications.isPasteFocusReady(target)
                if !identityReady { return safeFallback("目标已变化，请确认输入位置后手动粘贴") }
                if !plan.revalidate(settings: currentSettings, targetIsSame: sameTarget,
                                    targetIdentityReady: identityReady, fileIdentityCurrent: currentFiles,
                                    clipboardUnchanged: board.matches(receipt)), converted {
                    guard restoreFiles() else { return .failed("剪贴板已变化或复制失败，请重新选择") }
                }
            }
            guard applications.isAlive(target), applications.isFrontmost(target), applications.isPasteFocusReady(target) else {
                return safeFallback("目标已变化，请确认输入位置后手动粘贴")
            }
            try Task.checkCancellation()
            guard applications.sendPaste(target, ifClipboardUnchanged: { self.board.matches(receipt) }) else {
                return safeFallback((applications.pasteFailureReason ?? "粘贴指令未发出") + "，请手动粘贴")
            }
            return .commandSent
        } catch is OutputBudget { return .failed(OutputBudget.message) }
        catch let error as TransformError { return .failed(error.message) }
        catch StoreError.corruptPayload { return .failed(request.transform != nil ? "所选内容包含无文本项目，无法转换" : request.join != .newline ? "所选内容包含无文本项目，无法合并" : "所选内容包含无文本项目，不能纯文本输出；请使用原格式") }
        catch StoreError.notFound { return .failed("内容已删除或到期，请重新选择") }
        catch { return .failed("复制失败，请重试") }
    }
    /// 写入派生纯文本（如图中文字）：只复制不粘贴，自写收据过滤，不进历史，by AI.Coding。
    public var clipboardChangeCount: Int { board.changeCount }
    /// OCR准备期间的新复制不得被旧结果覆盖，by AI.Coding。
    public func copyText(_ text: String, expectedChangeCount: Int? = nil) -> PasteResult {
        guard expectedChangeCount == nil || expectedChangeCount == board.changeCount else { return .failed("识别完成，剪贴板已变化；请重新选择复制图中文字") }
        let payload = ClipboardPayload([.init([.init(SupportedType.string, Data(text.utf8))], plainText: text)])
        let receipt = board.write(payload, fingerprint: payload.fingerprint); capture.recordOwnWrite(receipt)
        return receipt.successful ? .copied : .failed("复制失败，请重试")
    }
    /// Finder文件复制通过实际文件操作报告结果，不把Command-V发送当成复制完成。
    private func copyFiles(_ sources: [URL], request: PasteRequest, receipt: WriteReceipt) async -> PasteResult {
        guard let target = request.target, target.bundleID == "com.apple.finder", applications.isAlive(target) else {
            return fallback("请打开Finder文件夹后重试", receipt: receipt)
        }
        // 允许前台仍为自身面板；用户已切到别的应用时不抢回Finder执行文件操作。
        if let current = applications.target(), current.pid != target.pid || current.bundleID != target.bundleID || current.launchedAt != target.launchedAt {
            return fallback("目标已变化，请在Finder手动粘贴", receipt: receipt)
        }
        closePanel?()
        guard applications.activate(target) else { return fallback("请在Finder手动粘贴", receipt: receipt) }
        let deadline = ContinuousClock.now + .milliseconds(500)
        while !applications.isFrontmost(target) && ContinuousClock.now < deadline {
            if let current = applications.target(), current.pid != target.pid { return fallback("目标已变化，请在Finder手动粘贴", receipt: receipt) }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return fallback("操作已取消，请在Finder手动粘贴", receipt: receipt) }
        }
        guard applications.isAlive(target), applications.isFrontmost(target), board.matches(receipt) else {
            return fallback("目标或剪贴板已变化，请重新选择", receipt: receipt)
        }
        let destination: FinderDestination
        switch await finder.destination() {
        case .success(let value): destination = value
        case .failure(let error): return fallback(error.message, receipt: receipt)
        }
        // 查询可能触发系统自动化授权；授权结束后再次核对窗口、应用、剪贴板及历史。
        guard applications.isAlive(target), applications.isFrontmost(target), board.matches(receipt) else {
            return fallback("目标或剪贴板已变化，请重新选择", receipt: receipt)
        }
        do { for id in request.ids { _ = try await store.metadata(id: id, at: clock.now()) } }
        catch { return .failed("内容已删除或到期，未复制文件") }
        guard case .success(let current) = await finder.destination(), current == destination,
              applications.isFrontmost(target), board.matches(receipt) else {
            return fallback("Finder目录或剪贴板已变化，请重新选择", receipt: receipt)
        }
        let journal = copyJournal
        let report = await Task.detached(priority: .userInitiated) { FileObjectCopier.copy(sources, to: destination.directory, journal: journal) }.value
        // 已发布的项目不自动回滚；失败结果准确陈述实际完成数量。
        return report.failure == nil ? .filesCopied(report.message) : .failed(report.message)
    }
    /// 所有提前回退也核对收据，切焦点并复制新内容时不能宣称旧内容已复制。
    private func fallback(_ reason: String, receipt: WriteReceipt) -> PasteResult {
        board.matches(receipt) ? .fallback(reason) : .failed("剪贴板已变化，请重新选择")
    }
}
