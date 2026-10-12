// 列表发布与延迟元数据读取的隔离回归，by AI.Coding。
import AppKit
import Combine
import SwiftUI
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct ReviewMetadataLoadingTests {
    /// 定位接管防抖中的查询后，成功、空分类与新输入都必须释放逻辑忙碌状态，by AI.Coding。
    @Test(arguments: ["success", "missing-category", "new-input"])
    func jumpOwnsPendingQueryLifecycle(outcome: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for index in 0..<12 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("jump-\(index)".utf8))])])), at: SystemClock().now()) }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        model.configureHistoryViewport(width: 1000, cardWidth: 200)
        try await model.start(); capture.stop(); try await until { !model.historyBusy }
        model.query = "jump"; model.searchChanged(); #expect(model.historyBusy)
        model.jumpToHistory(category: outcome == "missing-category" ? "missing-category" : nil)
        if outcome == "new-input" { model.query = "jump-3"; model.searchChanged() }
        try await until { !model.historyBusy }
        if outcome == "new-input" { #expect(model.query == "jump-3"); #expect(model.items.count == 1) }
        else if outcome == "success" {
            #expect(model.query.isEmpty); model.selectAllResults()
            try await until { !model.historyBusy && model.selectedIDs.count == 12 }
        } else { #expect(model.message.contains("记录已删除")) }
        try await Task.sleep(for: .milliseconds(120)); #expect(!model.historyBusy); #expect(!model.loading)
    }
    /// 离屏宿主验证重新打开的焦点令牌传到原生搜索框，不显示窗口，by AI.Coding。
    @Test func hostedSearchReceivesNewFocusToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await until { !model.historyBusy }
        let host = NSHostingView(rootView: HistoryView(model: model)), window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1440, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
        host.sizingOptions = []; window.contentView = host; host.frame = .init(x: 0, y: 0, width: 1440, height: 340)
        func searchField(_ view: NSView) -> NSSearchField? { (view as? NSSearchField) ?? view.subviews.lazy.compactMap(searchField).first }
        try await until { host.layoutSubtreeIfNeeded(); return searchField(host)?.delegate is SearchField.Coordinator }
        let field = try #require(searchField(host)), coordinator = try #require(field.delegate as? SearchField.Coordinator)
        let next = UUID(); model.focusRequest = next
        try await until { host.layoutSubtreeIfNeeded(); return coordinator.focus == next }
        #expect(coordinator.parent.focus == next); #expect(!window.isVisible)
    }
    /// 快查询不闪加载；列表与选择一次发布，输入和选择元数据不通知主界面，by AI.Coding。
    @Test func atomicListPublicationDoesNotInvalidateChrome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for text in ["atomic-first", "atomic-last"] {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: SystemClock().now())
        }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await until { !model.historyBusy && model.selectedMetadata != nil }
        var chromeChanges = 0, resultPublications = 0, footerResultPublications = 0, firstResult: HistoryListState.Snapshot?
        let chrome = model.objectWillChange.sink { chromeChanges += 1 }
        let list = model.listState.$snapshot.dropFirst().sink { snapshot in
            if snapshot.items.count == 1, snapshot.items.first?.preview == "atomic-first", snapshot.loading == false,
               snapshot.selectedID == snapshot.items.first?.id, snapshot.selectedIDs == Set(snapshot.items.map(\.id)) {
                resultPublications += 1
                if firstResult == nil { firstResult = snapshot }
            }
        }
        let footer = model.listState.footerState.$snapshot.dropFirst().sink { snapshot in
            if let firstResult, snapshot.itemCount == 1, snapshot.selectedID == firstResult.selectedID,
               snapshot.selectedCount == 1, snapshot.loading == false, snapshot.selectedMetadata == nil {
                footerResultPublications += 1
            }
        }
        defer { chrome.cancel(); list.cancel(); footer.cancel() }
        model.query = "atomic-first"; model.searchChanged()
        #expect(model.historyBusy); #expect(!model.loading)
        try await until { !model.historyBusy }
        #expect(model.items.count == 1)
        #expect(resultPublications == 1)
        #expect(footerResultPublications == 1)
        #expect(firstResult?.selectedID == firstResult?.items.first?.id)
        #expect(firstResult?.selectedIDs == Set(firstResult?.items.map(\.id) ?? []))
        #expect(firstResult?.loading == false); #expect(chromeChanges == 0)
        #expect(model.listState.footerState.snapshot.selectedID == model.items.first?.id)
        #expect(model.listState.footerState.snapshot.selectedCount == 1)
        try await until { model.selectedMetadata?.summary.id == model.items.first?.id }
        #expect(chromeChanges == 0)
        #expect(resultPublications == 1)
        #expect(model.listState.footerState.snapshot.selectedMetadata == model.selectedMetadata)
    }
    /// 隔离库锁只用于延迟查询；100ms后才显示加载，解锁后保留最终查询与分页，by AI.Coding。
    @Test func loadingDelayKeepsLogicalQueryGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("delayed-query".utf8))])])), at: SystemClock().now())
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await until { !model.historyBusy && model.selectedMetadata != nil }
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try db.exec("BEGIN EXCLUSIVE")
        defer { try? db.exec("ROLLBACK"); try? db.close() }
        model.query = "delayed"; model.searchChanged()
        #expect(model.historyBusy); #expect(!model.loading)
        model.loadMore(); model.selectAllResults(); model.edgeSelection(true, extend: false)
        let loadingStarted = ContinuousClock.now
        try await until { model.loading }
        #expect(loadingStarted.duration(to: .now) >= .milliseconds(90))
        #expect(model.loading); #expect(model.historyBusy)
        try db.exec("COMMIT")
        try await until { !model.historyBusy && !model.loading && model.items.first?.preview == "delayed-query" }
    }
    /// 成功的收藏、分类创建与重命名只由提交事件启动一次窗口查询，by AI.Coding。
    @Test func oneWindowQueryPerMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("single-refresh".utf8))])])), at: SystemClock().now())
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await until { !model.historyBusy && model.items.count == 1 }
        #if DEBUG
        var previous = model.historyWindowQueryCount
        var previousRefresh = model.historyWindowRefreshCount
        #endif
        model.change(.favorites([model.items[0].id], true))
        try await until { !model.historyBusy && model.items.first?.isFavorite == true && model.message.contains("已保存") }
        try await Task.sleep(for: .milliseconds(60))
        #if DEBUG
        #expect(model.historyWindowQueryCount - previous == 1)
        #expect(model.historyWindowRefreshCount - previousRefresh == 1)
        previous = model.historyWindowQueryCount
        previousRefresh = model.historyWindowRefreshCount
        #endif
        model.editCategory(); model.categoryDraft = "Single refresh"; model.saveCategory()
        try await until { !model.savingCategory && !model.historyBusy && model.categories.count == 1 && model.items.isEmpty }
        try await Task.sleep(for: .milliseconds(60))
        #if DEBUG
        #expect(model.historyWindowQueryCount - previous == 1)
        #expect(model.historyWindowRefreshCount - previousRefresh == 1)
        previous = model.historyWindowQueryCount
        previousRefresh = model.historyWindowRefreshCount
        #endif
        model.editCategory(model.categories[0]); model.categoryDraft = "Renamed"; model.saveCategory()
        try await until { !model.savingCategory && !model.historyBusy && model.categories.first?.name == "Renamed" }
        try await Task.sleep(for: .milliseconds(60))
        #if DEBUG
        #expect(model.historyWindowQueryCount - previous == 1)
        #expect(model.historyWindowRefreshCount - previousRefresh == 1)
        #endif
    }
    /// 真正的采集回调在隐藏时只失效，打开发布新卡片后再补来源缓存，by AI.Coding。
    @Test func unseenCapturedSourceWaitsForVisibleRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        let first = SourceAttribution(bundleID: "test.source.cached", name: "Cached")
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("cached".utf8))])]), source: first), at: SystemClock().now())
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); model.showingFilters = true
        try await until { model.sourceSuggestions.contains(first) }
        var sourcePublications = 0
        let observation = model.$sourceSuggestions.dropFirst().sink { sources in
            sourcePublications += 1
            if sources.contains(where: { $0.bundleID == "test.source.unseen" }) {
                #expect(model.items.first?.preview == "new-source-capture")
            }
        }
        defer { observation.cancel() }
        model.showingFilters = false; model.showingFilters = true
        try await Task.sleep(for: .milliseconds(60))
        #expect(sourcePublications == 0)
        model.showingFilters = false; model.panelVisibilityChanged(false)
        var committed = false; capture.onCommit = { committed = true }
        raw.user("new-source-capture")
        raw.items[0]["org.nspasteboard.source"] = Data("test.source.unseen".utf8)
        capture.tick(); try await until { committed }
        #expect(!model.sourceSuggestions.contains { $0.bundleID == "test.source.unseen" })
        model.panelVisibilityChanged(true)
        try await until { model.items.first?.preview == "new-source-capture" && model.sourceSuggestions.contains { $0.bundleID == "test.source.unseen" } }
        #expect(sourcePublications == 1)
    }
    /// 临时库一次读取失败后，显式刷新必须重新读取分类并恢复，无需额外提交，by AI.Coding。
    @Test func metadataFailureDoesNotPoisonRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for value in ["recover-A", "recover-B"] {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(value.utf8))])])), at: SystemClock().now())
        }
        let category = try await store.createCategory(name: "Gone", colorHex: "34C759")
        let id = try await store.search(.init()).items[0].id
        _ = try await store.apply(store.preview(.category([id], category.id, true)).token)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        model.selectCategories([category.id]); try await model.start(); capture.stop()
        try await until { model.items.count == 1 && !model.historyBusy }
        model.panelVisibilityChanged(false)
        _ = try await store.apply(store.preview(.deleteCategory(category.id)).token)
        try await Task.sleep(for: .milliseconds(60))
        let database = root.appendingPathComponent("History"), held = root.appendingPathComponent("held-history")
        try FileManager.default.moveItem(at: database, to: held)
        defer { if FileManager.default.fileExists(atPath: held.path) { try? FileManager.default.moveItem(at: held, to: database) } }
        model.panelVisibilityChanged(true)
        try await until { !model.historyBusy && model.items.isEmpty }
        try FileManager.default.moveItem(at: held, to: database)
        model.refresh()
        try await until { !model.historyBusy && model.items.count == 2 && model.activeCategories.isEmpty }
    }
    /// 外部删除分类后，无宿主视图也必须按新筛选发布，by AI.Coding。
    @Test(arguments: [false, true]) func deletedCategoryPrunesBeforeQuery(hidden: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for value in ["category-A", "category-B"] {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(value.utf8))])])), at: SystemClock().now())
        }
        let category = try await store.createCategory(name: "Gone", colorHex: "34C759")
        let id = try await store.search(.init()).items[0].id
        _ = try await store.apply(store.preview(.category([id], category.id, true)).token)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        model.selectCategories([category.id]); try await model.start(); capture.stop()
        try await until { model.items.count == 1 && !model.historyBusy }
        if hidden { model.panelVisibilityChanged(false) }
        _ = try await store.apply(store.preview(.deleteCategory(category.id)).token)
        if hidden {
            try await Task.sleep(for: .milliseconds(30)); model.panelVisibilityChanged(true)
        }
        try await until { model.activeCategories.isEmpty && model.items.count == 2 && !model.historyBusy }
    }
    /// 状态文字不变时仍发布新的忽略原因与时间，by AI.Coding。
    @Test func sameStatusStillPublishesCaptureIgnore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await until { !model.historyBusy }
        let status = model.status
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        for _ in 0..<2 {
            let previous = updates
            try await Task.sleep(for: .milliseconds(5))
            raw.count += 1; raw.items = [["test.unsupported": Data()]]; capture.tick()
            #expect(model.status == status)
            #expect(model.ignoreDescription.contains("无支持格式"))
            #expect(updates > previous)
        }
    }
    /// 等待真实模型完成异步工作，超时保留失败而不略过样本，by AI.Coding。
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    /// 旧来源与空间不阻塞首屏；筛选开启后新来源仍可选择，by AI.Coding。
    @Test func listDoesNotEagerlyReadSourcesOrUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        let source = SourceAttribution(bundleID: "test.source.first", name: "First")
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("first".utf8))])]), source: source), at: SystemClock().now())
        try await model.start(); capture.stop()
        try await until { model.items.count == 1 && !model.historyBusy }
        #expect(model.sourceSuggestions.isEmpty)
        #expect(model.usage == nil)
        model.showingFilters = true
        try await until { model.sourceSuggestions.contains(source) }
        let next = SourceAttribution(bundleID: "test.source.second", name: "Second")
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("second".utf8))])]), source: next), at: SystemClock().now() + 1000)
        try await until { model.items.first?.preview == "second" && model.sourceSuggestions.contains(next) }
        #expect(model.usage == nil)
        model.settingsVisibilityChanged(true)
        try await until { model.usage != nil }
        #expect(model.usage == (try await store.usage()))
        model.settingsVisibilityChanged(false)
    }
}
