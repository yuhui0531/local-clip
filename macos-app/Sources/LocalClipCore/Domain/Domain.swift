// 跨模块的纯值契约，不携带系统对象，by AI.Coding。
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
public typealias ClipID = String
public typealias Instant = Int64
public let dayMS: Int64 = 86_400_000
public let MiB: Int64 = 1_048_576
public protocol ClipClock: Sendable { func now() -> Instant }
public struct SystemClock: ClipClock {
    public init() {}
    /// UTC 毫秒用于保留期限，执行耗时另用单调时钟。
    public func now() -> Instant { Int64(Date().timeIntervalSince1970 * 1000) }
}
public enum StoreError: String, Error, Sendable {
    case diskFull, quotaExceeded, ioFailure, corruptPayload, incompatibleSchema, stalePreview
    case postCommitUnavailable, notFound, invalidSettings, invalidCursor, unavailable, policyChanged
}
public enum SkipReason: String, Codable, Sendable {
    case sensitive, unsupported, tooLarge, paused, excluded, changedDuringRead, accessUnavailable, busy, selfWrite
}
public enum SupportedType {
    public static let string = "public.utf8-plain-text"
    public static let url = "public.url"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"
    public static let fileURL = "public.file-url"
    public static let all: Set<String> = [string, url, rtf, html, png, tiff, jpeg, fileURL]
    public static let markers: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
}
public struct Representation: Codable, Hashable, Sendable {
    public var type: String
    public var data: Data
    public init(_ type: String, _ data: Data) { self.type = type; self.data = data }
}
public struct PasteboardItemValue: Codable, Equatable, Sendable {
    public var representations: [Representation]
    public var declaredTypes: [String]
    public var plainText: String?
    public init(_ representations: [Representation], declaredTypes: [String] = [], plainText: String? = nil) {
        self.representations = representations; self.declaredTypes = declaredTypes; self.plainText = plainText
    }
    /// 文件引用只接受完整的本地 file URL；采集时不读取文件本体。
    public var fileURL: URL? {
        guard let value = representations.first(where: { $0.type == SupportedType.fileURL }),
              let text = String(data: value.data, encoding: .utf8),
              let url = URL(string: text), url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url
    }
}
extension PasteboardItemValue {
    /// 保留旧接口；类型共存无法证明像素、页数或元数据等价，必须保留原始表示。
    public var withoutRedundantTIFF: PasteboardItemValue {
        self
    }
}
public struct ClipboardPayload: Codable, Equatable, Sendable {
    public var items: [PasteboardItemValue]
    public init(_ items: [PasteboardItemValue]) { self.items = items }
    /// 逐项返回文件引用，保持复制顺序；混入无文件项时不静默丢弃。
    public var fileURLs: [URL]? {
        let urls = items.compactMap(\.fileURL)
        return !items.isEmpty && urls.count == items.count ? urls : nil
    }
    public var hasFileReferences: Bool { items.contains { $0.representations.contains { $0.type == SupportedType.fileURL } } }
    /// 多项不能静默丢弃图片，任一无文本就不可纯文本恢复。
    public var plainText: String? {
        let texts = items.compactMap(\.plainText)
        return texts.count == items.count && !items.isEmpty ? texts.joined(separator: "\n") : nil
    }
    public var byteCount: Int64 { items.reduce(0) { $0 + $1.representations.reduce(0) { $0 + Int64($1.data.count) } } }
    /// 带长度编码且只排序表示，不改变项目顺序。
    public var canonicalData: Data {
        var result = Data()
        func integer(_ value: Int) { var v = UInt64(value).bigEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        func field(_ value: Data) { integer(value.count); result.append(value) }
        integer(1); integer(items.count)
        for item in items {
            let values = item.representations.sorted { $0.type < $1.type }
            integer(values.count)
            for value in values { field(Data(value.type.utf8)); field(value.data) }
        }
        return result
    }
    public var fingerprint: String { ContentFingerprint.hash(canonicalData) }
    /// 保留旧接口，不依据类型删除任何原始表示。
    public var withoutRedundantTIFF: ClipboardPayload { self }
    public var kind: ClipKind {
        if hasFileReferences { return fileURLs != nil ? .file : .mixed }
        let types = Set(items.flatMap { $0.representations.map(\.type) })
        let images = !types.isDisjoint(with: [SupportedType.png, SupportedType.tiff, SupportedType.jpeg])
        let texts = !types.isDisjoint(with: [SupportedType.string, SupportedType.url, SupportedType.rtf, SupportedType.html])
        if images { return texts ? .mixed : .image }
        // 富文本也是文本，原始RTF/HTML表示照常保留，粘贴与导出不受影响，by AI.Coding。
        if types.contains(SupportedType.rtf) || types.contains(SupportedType.html) { return .text }
        if types.contains(SupportedType.url) { return .url }
        // 浏览器地址栏等来源只写纯文本；单项全文恰为一个网址时同样归为链接，by AI.Coding。
        guard items.count == 1, let value = items[0].representations.first(where: { $0.type == SupportedType.string }),
              let text = String(data: value.data, encoding: .utf8) else { return .text }
        return Self.webLink(text) != nil ? .url : .text
    }
    /// 系统能解码的图片文件，只看扩展名不读文件；SVG等无法下采样的图片类型不算，by AI.Coding。
    public static func isImageFile(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .image) else { return false }
        return decodableImageTypes.contains(type.identifier)
    }
    private static let decodableImageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    /// 整段文本去首尾空白后是唯一的网址才返回；夹带空白或其他文字的段落仍是文本。
    /// 无协议时交给系统链接识别（按真实顶级域判断），"README.md"、"v0.3.22"等不会误判，结果补全为http。
    // 不可变链接检测器共用，匹配行为与完整范围校验保持不变，by AI.Coding。
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    public static func webLink(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192, !value.contains(where: \.isWhitespace) else { return nil }
        if value.contains("://") {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
            return url
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let detector = linkDetector,
              let match = detector.firstMatch(in: value, range: range), match.range == range,
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
public enum ContentFingerprint {
    /// SHA256 只是查找键，存储层还须比较规范原始内容。
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
// 来源依据区分声明与前台推断，只有声明参与应用排除，by AI.Coding。
public struct SourceAttribution: Codable, Equatable, Sendable {
    public var bundleID: String?
    public var name: String
    public var basis: String
    public static let unknown = SourceAttribution(bundleID: nil, name: "未知", basis: "unknown")
    public init(bundleID: String?, name: String, basis: String = "declared") { self.bundleID = bundleID; self.name = name; self.basis = basis }
    /// 协作声明不是防伪身份；冲突/非法标记保持未知，缺失时由Mac层另行提供推断。
    public static func declared(_ values: [String], names: [String: String] = [:]) -> SourceAttribution {
        guard !values.isEmpty, Set(values).count == 1, let first = values.first,
              first.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { return .unknown }
        return .init(bundleID: first, name: names[first] ?? first)
    }
}
public struct ClipboardSnapshot: Sendable {
    public var captureID: String
    public var changeCount: Int
    public var capturedAt: Instant
    public var payload: ClipboardPayload
    public var source: SourceAttribution
    public var policyRevision: Int64
    /// 采集后台解码阶段生成的派生缩略图；不参与内容身份。
    public var thumbnail: Data?
    public init(payload: ClipboardPayload, count: Int = 0, at: Instant = SystemClock().now(), source: SourceAttribution = .unknown, revision: Int64 = 0, id: String = UUID().uuidString) {
        self.captureID = id; self.changeCount = count; self.capturedAt = at
        self.payload = payload; self.source = source; self.policyRevision = revision
    }
}
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32 = 9, modifiers: UInt32 = 2304) { self.keyCode = keyCode; self.modifiers = modifiers }
}
// 用户外观选择与布局密度分别存储，紧凑不改变颜色主题，by AI.Coding。
public enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}
/// 发布标签（如 v0.3.16-38）与应用版本号按数字分段比较，忽略前缀v与“-构建号”后缀，by AI.Coding。
public enum AppVersion {
    /// 去掉前缀v和“-”“+”之后的构建信息，得到可比较、可展示的版本号。
    public static func marketing(_ value: String) -> String {
        String(value.drop(while: { $0 == "v" || $0 == "V" }).prefix(while: { $0 != "-" && $0 != "+" }))
    }
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] { marketing(value).split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
public struct SettingsSnapshot: Codable, Equatable, Sendable {
    // 可选字段允许已有设置直接读取；没有选择时保持系统外观与自适应布局。
    private var appearanceValue: AppAppearance?
    private var compactLayoutValue: Bool?
    public var appearance: AppAppearance {
        get { appearanceValue ?? .system }
        set { appearanceValue = newValue }
    }
    public var compactLayout: Bool {
        get { compactLayoutValue == true }
        set { compactLayoutValue = newValue }
    }
    public var retentionDays = 30
    public var defaultFormat: OutputFormat = .original
    public var pauseUntil: Instant?
    public var pauseWhenExcludedFrontmost = false
    public var panelHeight = 340.0
    // 可选存储字段通过默认值关闭功能，无历史迁移或自定义解码，by AI.Coding。
    private var codeFilePasteEnabled: Bool?
    public var smartCodeFilePaste: Bool {
        get { codeFilePasteEnabled == true }
        set { codeFilePasteEnabled = newValue }
    }
    // 通过本应用复制/粘贴后置前；缺失字段按开启处理，by AI.Coding。
    private var moveUsedToFrontValue: Bool?
    public var moveUsedToFront: Bool {
        get { moveUsedToFrontValue ?? true }
        set { moveUsedToFrontValue = newValue }
    }
    public var captureSounds = false
    public var showMenuIcon = true
    public var hideContents = false
    public var excludeFromSharing = false
    public var timingEnabled = false
    public var quickModifiers: UInt32 = 256
    public var boardModifiers: UInt32 = 2304
    public var quotaBytes = 500 * MiB
    // 新安装Enter直接粘贴；已保存的设置按原值解码，不改变老用户行为，by AI.Coding。
    public var defaultAction: PasteAction = .directPaste
    public var captureEnabled = true
    public var excludedBundleIDs: Set<String> = []
    // opt-in 编辑器列表默认关闭；缺失字段按空集合处理，by AI.Coding。
    // 默认每天最多一次读取GitHub最新版本号；缺失字段按开启处理，by AI.Coding。
    private var autoCheckUpdatesValue: Bool?
    public var autoCheckUpdates: Bool {
        get { autoCheckUpdatesValue ?? true }
        set { autoCheckUpdatesValue = newValue }
    }
    private var smartPasteEditorBundleIDsValue: Set<String>?
    public var smartPasteEditorBundleIDs: Set<String> {
        get { smartPasteEditorBundleIDsValue ?? [] }
        set { smartPasteEditorBundleIDsValue = newValue }
    }
    public var shortcut = Shortcut()
    /// 粘贴队列"下一项"快捷键，默认⌃⌥V；缺失字段按默认处理，只在队列进行中注册，by AI.Coding。
    private var queueShortcutValue: Shortcut?
    public var queueShortcut: Shortcut {
        get { queueShortcutValue ?? Shortcut(keyCode: 9, modifiers: 6144) }
        set { queueShortcutValue = newValue }
    }
    public var revision: Int64 = 0
    public init() {}
    /// 设置范围校验不影响测试注入的小配额。
    public func validate() throws {
        guard (0...365).contains(retentionDays), (100 * MiB...4096 * MiB).contains(quotaBytes), shortcut.keyCode <= 127,
              shortcut.modifiers != 0, queueShortcut.keyCode <= 127, queueShortcut.modifiers != 0, queueShortcut != shortcut, (220...520).contains(panelHeight),
              [UInt32(256),4096,2048,768].contains(quickModifiers), [UInt32(768),2304,6144].contains(boardModifiers) else { throw StoreError.invalidSettings }
    }
    /// 所有入库入口应用同一策略，旧配置快照不得穿透新暂停。
    public func rejection(source: SourceAttribution, types: [[String]], revision: Int64? = nil, at: Instant = SystemClock().now()) -> SkipReason? {
        if types.contains(where: { !Set($0).isDisjoint(with: SupportedType.markers) }) { return .sensitive }
        // 暂停判断使用采集/存储入口的时钟；默认值保持旧调用兼容，by AI.Coding。
        if !captureEnabled || (pauseUntil ?? 0) > at { return .paused }
        if let id = source.bundleID, source.basis == "declared", excludedBundleIDs.contains(id) { return .excluded }
        return nil
    }
}
public enum CaptureOutcome: Sendable { case noChange, snapshot(ClipboardSnapshot), skipped(SkipReason, Int) }
public enum IngestResult: Equatable, Sendable { case inserted(ClipID), deduplicated(ClipID), skipped(SkipReason) }
public struct ClipSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: ClipID
    public var firstCopiedAt: Instant
    public var lastCopiedAt: Instant
    public var copyCount: Int
    public var kind: ClipKind
    public var isFavorite: Bool
    public var isProtected: Bool = false
    public var source: SourceAttribution
    public var preview: String
    public var context: String
    // 默认标题仍由种类决定，自定义名称不参与内容身份，by AI.Coding。
    public var title: String? = nil
    // 内容身份随编辑变化；轻量查询即可使卡片缓存失效，无需读取正文，by AI.Coding。
    public var contentFingerprint: String? = nil
}
public struct ClipDetail: Sendable {
    public var summary: ClipSummary
    public var payload: ClipboardPayload
    public var revision: Int64
    public var categoryIDs: Set<String> = []
}
// 选择卡片仅读取轻量元数据，避免为了高亮或分类菜单加载图片正文，by AI.Coding。
public struct ClipMetadata: Equatable, Sendable {
    public var summary: ClipSummary
    public var categoryIDs: Set<String>
    public var hasTextRepresentations: Bool
    public var revision: Int64
    /// 输出预检仅读字节计数与类型，不读取正文，by AI.Coding。
    public var outputByteCount: Int64 = 0
    public var hasFileReferences: Bool = false
}
// 用户分类是SQLite元数据，可重命名，归属与内容格式身份分离，by AI.Coding。
public struct ClipCategory: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var colorHex: String = "34C759"
    public var position: Int = 0
}
public enum CategoryError: Error, Sendable {
    case invalidName, duplicateName, notFound
    public var message: String {
        switch self {
        case .invalidName: "分类名称需为1–64个字符，不能包含换行或控制字符"
        case .duplicateName: "已存在同名分类，请使用其他名称"
        case .notFound: "分类已不存在，请重新选择"
        }
    }
}
public struct SearchCursor: Sendable, Equatable { public var revision: Int64; public var offset: Int; public var signature: String }
// 所有筛选参与分页身份，分类取并集，其他条件取交集，by AI.Coding。
public struct SearchRequest: Sendable {
    public var queryID: UUID
    public var literal: String
    public var favoritesOnly: Bool
    public var kind: ClipKind?
    public var cursor: SearchCursor?
    public var pageSize: Int
    public var categoryIDs: Set<String>
    public var sourceBundleID: String?
    public var from: Instant?
    public var until: Instant?
    public init(_ literal: String = "", favorites: Bool = false, kind: ClipKind? = nil, cursor: SearchCursor? = nil, queryID: UUID = UUID(), pageSize: Int = 50, categoryIDs: Set<String> = [], sourceBundleID: String? = nil, from: Instant? = nil, until: Instant? = nil) {
        self.literal = literal; self.favoritesOnly = favorites; self.kind = kind; self.cursor = cursor; self.queryID = queryID; self.pageSize = pageSize
        self.categoryIDs = categoryIDs; self.sourceBundleID = sourceBundleID; self.from = from; self.until = until
    }
    public var signature: String {
        let values = [literal, String(favoritesOnly), kind?.rawValue ?? "", categoryIDs.sorted().joined(separator: ","), sourceBundleID ?? "", String(from ?? Int64.min), String(until ?? Int64.max)]
        return ContentFingerprint.hash((try? JSONEncoder().encode(values)) ?? Data())
    }
}
public struct SearchPage: Sendable { public var queryID: UUID; public var revision: Int64; public var items: [ClipSummary]; public var next: SearchCursor? }
public enum HistoryChange: Sendable, Equatable {
    case favorite(ClipID, Bool), favorites([ClipID], Bool), delete([ClipID]), clearOrdinary, retention(Int), quota(Int64)
    case category([ClipID], String, Bool), deleteCategory(String)
}
public struct ChangePreview: Sendable {
    public var token: UUID
    public var operation: HistoryChange
    public var storeRevision: Int64
    public var settingsRevision: Int64
    public var affectedCount: Int
    public var estimatedReclaimBytes: Int64
    public var requiresConfirmation: Bool
    public var message: String
    /// 删除预览的保护数量与撤销能力；其他操作无撤销估算，by AI.Coding。
    public var protectedCount: Int = 0
    public var canUndo: Bool? = nil
    public var undoUnavailableReason: String? = nil
}
public struct ChangeResult: Sendable { public var removed: Int; public var reclaimedBytes: Int64; public var revision: Int64 }
public struct StorageUsage: Equatable, Sendable {
    public var measuredTotal: Int64
    public var favoritePayload: Int64
    public var normalPayload: Int64
    public var common: Int64
    public var pending: Int64
    public var temporary: Int64
}
public struct RecoveryReport: Sendable { public var revision: Int64; public var pendingBytes: Int64 }
public enum HistoryEvent: Sendable { case changed(Int64), settings(Int64), derived(ClipID), unavailable(StoreError) }
public enum FaultPoint: String, Sendable, CaseIterable { case candidateCreated, candidateWritten, candidateValidated, beforeReplace, afterReplace, reopen }
public protocol StorageFaultInjector: Sendable { func check(_ point: FaultPoint) throws }
public struct NoStorageFault: StorageFaultInjector { public init() {}; public func check(_ point: FaultPoint) throws {} }
public protocol HistoryRepository: Sendable {
    func ingest(_ snapshot: ClipboardSnapshot, at: Instant) async throws -> IngestResult
    func search(_ request: SearchRequest) async throws -> SearchPage
    func detail(id: ClipID, at: Instant) async throws -> ClipDetail
    func metadata(id: ClipID, at: Instant) async throws -> ClipMetadata
    func loadPayload(id: ClipID, at: Instant) async throws -> ClipboardPayload
    func settings() async throws -> SettingsSnapshot
    func preview(_ change: HistoryChange) async throws -> ChangePreview
    func apply(_ token: UUID) async throws -> ChangeResult
    func expire(at: Instant) async throws -> ChangeResult
    func usage() async throws -> StorageUsage
    func canCapture() async throws -> Bool
    func updateCaptureSettings(_ settings: SettingsSnapshot) async throws -> SettingsSnapshot
    func events() async -> AsyncStream<HistoryEvent>
    func recover() async throws -> RecoveryReport
}
public struct TargetToken: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String
    public var launchedAt: TimeInterval
    public var session: UUID
    public init(pid: Int32, bundleID: String, launchedAt: TimeInterval, session: UUID = UUID()) { self.pid = pid; self.bundleID = bundleID; self.launchedAt = launchedAt; self.session = session }
}
public struct PasteRequest: Sendable {
    public var ids: [ClipID]
    public var format: OutputFormat
    public var action: PasteAction
    public var target: TargetToken?
    /// 本次输出的文字转换；nil保持原有输出，by AI.Coding。
    public var transform: TextTransform?
    /// 多选合并方式；换行保持原有输出，by AI.Coding。
    public var join: JoinStyle
    public init(ids: [ClipID], format: OutputFormat = .original, action: PasteAction = .copy, target: TargetToken? = nil, transform: TextTransform? = nil, join: JoinStyle = .newline) {
        self.ids = ids; self.format = format; self.action = action; self.target = target; self.transform = transform; self.join = join
    }
}
public struct WriteReceipt: Sendable, Equatable { public var count: Int; public var fingerprint: String; public var successful: Bool; public init(count: Int, fingerprint: String, successful: Bool) { self.count = count; self.fingerprint = fingerprint; self.successful = successful } }
@MainActor public protocol PasteboardClient: AnyObject {
    var changeCount: Int { get }
    func capture(after: Int, policy: SettingsSnapshot) -> CaptureOutcome
    func captureAsync(after: Int, policy: SettingsSnapshot) async -> CaptureOutcome
    func write(_ payload: ClipboardPayload, fingerprint: String) -> WriteReceipt
    func matches(_ receipt: WriteReceipt) -> Bool
}
extension PasteboardClient {
    /// 测试边界可同步读取，实际系统适配器覆写后台正文读取。
    public func captureAsync(after: Int, policy: SettingsSnapshot) async -> CaptureOutcome { capture(after: after, policy: policy) }
}
public enum PasteTargetKind: Sendable { case text, files, unknown }
@MainActor public protocol ApplicationClient: AnyObject {
    var permitted: Bool { get }
    var pasteFailureReason: String? { get }
    func requestPastePermission()
    func target() -> TargetToken?
    func pasteTargetKind(_ target: TargetToken) -> PasteTargetKind
    func pasteTargetKind(_ target: TargetToken, smartPasteEditorBundleIDs: Set<String>) -> PasteTargetKind
    func isAlive(_ target: TargetToken) -> Bool
    func isFrontmost(_ target: TargetToken) -> Bool
    func activate(_ target: TargetToken) -> Bool
    func restorePasteFocus(_ target: TargetToken) -> Bool
    func isPasteFocusReady(_ target: TargetToken) -> Bool
    func sendPaste(_ target: TargetToken, ifClipboardUnchanged: () -> Bool) -> Bool
}
extension ApplicationClient {
    public func pasteTargetKind(_ target: TargetToken, smartPasteEditorBundleIDs: Set<String>) -> PasteTargetKind {
        pasteTargetKind(target)
    }
}
public enum ClipKind: String, Codable, Sendable, CaseIterable { case text, url, image, file, mixed }
public enum OutputFormat: String, Codable, Sendable { case original, plainText }
public enum PasteAction: String, Codable, Sendable { case copy, directPaste }
public enum PasteResult: Equatable, Sendable {
    case copied, commandSent, filesCopied(String), fallback(String), failed(String)
    /// 仅陈述可证明的操作结果。
    public var message: String {
        switch self {
        case .copied: "已复制到剪贴板"
        case .commandSent: "已发送粘贴指令"
        case .filesCopied(let message): message
        case .fallback(let reason): "已复制，\(reason)"
        case .failed(let reason): reason
        }
    }
}
