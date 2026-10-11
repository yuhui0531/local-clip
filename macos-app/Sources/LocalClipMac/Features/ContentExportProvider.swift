// 原生有序多项拖出、延迟载荷与图片文件租约，by AI.Coding。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import LocalClipCore

@MainActor final class ContentExportProvider {
    /// 内部令牌只供本进程分类；每个真实项目有独立公开提供者。
    static func writers(ids: [ClipID], store: HistoryStore, token: String, register: (ClipExportAccess) -> Void) async throws -> [any NSPasteboardWriting] {
        var result: [any NSPasteboardWriting] = []
        for id in ids {
            let access = try await store.exportAccess(id: id)
            register(access)
            let types = try await Task.detached { try access.itemTypes() }.value
            for (index, values) in types.enumerated() {
                if !Set(values).isDisjoint(with: [SupportedType.png, SupportedType.tiff, SupportedType.jpeg]) {
                    let delegate = ImagePromise(access: access, index: index, types: values, store: store)
                    let writer = ImageWriter(access: access, index: index, types: values, token: token, owner: delegate)
                    result.append(writer)
                } else { result.append(ClipWriter(access: access, index: index, types: values, token: token)) }
            }
        }
        return result
    }
}
private final class ClipWriter: NSObject, NSPasteboardWriting {
    let access: ClipExportAccess
    let index: Int
    let types: [String]
    let token: String
    init(access: ClipExportAccess, index: Int, types: [String], token: String) { self.access = access; self.index = index; self.types = types; self.token = token }
    private var publicTypes: [String] { types.contains(SupportedType.string) || Set(types).isDisjoint(with: [SupportedType.rtf,SupportedType.html,SupportedType.url]) ? types : types + [SupportedType.string] }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { (publicTypes + [HistoryViewModel.categoryDragType]).map { NSPasteboard.PasteboardType($0) } }
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions { .promised }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == HistoryViewModel.categoryDragType { return Data(token.utf8) }
        if type.rawValue == SupportedType.string, !types.contains(SupportedType.string) {
            for original in [SupportedType.url,SupportedType.rtf,SupportedType.html] where types.contains(original) {
                if let data = try? access.itemData(index:index,type:original), let text = ContentDecoder.extract(.init(original,data)) { return Data(text.utf8) }
            }
        }
        return try? access.itemData(index: index, type: type.rawValue)
    }
}
@MainActor private final class ImageWriter: NSFilePromiseProvider {
    let owner: ImagePromise
    nonisolated let access: ClipExportAccess
    nonisolated let index: Int
    nonisolated let types: [String]
    nonisolated let token: String
    init(access: ClipExportAccess, index: Int, types: [String], token: String, owner: ImagePromise) {
        self.access = access; self.index = index; self.types = types; self.token = token; self.owner = owner
        // initWithFileType:delegate:会动态调用子类init；Swift合成的未实现init会直接trap。
        // 使用AppKit头文件标记的指定初始化器，然后设置文件类型与弱delegate；owner保持强引用。
        super.init()
        fileType = UTType.png.identifier
        delegate = owner
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { super.writableTypes(for: pasteboard) + (types + [HistoryViewModel.categoryDragType]).map { NSPasteboard.PasteboardType($0) } }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions { types.contains(type.rawValue) || type.rawValue == HistoryViewModel.categoryDragType ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard) }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == HistoryViewModel.categoryDragType { return Data(token.utf8) }
        if types.contains(type.rawValue) { return try? access.itemData(index: index, type: type.rawValue) }
        return super.pasteboardPropertyList(forType: type)
    }
}
@MainActor private final class ImagePromise: NSObject, NSFilePromiseProviderDelegate {
    let access: ClipExportAccess
    let index: Int
    let types: [String]
    let store: HistoryStore
    private let queue = OperationQueue()
    init(access: ClipExportAccess, index: Int, types: [String], store: HistoryStore) { self.access = access; self.index = index; self.types = types; self.store = store; queue.maxConcurrentOperationCount = 1 }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "LocalClip-" + UUID().uuidString + ".png" }
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            let access = self.access, index = self.index, types = self.types, store = self.store
            do {
                let data = try await Task.detached { () throws -> Data in
                    guard let type = [SupportedType.png,SupportedType.tiff,SupportedType.jpeg].first(where: { types.contains($0) }) else { throw StoreError.notFound }
                    let raw = try access.itemData(index: index, type: type)
                    if type == SupportedType.png { return raw }
                    guard let source = CGImageSourceCreateWithData(raw as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, Int64(width)*Int64(height) <= 40_000_000, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StoreError.corruptPayload }
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw StoreError.ioFailure }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw StoreError.ioFailure }
                    _ = try access.itemData(index: index, type: type)
                    return output as Data
                }.value
                try access.checkValid()
                let lease = try await store.writeExport(data, id: access.id, revision: access.revision)
                try access.checkValid()
                try await Task.detached { try FileManager.default.copyItem(at: lease, to: url) }.value
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
}
// 只监听卡片区域的拖动；点击与双击继续由SwiftUI处理，by AI.Coding。
struct HistoryDragBridge: NSViewRepresentable {
    let model: HistoryViewModel
    let id: ClipID
    func makeNSView(context: Context) -> DragView { let view = DragView(); view.model = model; view.id = id; view.install(); return view }
    func updateNSView(_ view: DragView, context: Context) { view.model = model; view.id = id }
    /// 背景桥覆盖整张卡片的实际区域，不依赖无固有尺寸NSView的默认布局。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    @MainActor final class DragView: NSView, NSDraggingSource {
        weak var model: HistoryViewModel?
        var id: ClipID = ""
        // 所有卡片共享一次面板事件订阅，拖动事件直接送往按下时命中的卡片。
        private static var monitor: Any?
        private static let views = NSHashTable<DragView>.weakObjects()
        private static weak var active: DragView?
        private var start: NSPoint?
        private var preparing = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// 阈值前保留原生点击；开始拖动后由AppKit完整接管源和目标会话。
        func install() {
            Self.views.add(self)
            guard Self.monitor == nil else { return }
            Self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { event in
                if event.type == .leftMouseDown {
                    Self.active = Self.views.allObjects.first { view in
                        event.window === view.window && view.visibleRect.contains(view.convert(event.locationInWindow, from: nil))
                    }
                }
                guard let active = Self.active else { return event }
                let result = active.handle(event)
                if event.type == .leftMouseUp { Self.active = nil }
                return result
            }
        }
        /// 只处理当前拖动来源，保留SwiftUI点击和双击语义。
        private func handle(_ event: NSEvent) -> NSEvent? {
                guard event.window === window, let model else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                // 滚动裁剪之外的卡片不能抢到相邻控件的按下事件。
                if event.type == .leftMouseDown { self.start = self.visibleRect.contains(point) ? point : nil; return event }
                if event.type == .leftMouseUp { self.start = nil; return event }
                guard let start = self.start, !self.preparing, hypot(point.x-start.x,point.y-start.y) > 4 else { return event }
                self.preparing = true; self.start = nil
                Task { @MainActor in
                    defer { self.preparing = false }
                    guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                    let token = model.prepareDrag(self.id)
                    do {
                        let writers = try await ContentExportProvider.writers(ids: model.orderedSelection, store: model.store, token: token, register: model.registerDragAccess)
                        guard self.window != nil, NSEvent.pressedMouseButtons & 1 != 0 else { model.finishDrag(cancelled: true); return }
                        let values = writers.enumerated().map { index, writer in
                            let item = NSDraggingItem(pasteboardWriter: writer)
                            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) ?? NSImage(size: NSSize(width:40,height:40))
                            item.setDraggingFrame(NSRect(x:point.x+CGFloat(index)*8,y:point.y,width:48,height:48), contents: image); return item
                        }
                        guard !values.isEmpty else { model.finishDrag(cancelled: true); return }
                        self.beginDraggingSession(with: values, event: event, source: self)
                    } catch { model.finishDrag(cancelled: true); model.message = "拖出失败，记录或容量已变化" }
                }
                return nil
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { model?.finishDrag(cancelled: operation.isEmpty) }
        isolated deinit {
            Self.views.remove(self)
            if Self.views.allObjects.isEmpty, let monitor = Self.monitor { NSEvent.removeMonitor(monitor); Self.monitor = nil }
        }
    }
}
