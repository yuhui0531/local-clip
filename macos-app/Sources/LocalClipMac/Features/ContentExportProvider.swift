// 原生有序多项拖出、延迟载荷与文件承诺租约，by AI.Coding。
@preconcurrency import AppKit
import UniformTypeIdentifiers
import SwiftUI
import LocalClipCore

@MainActor final class ContentExportProvider {
    /// 内部令牌只供本进程分类；每个真实项目有独立公开提供者。图片与文字项提供文件承诺，链接与文件引用沿用系统原生拖放，by AI.Coding。
    static func writers(ids: [ClipID], store: HistoryStore, token: String, register: (ClipExportAccess) -> Void) async throws -> [any NSPasteboardWriting] {
        var result: [any NSPasteboardWriting] = []
        var promises: [FilePromise] = []
        for id in ids {
            let access = try await store.exportAccess(id: id)
            register(access)
            let summary = try await store.metadata(id: id, at: SystemClock().now()).summary
            let base = ContentInspector.exportBaseName(title: summary.title, copiedAt: summary.lastCopiedAt)
            let types = try await Task.detached { try access.itemTypes() }.value
            for (index, values) in types.enumerated() {
                guard let plan = try await plan(access: access, index: index, types: values) else {
                    result.append(ClipWriter(access: access, index: index, types: values, token: token)); continue
                }
                let promise = FilePromise(access: access, index: index, types: values, store: store, plan: plan, base: base)
                promises.append(promise)
                // 文件承诺提供者不会回调延迟类型；文字类型在后台预读后立即提供，编辑器仍能插入文字，主线程不读库。
                // 图片保持原有延迟声明，不在拖动开始时读入大幅原图。
                let eager = plan.isImage ? [:] : await Task.detached { Dictionary(uniqueKeysWithValues: publicTypes(values).compactMap { type in
                    (exportValue(access: access, index: index, types: values, token: token, type: .init(type)) as? Data).map { (type, $0) } }) }.value
                result.append(FileWriter(access: access, index: index, types: values, token: token, eager: eager, owner: promise))
            }
        }
        // 一次拖出多个文件时按拖出顺序追加序号，同一秒复制的记录也不会同名。
        if promises.count > 1 { for (number, promise) in promises.enumerated() { promise.number = number + 1 } }
        return result
    }
    /// 单项导出方案：文件类型、扩展名与写出内容；nil表示交给系统原生处理（文件引用、链接）。
    struct Plan: Sendable {
        let fileType: String
        let fileExtension: String
        let format: ContentInspector.ExportFormat
        var isImage: Bool { ["png", "tiff", "jpg"].contains(fileExtension) }
    }
    private static let imageTypes: Set<String> = [SupportedType.png, SupportedType.tiff, SupportedType.jpeg]
    static func plan(access: ClipExportAccess, index: Int, types: [String]) async throws -> Plan? {
        // Finder对文件引用复制原件（即使附带图标图片）；对链接自行生成.webloc，保持原生行为。
        if types.contains(SupportedType.fileURL) { return nil }
        // 保持既有单文件格式优先级，但不转码原始TIFF/JPEG，避免丢页、精度和元数据。
        if !Set(types).isDisjoint(with: imageTypes) {
            let type = types.contains(SupportedType.png) ? SupportedType.png : types.contains(SupportedType.tiff) ? SupportedType.tiff : SupportedType.jpeg
            let ext = type == SupportedType.png ? "png" : type == SupportedType.tiff ? "tiff" : "jpg"
            return Plan(fileType: type, fileExtension: ext, format: .original(type: type, fileExtension: ext))
        }
        if types.contains(SupportedType.url) { return nil }
        let (text, markup) = try await Task.detached { (try ContentExportProvider.plainText(access: access, index: index, types: types), try ContentExportProvider.markupSource(access: access, index: index, types: types)) }.value
        guard let text else { return nil }
        // 拖动开始即需声明文件类型；语言识别只取前512字符（比卡片的180字符预览多），把拖动开始的等待控制在十几毫秒。
        let language = await SyntaxHighlighter.shared.language(of: text, sample: 512)
        let format = ContentInspector.exportFormat(plainText: text, language: language, types: types, markup: markup)
        let fileType: String = switch format {
        case .original(let type, _): type
        case .plain(let ext): UTType(filenameExtension: ext)?.identifier ?? UTType.plainText.identifier
        }
        return Plan(fileType: fileType, fileExtension: format.fileExtension, format: format)
    }
    /// 优先已保存的纯文字表示；只有RTF/HTML时本地解码，不加载外部资源。
    nonisolated static func plainText(access: ClipExportAccess, index: Int, types: [String]) throws -> String? {
        if types.contains(SupportedType.string) { return String(decoding: try access.itemData(index: index, type: SupportedType.string), as: UTF8.self) }
        for type in [SupportedType.rtf, SupportedType.html] where types.contains(type) {
            if let text = ContentDecoder.extract(.init(type, try access.itemData(index: index, type: type))) { return text }
        }
        return nil
    }
    /// HTML或RTF前64KiB源码只用于判断代码排版标记（等宽字体、pre/code）。
    nonisolated static func markupSource(access: ClipExportAccess, index: Int, types: [String]) throws -> String? {
        guard let type = [SupportedType.html, SupportedType.rtf].first(where: types.contains) else { return nil }
        return String(decoding: try access.itemData(index: index, type: type).prefix(65_536), as: UTF8.self)
    }
    /// 方案对应的写出字节：原样表示或UTF-8纯文本（无BOM、保留原换行）。
    nonisolated static func data(_ plan: Plan, access: ClipExportAccess, index: Int, types: [String]) throws -> Data {
        switch plan.format {
        case .original(let type, _): return try access.itemData(index: index, type: type)
        case .plain: guard let text = try plainText(access: access, index: index, types: types) else { throw StoreError.corruptPayload }; return Data(text.utf8)
        }
    }
}
/// 文字与链接的系统读取值；文件承诺写入者共用，保证拖进编辑器的内容与原有行为一致，by AI.Coding。
private func exportValue(access: ClipExportAccess, index: Int, types: [String], token: String, type: NSPasteboard.PasteboardType) -> Any? {
    if type.rawValue == HistoryViewModel.categoryDragType { return Data(token.utf8) }
    if type.rawValue == SupportedType.string, !types.contains(SupportedType.string) {
        for original in [SupportedType.url,SupportedType.rtf,SupportedType.html] where types.contains(original) {
            if let data = try? access.itemData(index:index,type:original), let text = ContentDecoder.extract(.init(original,data)) { return Data(text.utf8) }
        }
    }
    return try? access.itemData(index: index, type: type.rawValue)
}
/// RTF/HTML/URL之外补一份纯文字，让只收文字的目标也能接收。
private func publicTypes(_ types: [String]) -> [String] {
    types.contains(SupportedType.string) || Set(types).isDisjoint(with: [SupportedType.rtf,SupportedType.html,SupportedType.url]) ? types : types + [SupportedType.string]
}
private final class ClipWriter: NSObject, NSPasteboardWriting {
    let access: ClipExportAccess
    let index: Int
    let types: [String]
    let token: String
    init(access: ClipExportAccess, index: Int, types: [String], token: String) { self.access = access; self.index = index; self.types = types; self.token = token }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { (publicTypes(types) + [HistoryViewModel.categoryDragType]).map { NSPasteboard.PasteboardType($0) } }
    /// 分类令牌立即提供；只有公开正文延迟读取，分类悬停不依赖载荷回调，by AI.Coding。
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions { type.rawValue == HistoryViewModel.categoryDragType ? [] : .promised }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? { exportValue(access: access, index: index, types: types, token: token, type: type) }
}
/// 同一拖动项同时提供文件承诺与原有类型：Finder得到文件，编辑器仍插入文字或原格式，by AI.Coding。
@MainActor private final class FileWriter: NSFilePromiseProvider {
    let owner: FilePromise
    nonisolated let access: ClipExportAccess
    nonisolated let index: Int
    nonisolated let types: [String]
    nonisolated let token: String
    nonisolated let eager: [String: Data]
    init(access: ClipExportAccess, index: Int, types: [String], token: String, eager: [String: Data], owner: FilePromise) {
        self.access = access; self.index = index; self.types = types; self.token = token; self.eager = eager; self.owner = owner
        // initWithFileType:delegate:会动态调用子类init；Swift合成的未实现init会直接trap。
        // 使用AppKit头文件标记的指定初始化器，然后设置文件类型与弱delegate；owner保持强引用。
        super.init()
        fileType = owner.plan.fileType
        delegate = owner
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { super.writableTypes(for: pasteboard) + (publicTypes(types) + [HistoryViewModel.categoryDragType]).map { NSPasteboard.PasteboardType($0) } }
    /// 文件承诺与正文保持原路径，内部分类身份在建立会话时即可读取，by AI.Coding。
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type.rawValue == HistoryViewModel.categoryDragType || eager[type.rawValue] != nil { return [] }
        return publicTypes(types).contains(type.rawValue) ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if let value = eager[type.rawValue] { return value }
        if type.rawValue == HistoryViewModel.categoryDragType || publicTypes(types).contains(type.rawValue) { return exportValue(access: access, index: index, types: types, token: token, type: type) }
        return super.pasteboardPropertyList(forType: type)
    }
}
@MainActor private final class FilePromise: NSObject, NSFilePromiseProviderDelegate {
    let access: ClipExportAccess
    let index: Int
    let types: [String]
    let store: HistoryStore
    let plan: ContentExportProvider.Plan
    let base: String
    var number: Int?
    init(access: ClipExportAccess, index: Int, types: [String], store: HistoryStore, plan: ContentExportProvider.Plan, base: String) {
        self.access = access; self.index = index; self.types = types; self.store = store; self.plan = plan; self.base = base
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { ContentInspector.fileName(base: base, index: number, fileExtension: plan.fileExtension) }
    private final class CompletionBox: @unchecked Sendable {
        let callback: (Error?) -> Void
        init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    }
    /// 不依赖主线程：拖放期间主线程忙于拖拽界面，回主线程会推迟租约释放甚至卡住导出。
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let access = self.access, index = self.index, types = self.types, store = self.store, plan = self.plan
        let box = CompletionBox(completionHandler)
        Task {
            await ExportLeaseQueue.shared.run {
                do {
                    let data = try ContentExportProvider.data(plan, access: access, index: index, types: types)
                    let lease = try await store.writeExport(data, id: access.id, revision: access.revision, fileExtension: plan.fileExtension)
                    // 目标拿到副本后租约即无用；成功或失败都立即释放，避免大幅原始TIFF挤占导出预算。
                    defer { try? FileManager.default.removeItem(at: lease) }
                    try access.checkValid()
                    // 同名文件不覆盖，改写为"名称 2.ext"；copyItem遇到并发出现的同名文件同样失败而不覆盖。
                    guard let target = ContentInspector.availableURL(url, exists: { FileManager.default.fileExists(atPath: $0.path) }) else { throw CocoaError(.fileWriteFileExists) }
                    try FileManager.default.copyItem(at: lease, to: target)
                    box.callback(nil)
                } catch { box.callback(error) }
            }
        }
    }
}
/// 多选拖出时AppKit并发索取承诺；逐个完成"读取→租约→复制→释放"，同一时刻至多一个租约，
/// 多个大幅原始TIFF不会合计超出50MiB导出预算，内存也只驻留一份载荷。
/// ponytail: 全局串行，慢速目标卷会让后续导出排队；需要并行时改为按预算计数的信号量。
private actor ExportLeaseQueue {
    static let shared = ExportLeaseQueue()
    private var tail: Task<Void, Never>?
    func run(_ work: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let current = Task { await previous?.value; await work() }
        tail = current
        await current.value
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
        /// ⌘T转换菜单定位到所选卡片；只取仍在窗口中的卡片，by AI.Coding。
        static func view(for id: ClipID) -> NSView? { views.allObjects.first { $0.id == id && $0.window != nil } }
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
