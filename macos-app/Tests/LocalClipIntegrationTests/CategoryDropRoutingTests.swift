// 隔离原生分类视图的命中与拖放路由回归，不启动应用或读取用户剪贴板，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 仅构造目的地协议回调，测试真实托管路由；不伪称物理AppKit拖动会话，by AI.Coding。
@MainActor private final class RoutingDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, point: NSPoint, board: NSPasteboard) { draggingDestinationWindow = window; draggingLocation = point; draggingPasteboard = board }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor struct CategoryDropRoutingTests {
    /// 新建分类弹窗锚在加号上；加号滚出可见范围时贴边，未布局时退回整段导航区，by AI.Coding。
    @Test func categoryEditorAnchorsAtPlus() {
        let plus = CGRect(x: 300, y: 2, width: 28, height: 28)
        #expect(HistoryView.categoryEditorAnchor(plus: plus, width: 900) == plus)
        #expect(HistoryView.categoryEditorAnchor(plus: plus.offsetBy(dx: 700, dy: 0), width: 900) == CGRect(x: 899, y: 2, width: 1, height: 28))
        #expect(HistoryView.categoryEditorAnchor(plus: plus.offsetBy(dx: -400, dy: 0), width: 900) == CGRect(x: 0, y: 2, width: 1, height: 28))
        #expect(HistoryView.categoryEditorAnchor(plus: .zero, width: 900) == CGRect(x: 0, y: 0, width: 900, height: 32))
    }
    /// 必须经过实际托管层级，直接调用接收函数无法发现SwiftUI拦截原生目的地，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func hostedCategoryRouting() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let category = try await store.createCategory(name: "提示词", colorHex: "AF52DE")
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("native-category-test".utf8))])])), at: SystemClock().now())
        try await model.start(); capture.stop()
        let host = CategoryDropHostingView(rootView: HistoryView(model: model), model: model)
        host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1400, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let button = try #require(views(host).compactMap { $0 as? CategoryDropTarget.CategoryButton }.first)
        // hitTest接收父视图坐标，托管内容为flipped而窗口父视图不是，不能直接传本地坐标，by AI.Coding。
        let point = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
        let hit = host.hitTest(point)
        #expect(button.category?.id == category.id)
        #expect(button.registeredDraggedTypes.contains(.init(HistoryViewModel.categoryDragType)))
        #expect(host.registeredDraggedTypes.contains(.init(HistoryViewModel.categoryDragType)))
        #expect(hit === button || hit?.isDescendant(of: button) == true)
        let windowPoint = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        #expect(host.categoryTarget(at: windowPoint) === button)
        #expect(host.categoryTarget(at: .init(x: 10, y: 10)) == nil)
        button.isHidden = true; #expect(host.categoryTarget(at: windowPoint) == nil); button.isHidden = false
    }

    /// 全部八种表示、混合及多选经过公开写入者、托管目的地协议回调和SQLite持久归属，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func everyKindThroughHostingDestination() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root, extractor: ContentDecoder.extract)
        let file = root.appendingPathComponent("route-file.txt"); try Data("file content".utf8).write(to: file)
        var payloads = [ClipboardPayload([.init([.init(SupportedType.string, Data("route-text".utf8))])]),
                        .init([.init([.init(SupportedType.url, Data("https://example.invalid/route".utf8))])]),
                        .init([.init([.init(SupportedType.rtf, Data("{\\rtf1\\ansi route-rich}".utf8))])]),
                        .init([.init([.init(SupportedType.html, Data("<b>route-html</b>".utf8))])]),
                        .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])]
        for type in [SupportedType.png, SupportedType.tiff, SupportedType.jpeg] { payloads.append(.init([.init([.init(type, try ImageFixtures.image(width: 16, height: 16, type: type))])])) }
        payloads.append(.init([.init([.init(SupportedType.string, Data("mixed-route".utf8))]), .init([.init(SupportedType.png, try ImageFixtures.image(width: 17, height: 17, type: SupportedType.png))])]))
        for (index, payload) in payloads.enumerated() { _ = try await store.ingest(.init(payload: payload), at: SystemClock().now() + Int64(index)) }
        let rawBoard = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: rawBoard, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: rawBoard, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        func wait(_ predicate: () -> Bool) async throws {
            let until = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
            #expect(predicate())
        }
        try await wait { !model.historyBusy && model.items.count == payloads.count }
        #expect(Set(model.items.map(\.kind)) == Set(ClipKind.allCases))
        let host = CategoryDropHostingView(rootView: HistoryView(model: model), model: model); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1400, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        // 已显示的托管层无需重建，必须接收之后新建分类的实际视图和持久事件，by AI.Coding。
        let category = try await store.createCategory(name: "提示词", colorHex: "AF52DE")
        try await wait { !model.historyBusy && model.categories.contains { $0.id == category.id } }
        window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        func buttons(_ view: NSView) -> [CategoryDropTarget.CategoryButton] { (view as? CategoryDropTarget.CategoryButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let button = try #require(buttons(host).first)
        let point = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let board = NSPasteboard(name: .init("local.localclip.host-route." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let info = RoutingDragInfo(window: window, point: point, board: board)
        info.draggedImageLocation = point
        for id in model.items.map(\.id) {
            model.message = ""; model.select(id); let token = model.prepareDrag(id)
            #expect(host.registeredDraggedTypes.contains(.init(HistoryViewModel.categoryDragType)))
            let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: token, register: model.registerDragAccess)
            board.clearContents(); #expect(board.writeObjects(writers))
            info.draggingDestinationWindow = nil
            #expect(host.draggingEntered(info).isEmpty); #expect(!host.performDragOperation(info))
            info.draggingDestinationWindow = window
            #expect(host.draggingEntered(info) == .copy); #expect(host.prepareForDragOperation(info))
            info.draggingLocation = .init(x: 10, y: 10)
            #expect(host.draggingUpdated(info).isEmpty); #expect(!host.performDragOperation(info))
            info.draggingLocation = point
            #expect(host.draggingUpdated(info) == .copy); #expect(host.performDragOperation(info))
            #expect(!host.performDragOperation(info)); host.concludeDragOperation(info); model.finishDrag(cancelled: false)
            try await wait { model.message.contains("加入") && !model.historyBusy }
            #expect(try await store.metadata(id: id, at: SystemClock().now()).categoryIDs.contains(category.id))
        }
        let ids = Array(model.items.prefix(2).map(\.id))
        let multi = try await store.createCategory(name: "多选分类", colorHex: "34C759")
        try await wait { !model.historyBusy && model.categories.contains { $0.id == multi.id } }
        window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        let multiButton = try #require(buttons(host).first { $0.category?.id == multi.id })
        #expect(host.registeredDraggedTypes.contains(.init(HistoryViewModel.categoryDragType)))
        info.draggingLocation = multiButton.convert(.init(x: multiButton.bounds.midX, y: multiButton.bounds.midY), to: nil)
        model.message = ""
        model.choose(ids[0], modifiers: []); model.choose(ids[1], modifiers: .command)
        let token = model.prepareDrag(ids[0])
        let writers = try await ContentExportProvider.writers(ids: model.orderedSelection, store: store, token: token, register: model.registerDragAccess)
        board.clearContents(); #expect(board.writeObjects(writers)); #expect(host.performDragOperation(info))
        model.finishDrag(cancelled: false); try await wait { !model.historyBusy && model.message.contains("加入") }
        for item in model.items {
            let memberships = try await store.metadata(id: item.id, at: SystemClock().now()).categoryIDs
            #expect(memberships.contains(category.id)); #expect(memberships.contains(multi.id) == ids.contains(item.id))
        }
        let beforeCancellation = try await store.search(.init()).revision
        model.select(ids[0]); let cancelled = model.prepareDrag(ids[0]); board.clearContents(); board.setData(Data(cancelled.utf8), forType: .init(HistoryViewModel.categoryDragType))
        #expect(host.draggingEntered(info) == .copy); #expect(multiButton.layer?.borderWidth == 1.5)
        host.draggingEnded(info); #expect(multiButton.layer?.borderWidth == 0)
        #expect(multiButton.draggingEntered(info) == .copy)
        multiButton.draggingEnded(info); #expect(multiButton.layer?.borderWidth == 0)
        model.finishDrag(cancelled: true)
        #expect(!host.prepareForDragOperation(info)); #expect(!host.performDragOperation(info))
        board.clearContents(); board.setData(Data(UUID().uuidString.utf8), forType: .init(HistoryViewModel.categoryDragType))
        #expect(host.draggingEntered(info).isEmpty); #expect(!host.performDragOperation(info))
        #expect(try await store.search(.init()).revision == beforeCancellation)
    }
    /// 隐藏窗口中经过实际托管路由排序；拒绝外部令牌、重复认领和换范围后的旧拖动。
    @Test func cardReorderingThroughHostingDestination() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for index in 0..<5 {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("reorder-route-\(index)".utf8))])])), at: SystemClock().now() + Int64(index))
        }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        func wait(_ predicate: () -> Bool) async throws {
            let until = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
            #expect(predicate())
        }
        try await wait { !model.historyBusy && model.items.count == 5 }
        let original = model.items.map(\.id)
        let host = CategoryDropHostingView(rootView: HistoryView(model: model), model: model); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1600, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let target = try #require(HistoryDragBridge.DragView.view(for: original[0]))
        let point = target.convert(.init(x: target.bounds.width * 0.25, y: target.bounds.midY), to: nil)
        let privateBoard = NSPasteboard(name: .init("local.localclip.reorder." + UUID().uuidString))
        defer { privateBoard.releaseGlobally() }
        let info = RoutingDragInfo(window: window, point: point, board: privateBoard)
        info.draggingSourceOperationMask = [.copy, .move]
        // 缩窄隐藏视口，在来源卡片仍占据右边缘时也应推进滚动，而不是因自身不可投放而卡住。
        window.setContentSize(.init(width: 900, height: 340)); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let scroll = try #require(target.enclosingScrollView), clip = scroll.contentView
        let edge = clip.convert(.init(x: clip.bounds.maxX - 4, y: clip.bounds.midY), to: nil)
        let edgeCard = try #require(HistoryDragBridge.DragView.dropTarget(at: edge, in: window, model: model))
        let edgeToken = model.prepareDrag(edgeCard.view.id)
        privateBoard.setData(Data(edgeToken.utf8), forType: .init(HistoryViewModel.categoryDragType))
        info.draggingLocation = edge
        let beforeEdge = clip.bounds.minX
        _ = host.draggingUpdated(info)
        #expect(clip.bounds.minX > beforeEdge)
        host.draggingExited(info); model.finishDrag(cancelled: true)
        clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
        window.setContentSize(.init(width: 1600, height: 340)); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        info.draggingLocation = target.convert(.init(x: target.bounds.width * 0.25, y: target.bounds.midY), to: nil)
        let token = model.prepareDrag(original[3])
        privateBoard.setData(Data(UUID().uuidString.utf8), forType: .init(HistoryViewModel.categoryDragType))
        #expect(host.draggingEntered(info).isEmpty)
        privateBoard.setData(Data(token.utf8), forType: .init(HistoryViewModel.categoryDragType))
        #expect(host.draggingEntered(info) == .move)
        #expect(host.prepareForDragOperation(info)); #expect(host.performDragOperation(info))
        #expect(!host.performDragOperation(info))
        model.finishDrag(cancelled: false)
        try await wait { !model.historyBusy && !model.reorderingCards && model.items.first?.id == original[3] }
        #expect(model.items.map(\.id) == [original[3], original[0], original[1], original[2], original[4]])
        #expect(model.selectedID == original[3])
        let reopened = try HistoryStore(location: root)
        #expect(try await reopened.search(.init(sort: .manual)).items.map(\.id) == model.items.map(\.id))
        // 多选在同一会话内保持当前先后顺序，一次认领后整批插在目标后方。
        // 与前段一致，布局后等卡片位移落定再取坐标；满载时首次重排的动画可能尚未结束，by AI.Coding。
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        // 重排提交后的存储事件可能再触发一次刷新；刷新进行中拖放会被拒绝，等其结束再继续。
        try await wait { !model.historyBusy && !model.reorderingCards }
        window.contentView?.layoutSubtreeIfNeeded()
        let tail = try #require(HistoryDragBridge.DragView.view(for: original[4]))
        info.draggingLocation = tail.convert(.init(x: tail.bounds.width * 0.75, y: tail.bounds.midY), to: nil)
        model.choose(original[0], modifiers: []); model.choose(original[1], modifiers: .command)
        let multi = model.prepareDrag(original[0])
        privateBoard.setData(Data(multi.utf8), forType: .init(HistoryViewModel.categoryDragType))
        #expect(host.draggingEntered(info) == .move); #expect(host.performDragOperation(info))
        model.finishDrag(cancelled: false)
        try await wait { !model.historyBusy && !model.reorderingCards && model.items.last?.id == original[1] }
        #expect(model.items.map(\.id) == [original[3], original[2], original[4], original[0], original[1]])
        #expect(model.selectedIDs == Set([original[0], original[1]]))
        #expect(model.listState.snapshot.reorderRevision >= 2)
        let cancelled = model.prepareDrag(original[4])
        model.query = "different scope"
        #expect(!model.canReorderCards(cancelled, relativeTo: original[0]))
        model.finishDrag(cancelled: true)
        #expect(!host.prepareForDragOperation(info))
    }

}
