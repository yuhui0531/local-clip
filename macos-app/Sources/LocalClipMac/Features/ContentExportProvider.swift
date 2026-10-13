// 原生有序多项拖出、延迟载荷与图片文件租约，by AI.Coding。
@preconcurrency import AppKit
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
    /// 分类令牌立即提供；只有公开正文延迟读取，分类悬停不依赖载荷回调，by AI.Coding。
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions { type.rawValue == HistoryViewModel.categoryDragType ? [] : .promised }
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
    /// 文件承诺与图片正文保持原路径，内部分类身份在建立会话时即可读取，by AI.Coding。
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type.rawValue == HistoryViewModel.categoryDragType { return [] }
        return types.contains(type.rawValue) ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
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
    init(access: ClipExportAccess, index: Int, types: [String], store: HistoryStore) { self.access = access; self.index = index; self.types = types; self.store = store }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "LocalClip-" + UUID().uuidString + ".png" }
    private final class CompletionBox: @unchecked Sendable {
        let callback: (Error?) -> Void
        init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let access = self.access, index = self.index, types = self.types, store = self.store
        let box = CompletionBox(completionHandler)
        Task {
            do {
                guard let type = [SupportedType.png,SupportedType.tiff,SupportedType.jpeg].first(where: { types.contains($0) }) else { throw StoreError.notFound }
                let raw = try access.itemData(index: index, type: type)
                let data: Data
                if type == SupportedType.png { data = raw }
                else {
                    guard let source = CGImageSourceCreateWithData(raw as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, Int64(width)*Int64(height) <= 40_000_000, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StoreError.corruptPayload }
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw StoreError.ioFailure }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw StoreError.ioFailure }
                    data = output as Data
                }
                try access.checkValid()
                let lease = try await store.writeExport(data, id: access.id, revision: access.revision)
                try access.checkValid()
                try FileManager.default.copyItem(at: lease, to: url)
                box.callback(nil)
            } catch { box.callback(error) }
        }
    }
}
// 卡片点击和拖动共享一次原生事件认领，避免SwiftUI在拖动结束后误选相邻卡片，by AI.Coding。
struct HistoryDragBridge: NSViewRepresentable {
    let model: HistoryViewModel
    let id: ClipID
    let headerRect: CGRect
    /// 卡片上的按钮区域，点击交还SwiftUI按钮处理，by AI.Coding。
    var passThroughRect: CGRect = .zero
    /// 保留实际标题命中区域，默认正文点击仍归拖放桥，by AI.Coding。
    func makeNSView(context: Context) -> DragView { let view = DragView(); view.model = model; view.id = id; view.headerRect = headerRect; view.passThroughRect = passThroughRect; view.install(); return view }
    func updateNSView(_ view: DragView, context: Context) { view.model = model; view.id = id; view.headerRect = headerRect; view.passThroughRect = passThroughRect }
    /// 背景桥覆盖整张卡片区域，不依赖无固有尺寸NSView的默认布局，by AI.Coding。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    @MainActor final class DragView: NSView, NSDraggingSource {
        weak var model: HistoryViewModel?
        var id: ClipID = ""
        var headerRect: CGRect = .zero
        var passThroughRect: CGRect = .zero
        private var pressedTitle = false
        private static var monitor: Any?
        private static let views = NSHashTable<DragView>.weakObjects()
        private static var active: DragView?
        private var down: NSEvent?
        private var pressedID: ClipID?
        private var preparing = false
        private var dragged = false
        private var nativeSessionActive = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// 按下时冻结来源ID，并消费整段左键手势；右键菜单仍由SwiftUI处理。
        func install() {
            Self.views.add(self)
            guard Self.monitor == nil else { return }
            Self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { event in
                if event.type == .leftMouseDown {
                    Self.active = Self.views.allObjects.first { view in
                        let point = view.convert(event.locationInWindow, from: nil)
                        // 非裁剪NSView的visibleRect可能延伸到整个父视口；必须同时命中自身bounds，by AI.Coding。
                        return event.window === view.window && view.bounds.contains(point) && view.visibleRect.contains(point)
                    }
                    // 按在卡片按钮上时整段手势交给按钮，不选择、不拖动、不触发双击粘贴。
                    if let view = Self.active {
                        let point = view.convert(event.locationInWindow, from: nil)
                        if view.passThroughRect.contains(CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)) { Self.active = nil }
                    }
                }
                #if DEBUG
                if GUIAcceptanceProbe.configuration != nil {
                    GUIAcceptanceProbe.pointer(event, id: Self.active?.id, rectangles: Self.views.allObjects.filter { $0.window === event.window }.map { ["id":$0.id,"rect":NSStringFromRect($0.convert($0.bounds.intersection($0.visibleRect),to:nil))] })
                }
                #endif
                guard let active = Self.active else { return event }
                let result = active.handle(event)
                if event.type == .leftMouseUp && !active.nativeSessionActive { Self.active = nil }
                return result
            }
        }
        /// 原生会话接管后必须收到拖动和抬起事件，否则AppKit无法向分类目标派发放下，by AI.Coding。
        func handPointerToNativeSession() { nativeSessionActive = true }
        func handle(_ event: NSEvent) -> NSEvent? {
            if nativeSessionActive { return event }
            guard let model else { return event }
            // 编辑时事件交给原生文本域，不能吞掉定位光标和文字选择，by AI.Coding。
            if model.renamingID == id { return event }
            if event.type == .leftMouseDown {
                guard !model.dragActive else { return nil }
                model.cancelRename()
                let point = convert(event.locationInWindow, from: nil)
                pressedTitle = headerRect.contains(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
                down = event; pressedID = id; dragged = false
                return nil
            }
            guard let down, let pressedID else { return nil }
            if event.type == .leftMouseUp {
                self.down = nil; self.pressedID = nil
                if !dragged && !preparing {
                    if down.clickCount == 2 {
                        if pressedTitle { model.beginRename(pressedID) } else { model.doubleClick(pressedID) }
                    }
                    else { model.choose(pressedID, modifiers: down.modifierFlags) }
                }
                return nil
            }
            let distance = hypot(event.locationInWindow.x-down.locationInWindow.x, event.locationInWindow.y-down.locationInWindow.y)
            guard !dragged, !preparing, distance > 5 else { return nil }
            dragged = true; preparing = true
            // 先截取实际卡片，再触发源卡片的提起动画；不展示不相关的通用图标。
            let image = preview(), frame = bounds
            let token = model.prepareDrag(pressedID), ids = model.orderedSelection
            Task { @MainActor in
                defer { self.preparing = false }
                do {
                    let writers = try await ContentExportProvider.writers(ids: ids, store: model.store, token: token, register: model.registerDragAccess)
                    guard Self.active === self, self.down === down, self.window != nil,
                          NSEvent.pressedMouseButtons & 1 != 0, !writers.isEmpty else { model.finishDrag(cancelled: true); return }
                    let values = writers.enumerated().map { index, writer in
                        let item = NSDraggingItem(pasteboardWriter: writer)
                        item.setDraggingFrame(frame.offsetBy(dx: CGFloat(index)*8, dy: CGFloat(index)*8), contents: image)
                        return item
                    }
                    self.handPointerToNativeSession()
                    let session = self.beginDraggingSession(with: values, event: event, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = true
                    session.draggingFormation = .pile
                } catch { model.finishDrag(cancelled: true); model.message = "拖出失败，记录或容量已变化" }
            }
            return nil
        }
        /// 在卡片坐标内保存真实绘制结果，图片/正文/标题随拖动一起移动，by AI.Coding。
        private func preview() -> NSImage {
            guard let content = window?.contentView else { return NSImage(size: bounds.size) }
            let rect = convert(bounds, to: content)
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return NSImage(size: bounds.size) }
            content.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: bounds.size); image.addRepresentation(bitmap); return image
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            #if DEBUG
            if let model { GUIAcceptanceProbe.event("native-session-started", model) }
            #endif
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            nativeSessionActive = false; down = nil; pressedID = nil; Self.active = nil
            model?.finishDrag(cancelled: operation.isEmpty)
        }
        deinit {
            MainActor.assumeIsolated {
                Self.views.remove(self)
                if Self.views.allObjects.isEmpty, let monitor = Self.monitor { NSEvent.removeMonitor(monitor); Self.monitor = nil }
            }
        }
    }
}
