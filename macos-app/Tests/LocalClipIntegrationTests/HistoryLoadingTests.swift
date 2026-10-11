// 视口分页、稳定滚动锚点和原生分类接收的回归；数据与剪贴板均隔离，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct HistoryLoadingTests {
    private func makeModel(_ store: HistoryStore) -> HistoryViewModel {
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        return HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
    }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    private func seed(_ store: HistoryStore, count: Int) async throws {
        let at = SystemClock().now()
        for index in 0..<count { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("page-item-\(index)".utf8))])])), at: at + Int64(index)) }
    }
    /// 首屏、合并预读、键盘越页和乱序筛选验证真实模型/SQLite，不依赖GUI输入工具，by AI.Coding。
    @Test func viewportPagingAndQueryCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 160)
        let model = makeModel(store); model.configureHistoryViewport(width: 1000, cardWidth: 200)
        try await model.start(); model.capture.stop()
        try await until { !model.loading && model.items.count == 5 }
        let first = model.selectedID, expected = try await store.search(.init()).items.map(\.id)
        for _ in 0..<100 { model.historyScrolled(offset: 0) }
        try await Task.sleep(for: .milliseconds(60)); #expect(model.items.count == 5)
        for _ in 0..<100 { model.historyScrolled(offset: 30) }
        try await until { !model.loading && model.items.count == 15 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.items.count == 15); #expect(model.selectedID == first)
        #expect(model.items.map(\.id) == Array(expected.prefix(15)))
        model.select(model.items.last?.id); model.navigate(1)
        try await until { !model.loading && model.items.count == 25 }
        #expect(model.selectedID == expected[15])
        model.loadMore(); model.query = "page-item-149"; model.searchChanged()
        try await until { !model.loading && model.items.count == 1 }
        #expect(model.items[0].preview == "page-item-149")
        #expect(model.scrollRestoration?.offset == 0)
        model.query = ""; model.searchChanged(); try await until { !model.loading && model.items.count == 5 }
        #expect(model.items.map(\.id) == Array(expected.prefix(5)))
        model.select(model.items.last?.id); model.historyScrolled(offset: 30); model.extendNavigation(1)
        try await until { !model.loading && model.items.count == 15 }
        #expect(model.selectedID == expected[5]); #expect(model.selectedIDs == [expected[4], expected[5]])
    }
    /// 捕获插入不能移动正在浏览的卡片；详情和多选仍以原ID保存，by AI.Coding。
    @Test func viewportRefreshPreservesScrollAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 80)
        let model = makeModel(store); model.configureHistoryViewport(width: 1000, cardWidth: 200)
        try await model.start(); model.capture.stop(); try await until { !model.loading && model.items.count == 5 }
        model.configureHistoryViewport(width: 1000, cardWidth: 200)
        model.historyScrolled(offset: 500); try await until { !model.loading && model.items.count == 15 }
        let selected = model.items[2].id, second = model.items[3].id
        model.choose(selected, modifiers: []); model.choose(second, modifiers: .command)
        model.showingDetail = true; model.detailVisibilityChanged()
        try await until { model.detail?.summary.id == second }
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("new-page-head".utf8))])])), at: SystemClock().now() + 1000)
        try await until { !model.loading && model.items.first?.preview == "new-page-head" }
        #expect(model.scrollRestoration?.offset == 716)
        #expect(model.selectedID == second); #expect(model.selectedIDs == [selected, second])
        #expect(model.detail?.summary.id == second); #expect(model.items.count == 16)
        model.historyScrolled(offset: 716)
        let beforeAnchor = model.items[1].id
        let preview = try await store.preview(.delete([beforeAnchor])); _ = try await store.apply(preview.token)
        try await until { !model.loading && !model.items.contains { $0.id == beforeAnchor } }
        #expect(model.items.first?.preview == "new-page-head"); #expect(model.scrollRestoration?.offset == 500)
        #expect(model.selectedIDs == [selected, second]); #expect(model.detail?.summary.id == second)
        model.loadMore(); try await until { !model.loading && model.items.count == 26 }
        #expect(Set(model.items.map(\.id)).count == model.items.count)
    }
    /// 查询或预读期间视口增大，补屏只取缺口，不能多取两整屏，by AI.Coding。
    @Test func resizeWhileLoadingFillsLatestViewport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 80)
        let model = makeModel(store); model.configureHistoryViewport(width: 1000, cardWidth: 200)
        try await model.start(); model.capture.stop()
        model.configureHistoryViewport(width: 1800, cardWidth: 200)
        try await until { !model.loading && model.items.count == 9 }
        model.loadMore(); model.configureHistoryViewport(width: 3000, cardWidth: 80)
        try await until { !model.loading && model.items.count == 31 }
        #expect(Set(model.items.map(\.id)).count == 31)
    }
    /// End/全选接管预读且可重复按，不重复追加同一页或漏掉末尾记录，by AI.Coding。
    @Test func bulkNavigationOwnsPrefetch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 100)
        let model = makeModel(store); model.configureHistoryViewport(width: 1000, cardWidth: 200)
        try await model.start(); model.capture.stop(); try await until { !model.loading && model.items.count == 5 }
        model.historyScrolled(offset: 30); model.edgeSelection(true, extend: false); model.edgeSelection(true, extend: false)
        try await until { !model.loading && !model.hasMore }
        #expect(model.items.count == 100); #expect(Set(model.items.map(\.id)).count == 100)
        #expect(model.selectedID == model.items.last?.id)
        model.searchChanged(); try await until { !model.loading && model.items.count == 5 }
        model.historyScrolled(offset: 30); model.selectAllResults(); model.selectAllResults()
        try await until { !model.loading && !model.hasMore }
        #expect(model.items.count == 100); #expect(Set(model.items.map(\.id)).count == 100)
        #expect(model.selectedIDs.count == 100)
    }
    /// 消费原生会话的抬起会阻断分类放下；回归直接经过生产事件处理方法，by AI.Coding。
    @Test func nativeSessionReceivesDragAndMouseUp() throws {
        let view = HistoryDragBridge.DragView(frame: .zero)
        view.handPointerToNativeSession()
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            #expect(view.handle(event) === event)
        }
    }
    /// 公开提供者→真实命名剪贴板→分类原生按钮→持久归属，伪造/重放令牌拒绝，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func namedDragWritersPersistCustomCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 3)
        let category = try await store.createCategory(name: "Drag target", colorHex: "34C759")
        let model = makeModel(store); try await model.start(); model.capture.stop()
        try await until { !model.loading && model.items.count == 3 && model.categories.contains { $0.id == category.id } }
        let ids = [model.items[0].id, model.items[1].id]
        model.choose(ids[0], modifiers: []); model.choose(ids[1], modifiers: .command)
        let token = model.prepareDrag(ids[0])
        let writers = try await ContentExportProvider.writers(ids: model.orderedSelection, store: store, token: token, register: model.registerDragAccess)
        let board = NSPasteboard(name: .init("local.localclip.category-regression." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType(HistoryViewModel.categoryDragType)
        #expect(writers.count == 2)
        #expect(writers.allSatisfy { $0.writingOptions?(forType: type, pasteboard: board) == [] })
        #expect(board.writeObjects(writers)); #expect(board.data(forType: type) == Data(token.utf8))
        let target = CategoryDropTarget.CategoryButton(); target.model = model; target.category = category
        #expect(target.acceptedToken(from: board) == token)
        #expect(target.performCategoryDrop(from: board)); #expect(!target.performCategoryDrop(from: board))
        model.finishDrag(cancelled: false)
        try await until { model.message.contains("加入") && !model.loading }
        for id in ids { #expect(try await store.metadata(id: id, at: SystemClock().now()).categoryIDs.contains(category.id)) }
        #expect(try await store.metadata(id: model.items[2].id, at: SystemClock().now()).categoryIDs.isEmpty)
        board.clearContents(); #expect(board.setData(Data(UUID().uuidString.utf8), forType: type))
        #expect(target.acceptedToken(from: board) == nil)
    }

    /// 同一10k/真实图像库比较固定50条和视口批次，计时仅到摘要返回，不宣称帧率，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_LOADING_BENCHMARK"] == "1"))
    func viewportLoadingBenchmark() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_LOADING_OUTPUT"]!)
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_LOADING_FIXTURE"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let clone = output.appendingPathComponent("fixture-store")
        try FileManager.default.copyItem(at: source, to: clone)
        let store = try HistoryStore(location: clone)
        func ms(_ start: ContinuousClock.Instant) -> Double { let d = start.duration(to: .now); return Double(d.components.seconds)*1000 + Double(d.components.attoseconds)/1e15 }
        var fixed: [Double] = [], viewport: [Double] = [], subsequent: [Double] = []
        var fixedBytes = 0, viewportBytes = 0
        let size = 10 // 1920pt视口、179pt正方形卡片：实际首屏10条。
        for index in 0..<200 {
            // 交替顺序，避免总让第二组受益于页缓存预热。
            for count in (index % 2 == 0 ? [50, size] : [size, 50]) {
                let start = ContinuousClock.now; let page = try await store.search(.init(pageSize: count)); let duration = ms(start)
                #expect(page.items.count == count)
                let bytes = page.items.reduce(0) { $0 + $1.preview.utf8.count + $1.context.utf8.count }
                if count == 50 { fixed.append(duration); fixedBytes = bytes }
                else { viewport.append(duration); viewportBytes = bytes
                    let nextStart = ContinuousClock.now; let following = try await store.search(.init(cursor: page.next, pageSize: size * 2)); subsequent.append(ms(nextStart))
                    #expect(following.items.count == size * 2); #expect(Set(page.items.map(\.id)).isDisjoint(with: following.items.map(\.id)))
                }
            }
        }
        func metrics(_ values: [Double]) -> [String: Any] { let sorted = values.sorted(); return ["n":values.count,"samplesMs":values,"p95Ms":sorted[Int(ceil(Double(sorted.count)*0.95))-1],"maxMs":sorted.last!] }
        let report: [String:Any] = ["boundary":"Current Release HistoryStore search call-to-return; same code, fixed50 vs viewport10; excludes AppKit draw/input and startup", "fixed50":metrics(fixed),"viewport10":metrics(viewport),"prefetch20":metrics(subsequent),"initialRowReductionPercent":80,"fixedPreviewAndContextBytes":fixedBytes,"viewportPreviewAndContextBytes":viewportBytes]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("loading-results.json"))
    }
}
