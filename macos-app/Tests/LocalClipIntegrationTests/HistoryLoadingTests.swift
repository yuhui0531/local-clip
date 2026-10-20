// 视口分页、稳定滚动锚点和原生分类接收的回归；数据与剪贴板均隔离，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

extension HistoryStore {
    /// 测试切换既有不可用状态，模拟查询失败而不损坏数据库。
    func setUnavailableForTesting(_ value: Bool) { unavailable = value }
}

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
    /// F20 AC1：搜索框前缀与筛选面板选同样条件得到相同结果，状态行列出已生效条件，by AI.Coding。
    @Test func searchPrefixesMatchPanelFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), at = SystemClock().now()
        let xcode = SourceAttribution(bundleID: "com.apple.dt.Xcode", name: "Xcode"), safari = SourceAttribution(bundleID: "com.apple.Safari", name: "Safari")
        let image = try ImageFixtures.image(width: 4, height: 4)
        for (index, (payload, source)) in [(ClipboardPayload([.init([.init(SupportedType.png, image)])]), xcode),
                                           (.init([.init([.init(SupportedType.string, Data("xcode text".utf8))])]), xcode),
                                           (.init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 5, height: 5))])]), safari)].enumerated() {
            _ = try await store.ingest(.init(payload: payload, source: source), at: at + Int64(index))
        }
        let model = makeModel(store); try await model.start(); model.capture.stop()
        try await until { !model.historyBusy && model.items.count == 3 }
        model.query = "app:xcode type:image"; model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.items.count == 1 }
        let viaPrefix = model.items.map(\.id)
        #expect(model.queryConditions == ["来源 Xcode", "类型 图片"] && model.queryProblems.isEmpty)
        model.query = ""; model.sourceFilter = xcode.bundleID; model.kind = .image; model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.items.count == 1 }
        #expect(model.items.map(\.id) == viaPrefix && model.queryConditions.isEmpty)
        model.sourceFilter = nil; model.kind = nil; model.query = "app:nothing"; model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.queryProblems == ["未找到来源 nothing"] }
        #expect(model.items.count == 3)
    }
    /// A1-1/2：临时库中 in:"带空格分类" 与点击该分类得到同一集合，并与普通词同时生效；未闭合引号不应用分类、按普通文字搜索并提示，by AI.Coding。
    @Test func quotedCategoryPrefixMatchesCategoryClick() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 4)
        let alpha = try await store.createCategory(name: "UI7319 Project Alpha", colorHex: "34C759")
        _ = try await store.createCategory(name: "UI7319", colorHex: "007AFF")
        let members = try await store.search(.init()).items.prefix(2).map(\.id)
        _ = try await store.apply(try await store.preview(.category(members, alpha.id, true)).token)
        let model = makeModel(store); try await model.start(); model.capture.stop()
        try await until { !model.historyBusy && model.items.count == 4 }
        model.selectCategories([alpha.id]); model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.items.count == 2 }
        let viaClick = model.items.map(\.id)
        model.selectCategories([]); model.query = "in:\"UI7319 Project Alpha\""; model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.items.count == 2 }
        #expect(model.items.map(\.id) == viaClick && Set(viaClick) == Set(members))
        #expect(model.queryConditions == ["分类 UI7319 Project Alpha"] && model.queryProblems.isEmpty)
        let memberText = try await store.search(.init()).items.first { $0.id == members[0] }!.preview
        model.query = "in:\"UI7319 Project Alpha\" \(memberText)"; model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.items.count == 1 }
        #expect(model.items.map(\.id) == [members[0]] && model.queryConditions == ["分类 UI7319 Project Alpha"])
        model.query = "in:\"UI7319 Project"; model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.queryProblems == ["in: 的引号未闭合，按普通文字搜索"] }
        #expect(model.queryConditions.isEmpty && model.items.isEmpty)
    }
    /// 换分类结果未到时空状态留空，不先显示新范围的空提示；连续切换只发布最后一次，后台刷新不清空提示，by AI.Coding。
    @Test func categorySwitchHoldsEmptyStateUntilResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 3)
        let category = try await store.createCategory(name: "空分类", colorHex: "34C759")
        let model = makeModel(store); try await model.start(); model.capture.stop()
        try await until { !model.historyBusy && model.items.count == 3 }
        let status = model.listState.queryStatus
        model.selectCategories([category.id]); model.searchChanged(debounce: false)
        #expect(status.switching && model.items.count == 3)
        try await until { !model.historyBusy && model.items.isEmpty }
        #expect(!status.switching && !status.failed)
        model.refresh(); #expect(!status.switching)
        try await until { !model.historyBusy }
        model.selectKind(nil); model.searchChanged(debounce: false)
        #expect(status.switching && model.items.isEmpty)
        model.selectCategories([category.id]); model.searchChanged(debounce: false)
        model.selectKind(nil); model.searchChanged(debounce: false)
        try await until { !model.historyBusy && model.items.count == 3 }
        #expect(!status.switching)
    }
    /// T10：新建分类默认取首个未用色（大小写不敏感），六色用尽按分类数取模轮换；编辑已有分类保留原色，by AI.Coding。
    @Test func newCategoryRotatesDefaultColor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        _ = try await store.createCategory(name: "绿", colorHex: "34c759"); let blue = try await store.createCategory(name: "蓝", colorHex: "007AFF")
        let model = makeModel(store); try await model.start(); model.capture.stop()
        try await until { model.categories.count == 2 }
        model.editCategory(); #expect(model.categoryColor == "AF52DE")
        model.editCategory(blue); #expect(model.categoryColor == "007AFF")
        for (index, hex) in ["AF52DE", "FFCC00", "FF3B30", "8E8E93", "AF52DE"].enumerated() { _ = try await store.createCategory(name: "c\(index)", colorHex: hex) }
        let full = makeModel(store); try await full.start(); full.capture.stop()
        #expect(full.categories.count == 7)
        full.editCategory(); #expect(full.categoryColor == "007AFF")
    }
    /// T13：卡片取大小时单张图片带像素；损坏数据与多张图片只有大小，标签退化为纯大小，by AI.Coding。
    @Test func previewImageSizeCarriesPixelsOnlyForSingleDecodableImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), at = SystemClock().now()
        let png = try ImageFixtures.image(width: 40, height: 30), broken = Data("broken".utf8)
        var ids: [ClipID] = []
        for (index, payload) in [ClipboardPayload([.init([.init(SupportedType.png, png)])]), .init([.init([.init(SupportedType.png, broken)])]),
                                 .init([.init([.init(SupportedType.png, png)]), .init([.init(SupportedType.png, try ImageFixtures.image(width: 5, height: 5))])])].enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: at + Int64(index)) else { throw StoreError.notFound }
            ids.append(id)
        }
        let model = makeModel(store)
        let single = try #require(try await model.previewImageSize(id: ids[0]))
        #expect(single.items == 1 && single.pixels == PixelSize(width: 40, height: 30))
        let damaged = try #require(try await model.previewImageSize(id: ids[1]))
        #expect(damaged.pixels == nil)
        #expect(ClipContentSize.stored(bytes: damaged.bytes, items: damaged.items, pixels: damaged.pixels).label == HistoryViewModel.bytes(Int64(broken.count)))
        let multiple = try #require(try await model.previewImageSize(id: ids[2]))
        #expect(multiple.items == 2 && multiple.pixels == nil)
    }
    /// 失败后重试期间保持失败提示，再次失败仍保留，成功后才清除，by AI.Coding。
    @Test func failedQueryRetryAndChangeKeepStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 3)
        let category = try await store.createCategory(name: "空分类", colorHex: "34C759")
        let model = makeModel(store); try await model.start(); model.capture.stop()
        try await until { !model.historyBusy && model.items.count == 3 }
        let status = model.listState.queryStatus
        await store.setUnavailableForTesting(true)
        model.selectCategories([category.id]); model.searchChanged(debounce: false)
        try await until { !model.historyBusy && status.failed }
        #expect(!status.switching && model.items.isEmpty)
        model.refresh(); #expect(status.failed)
        try await until { !model.historyBusy }
        #expect(status.failed)
        await store.setUnavailableForTesting(false)
        model.refresh(); #expect(status.failed)
        try await until { !model.historyBusy && !status.failed }
        #expect(!status.switching && model.items.isEmpty)
    }
    /// 首屏、合并预读、键盘越页和乱序筛选验证真实模型/SQLite，不依赖GUI输入工具，by AI.Coding。
    @Test func viewportPagingAndQueryCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 160)
        // start()按面板高度重设卡片边长；新几何下 cardSide(340)=268，1300pt 视口与原 1000pt/219pt 同为5张一页，by AI.Coding。
        let model = makeModel(store); model.configureHistoryViewport(width: 1300, cardWidth: HistoryView.cardSide(height: 340))
        try await model.start(); model.capture.stop()
        try await until { !model.historyBusy && model.items.count == 5 }
        let first = model.selectedID, expected = try await store.search(.init()).items.map(\.id)
        for _ in 0..<100 { model.historyScrolled(offset: 0, epoch: model.listState.snapshot.scrollEpoch) }
        try await Task.sleep(for: .milliseconds(60)); #expect(model.items.count == 5)
        for _ in 0..<100 { model.historyScrolled(offset: 30, epoch: model.listState.snapshot.scrollEpoch) }
        try await until { !model.historyBusy && model.items.count == 15 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.items.count == 15); #expect(model.selectedID == first)
        #expect(model.items.map(\.id) == Array(expected.prefix(15)))
        model.select(model.items.last?.id); model.navigate(1)
        try await until { !model.historyBusy && model.items.count == 25 }
        #expect(model.selectedID == expected[15])
        model.loadMore(); model.query = "page-item-14"; model.searchChanged()
        model.query = "page-item-149"; model.searchChanged()
        try await until { !model.historyBusy && model.items.count == 1 }
        #expect(model.items[0].preview == "page-item-149")
        #expect(model.scrollRestoration?.offset == 0)
        model.query = ""; model.searchChanged(); try await until { !model.historyBusy && model.items.count == 5 }
        #expect(model.items.map(\.id) == Array(expected.prefix(5)))
        model.select(model.items.last?.id); model.historyScrolled(offset: 30, epoch: model.listState.snapshot.scrollEpoch); model.extendNavigation(1)
        try await until { !model.historyBusy && model.items.count == 15 }
        #expect(model.selectedID == expected[5]); #expect(model.selectedIDs == [expected[4], expected[5]])
    }
    /// 旧列表回调不能给新查询预读；新列表的真实滚动仍正常分页，by AI.Coding。
    @Test func staleScrollCannotPageNewSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 160)
        let model = makeModel(store); model.configureHistoryViewport(width: 1300, cardWidth: HistoryView.cardSide(height: 340))
        try await model.start(); model.capture.stop()
        try await until { !model.historyBusy && model.items.count == 5 }
        let oldEpoch = model.listState.snapshot.scrollEpoch
        model.query = "page-item-1"; model.searchChanged(debounce: false)
        model.historyScrolled(offset: 13000, epoch: oldEpoch)
        try await until { !model.historyBusy && model.items.count == 5 }
        let expected = model.items.map(\.id), selected = model.selectedID
        model.historyScrolled(offset: 13000, epoch: oldEpoch)
        #expect(!model.historyBusy)
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.items.map(\.id) == expected && model.selectedID == selected)
        model.refresh(); try await until { !model.historyBusy }
        #expect(model.items.count == 5 && model.scrollRestoration?.offset == 0)
        model.historyScrolled(offset: 30, epoch: model.listState.snapshot.scrollEpoch)
        try await until { !model.historyBusy && model.items.count == 15 }
        #expect(Array(model.items.prefix(5)).map(\.id) == expected)
    }
    /// 捕获插入不能移动正在浏览的卡片；详情和多选仍以原ID保存，by AI.Coding。
    @Test func viewportRefreshPreservesScrollAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 80)
        let model = makeModel(store); model.configureHistoryViewport(width: 1300, cardWidth: HistoryView.cardSide(height: 340))
        try await model.start(); model.capture.stop(); try await until { !model.historyBusy && model.items.count == 5 }
        model.configureHistoryViewport(width: 1000, cardWidth: 200)
        model.historyScrolled(offset: 500, epoch: model.listState.snapshot.scrollEpoch); try await until { !model.historyBusy && model.items.count == 15 }
        let selected = model.items[2].id, second = model.items[3].id
        model.choose(selected, modifiers: []); model.choose(second, modifiers: .command)
        model.showingDetail = true; model.detailVisibilityChanged()
        try await until { model.detail?.summary.id == second }
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("new-page-head".utf8))])])), at: SystemClock().now() + 1000)
        try await until { !model.historyBusy && model.items.first?.preview == "new-page-head" }
        #expect(model.scrollRestoration?.offset == 716)
        #expect(model.selectedID == second); #expect(model.selectedIDs == [selected, second])
        #expect(model.detail?.summary.id == second); #expect(model.items.count == 16)
        model.historyScrolled(offset: 716, epoch: model.listState.snapshot.scrollEpoch)
        let beforeAnchor = model.items[1].id
        let preview = try await store.preview(.delete([beforeAnchor])); _ = try await store.apply(preview.token)
        try await until { !model.historyBusy && !model.items.contains { $0.id == beforeAnchor } }
        #expect(model.items.first?.preview == "new-page-head"); #expect(model.scrollRestoration?.offset == 500)
        #expect(model.selectedIDs == [selected, second]); #expect(model.detail?.summary.id == second)
        model.loadMore(); try await until { !model.historyBusy && model.items.count == 26 }
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
        try await until { !model.historyBusy && model.items.count == 9 }
        model.loadMore(); model.configureHistoryViewport(width: 3000, cardWidth: 80)
        try await until { !model.historyBusy && model.items.count == 31 }
        #expect(Set(model.items.map(\.id)).count == 31)
    }
    /// End/全选接管预读且可重复按，不重复追加同一页或漏掉末尾记录，by AI.Coding。
    @Test func bulkNavigationOwnsPrefetch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); try await seed(store, count: 100)
        let model = makeModel(store); model.configureHistoryViewport(width: 1300, cardWidth: HistoryView.cardSide(height: 340))
        try await model.start(); model.capture.stop(); try await until { !model.historyBusy && model.items.count == 5 }
        model.historyScrolled(offset: 30, epoch: model.listState.snapshot.scrollEpoch); model.edgeSelection(true, extend: false); model.edgeSelection(true, extend: false)
        try await until { !model.historyBusy && !model.hasMore }
        #expect(model.items.count == 100); #expect(Set(model.items.map(\.id)).count == 100)
        #expect(model.selectedID == model.items.last?.id)
        model.searchChanged(); try await until { !model.historyBusy && model.items.count == 5 }
        model.historyScrolled(offset: 30, epoch: model.listState.snapshot.scrollEpoch); model.selectAllResults(); model.selectAllResults()
        try await until { !model.historyBusy && !model.hasMore }
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
        try await until { !model.historyBusy && model.items.count == 3 && model.categories.contains { $0.id == category.id } }
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
        try await until { model.message.contains("加入") && !model.historyBusy }
        for id in ids { #expect(try await store.metadata(id: id, at: SystemClock().now()).categoryIDs.contains(category.id)) }
        #expect(try await store.metadata(id: model.items[2].id, at: SystemClock().now()).categoryIDs.isEmpty)
        board.clearContents(); #expect(board.setData(Data(UUID().uuidString.utf8), forType: type))
        #expect(target.acceptedToken(from: board) == nil)
    }

    /// 同一10k/真实图像库比较固定50条和视口批次，计时仅到摘要返回，不宣称帧率，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_LOADING_BENCHMARK"] == "1"))
    func viewportLoadingBenchmark() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_LOADING_OUTPUT"], "Required benchmark environment: LOCALCLIP_LOADING_OUTPUT"))
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_LOADING_FIXTURE"], "Required benchmark environment: LOCALCLIP_LOADING_FIXTURE"))
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
