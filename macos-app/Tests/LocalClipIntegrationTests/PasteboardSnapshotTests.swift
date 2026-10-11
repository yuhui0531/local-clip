// 系统边界 fake 验证正文读取前过滤和稳定快照，by AI.Coding。
import Foundation
import Testing
import LocalClipCore
@testable import LocalClipMac
@MainActor final class RawBoard: PasteboardAccess {
    var count = 1
    var items: [[String: Data]] = []
    var reads: [String] = []
    var onRead: ((Int, String) -> Void)?
    var onTypes: (() -> Void)?
    var writeOK = true
    var types: [[String]]? { let values = items.map { Array($0.keys) }; onTypes?(); return values }
    /// fake 在数据读取时可制造计数变化，不使用真实用户剪贴板。
    func data(item: Int, type: String) -> Data? { reads.append(type); onRead?(item, type); return items.indices.contains(item) ? items[item][type] : nil }
    /// 精确模拟一次写入与自写控制标记。
    func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool {
        count += 1
        items = writeOK ? payload.items.map { item in
            var values = Dictionary(uniqueKeysWithValues: item.representations.map { ($0.type, $0.data) })
            values[NativePasteboardAccess.ownType] = Data(fingerprint.utf8); return values
        } : []
        return writeOK
    }
    /// 用户复制不带自写标记，count 立即使旧 receipt 失效。
    func user(_ text: String) { count += 1; items = [[SupportedType.string: Data(text.utf8)]] }
}
@MainActor struct PasteboardSnapshotTests {
    /// 类型/来源检查期间出现用户B，不把A的拒绝结果盖到B的计数。
    @Test func AC09_AC18_metadataRaceDoesNotLoseNextUserCopy() {
        let raw = RawBoard(); raw.items = [[SupportedType.string:Data("SECRET-A".utf8),"org.nspasteboard.ConcealedType":Data()]]
        raw.onTypes = { raw.onTypes=nil; raw.user("USER-B") }
        let board = MacPasteboardClient(access:raw)
        if case .snapshot(let snapshot) = board.capture(after:0,policy:.init()) { #expect(snapshot.payload.items[0].representations[0].data == Data("USER-B".utf8)) } else { Issue.record("类型拒绝覆盖新复制") }
        #expect(!raw.reads.contains("org.nspasteboard.ConcealedType"))
        raw.items = [[SupportedType.string:Data("A".utf8),"org.nspasteboard.source":Data("local.excluded".utf8)]]; raw.count += 1
        raw.onRead = { _, type in if type == "org.nspasteboard.source" { raw.onRead=nil; raw.user("USER-C") } }
        var policy=SettingsSnapshot(); policy.excludedBundleIDs.insert("local.excluded")
        if case .snapshot(let snapshot) = board.capture(after:0,policy:policy) { #expect(snapshot.source == .unknown); #expect(snapshot.payload.items[0].representations[0].data == Data("USER-C".utf8)) } else { Issue.record("来源拒绝覆盖新复制") }
    }
    /// 整次敏感过滤，正文读取零次。
    @Test func AC22_sensitiveBeforeAnyBodyRead() {
        for marker in SupportedType.markers {
            let raw = RawBoard(); raw.items = [[SupportedType.string: Data("SAFE".utf8)], [SupportedType.string: Data("PRIVATE".utf8), marker: Data()]]
            let board = MacPasteboardClient(access: raw)
            if case .skipped(.sensitive, _) = board.capture(after: 0, policy: .init()) {} else { Issue.record("未先过滤") }
            #expect(raw.reads.isEmpty)
        }
    }
    /// 先检查来源排除，不以 fake 前台身份代替声明。
    @Test func AC10_AC18_sourceBoundary() {
        let raw = RawBoard(); raw.items = [[SupportedType.string: Data("PRIVATE".utf8), "org.nspasteboard.source": Data("local.test.source".utf8)]]
        var policy = SettingsSnapshot(); policy.excludedBundleIDs.insert("local.test.source")
        let board = MacPasteboardClient(access: raw)
        if case .skipped(.excluded, _) = board.capture(after: 0, policy: policy) {} else { Issue.record("排除失败") }
        #expect(!raw.reads.contains(SupportedType.string))
        raw.user("unknown")
        if case .snapshot(let snapshot) = board.capture(after: 0, policy: policy) { #expect(snapshot.source == .unknown) } else { Issue.record("未知来源默认保存") }
        #expect(SourceAttribution.declared(["local.a", "local.b"]) == .unknown)
    }
    /// item和字节上限整次拒绝；32项顺序不变。
    @Test func E06_boundsAndUnsupportedMixedItem() {
        let raw = RawBoard(); let board = MacPasteboardClient(access: raw)
        raw.items = (0..<32).map { [SupportedType.string: Data("item-\($0)".utf8)] }
        if case .snapshot(let value) = board.capture(after: 0, policy: .init()) { #expect(value.payload.items.count == 32); #expect(String(data: value.payload.items[31].representations[0].data, encoding: .utf8) == "item-31") } else { Issue.record("32项失败") }
        raw.items.append([SupportedType.string: Data()])
        if case .skipped(.tooLarge, _) = board.capture(after: 0, policy: .init()) {} else { Issue.record("33项未拒绝") }
        raw.items = [[SupportedType.png: Data(repeating: 0, count: 50 * 1_048_576)]]
        if case .snapshot = board.capture(after: 0, policy: .init()) {} else { Issue.record("50MiB边界失败") }
        raw.items[0][SupportedType.png]?.append(0)
        if case .skipped(.tooLarge, _) = board.capture(after: 0, policy: .init()) {} else { Issue.record("超限未拒绝") }
        raw.items = [[SupportedType.string: Data("a".utf8)], ["local.private": Data()]]
        if case .skipped(.unsupported, _) = board.capture(after: 0, policy: .init()) {} else { Issue.record("不支持项目被丢弃") }
    }
    /// 第2次表示读取时改变计数，不存混合快照；有界重试。
    @Test func stableRetry() {
        let raw = RawBoard(); raw.items = [[SupportedType.string: Data("a".utf8), SupportedType.html: Data("<b>a</b>".utf8)]]
        raw.onRead = { _, _ in raw.count += 1 }
        if case .skipped(.changedDuringRead, _) = MacPasteboardClient(access: raw).capture(after: 0, policy: .init()) {} else { Issue.record("竞态未拒绝") }
        #expect(raw.reads.count == 3) // 世代变化后不再读取同一轮的下一表示。
    }
}
