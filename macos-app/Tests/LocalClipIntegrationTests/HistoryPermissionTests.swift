// 授权警告生命周期回归：临时数据库、假权限与内存剪贴板，不操作桌面，by AI.Coding。
import Foundation
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct HistoryPermissionTests {
    /// 走真实粘贴回退与状态发布链，不直接伪造待授权标记。
    private func deniedPaste(root: URL) async throws -> (HistoryViewModel, FakeApplications) {
        let store = try HistoryStore(location: root)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("permission regression".utf8))])])), at: SystemClock().now())
        let id = try #require(try await store.search(.init()).items.first?.id)
        let board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let apps = FakeApplications(); apps.permitted = false
        let paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
        model.perform(action: .directPaste, ids: [id])
        try await until { model.message == PasteResult.fallback(PasteCoordinator.permissionFallbackReason).message }
        return (model, apps)
    }
    /// 有界等待真实异步任务，失败时不无限挂起。
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
    /// 在第一次粘贴写入后、焦点稳定前重入两个入口，保留第一次的结果，by AI.Coding。
    @Test func repeatedPasteProducesNoFailureFeedback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let payload = ClipboardPayload([.init([.init(SupportedType.string, Data("paste feedback".utf8))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else {
            Issue.record("未保存测试记录")
            return
        }
        let board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let apps = FakeApplications()
        let paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
        try await model.start()
        capture.stop()
        try await until { model.items.contains { $0.id == id } }
        model.select(id)
        model.target = apps.remembered
        var feedback: [Bool] = []
        model.showPasteFeedback = { _, failed in feedback.append(failed) }
        apps.onRestore = { [weak model] in
            model?.perform(action: .directPaste, ids: [id])
            model?.doubleClick(id)
        }
        model.perform(action: .directPaste, ids: [id])
        try await until { apps.events == 1 && model.message == PasteResult.commandSent.message }
        #expect(feedback.isEmpty)
    }

    /// 回退内容已写入测试剪贴板；提示使用复制图标，by AI.Coding。
    @Test func fallbackUsesClipboardFeedback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let data = Data("fallback content".utf8)
        let payload = ClipboardPayload([.init([.init(SupportedType.string, data)])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else {
            Issue.record("未保存测试记录")
            return
        }
        let raw = RawBoard()
        let board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture)
        let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
        var feedback: [Bool] = []
        model.showPasteFeedback = { _, failed in feedback.append(failed) }
        model.perform(action: .directPaste, ids: [id])
        try await until { !feedback.isEmpty }
        #expect(feedback == [false])
        #expect(raw.items.first?[SupportedType.string] == data)
    }

    /// 置顶可见时自动同步；隐藏期间授权则重开立即同步，且不能补发旧粘贴。
    @Test(arguments: [false, true]) func grantedPermissionClearsOnlyPendingWarning(reopen: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, apps) = try await deniedPaste(root: root)
        defer { model.panelVisibilityChanged(false) }
        try await Task.sleep(for: .milliseconds(650))
        #expect(!model.message.isEmpty && model.messageSeverity == .failure)
        if reopen { model.panelVisibilityChanged(false) }
        apps.permitted = true
        if reopen {
            try await Task.sleep(for: .milliseconds(650))
            #expect(!model.message.isEmpty)
            model.panelVisibilityChanged(true)
            #expect(model.message.isEmpty)
        }
        try await until { model.message.isEmpty }
        #expect(apps.events == 0 && apps.activations == 0)
    }
    /// 授权期间出现新错误，旧轮询不得覆盖它；手动关闭同样终止观察。
    @Test(arguments: [false, true]) func supersededWarningDoesNotClearLaterMessage(dismiss: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, apps) = try await deniedPaste(root: root)
        defer { model.panelVisibilityChanged(false) }
        if dismiss { model.dismissMessage() }
        model.message = "历史查询失败，请重试"
        apps.permitted = true
        try await Task.sleep(for: .milliseconds(750))
        model.panelVisibilityChanged(false); model.panelVisibilityChanged(true)
        #expect(model.message == "历史查询失败，请重试" && model.messageSeverity == .failure)
        #expect(apps.events == 0 && apps.activations == 0)
    }
}
