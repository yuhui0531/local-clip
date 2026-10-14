// F19连续粘贴队列：真实临时SQLite + fake剪贴板与目标应用，验证顺序、忽略重入、修饰键回退、跳过已删项与快捷键注册，by AI.Coding。
import Foundation
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
        let deadline = ContinuousClock.now + .seconds(5)
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

    /// 修饰键500ms未松开只复制并提示；已删项跳过并说明；没有外部目标不前进，by AI.Coding。
    @Test func modifiersDeletedItemsAndMissingTarget() async throws {
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        h.model.startPasteQueue(h.ids)
        h.model.pasteQueueNext(target: nil) { false }
        #expect(h.model.pasteQueuePosition == 0 && h.recorder.feedback.last?.0 == "请先切换到要粘贴的应用")
        let began = ContinuousClock.now
        h.model.pasteQueueNext(target: h.apps.remembered) { true }
        try await until(h) { h.model.pasteQueuePosition == 1 && h.recorder.feedback.count == 3 }
        #expect(ContinuousClock.now - began >= .milliseconds(500))
        #expect(h.apps.events == 0 && clipboard(h.raw) == "first" && h.recorder.feedback.last?.0.hasPrefix("修饰键未松开") == true)
        _ = try await h.store.apply(h.store.preview(.delete([h.ids[1]])).token)
        h.model.pasteQueueNext(target: h.apps.remembered) { false }
        try await until(h) { h.recorder.feedback.count == 4 }
        #expect(clipboard(h.raw) == "third" && h.recorder.feedback.last?.0 == "已发送粘贴指令 3/3（第 2 项已不存在，已跳过）")
        try await until(h) { !h.model.pasteQueueActive }
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
}
