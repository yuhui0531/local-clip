// 历史管理窗口模型：页码、总数、筛选、删除撤销与按键路由，不创建窗口，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac
@MainActor struct HistoryManagerTests {
    /// 超时记为失败，等待之后没有断言的步骤也不会静默通过。
    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { Issue.record("等待条件超时", sourceLocation: sourceLocation) }
    }
    private func make(_ count: Int) async throws -> (HistoryManagerModel, HistoryStore, ManagerClock, [ClipID], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = ManagerClock(), store = try HistoryStore(location: root, clock: clock)
        var ids: [ClipID] = []
        for index in 0..<count {
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("row-\(index)".utf8))])])), at: clock.now()) else { throw StoreError.ioFailure }
            ids.append(id); clock.advance(1)
        }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store, clock: clock)
        let history = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture, clock: clock), derived: DerivedContentService(store: store), clock: clock)
        try await history.start(); capture.stop()
        let model = HistoryManagerModel(history: history)
        model.pageSize = 25; model.start()
        try await until { model.rows.count == min(25, count) && model.total == count }
        return (model, store, clock, ids.reversed(), root)
    }
    @Test func pagesTotalsAndPageSizes() async throws {
        let (model, _, _, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(model.rows.map(\.id) == Array(newest[0..<25]) && model.pageCount == 3 && model.rangeText == "1–25，共 60 条")
        model.go(toPage: 2)
        try await until { model.rows.count == 10 }
        #expect(model.rows.map(\.id) == Array(newest[50...]) && model.rangeText == "51–60，共 60 条")
        // 每页100需两次取页；改每页回到首页。
        model.pageSize = 100
        try await until { model.rows.count == 60 }
        #expect(model.page == 0 && model.pageCount == 1)
        model.literal = "row-5"
        try await until { model.total == 11 }
        #expect(model.rows.count == 11)
    }
    @Test func scopeAndCategoryMemberships() async throws {
        let (model, store, _, newest, root) = try await make(5)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let category = try await store.createCategory(name: "工作", colorHex: "007AFF")
        _ = try await store.apply(try await store.preview(.category([newest[1]], category.id, true)).token)
        try await until { model.memberships[newest[1]] == [category.id] }
        model.scope = .category(category.id)
        try await until { model.rows.map(\.id) == [newest[1]] }
        #expect(model.total == 1)
        model.scope = .kind(.image)
        try await until { model.total == 0 }
        model.scope = .all; model.time = .today
        try await until { model.total == 5 }
    }
    @Test func deleteClampsPageAndUndoRestores() async throws {
        let (model, _, _, newest, root) = try await make(26)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.go(toPage: 1)
        try await until { model.rows.map(\.id) == [newest[25]] }
        model.selection = [newest[25]]
        // 文字编辑中⌫交给文本框；结果区才删除。
        #expect(!model.handleKey(code: 51, flags: [], editing: true))
        #expect(model.handleKey(code: 51, flags: [], editing: false))
        try await until { model.page == 0 && model.total == 25 }
        #expect(model.rows.count == 25 && model.canUndo && model.toast?.undo == true)
        #expect(model.handleKey(code: 6, flags: .command, editing: false))
        try await until { model.total == 26 }
    }
    @Test func escapeClearsOnlyMultiSelection() async throws {
        let (model, _, _, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[0]]
        #expect(!model.handleKey(code: 53, flags: [], editing: false))
        model.selection = [newest[0], newest[1]]
        #expect(model.targetIDs == [newest[0], newest[1]])
        #expect(model.handleKey(code: 53, flags: [], editing: false) && model.selection.isEmpty)
        model.selectAllMatching()
        try await until { model.allMatching?.count == 3 }
        #expect(model.targetIDs == newest)
    }
    @Test func revealJumpsToRecordPage() async throws {
        let (model, _, _, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.literal = "row-1"; try await until { model.total == 11 }
        model.reveal([newest[55], newest[56]])
        try await until { model.selection == [newest[55], newest[56]] }
        #expect(model.page == 2 && model.literal.isEmpty && model.total == 60)
    }
    @Test func hiddenContentsBlocksWrites() async throws {
        let (model, _, _, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[0]]
        model.history.updateSettings { $0.hideContents = true }
        try await until { !model.history.canDisplayContents }
        #expect(!model.handleKey(code: 51, flags: [], editing: false))
        #expect(!model.handleKey(code: 2, flags: .command, editing: false))
        model.delete([newest[0]]); model.selectAllMatching()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.total == 3 && model.allMatching == nil && !model.selectingAll)
    }
    @Test func repeatedDeleteKeepsUndo() async throws {
        let (model, store, _, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[0]]
        #expect(model.handleKey(code: 51, flags: [], editing: false) && model.handleKey(code: 51, flags: [], editing: false))
        try await until { model.total == 2 && model.toast?.undo == true }
        // 提交前已移出选择；之后再按⌫没有目标。
        #expect(model.selection.isEmpty)
        _ = model.handleKey(code: 51, flags: [], editing: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await store.undoAvailable() && model.toast?.undo == true)
    }
    @Test func selectAllCancelledByFilterChange() async throws {
        let (model, _, _, _, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selectAllMatching()
        #expect(model.selectingAll)
        model.scope = .favorites
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.allMatching == nil && !model.selectingAll)
    }
    @Test func hundredPerPageUsesTwoReads() async throws {
        let (model, _, _, newest, root) = try await make(160)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.pageSize = 100
        try await until { model.rows.count == 100 }
        #expect(model.rows.map(\.id) == Array(newest[0..<100]))
        model.go(toPage: 1)
        try await until { model.rows.count == 60 }
        #expect(model.rows.map(\.id) == Array(newest[100...]))
    }
    @Test func unrelatedCaptureDoesNotReloadDetail() async throws {
        let (model, store, clock, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[1]]
        try await until { model.detail?.detail.summary.id == newest[1] }
        let loads = model.detailLoads
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("new".utf8))])])), at: clock.now())
        try await until { model.total == 4 }
        #expect(model.detailLoads == loads && model.selection == [newest[1]])
    }
    @Test func copyKeysYieldWithoutSelectionOrToTextSelection() async throws {
        let (model, _, _, _, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(!model.handleKey(code: 8, flags: .command, editing: false))
        let text = NSTextView(); text.isEditable = false; text.string = "abc"
        #expect(!AppDelegate.managerTextOwnsKeys(text) && !AppDelegate.managerTextOwnsKeys(nil))
        text.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(AppDelegate.managerTextOwnsKeys(text))
    }
}
private final class ManagerClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = SystemClock().now()
    func now() -> Instant { lock.withLock { value } }
    func advance(_ delta: Instant) { lock.withLock { value += delta } }
}
