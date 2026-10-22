// F19连续粘贴队列：真实临时SQLite + fake剪贴板与目标应用，验证顺序、忽略重入、修饰键回退、跳过已删项与快捷键注册，by AI.Coding。
import AppKit
import SwiftUI
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct PasteQueueTests {
    private final class Recorder { var feedback: [(String, Bool)] = []; var registered = 0; var unregistered = 0 }
    private struct Harness { let root: URL, store: HistoryStore, raw: RawBoard, apps: FakeApplications, model: HistoryViewModel, recorder: Recorder, ids: [ClipID] }
    private func harness(registerOK: Bool = true) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root), raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications()
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: apps, store: store, capture: capture), derived: DerivedContentService(store: store))
        let recorder = Recorder(), now = SystemClock().now()
        model.showPasteFeedback = { recorder.feedback.append(($0, $1)) }
        model.registerQueueShortcut = { _ in recorder.registered += 1; return registerOK }
        model.unregisterQueueShortcut = { recorder.unregistered += 1 }
        var ids: [ClipID] = []
        for (index, text) in ["first", "second", "third"].enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))], plainText: text)])), at: now + Int64(index)) else { throw StoreError.notFound }
            ids.append(id)
        }
        return .init(root: root, store: store, raw: raw, apps: apps, model: model, recorder: recorder, ids: ids)
    }
    private func until(_ h: Harness, _ predicate: () -> Bool, line: Int = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate(), "line \(line): position=\(h.model.pasteQueuePosition) active=\(h.model.pasteQueueActive) events=\(h.apps.events) feedback=\(h.recorder.feedback.map(\.0)) message=\(h.model.message)")
    }
    private func clipboard(_ raw: RawBoard) -> String? { raw.items.first?[SupportedType.string].map { String(decoding: $0, as: UTF8.self) } }

    /// LC-008：等待修饰键期间替换队列，旧任务不能发布新队列内容或推进位置。
    @Test func replacedQueueRejectsOldGeneration() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        var held = true
        h.model.startPasteQueue(h.ids)
        h.model.pasteQueueNext(target: h.apps.remembered) { held }
        try await Task.sleep(for: .milliseconds(30))
        h.model.stopPasteQueue()
        h.model.startPasteQueue(Array(h.ids.reversed()))
        held = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.apps.events == 0)
        #expect(h.model.pasteQueuePosition == 0)
        #expect(clipboard(h.raw) == nil)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.apps.events == 1 }
        #expect(clipboard(h.raw) == "third")
    }

    /// 按选择顺序逐项粘贴，处理中再按忽略；用完自动结束并注销快捷键，by AI.Coding。
    @Test func pastesInOrderAndEnds() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids)
        #expect(h.model.pasteQueueActive && h.recorder.registered == 1 && h.model.pasteQueueStatus?.hasPrefix("粘贴队列 0/3") == true)
        for (step, text) in ["first", "second", "third"].enumerated() {
            h.model.pasteQueueNext(target: h.apps.remembered) { false }
            h.model.pasteQueueNext(target: h.apps.remembered) { false }   // 处理中重入被忽略
            // 最后一项完成后队列结束、位置清零，所以只看事件数与反馈数。
            try await until(h) { h.apps.events == step + 1 && h.recorder.feedback.count == step + 2 }
            #expect(clipboard(h.raw) == text)
        }
        try await until(h) { !h.model.pasteQueueActive && h.recorder.unregistered == 1 }
        #expect(h.recorder.feedback.last?.0 == "已发送粘贴指令 3/3")
        #expect(try await h.store.search(.init()).items.count == 3)
    }

    /// A3：修饰键500ms未松开只复制并停在当前项等待确认；再按不覆盖剪贴板，确认只推进一次；已删项跳过并说明；没有外部目标不前进，by AI.Coding。
    @Test func modifiersDeletedItemsAndMissingTarget() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids)
        h.model.pasteQueueNext(target: nil) { false }
        #expect(h.model.pasteQueuePosition == 0 && h.recorder.feedback.last?.0 == "请先切换到要粘贴的应用" && clipboard(h.raw) == nil)
        let began = ContinuousClock.now
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueueAwaiting && h.recorder.feedback.count == 3 }
        #expect(ContinuousClock.now - began >= .milliseconds(500))
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0 && clipboard(h.raw) == "first")
        #expect(h.recorder.feedback.last?.0 == "修饰键未松开，当前项已复制，请手动粘贴（0/3）" && h.recorder.feedback.last?.1 == true)
        #expect(h.model.pasteQueueStatus?.contains("等待手动粘贴后确认") == true)
        // 等待确认时再按：不写剪贴板、不粘贴、不推进，只提醒。
        h.raw.items = [[SupportedType.string: Data("user-manual".utf8)]]
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0 && clipboard(h.raw) == "user-manual")
        #expect(h.recorder.feedback.last?.0 == "修饰键未松开，当前项已复制，请手动粘贴（0/3）；" + HistoryViewModel.pasteQueueAwaitingReminder)
        h.model.confirmPasteQueueManualPaste(); h.model.confirmPasteQueueManualPaste()
        #expect(h.model.pasteQueuePosition == 1 && !h.model.pasteQueueAwaiting && h.recorder.feedback.last?.0 == "已确认手动粘贴 1/3")
        _ = try await h.store.apply(h.store.preview(.delete([h.ids[1]])).token)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.recorder.feedback.count == 6 }
        #expect(clipboard(h.raw) == "third" && h.recorder.feedback.last?.0 == "已发送粘贴指令 3/3（第 2 项已不存在，已跳过）")
        try await until(h) { !h.model.pasteQueueActive }
    }

    /// 队列浮窗：中途跳过的说明留在浮窗；普通成功只更新进度；全部失效与最后一步的失败、回退仍有提示，by AI.Coding。
    @Test func queuePanelKeepsSkipNotes() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.showsQueuePanel = true
        // 中途跳过：A失效、B成功、C待粘贴。
        h.model.startPasteQueue(h.ids)
        _ = try await h.store.apply(h.store.preview(.delete([h.ids[0]])).token)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.apps.events == 1 && h.model.pasteQueueWarning != nil }
        #expect(clipboard(h.raw) == "second" && h.model.pasteQueuePosition == 2 && h.model.pasteQueueActive)
        #expect(h.model.pasteQueueWarning == "第 1 项已不存在，已跳过" && h.recorder.feedback.isEmpty)
        // 普通成功只更新进度；最后一步结束后由提示收尾。
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { !h.recorder.feedback.isEmpty }
        #expect(h.recorder.feedback.map(\.0) == ["已发送粘贴指令 3/3"] && !h.model.pasteQueueActive)
    }
    @Test func queuePanelReportsExhaustionAndLastStep() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.showsQueuePanel = true
        h.model.startPasteQueue(h.ids)
        // 位置在记录使用前就已前进；以浮窗刷新作为本步完成的信号。
        var changes = 0; h.model.pasteQueueChanged = { changes += 1 }
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { changes > 0 }
        #expect(h.model.pasteQueueWarning == nil && h.recorder.feedback.isEmpty)
        // 剩余全部失效：队列结束并提示跳过的项。
        _ = try await h.store.apply(h.store.preview(.delete([h.ids[1], h.ids[2]])).token)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { !h.recorder.feedback.isEmpty }
        #expect(!h.model.pasteQueueActive && h.recorder.feedback.last?.0 == "第 2、3 项已不存在，已跳过" && h.recorder.feedback.last?.1 == true)
        // 最后一步失败：不前进，浮窗写出原因；随后回退复制结束队列并提示。
        let more = try await harness(); defer { more.model.stopPasteQueue(); try? FileManager.default.removeItem(at: more.root) }
        more.model.showsQueuePanel = true
        more.model.startPasteQueue(Array(more.ids.prefix(2)))
        var steps = 0; more.model.pasteQueueChanged = { steps += 1 }
        more.model.pasteQueueNext(target: more.apps.remembered) { false }
        try await until(more) { steps > 0 }
        #expect(more.model.pasteQueuePosition == 1)
        more.raw.writeOK = false
        more.model.pasteQueueNext(target: more.apps.remembered) { false }
        try await until(more) { more.model.pasteQueueWarning?.contains("（1/2）") == true }
        #expect(more.model.pasteQueuePosition == 1 && more.recorder.feedback.isEmpty)
        more.raw.writeOK = true
        // 最后一项修饰键降级：队列不结束，浮窗等待确认；确认后才到 2/2 并结束。
        more.model.pasteQueueNext(target: more.apps.remembered) { true }
        try await until(more) { more.model.pasteQueueWarning?.hasPrefix("修饰键未松开") == true }
        #expect(more.model.pasteQueueAwaiting && more.model.pasteQueueActive && more.model.pasteQueuePosition == 1 && more.recorder.feedback.isEmpty)
        #expect(more.model.pasteQueueWarning == "修饰键未松开，当前项已复制，请手动粘贴（1/2）" && clipboard(more.raw) == "second")
        more.model.confirmPasteQueueManualPaste()
        #expect(!more.model.pasteQueueActive && more.recorder.feedback.last?.0 == "已确认手动粘贴 2/2" && more.recorder.feedback.last?.1 == false)
    }

    /// 快捷键冲突时不启动；少于两项不启动；手动结束注销快捷键，by AI.Coding。
    @Test func registrationAndManualStop() async throws {
        let failing = try await harness(registerOK: false); defer { try? FileManager.default.removeItem(at: failing.root) }
        failing.model.startPasteQueue(failing.ids)
        #expect(!failing.model.pasteQueueActive && failing.model.message.contains("注册冲突"))
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue([h.ids[0]])
        #expect(!h.model.pasteQueueActive && h.recorder.registered == 0)
        h.model.startPasteQueue(h.ids); h.model.stopPasteQueue()
        #expect(!h.model.pasteQueueActive && h.recorder.unregistered == 1 && h.model.pasteQueueStatus == nil)
    }

    /// LC-008：写入失败保留当前位置，重试不会跳过该项。
    @Test func failedWriteKeepsQueuePosition() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids); h.raw.writeOK = false
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.recorder.feedback.count == 2 }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0)
        h.raw.writeOK = true
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.apps.events == 1 }
        #expect(clipboard(h.raw) == "first")
    }

    /// LC-009：活动队列快捷键替换成功才持久化；冲突时保持旧配置和提示。
    @Test func activeQueueShortcutCommitAndConflict() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        try await h.model.start(); h.model.capture.stop()
        h.model.startPasteQueue(h.ids)
        let previous = h.model.settings.queueShortcut
        var proposed = previous; proposed.keyCode = previous.keyCode == 8 ? 9 : 8
        h.model.updateSettings { $0.queueShortcut = proposed }
        try await until(h) { h.model.settings.queueShortcut == proposed }
        #expect(h.model.pasteQueueStatus?.contains(HotKeyService.label(proposed)) == true)
        h.model.registerQueueShortcut = { _ in false }
        h.model.updateSettings { $0.queueShortcut = previous }
        try await until(h) { h.model.message.contains("队列快捷键注册冲突") }
        #expect(h.model.settings.queueShortcut == proposed)
        #expect(try await h.store.settings().queueShortcut == proposed)
    }

    private func copyCount(_ h: Harness, _ id: ClipID) async throws -> Int { try await h.store.search(.init()).items.first { $0.id == id }?.copyCount ?? -1 }

    /// A3：权限/目标回退（.fallback）同样停在当前项；重试成功只发送一次粘贴并只推进一次，复制次数只记一次，by AI.Coding。
    @Test func fallbackAwaitsAndRetrySendsOnce() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        let before = try await copyCount(h, h.ids[0])
        h.model.startPasteQueue(h.ids)
        h.apps.permitted = false
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.model.pasteQueueAwaiting && h.recorder.feedback.count == 2 }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0 && clipboard(h.raw) == "first")
        #expect(h.recorder.feedback.last?.0 == "当前项已复制，请授予当前LocalClip辅助功能权限后点“重试当前项”（0/3）")
        h.raw.items = [[SupportedType.string: Data("user-manual".utf8)]]
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0 && clipboard(h.raw) == "user-manual")
        #expect(h.recorder.feedback.last?.0.hasPrefix("当前项已复制，请授予") == true)
        h.apps.permitted = true
        h.model.pasteQueueNext(target: h.apps.remembered, retry: true) { false }
        h.model.pasteQueueNext(target: h.apps.remembered, retry: true) { false }   // 处理中重入被忽略
        try await until(h) { h.apps.events == 1 && !h.model.pasteQueueAwaiting }
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.apps.events == 1 && h.model.pasteQueuePosition == 1 && clipboard(h.raw) == "first")
        #expect(h.recorder.feedback.last?.0 == "已发送粘贴指令 1/3")
        #expect(try await copyCount(h, h.ids[0]) == before + 1)
        // 处理完毕后不再等待确认，下一次快捷键照常粘贴第二项。
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.apps.events == 2 }
        #expect(clipboard(h.raw) == "second" && h.model.pasteQueuePosition == 2)
    }

    /// A3：用户设置本就是仅复制时保持原推进语义，修饰键按住也不算异常回退；动作在请求开始时固定，by AI.Coding。
    @Test func copyOnlySettingKeepsAdvancing() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        try await h.model.start(); h.model.capture.stop()
        h.model.updateSettings { $0.defaultAction = .copy }
        try await until(h) { h.model.settings.defaultAction == .copy }
        h.model.startPasteQueue(h.ids)
        let before = h.recorder.feedback.count
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.recorder.feedback.count == before + 1 }
        #expect(h.model.pasteQueuePosition == 1 && !h.model.pasteQueueAwaiting && h.apps.events == 0 && clipboard(h.raw) == "first")
        #expect(h.recorder.feedback.last?.0 == "已复制 1/3" && h.recorder.feedback.last?.1 == false)
        // 原始动作为直接粘贴：等待修饰键期间改成仅复制，本次仍按降级处理并等待确认。
        h.model.updateSettings { $0.defaultAction = .directPaste }
        try await until(h) { h.model.settings.defaultAction == .directPaste }
        var held = true
        h.model.pasteQueueNext(target: h.apps.remembered) { held }
        try await Task.sleep(for: .milliseconds(30))
        h.model.updateSettings { $0.defaultAction = .copy }
        try await until(h) { h.model.pasteQueueAwaiting }
        held = false
        #expect(h.model.pasteQueuePosition == 1 && h.apps.events == 0 && clipboard(h.raw) == "second")
    }

    /// A3：等待确认的当前项已删除时，重试只跳过并说明，不顺带粘贴下一项；新建队列与结束都清除等待状态，by AI.Coding。
    @Test func retryDeletedAwaitingItemOnlySkips() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids)
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueueAwaiting }
        _ = try await h.store.apply(h.store.preview(.delete([h.ids[0]])).token)
        h.model.pasteQueueNext(target: h.apps.remembered, retry: true) { false }
        try await until(h) { h.model.pasteQueuePosition == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!h.model.pasteQueueAwaiting && h.apps.events == 0 && clipboard(h.raw) == "first")
        #expect(h.recorder.feedback.last?.0 == "第 1 项已不存在，已跳过")
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueueAwaiting }
        h.model.startPasteQueue(h.ids)
        #expect(!h.model.pasteQueueAwaiting && h.model.pasteQueuePosition == 0)
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueueAwaiting }
        h.model.stopPasteQueue()
        #expect(!h.model.pasteQueueAwaiting && !h.model.pasteQueueActive)
        h.model.confirmPasteQueueManualPaste()
        #expect(h.model.pasteQueuePosition == 0 && !h.model.pasteQueueActive)
    }

    /// A3：目标失效或已变化产生的回退同样停在当前项；重试写入失败清除等待、留在当前项，快捷键可直接再试，by AI.Coding。
    @Test func targetFallbackAndFailedRetry() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids)
        h.apps.alive = false
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.model.pasteQueueAwaiting }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0 && clipboard(h.raw) == "first" && h.recorder.feedback.last?.0 == "当前项已复制，请选择目标应用后粘贴（0/3）")
        h.apps.alive = true; h.raw.writeOK = false
        h.model.pasteQueueNext(target: h.apps.remembered, retry: true) { false }
        try await until(h) { !h.model.pasteQueueAwaiting && h.recorder.feedback.last?.0 == "复制失败，请重试（0/3）" }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0)
        h.raw.writeOK = true
        h.apps.current = TargetToken(pid: 999, bundleID: "local.other", launchedAt: 1)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.model.pasteQueueAwaiting }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0 && h.recorder.feedback.last?.0.hasPrefix("当前项已复制，目标已变化") == true)
        h.apps.current = nil
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        #expect(h.model.pasteQueuePosition == 0 && h.apps.events == 0)
        h.model.pasteQueueNext(target: h.apps.remembered, retry: true) { false }
        try await until(h) { h.apps.events == 1 }
        #expect(h.model.pasteQueuePosition == 1 && !h.model.pasteQueueAwaiting)
    }

    /// A3：重试在途时确认被忽略且按钮禁用；重试在途换新队列，旧结果不推进新队列也不进入等待，by AI.Coding。
    @Test func retryInFlightIgnoresConfirmAndNewQueue() async throws {
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids)
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueueAwaiting && !h.model.pasteQueueBusy }
        var held = true
        h.model.pasteQueueNext(target: h.apps.remembered, retry: true) { held }
        #expect(h.model.pasteQueueBusy)
        h.model.confirmPasteQueueManualPaste()
        #expect(h.model.pasteQueuePosition == 0 && h.model.pasteQueueAwaiting)
        h.model.startPasteQueue(Array(h.ids.reversed()))
        held = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.model.pasteQueuePosition == 0 && !h.model.pasteQueueAwaiting && !h.model.pasteQueueBusy && h.apps.events == 0)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.apps.events == 1 }
        #expect(clipboard(h.raw) == "third")
    }

    /// A3：等待确认时浮窗显示两个按钮，宽度不超出浮窗，高度大于普通状态，by AI.Coding。
    @Test func awaitingPanelLayoutFits() async throws {
        _ = NSApplication.shared
        let h = try await harness(); defer { h.model.stopPasteQueue(); try? FileManager.default.removeItem(at: h.root) }
        h.model.showsQueuePanel = true
        h.model.startPasteQueue(h.ids)
        let normal = NSHostingView(rootView: PasteQueueView(model: h.model)).fittingSize
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueueAwaiting && h.model.pasteQueueWarning != nil }
        let awaiting = NSHostingView(rootView: PasteQueueView(model: h.model)).fittingSize
        #expect(awaiting.width <= 262 && awaiting.height > normal.height)
    }
}
