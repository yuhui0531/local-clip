// 系统剪贴板 adapter 与可测试的原始读取边界，by AI.Coding。
import AppKit
import LocalClipCore
@MainActor public protocol PasteboardAccess: AnyObject {
    var count: Int { get }
    var types: [[String]]? { get }
    func data(item: Int, type: String) -> Data?
    func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool
}
@MainActor public final class NativePasteboardAccess: PasteboardAccess {
    public let board: NSPasteboard
    public static let ownType = "local.localclip.self-write"
    public init(_ board: NSPasteboard = .general) { self.board = board }
    public var count: Int { board.changeCount }
    public var types: [[String]]? { board.pasteboardItems?.map { $0.types.map(\.rawValue) } }
    /// 不调用文件 promise，不隐式读取文件本体。
    public func data(item: Int, type: String) -> Data? {
        guard let items = board.pasteboardItems, items.indices.contains(item) else { return nil }
        return items[item].data(forType: .init(type))
    }
    /// 原始多项和全部支持表示保持；自写标记不纳入历史内容身份。
    public func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool {
        let objects = payload.items.map { item in
            let object = NSPasteboardItem()
            for representation in item.representations {
                object.setData(representation.data, forType: .init(representation.type))
            }
            object.setString(fingerprint, forType: .init(Self.ownType))
            return object
        }
        board.clearContents()
        return board.writeObjects(objects)
    }
}
@MainActor public final class MacPasteboardClient: PasteboardClient {
    private let access: any PasteboardAccess
    private let clock: any ClipClock
    private let observedSource: (Int) -> SourceAttribution
    public init(access: any PasteboardAccess = NativePasteboardAccess(), clock: any ClipClock = SystemClock(), observedSource: @escaping (Int) -> SourceAttribution = { _ in .unknown }) {
        self.access = access; self.clock = clock; self.observedSource = observedSource
    }
    public var changeCount: Int { access.count }
    /// 所有类型先检查，敏感/排除/暂停时正文读取次数为零。
    public func capture(after: Int, policy: SettingsSnapshot) -> CaptureOutcome {
        guard access.count != after else { return .noChange }
        for _ in 0..<3 {
            let before = access.count
            guard let types = access.types else { return .skipped(.accessUnavailable, before) }
            if before != access.count { continue }
            if let reason = policy.rejection(source: .unknown, types: types) { return .skipped(reason, before) }
            if policy.pauseWhenExcludedFrontmost, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, policy.excludedBundleIDs.contains(id) {
                return .skipped(.excluded, before)
            }
            guard !types.isEmpty else { return .skipped(.unsupported, before) }
            guard types.count <= 32 else { return .skipped(.tooLarge, before) }
            var sources: [String] = []
            for (index, list) in types.enumerated() where list.contains("org.nspasteboard.source") {
                if let data = access.data(item: index, type: "org.nspasteboard.source"), let text = String(data: data, encoding: .utf8) { sources.append(text) }
                else { sources.append("") }
            }
            if before != access.count { continue }
            var source = SourceAttribution.declared(sources)
            // 用户追加来源展示：只有完全没有声明时才使用前台推断；冲突/非法声明仍未知。
            // 自写计数由CaptureCoordinator精确过滤，不把自身恢复归因给原目标应用。
            if sources.isEmpty, !types.contains(where: { $0.contains(NativePasteboardAccess.ownType) }) {
                source = observedSource(before)
            }
            if before != access.count { continue }
            if let id = source.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                if source.basis == "declared" {
                    source.name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
                        ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                }
            }
            if let reason = policy.rejection(source: source, types: types) { return .skipped(reason, before) }
            var items: [PasteboardItemValue] = []; var size: Int64 = 0
            var failure: SkipReason?
            for (index, list) in types.enumerated() {
                // 真正的文件URL可以入库；仅有延迟promise时不触发下载或读取文件。
                if list.contains("com.apple.pasteboard.promised-file-url"), !list.contains(SupportedType.fileURL) { failure = .unsupported; break }
                let supported = list.filter { SupportedType.all.contains($0) }.sorted()
                if supported.isEmpty { failure = .unsupported; break }
                var values: [Representation] = []
                for type in supported {
                    guard let data = access.data(item: index, type: type) else { failure = .accessUnavailable; break }
                    size += Int64(data.count)
                    if size > 50 * MiB { failure = .tooLarge; break }
                    if type == SupportedType.fileURL, PasteboardItemValue([.init(type, data)]).fileURL == nil { failure = .unsupported; break }
                    if type == SupportedType.url, let text = String(data: data, encoding: .utf8), URL(string: text)?.isFileURL == true,
                       !list.contains(SupportedType.fileURL) { failure = .unsupported; break }
                    values.append(.init(type, data))
                }
                if failure != nil { break }
                items.append(.init(values, declaredTypes: list.filter { $0 != NativePasteboardAccess.ownType && $0 != "org.nspasteboard.source" }))
            }
            if before != access.count { continue }
            if let failure { return .skipped(failure, before) }
            let payload = ClipboardPayload(items)
            if payload.hasFileReferences, payload.fileURLs == nil { return .skipped(.unsupported, before) }
            return .snapshot(.init(payload: payload, count: before, at: clock.now(), source: source, revision: policy.revision))
        }
        return .skipped(.changedDuringRead, access.count)
    }
    /// 调用方预先在后台计算指纹，adapter 不在主线程哈希大图。
    public func write(_ payload: ClipboardPayload, fingerprint: String) -> WriteReceipt {
        let successful = access.write(payload, fingerprint: fingerprint)
        return .init(count: access.count, fingerprint: fingerprint, successful: successful)
    }
    /// exact count + 指纹控制标记；用户随后复制会立即使 receipt 失效。
    public func matches(_ receipt: WriteReceipt) -> Bool {
        guard receipt.successful, access.count == receipt.count,
              let bytes = access.data(item: 0, type: NativePasteboardAccess.ownType),
              String(data: bytes, encoding: .utf8) == receipt.fingerprint else { return false }
        return true
    }
}
