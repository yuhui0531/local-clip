// 原格式恢复与一次直接粘贴尝试，by AI.Coding。
import Foundation
import LocalClipCore
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
    public init(board: any PasteboardClient, applications: any ApplicationClient, store: any HistoryRepository, capture: CaptureCoordinator, clock: any ClipClock = SystemClock()) {
        self.board = board; self.applications = applications; self.store = store; self.capture = capture; self.clock = clock
    }
    /// 输出格式与操作动作正交；写失败或剪贴板变更不虚报已复制。
    public func perform(_ request: PasteRequest, copyFilesToFinder: Bool = false) async -> PasteResult {
        guard !performing else { return .failed("正在处理，请稍后") }
        performing = true; smartPasteNotice = nil; defer { performing = false }
        do {
            let initialCount = board.changeCount
            var records: [ClipboardPayload] = []
            for id in request.ids { records.append(try await store.loadPayload(id: id, at: clock.now())) }
            let started = ContinuousClock.now
            // 开关关闭保持原组合逻辑；开启也只读取确认文本目标的整组文件，by AI.Coding。
            let settings = try await store.settings()
            let smartFiles = settings.smartCodeFilePaste && !records.isEmpty && records.allSatisfy { $0.fileURLs != nil }
            // 复制没有确定接收目标，始终恢复原文件；仅直接粘贴允许转换正文。
            let eligible = request.action == .directPaste && smartFiles && !copyFilesToFinder && applications.permitted
                && request.target.map { applications.isAlive($0) && applications.pasteTargetKind($0) == .text
                    && (applications.target() == nil || applications.target() == $0) } == true
            let raw = try await Task.detached { try OutputComposer.combine(records, format: smartFiles ? .original : request.format) }.value
            var payload = raw
            var codeContents: CodeFileContents?
            var codeReadAttempted = false
            if eligible, let urls = raw.fileURLs {
                codeReadAttempted = true
                do { codeContents = try await Task.detached(priority: .userInitiated) { try CodeFileReader.snapshot(urls) }.value }
                catch let error as CodeFileReadError { smartPasteNotice = error.message }
                catch { smartPasteNotice = "已保留原文件：文件无法读取" }
                let enabled = try await store.settings().smartCodeFilePaste
                if enabled, let target = request.target, applications.pasteTargetKind(target) == .text,
                   (applications.target() == nil || applications.target() == target), let contents = codeContents {
                    payload = ClipboardPayload([.init([.init(SupportedType.string, Data(contents.text.utf8))], plainText: contents.text)])
                }
            }
            var converted = payload.fileURLs == nil && raw.fileURLs != nil
            let prepared = payload
            var fingerprint = await Task.detached { prepared.fingerprint }.value
            let originalFingerprint = converted ? await Task.detached { raw.fingerprint }.value : fingerprint
            // await期间用户新复制不能被长文件读取覆盖；转换结果写入前再次确认开关及目标，by AI.Coding。
            if converted, let target = request.target {
                let enabled = try await store.settings().smartCodeFilePaste
                let currentFiles = await Task.detached { [codeContents] in codeContents?.isCurrent() == true }.value
                if !enabled || !currentFiles || applications.pasteTargetKind(target) != .text || (applications.target() != nil && applications.target() != target) {
                    payload = raw; converted = false
                }
            }
            // 计算期间删除/到期时不允许恢复。取值再次验证，UI不直接触碰存储。
            for id in request.ids { _ = try await store.detail(id: id, at: clock.now()) }
            if converted {
                let enabled = try await store.settings().smartCodeFilePaste
                if !enabled || request.target.map({ applications.pasteTargetKind($0) == .text && (applications.target() == nil || applications.target() == $0) }) != true {
                    payload = raw; converted = false
                }
            }
            guard board.changeCount == initialCount else { return .failed("剪贴板已变化，请重新选择") }
            var receipt = board.write(payload, fingerprint: converted ? fingerprint : originalFingerprint); capture.recordOwnWrite(receipt)
            // 不确定或关闭开关时恢复原文件；只改自己仍持有的剪贴板，不覆盖用户的新复制，by AI.Coding。
            func restoreFiles() -> Bool {
                guard converted else { return true }
                guard board.matches(receipt) else { return false }
                receipt = board.write(raw, fingerprint: originalFingerprint); capture.recordOwnWrite(receipt)
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
            if converted, try await store.settings().smartCodeFilePaste == false {
                guard restoreFiles() else { return .failed("剪贴板已变化或复制失败，请重新选择") }
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
            // 非激活面板打开时，某些应用暂不暴露原文本焦点。恢复后必须重新识别，
            // 不能把面板期间的一次unknown永久当作文件目标；等待期间的新复制仍不可覆盖。
            if smartFiles, !converted, !codeReadAttempted, applications.pasteTargetKind(target) == .text,
               try await store.settings().smartCodeFilePaste, let urls = raw.fileURLs {
                codeReadAttempted = true
                do { codeContents = try await Task.detached(priority: .userInitiated) { try CodeFileReader.snapshot(urls) }.value }
                catch let error as CodeFileReadError { smartPasteNotice = error.message }
                catch { smartPasteNotice = "已保留原文件：文件无法读取" }
                if let contents = codeContents {
                    let textPayload = ClipboardPayload([.init([.init(SupportedType.string, Data(contents.text.utf8))], plainText: contents.text)])
                    let textFingerprint = await Task.detached { textPayload.fingerprint }.value
                    let currentFiles = await Task.detached { contents.isCurrent() }.value
                    for id in request.ids { _ = try await store.detail(id: id, at: clock.now()) }
                    let enabled = try await store.settings().smartCodeFilePaste
                    guard board.matches(receipt) else { return .failed("剪贴板已变化，请重新选择") }
                    if enabled, currentFiles, applications.permitted, applications.isFrontmost(target),
                       applications.isPasteFocusReady(target), applications.pasteTargetKind(target) == .text {
                        payload = textPayload; fingerprint = textFingerprint; converted = true
                        receipt = board.write(payload, fingerprint: fingerprint); capture.recordOwnWrite(receipt)
                        guard receipt.successful else { return .failed("复制失败，请重试") }
                    }
                }
            }
            if converted {
                let enabled = try await store.settings().smartCodeFilePaste
                let currentFiles = await Task.detached { [codeContents] in codeContents?.isCurrent() == true }.value
                guard board.matches(receipt) else { return .failed("剪贴板已变化，请重新选择") }
                if !enabled || !currentFiles || applications.pasteTargetKind(target) != .text {
                    guard restoreFiles() else { return .failed("剪贴板已变化或复制失败，请重新选择") }
                }
            }
            // 焦点等待期间删除的记录不能重新发往目标，by AI.Coding。
            for id in request.ids { _ = try await store.detail(id: id, at: clock.now()) }
            if converted {
                let enabled = try await store.settings().smartCodeFilePaste
                if !enabled || applications.pasteTargetKind(target) != .text {
                    guard restoreFiles() else { return .failed("剪贴板已变化或复制失败，请重新选择") }
                }
            }
            guard applications.sendPaste(target, ifClipboardUnchanged: { self.board.matches(receipt) }) else {
                return safeFallback((applications.pasteFailureReason ?? "粘贴指令未发出") + "，请手动粘贴")
            }
            return .commandSent
        } catch StoreError.corruptPayload { return .failed("所选内容包含无文本项目，不能纯文本输出；请使用原格式") }
        catch StoreError.notFound { return .failed("内容已删除或到期，请重新选择") }
        catch { return .failed("复制失败，请重试") }
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
        do { for id in request.ids { _ = try await store.detail(id: id, at: clock.now()) } }
        catch { return .failed("内容已删除或到期，未复制文件") }
        guard case .success(let current) = await finder.destination(), current == destination,
              applications.isFrontmost(target), board.matches(receipt) else {
            return fallback("Finder目录或剪贴板已变化，请重新选择", receipt: receipt)
        }
        let report = await Task.detached(priority: .userInitiated) { FileObjectCopier.copy(sources, to: destination.directory) }.value
        // 已发布的项目不自动回滚；失败结果准确陈述实际完成数量。
        return report.failure == nil ? .filesCopied(report.message) : .failed(report.message)
    }
    /// 所有提前回退也核对收据，切焦点并复制新内容时不能宣称旧内容已复制。
    private func fallback(_ reason: String, receipt: WriteReceipt) -> PasteResult {
        board.matches(receipt) ? .fallback(reason) : .failed("剪贴板已变化，请重新选择")
    }
}
