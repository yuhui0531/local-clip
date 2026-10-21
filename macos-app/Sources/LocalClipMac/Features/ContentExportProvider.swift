// 原生有序多项拖出、延迟载荷与文件承诺租约，by AI.Coding。
@preconcurrency import AppKit
import UniformTypeIdentifiers
import SwiftUI
import LocalClipCore
import Synchronization

@MainActor final class ContentExportProvider {
    /// 内部令牌只供本进程分类；每个真实项目有独立公开提供者。图片与文字项提供文件承诺，链接与文件引用沿用系统原生拖放，by AI.Coding。
    static func writers(ids: [ClipID], store: HistoryStore, token: String, register: (ClipExportAccess) -> Void, clock: any ClipClock = SystemClock(), registerSession: (ImageDragSession) -> Void = { _ in }) async throws -> [any NSPasteboardWriting] {
        var result: [(any NSPasteboardWriting)?] = []
        var promises: [FilePromise] = []
        var pending: [(slot: Int, promise: FilePromise, types: [String], eager: [String: Data])] = []
        let imageSession = ImageDragSession()
        registerSession(imageSession)
        let smartCode = try await store.settings().smartCodeFilePaste
        // 多选拖出时正文合计与智能粘贴同一上限，超出部分保持原文件拖放，不在拖动开始驻留大量正文。
        var codeBytes = 0
        for id in ids {
            let access = try await store.exportAccess(id: id)
            register(access)
            let summary = try await store.metadata(id: id, at: clock.now()).summary
            let base = ContentInspector.exportBaseName(title: summary.title, copiedAt: summary.lastCopiedAt)
            let types = try await Task.detached { try access.itemTypes() }.value
            for (index, values) in types.enumerated() {
                // 开启代码文件智能粘贴时，代码文件只提供正文与文件承诺、不提供文件URL：
                // 编辑器/IDE插入正文而不是打开文件，Finder按承诺复制原文件，by AI.Coding。
                if smartCode, codeBytes < CodeFileReader.totalLimit, values.contains(SupportedType.fileURL),
                   let code = await Task.detached(operation: { codeFile(access: access, index: index) }).value,
                   codeBytes + code.text.utf8.count <= CodeFileReader.totalLimit {
                    codeBytes += code.text.utf8.count
                    let ext = code.url.pathExtension
                    let plan = Plan(fileType: UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier, fileExtension: ext,
                                    format: .original(type: SupportedType.fileURL, fileExtension: ext))
                    let promise = FilePromise(access: access, index: index, types: values, store: store, plan: plan, base: base, sourceFile: code.url)
                    promises.append(promise)
                    pending.append((result.count, promise, [], [SupportedType.string: Data(code.text.utf8)])); result.append(nil)
                    continue
                }
                guard let plan = try await plan(access: access, index: index, types: values) else {
                    result.append(ClipWriter(access: access, index: index, types: values, token: token)); continue
                }
                let promise = FilePromise(access: access, index: index, types: values, store: store, plan: plan, base: base)
                promises.append(promise)
                // 文件承诺提供者不会回调延迟类型；文字类型在后台预读后立即提供，编辑器仍能插入文字，主线程不读库。
                // 图片原图和文件URL都按请求提供；起手只读取类型/名称，不碰原图BLOB。
                let eager = plan.isImage ? [:] : await Task.detached { Dictionary(uniqueKeysWithValues: publicTypes(values).compactMap { type in
                    (exportValue(access: access, index: index, types: values, token: token, type: .init(type)) as? Data).map { (type, $0) } }) }.value
                pending.append((result.count, promise, values, eager)); result.append(nil)
            }
        }
        // 一次拖出多个文件时按拖出顺序追加序号，同一秒复制的记录也不会同名。
        if promises.count > 1 { for (number, promise) in promises.enumerated() { promise.number = number + 1 } }
        for entry in pending {
            let promise = entry.promise
            let imageData = promise.plan.isImage ? ImageDataProvider(access: promise.access, index: promise.index, types: entry.types, token: token, session: imageSession, fileName: promise.fileName) : nil
            // 拖动项必须保留原生provider身份；包装其元数据会丢失真实文件承诺回调，by AI.Coding。
            result[entry.slot] = FileWriter(access: promise.access, index: promise.index, types: entry.types, token: token, eager: entry.eager, owner: promise, imageData: imageData)
        }
        return result.compactMap { $0 }
    }
    /// 返回同一项目实际持有的原生承诺提供者，供生产类型桥和既有承诺验证复用。
    static func promiseProvider(for writer: any NSPasteboardWriting) -> NSFilePromiseProvider? {
        writer as? NSFilePromiseProvider
    }
    /// 原生会话写好各项后，仅为原图/URL注册公开的延迟数据提供者；不接管承诺元数据，by AI.Coding。
    static func installImageDataProviders(_ writers: [any NSPasteboardWriting], on board: NSPasteboard) throws {
        guard writers.contains(where: { ($0 as? FileWriter)?.imageData != nil }) else { return }
        guard let items = board.pasteboardItems, items.count == writers.count else { throw StoreError.ioFailure }
        for (writer, item) in zip(writers, items) {
            if let data = (writer as? FileWriter)?.imageData,
               !item.setDataProvider(data, forTypes: (publicTypes(data.types) + [SupportedType.fileURL]).map { NSPasteboard.PasteboardType($0) }) {
                throw StoreError.ioFailure
            }
        }
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
        // 拖动开始即需声明文件类型：只有完整正文验证通过的语言才决定扩展名；超出判定预算返回未确定，按文本或原表示导出。
        let language = await SyntaxHighlighter.shared.guess(of: text).verifiedLanguage
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
    /// HTML或RTF完整源码（不超过验证预算）只用于判断代码排版标记（等宽字体、pre/code）。
    nonisolated static func markupSource(access: ClipExportAccess, index: Int, types: [String]) throws -> String? {
        guard let type = [SupportedType.html, SupportedType.rtf].first(where: types.contains) else { return nil }
        // 超出验证预算时不截取前缀：尾部可能有非等宽正文，返回nil让导出保留原表示。
        let data = try access.itemData(index: index, type: type)
        return data.count <= ContentInspector.markupLimit ? String(decoding: data, as: UTF8.self) : nil
    }
    /// 方案对应的写出字节：原样表示或UTF-8纯文本（无BOM、保留原换行）。
    nonisolated static func data(_ plan: Plan, access: ClipExportAccess, index: Int, types: [String]) throws -> Data {
        switch plan.format {
        case .original(let type, _): return try access.itemData(index: index, type: type)
        case .plain: guard let text = try plainText(access: access, index: index, types: types) else { throw StoreError.corruptPayload }; return Data(text.utf8)
        }
    }
}
/// 同步跟踪延迟回调与会话结束；禁止取消后新建文件，外部接收后继续保留路径，by AI.Coding。
final class ImageDragSession: Sendable {
    private struct State {
        var finished = false
        var retain = false
        var urls: [String: URL] = [:]
        var created = Set<URL>()
    }
    private let state = Mutex(State())
    /// 每项只兑现一次；锁覆盖创建/登记，结束会话不会漏掉跨线程的新建路径。
    func fileURL(key: String, create: () throws -> (url: URL, created: Bool)) throws -> URL {
        #if DEBUG
        let requested = ProcessInfo.processInfo.systemUptime
        #endif
        return try state.withLock { state in
            #if DEBUG
            let acquired = ProcessInfo.processInfo.systemUptime, mainThread = Thread.isMainThread
            defer {
                let ended = ProcessInfo.processInfo.systemUptime, provided = state.urls[key] != nil
                Task { @MainActor in GUIAcceptanceProbe.exportRequest("image-lock", id: key, type: SupportedType.fileURL, provided: provided, bytes: -1, at: ended, durationMs: (ended - acquired) * 1000, mainThread: mainThread, lockWaitMs: (acquired - requested) * 1000) }
            }
            #endif
            guard !state.finished || state.retain else { throw StoreError.notFound }
            if let url = state.urls[key] { return url }
            let file = try create()
            state.urls[key] = file.url
            if file.created && !state.finished { state.created.insert(file.url) }
            return file.url
        }
    }
    /// 返回唯一允许回收的本次新建路径；已接受的外部引用不会回收。
    func finish(keepFiles: Bool) -> [URL] {
        state.withLock { state in
            guard !state.finished else { return [] }
            state.finished = true; state.retain = keepFiles
            let files = keepFiles ? [] : Array(state.created)
            state.created.removeAll()
            if !keepFiles { state.urls.removeAll() }
            return files
        }
    }
}
/// 只提供原图与URL；原生文件承诺由同项的NSFilePromiseProvider独立兑现，by AI.Coding。
private final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let access: ClipExportAccess
    private let index: Int
    let types: [String]
    private let token: String
    private let session: ImageDragSession
    private let fileName: String
    private let key = UUID().uuidString
    init(access: ClipExportAccess, index: Int, types: [String], token: String, session: ImageDragSession, fileName: String) {
        self.access = access; self.index = index; self.types = types; self.token = token
        self.session = session; self.fileName = fileName
    }
    /// 当前项被索取时设置其数据；注册时不读载荷、不写图片文件。
    func pasteboard(_ board: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = value(for: type) as? Data { item.setData(data, forType: type) }
    }
    /// 目标首次索取URL才读取/哈希/写出原图；无需等待主线程actor回调。
    func value(for type: NSPasteboard.PasteboardType) -> Any? {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime, mainThread = Thread.isMainThread
        #endif
        let value: Any?
        if type == .fileURL {
            value = [SupportedType.png, SupportedType.tiff, SupportedType.jpeg].first(where: types.contains).flatMap { imageType in
                try? session.fileURL(key: key) { try access.materializeDragFile(index: index, type: imageType, fileName: fileName) }.dataRepresentation
            }
        } else {
            value = exportValue(access: access, index: index, types: types, token: token, type: type)
        }
        #if DEBUG
        // 原生目标拒绝时区分未请求、请求失败与解码失败；Release不编译诊断，by AI.Coding。
        let id = access.id, type = type.rawValue, provided = value != nil, bytes = (value as? Data)?.count ?? -1, at = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in GUIAcceptanceProbe.exportRequest("image-read", id: id, type: type, provided: provided, bytes: bytes, at: at, durationMs: (at - began) * 1000, mainThread: mainThread) }
        #endif
        return value
    }
}
/// 可整份读出正文的代码文件引用；非代码、过大、二进制或已移动时返回nil，保持原文件拖放，by AI.Coding。
private func codeFile(access: ClipExportAccess, index: Int) -> (url: URL, text: String)? {
    guard let data = try? access.itemData(index: index, type: SupportedType.fileURL),
          let url = PasteboardItemValue([.init(SupportedType.fileURL, data)]).fileURL,
          let text = try? CodeFileReader.read([url]) else { return nil }
    return (url, text)
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
    nonisolated let imageData: ImageDataProvider?
    nonisolated let access: ClipExportAccess
    nonisolated let index: Int
    nonisolated let types: [String]
    nonisolated let token: String
    nonisolated let eager: [String: Data]
    init(access: ClipExportAccess, index: Int, types: [String], token: String, eager: [String: Data], owner: FilePromise, imageData: ImageDataProvider?) {
        self.access = access; self.index = index; self.types = types; self.token = token; self.eager = eager; self.owner = owner
        self.imageData = imageData
        // initWithFileType:delegate:会动态调用子类init；Swift合成的未实现init会直接trap。
        // 使用AppKit头文件标记的指定初始化器，然后设置文件类型与弱delegate；owner保持强引用。
        super.init()
        fileType = owner.plan.fileType
        delegate = owner
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let own = publicTypes(types) + [HistoryViewModel.categoryDragType] + (imageData == nil ? [] : [SupportedType.fileURL])
        return super.writableTypes(for: pasteboard) + (own + eager.keys.filter { !own.contains($0) }.sorted()).map { NSPasteboard.PasteboardType($0) }
    }
    /// 文件承诺与正文保持原路径，内部分类身份在建立会话时即可读取，by AI.Coding。
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type.rawValue == HistoryViewModel.categoryDragType || eager[type.rawValue] != nil { return [] }
        if type == .fileURL, imageData != nil { return .promised }
        return publicTypes(types).contains(type.rawValue) ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if let value = eager[type.rawValue] { return value }
        if let imageData, type == .fileURL || publicTypes(types).contains(type.rawValue) { return imageData.value(for: type) }
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
    /// 代码文件承诺直接复制原文件，沿用原文件名，by AI.Coding。
    let sourceFile: URL?
    init(access: ClipExportAccess, index: Int, types: [String], store: HistoryStore, plan: ContentExportProvider.Plan, base: String, sourceFile: URL? = nil) {
        self.access = access; self.index = index; self.types = types; self.store = store; self.plan = plan; self.base = base; self.sourceFile = sourceFile
    }
    var fileName: String { sourceFile?.lastPathComponent ?? ContentInspector.fileName(base: base, index: number, fileExtension: plan.fileExtension) }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { fileName }
    private final class CompletionBox: @unchecked Sendable {
        let callback: (Error?) -> Void
        init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    }
    /// 不依赖主线程：拖放期间主线程忙于拖拽界面，回主线程会推迟租约释放甚至卡住导出。
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let access = self.access, index = self.index, types = self.types, store = self.store, plan = self.plan
        #if DEBUG
        let at = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in GUIAcceptanceProbe.exportRequest("native-promise-write", id: access.id, type: plan.fileType, provided: true, bytes: -1, at: at) }
        #endif
        let box = CompletionBox(completionHandler)
        // 悬空符号链接也占用名称；不跟随链接判冲突，沿用自动编号且不覆盖。
        if let source = sourceFile {
            do {
                try access.checkValid()
                guard let target = ContentInspector.availableURL(url, exists: { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }) else { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.copyItem(at: source, to: target)
                box.callback(nil)
            } catch { box.callback(error) }
            return
        }
        Task {
            await ExportLeaseQueue.shared.run {
                do {
                    let data = try ContentExportProvider.data(plan, access: access, index: index, types: types)
                    let lease = try await store.writeExport(data, id: access.id, revision: access.revision, fileExtension: plan.fileExtension)
                    // 目标拿到副本后租约即无用；成功或失败都立即释放，避免大幅原始TIFF挤占导出预算。
                    defer { try? FileManager.default.removeItem(at: lease) }
                    try access.checkValid()
                    // 同名文件不覆盖，改写为"名称 2.ext"；copyItem遇到并发出现的同名文件同样失败而不覆盖。
                    guard let target = ContentInspector.availableURL(url, exists: { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }) else { throw CocoaError(.fileWriteFileExists) }
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
        private var dataProviderRegistrationFailed = false
        private var preparedWriters: [any NSPasteboardWriting] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// ⌘T转换菜单定位到所选卡片；只取仍在窗口中的卡片，by AI.Coding。
        static func view(for id: ClipID) -> NSView? { views.allObjects.first { $0.id == id && $0.window != nil } }
        /// 托管目的地按实际卡片裁剪范围选插入锚点，间距也归最近卡片；不以拖动预览位置命中。
        static func dropTarget(at point: NSPoint, in window: NSWindow, model: HistoryViewModel) -> (view: DragView, after: Bool)? {
            let candidates = views.allObjects.filter { view in
                guard view.window === window, view.model === model, !view.isHiddenOrHasHiddenAncestor else { return false }
                let visible = view.bounds.intersection(view.visibleRect)
                guard !visible.isEmpty else { return false }
                return visible.insetBy(dx: -HistoryView.cardSpacing / 2, dy: 0).contains(view.convert(point, from: nil))
            }
            guard let view = candidates.min(by: {
                abs($0.convert(point, from: nil).x - $0.bounds.midX) < abs($1.convert(point, from: nil).x - $1.bounds.midX)
            }) else { return nil }
            return (view, view.convert(point, from: nil).x >= view.bounds.midX)
        }
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
                        // 卡片内联按钮也属于浮层背后；在按钮透传判断前消费关闭手势。
                        if view.model?.dismissPopoverForBackdropClick(count: event.clickCount, timestamp: event.timestamp) == true {
                            view.down = nil; view.pressedID = nil; view.dragged = false; Self.active = nil
                            return nil
                        }
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
        func handPointerToNativeSession() { nativeSessionActive = true; dataProviderRegistrationFailed = false }
        func handle(_ event: NSEvent) -> NSEvent? {
            if nativeSessionActive { return event }
            guard let model else { return event }
            // 面板内确认浮层在最上层：整段左键交还SwiftUI按钮与遮罩，不选择、不拖动、不双击粘贴，by AI.Coding。
            if model.panelConfirmation != nil { down = nil; pressedID = nil; dragged = false; return event }
            // 在卡片选择/改名前消费浮层关闭手势，包括紧随其后的双击第二下。
            if event.type == .leftMouseDown, model.dismissPopoverForBackdropClick(count: event.clickCount, timestamp: event.timestamp) {
                down = nil; pressedID = nil; dragged = false
                return nil
            }
            // 编辑时事件交给原生文本域，不能吞掉定位光标和文字选择；内容编辑打开时先走取消保护，by AI.Coding。
            if model.renamingID == id { return event }
            if model.contentEditorPresented {
                // 外点只取消编辑；清掉整段手势，不能让同一次 mouseUp 选择或双击粘贴。
                down = nil; pressedID = nil; dragged = false
                if event.type == .leftMouseDown { model.requestCancelContentEdit() }
                return nil
            }
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
                    // 下一次准备先等上一轮回收，避免复用路径后被旧清理任务删除，by AI.Coding。
                    await model.waitForDragCleanup()
                    let writers = try await ContentExportProvider.writers(ids: ids, store: model.store, token: token, register: model.registerDragAccess, clock: model.previewClock, registerSession: model.registerDragSession)
                    guard Self.active === self, self.down === down, self.window != nil,
                          NSEvent.pressedMouseButtons & 1 != 0, !writers.isEmpty else { model.finishDrag(cancelled: true); return }
                    let values = writers.enumerated().map { index, writer in
                        let item = NSDraggingItem(pasteboardWriter: writer)
                        item.setDraggingFrame(frame.offsetBy(dx: CGFloat(index)*8, dy: CGFloat(index)*8), contents: image)
                        return item
                    }
                    self.preparedWriters = writers
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
        /// LC-V02：注册失败后禁止接收端接受投放，原生手势仍由AppKit处理到结束，by AI.Coding。
        var allowedDragOperation: NSDragOperation { dataProviderRegistrationFailed ? [] : .copy }
        // 内部排序允许move；外部应用继续接收原有copy操作，by AI.Coding。
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            guard !dataProviderRegistrationFailed else { return [] }
            return context == .withinApplication ? [.copy, .move] : .copy
        }
        /// 不在willBegin中提前结束模型会话；失败的原生会话禁止投放，结束回调统一取消/清理。
        func installDataProviders(on board: NSPasteboard, _ install: () throws -> Void) {
            do { try install() }
            catch {
                dataProviderRegistrationFailed = true
                // 撤销本次会话已部分注册的类型/承诺，避免接收方缓存了copy操作后仍读到半成品。
                board.clearContents()
                model?.message = "拖出失败，无法注册图片输出，请松开鼠标后重试"
            }
        }
        /// AppKit已写入真实原生promise项，在接收方读取前补充公开延迟类型回调，by AI.Coding。
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            installDataProviders(on: session.draggingPasteboard) {
                try ContentExportProvider.installImageDataProviders(preparedWriters, on: session.draggingPasteboard)
                #if DEBUG
                // 仅隔离验收包显式文件命令可注入部分注册失败；不访问系统general板，by AI.Coding。
                if let output = GUIAcceptanceProbe.output {
                    let trigger = output.appendingPathComponent("fail-next-registration")
                    if FileManager.default.fileExists(atPath: trigger.path) {
                        try FileManager.default.removeItem(at: trigger)
                        if let model { GUIAcceptanceProbe.event("registration-failure-injected", model) }
                        throw StoreError.ioFailure
                    }
                }
                #endif
            }
            #if DEBUG
            if let model { GUIAcceptanceProbe.event("native-session-started", model) }
            #endif
        }
        /// 失败注册即使接收端错误报告copy也按取消清理，不保留本轮未接受路径。
        func finishNativeSession(operation: NSDragOperation) {
            preparedWriters.removeAll()
            nativeSessionActive = false; down = nil; pressedID = nil; Self.active = nil
            model?.finishDrag(cancelled: dataProviderRegistrationFailed || operation.isEmpty)
            dataProviderRegistrationFailed = false
        }
        /// 原生结束事件是模型状态与文件生命周期的唯一结束点，by AI.Coding。
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishNativeSession(operation: operation)
            #if DEBUG
            if let model { GUIAcceptanceProbe.event("native-session-ended-\(operation.rawValue)", model) }
            #endif
        }
        deinit {
            MainActor.assumeIsolated {
                Self.views.remove(self)
                if Self.views.allObjects.isEmpty, let monitor = Self.monitor { NSEvent.removeMonitor(monitor); Self.monitor = nil }
            }
        }
    }
}
