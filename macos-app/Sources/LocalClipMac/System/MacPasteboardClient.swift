// 系统剪贴板 adapter 与可测试的原始读取边界，by AI.Coding。
import AppKit
import LocalClipCore
@MainActor public protocol PasteboardAccess: AnyObject {
    var count: Int { get }
    var types: [[String]]? { get }
    func data(item: Int, type: String) -> Data?
    func readBody(types: [[String]], expectedCount: Int) async -> PasteboardBody
    func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool
}
public enum PasteboardBody: Sendable {
    case payload(ClipboardPayload), failure(SkipReason)
    /// 后台重开剪贴板后先复查当前世代/全部类型；每次正文IPC前后仍检查世代。
    static func readApproved(types: [[String]], expectedCount: Int, currentCount: () -> Int,
                             currentTypes: () -> [[String]]?, data: (Int, String) -> Data?) -> PasteboardBody {
        guard currentCount() == expectedCount else { return .failure(.changedDuringRead) }
        guard let actualTypes = currentTypes() else { return .failure(.accessUnavailable) }
        guard currentCount() == expectedCount else { return .failure(.changedDuringRead) }
        guard !actualTypes.contains(where: { !Set($0).isDisjoint(with: SupportedType.markers) }) else { return .failure(.sensitive) }
        guard actualTypes.map({ Set($0) }) == types.map({ Set($0) }) else { return .failure(.changedDuringRead) }
        guard !actualTypes.isEmpty else { return .failure(.unsupported) }
        guard actualTypes.count <= 32 else { return .failure(.tooLarge) }
        let body = read(types: actualTypes) { index, type in
            guard currentCount() == expectedCount else { return nil }
            return data(index, type)
        }
        guard currentCount() == expectedCount else { return .failure(.changedDuringRead) }
        return body
    }
    /// 保留全部支持表示和项目顺序；正文最多50MiB，不触发文件promise。
    static func read(types: [[String]], data: (Int, String) -> Data?) -> PasteboardBody {
        var items: [PasteboardItemValue] = []; var size: Int64 = 0
        for (index, list) in types.enumerated() {
            if list.contains("com.apple.pasteboard.promised-file-url"), !list.contains(SupportedType.fileURL) { return .failure(.unsupported) }
            let supported = list.filter { SupportedType.all.contains($0) }.sorted()
            guard !supported.isEmpty else { return .failure(.unsupported) }
            var values: [Representation] = []
            for type in supported {
                guard let bytes = data(index, type) else { return .failure(.accessUnavailable) }
                size += Int64(bytes.count)
                guard size <= 50 * MiB else { return .failure(.tooLarge) }
                if type == SupportedType.fileURL, PasteboardItemValue([.init(type, bytes)]).fileURL == nil { return .failure(.unsupported) }
                if type == SupportedType.url, let text = String(data: bytes, encoding: .utf8), URL(string: text)?.isFileURL == true,
                   !list.contains(SupportedType.fileURL) { return .failure(.unsupported) }
                values.append(.init(type, bytes))
            }
            items.append(.init(values, declaredTypes: list.filter { $0 != "local.localclip.self-write" && $0 != "org.nspasteboard.source" }))
        }
        let payload = ClipboardPayload(items)
        if payload.hasFileReferences, payload.fileURLs == nil { return .failure(.unsupported) }
        return .payload(payload)
    }
}
extension PasteboardAccess {
    /// 假系统同步执行相同正文校验；原生适配器把IPC读取移出主线程。
    public func readBody(types: [[String]], expectedCount: Int) async -> PasteboardBody {
        PasteboardBody.readApproved(types: types, expectedCount: expectedCount, currentCount: { count }, currentTypes: { self.types }, data: data)
    }
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
    /// 工作者自行打开相同命名剪贴板，不跨actor传递AppKit对象。
    public func readBody(types: [[String]], expectedCount: Int) async -> PasteboardBody {
        let name = board.name.rawValue
        return await Task.detached(priority: .utility) {
            let board = NSPasteboard(name: .init(name))
            var items: [NSPasteboardItem] = []
            return PasteboardBody.readApproved(types: types, expectedCount: expectedCount, currentCount: { board.changeCount }, currentTypes: {
                guard let current = board.pasteboardItems else { return nil }
                items = current
                return current.map { $0.types.map(\.rawValue) }
            }) { index, type in
                guard items.indices.contains(index) else { return nil }
                return items[index].data(forType: .init(type))
            }
        }.value
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
    private struct ReadPlan {
        let count: Int, types: [[String]], source: SourceAttribution, at: Instant
    }
    private enum Preparation { case outcome(CaptureOutcome), read(ReadPlan) }
    /// 先检查标记及排除来源；只有批准的快照才能读取正文。
    private func prepare(after: Int, policy: SettingsSnapshot) -> Preparation {
        guard access.count != after else { return .outcome(.noChange) }
        let before = access.count
        guard let types = access.types else { return .outcome(.skipped(.accessUnavailable, before)) }
        if before != access.count { return .outcome(.skipped(.changedDuringRead, access.count)) }
        if let reason = policy.rejection(source: .unknown, types: types) { return .outcome(.skipped(reason, before)) }
        if policy.pauseWhenExcludedFrontmost, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, policy.excludedBundleIDs.contains(id) {
            return .outcome(.skipped(.excluded, before))
        }
        guard !types.isEmpty else { return .outcome(.skipped(.unsupported, before)) }
        guard types.count <= 32 else { return .outcome(.skipped(.tooLarge, before)) }
        var sources: [String] = []
        for (index, list) in types.enumerated() where list.contains("org.nspasteboard.source") {
            if let data = access.data(item: index, type: "org.nspasteboard.source"), let text = String(data: data, encoding: .utf8) { sources.append(text) }
            else { sources.append("") }
        }
        if before != access.count { return .outcome(.skipped(.changedDuringRead, access.count)) }
        var source = SourceAttribution.declared(sources)
        // 用户追加来源展示：只有完全没有声明时才使用前台推断；冲突/非法声明仍未知。
        // 自写计数由CaptureCoordinator精确过滤，不把自身恢复归因给原目标应用。
        if sources.isEmpty, !types.contains(where: { $0.contains(NativePasteboardAccess.ownType) }) {
            source = observedSource(before)
        }
        if before != access.count { return .outcome(.skipped(.changedDuringRead, access.count)) }
        if let id = source.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            if source.basis == "declared" {
                source.name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
        }
        if let reason = policy.rejection(source: source, types: types) { return .outcome(.skipped(reason, before)) }
        return .read(.init(count: before, types: types, source: source, at: clock.now()))
    }
    /// 同步入口保留给假系统和独立命名板单元验证；生产轮询使用异步入口。
    public func capture(after: Int, policy: SettingsSnapshot) -> CaptureOutcome {
        for _ in 0..<3 {
            switch prepare(after: after, policy: policy) {
            case .outcome(.skipped(.changedDuringRead, _)): continue
            case .outcome(let outcome): return outcome
            case .read(let plan):
                let body = PasteboardBody.readApproved(types: plan.types, expectedCount: plan.count, currentCount: { access.count }, currentTypes: { access.types }, data: access.data)
                guard plan.count == access.count else { continue }
                if case .failure(.changedDuringRead) = body { continue }
                return finish(plan, body: body, policy: policy)
            }
        }
        return .skipped(.changedDuringRead, access.count)
    }
    /// 正文在后台完整读取，回到主线程复查计数再排队，保留所有支持格式。
    public func captureAsync(after: Int, policy: SettingsSnapshot) async -> CaptureOutcome {
        for _ in 0..<3 {
            switch prepare(after: after, policy: policy) {
            case .outcome(.skipped(.changedDuringRead, _)): continue
            case .outcome(let outcome): return outcome
            case .read(let plan):
                let body = await access.readBody(types: plan.types, expectedCount: plan.count)
                guard plan.count == access.count else { continue }
                if case .failure(.changedDuringRead) = body { continue }
                return finish(plan, body: body, policy: policy)
            }
        }
        return .skipped(.changedDuringRead, access.count)
    }
    private func finish(_ plan: ReadPlan, body: PasteboardBody, policy: SettingsSnapshot) -> CaptureOutcome {
        switch body {
        case .failure(let reason): .skipped(reason, plan.count)
        case .payload(let payload): .snapshot(.init(payload: payload, count: plan.count, at: plan.at, source: plan.source, revision: policy.revision))
        }
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
