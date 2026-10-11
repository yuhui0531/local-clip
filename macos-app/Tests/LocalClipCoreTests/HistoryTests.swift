// 固定合成输入检验持久化与内容身份，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
final class TestClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Instant
    init(_ value: Instant = 1_800_000_000_000) { self.value = value }
    /// 显式锁保护跨任务的测试时钟。
    func now() -> Instant { lock.withLock { value } }
    /// 不修改系统时间。
    func advance(_ delta: Instant) { lock.withLock { value += delta } }
}
func fixture(_ text: String, source: SourceAttribution = .unknown, id: String = UUID().uuidString) -> ClipboardSnapshot {
    ClipboardSnapshot(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))], plainText: text)]), source: source, id: id)
}
func insertedID(_ result: IngestResult) -> ClipID {
    switch result { case .inserted(let id), .deduplicated(let id): return id; case .skipped: return "" }
}
struct HistoryTests {
    /// 真正的生产collector保留收藏共享的正文，最后引用删除才回收；schema允许的NULL孤儿也回收。
    @Test func AC25_productionSharedBlobAndNullOrphan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let ordinaryID = insertedID(try await store.ingest(fixture("SHARED-PRODUCTION"), at: now))
        let rich = ClipboardPayload([.init([.init(SupportedType.string, Data("SHARED-PRODUCTION".utf8)), .init(SupportedType.html, Data("<b>SHARED-PRODUCTION</b>".utf8))])])
        let favoriteID = insertedID(try await store.ingest(.init(payload: rich), at: now))
        let favorite = try await store.preview(.favorite(favoriteID, true)); _ = try await store.apply(favorite.token)
        let path = root.appendingPathComponent("History/history.sqlite")
        // 单独fixture插入在没有在途actor操作的真实库中，生产写入从不生成NULL指纹。
        await store.waitForPageCacheWarmupForTesting()
        let db = try SQLiteConnection(path); try db.configure()
        try db.exec("INSERT INTO blobs VALUES(NULL,6,x'4f525048414e')")
        #expect(try db.scalarText("PRAGMA quick_check") == "ok"); try db.close()
        let deletion = try await store.preview(.delete([ordinaryID])); _ = try await store.apply(deletion.token)
        #expect(try await store.loadPayload(id: favoriteID, at: now).canonicalData == rich.canonicalData)
        let afterFirst = try SQLiteConnection(path, readonly: true)
        #expect(try afterFirst.scalarInt("SELECT COUNT(*) FROM blobs") == 2)
        #expect(try afterFirst.scalarInt("SELECT COUNT(*) FROM blobs WHERE digest IS NULL") == 0)
        #expect(try afterFirst.rows("PRAGMA foreign_key_check").isEmpty); try afterFirst.close()
        let last = try await store.preview(.delete([favoriteID])); _ = try await store.apply(last.token)
        let afterLast = try SQLiteConnection(path, readonly: true)
        #expect(try afterLast.scalarInt("SELECT COUNT(*) FROM blobs") == 0)
        #expect(try afterLast.scalarText("PRAGMA integrity_check") == "ok"); try afterLast.close()
    }
    /// 同内容复制更新次数，重新打开所有原始字节不变。
    @Test func AC01_AC02_AC03_persistDeduplicateAndOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock)
        var ids: [String] = []
        for text in ["LOCALCLIP-TEST-A", "LOCALCLIP-TEST-B", "LOCALCLIP-TEST-C"] {
            ids.append(insertedID(try await store.ingest(fixture(text), at: clock.now()))); clock.advance(1000)
        }
        #expect(try await store.search(.init()).items.map(\.id) == ids.reversed())
        let a = fixture("LOCALCLIP-TEST-A")
        #expect(try await store.ingest(a, at: clock.now()) == .deduplicated(ids[0]))
        #expect(try await store.detail(id: ids[0], at: clock.now()).summary.copyCount == 2)
        _ = try await store.ingest(a, at: clock.now())
        #expect(try await store.detail(id: ids[0], at: clock.now()).summary.copyCount == 2)
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.loadPayload(id: ids[0], at: clock.now()) == a.payload)
        #expect(try await reopened.search(.init()).items.count == 3)
    }
    /// 同文字不同富文本不能合并；项目次序与表示枚举次序不同处理。
    @Test func AC04_formatSensitiveAndItemOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let plain = fixture("same").payload.items[0]
        var rich = plain; rich.representations.append(.init(SupportedType.rtf, Data("{\\rtf1 same}".utf8)))
        var alternate = rich; alternate.representations[1].data = Data("{\\rtf1 \\b same}".utf8)
        let first = ClipboardPayload([plain, rich])
        let id = insertedID(try await store.ingest(.init(payload: first), at: SystemClock().now()))
        var shuffled = rich; shuffled.representations.reverse()
        #expect(try await store.ingest(.init(payload: .init([plain, shuffled])), at: SystemClock().now()) == .deduplicated(id))
        _ = try await store.ingest(.init(payload: .init([rich, plain])), at: SystemClock().now())
        _ = try await store.ingest(.init(payload: .init([plain, alternate])), at: SystemClock().now())
        #expect(try await store.search(.init()).items.count == 3)
    }
}
