// 使用临时数据库验证编辑的原子性与既有功能兼容，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct ClipContentEditTests {
    /// 修改长文尾部也要更新身份、全文搜索和字符数，原有元数据和去重行为保持一致。
    @Test func persistenceSearchMetadataAndDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let original = String(repeating: "same prefix ", count: 20) + "old-tail"
        let updated = String(repeating: "same prefix ", count: 20) + "新的修正内容📝"
        let id = insertedID(try await store.ingest(fixture(original), at: clock.now()))
        try await store.renameClip(id: id, title: "我的记录")
        let category = try await store.createCategory(name: "资料", colorHex: "34C759")
        for change in [HistoryChange.favorite(id, true), .category([id], category.id, true)] {
            let preview = try await store.preview(change); _ = try await store.apply(preview.token)
        }
        let before = try await store.detail(id: id, at: clock.now())
        _ = try await store.textCharacterCount(id: id, at: clock.now())
        #expect(try await store.search(.init("old-tail")).items.map(\.id) == [id])
        try await store.updateText(id: id, text: updated, expectedFingerprint: before.payload.fingerprint)
        let reopened = try HistoryStore(location: root, clock: clock)
        let after = try await reopened.detail(id: id, at: clock.now())
        #expect(after.payload.plainText == updated)
        #expect(after.summary.contentFingerprint != before.summary.contentFingerprint)
        #expect(after.summary.id == id && after.summary.title == before.summary.title)
        #expect(after.summary.firstCopiedAt == before.summary.firstCopiedAt && after.summary.lastCopiedAt == before.summary.lastCopiedAt)
        #expect(after.summary.source == before.summary.source && after.summary.copyCount == before.summary.copyCount)
        #expect(after.summary.isFavorite && after.categoryIDs == [category.id])
        #expect(try await store.textCharacterCount(id: id, at: clock.now()) == updated.count)
        #expect(try await store.search(.init("old-tail")).items.isEmpty)
        #expect(try await reopened.search(.init("修正内容")).items.map(\.id) == [id])
        #expect(try await reopened.ingest(fixture(updated), at: clock.now()) == .deduplicated(id))
        let deletion = try await reopened.preview(.delete([id])); _ = try await reopened.apply(deletion.token)
        try await reopened.undoDelete()
        #expect(try await reopened.loadPayload(id: id, at: clock.now()).plainText == updated)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty); try db.close()
    }

    /// 冲突、重复、空内容及不支持的载荷均拒绝，不能合并或删除任何历史。
    @Test func conflictsAndValidationPreserveRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let a = insertedID(try await store.ingest(fixture("one"), at: now))
        let b = insertedID(try await store.ingest(fixture("two"), at: now))
        let old = try await store.loadPayload(id: a, at: now)
        await #expect(throws: ContentEditError.duplicateContent) { try await store.updateText(id: a, text: "two", expectedFingerprint: old.fingerprint) }
        await #expect(throws: ContentEditError.emptyText) { try await store.updateText(id: a, text: " \n\t", expectedFingerprint: old.fingerprint) }
        try await store.updateText(id: a, text: "changed", expectedFingerprint: old.fingerprint)
        await #expect(throws: ContentEditError.contentChanged) { try await store.updateText(id: a, text: "stale", expectedFingerprint: old.fingerprint) }
        #expect(try await store.loadPayload(id: a, at: now).plainText == "changed")
        #expect(try await store.loadPayload(id: b, at: now).plainText == "two")
        let image = insertedID(try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data([1, 2]))])])), at: now))
        let imagePayload = try await store.loadPayload(id: image, at: now)
        await #expect(throws: ContentEditError.unsupportedContent) { try await store.updateText(id: image, text: "destroy image", expectedFingerprint: imagePayload.fingerprint) }
        let deletion = try await store.preview(.delete([a])); _ = try await store.apply(deletion.token)
        await #expect(throws: StoreError.notFound) { try await store.updateText(id: a, text: "resurrect", expectedFingerprint: old.fingerprint) }
        #expect(try await store.search(.init()).items.count == 2)
    }

    /// 修改链接必须同步删除旧URL表示；未修改的富文本保存不破坏格式。
    @Test func linkAndRichTextRepresentationsStayConsistent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let payload = ClipboardPayload([.init([.init(SupportedType.string, Data("https://old.example".utf8)), .init(SupportedType.url, Data("https://old.example".utf8)), .init(SupportedType.html, Data("<a href='https://old.example'>old</a>".utf8))])])
        let id = insertedID(try await store.ingest(.init(payload: payload), at: now))
        try await store.updateText(id: id, text: "https://old.example", expectedFingerprint: payload.fingerprint)
        #expect(try await store.loadPayload(id: id, at: now).canonicalData == payload.canonicalData)
        try await store.updateText(id: id, text: "https://new.example", expectedFingerprint: payload.fingerprint)
        let link = try await store.detail(id: id, at: now)
        #expect(link.summary.kind == .url && link.payload.plainText == "https://new.example")
        #expect(link.payload.items[0].representations.map(\.type) == [SupportedType.string])
        try await store.updateText(id: id, text: "ordinary text", expectedFingerprint: link.payload.fingerprint)
        #expect(try await store.detail(id: id, at: now).summary.kind == .text)
    }

    /// 各提交前故障必须回滚载荷、索引和共享BLOB；不留下部分编辑。
    @Test(arguments: [FaultPoint.candidateCreated, .candidateWritten, .candidateValidated, .beforeReplace])
    func failedCommitRollsBack(point: FaultPoint) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let id = insertedID(try await store.ingest(fixture("original"), at: now))
        let rich = ClipboardPayload([.init([.init(SupportedType.string, Data("original".utf8)), .init(SupportedType.html, Data("<b>original</b>".utf8))])])
        let shared = insertedID(try await store.ingest(.init(payload: rich), at: now))
        let old = try await store.loadPayload(id: id, at: now)
        let failing = try HistoryStore(location: root, faults: ThrowAt(point: point))
        await #expect(throws: StoreError.diskFull) { try await failing.updateText(id: id, text: "replacement", expectedFingerprint: old.fingerprint) }
        #expect(try await store.loadPayload(id: id, at: now).canonicalData == old.canonicalData)
        #expect(try await store.loadPayload(id: shared, at: now).canonicalData == rich.canonicalData)
        #expect(try await store.search(.init("replacement")).items.isEmpty)
        #expect(try await store.search(.init("original")).items.count == 2)
    }

    /// 编辑不能以配额为由清理其他历史；拒绝后原内容仍完整。
    @Test func quotaFailureDoesNotEvictHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let id = insertedID(try await store.ingest(fixture("keep"), at: now))
        _ = try await store.ingest(fixture("other history"), at: now)
        let old = try await store.loadPayload(id: id, at: now)
        var settings = try await store.settings(); settings.quotaBytes = try await store.usage().measuredTotal
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try Schema.writeSettings(db, settings); try db.close()
        await #expect(throws: StoreError.quotaExceeded) { try await store.updateText(id: id, text: String(repeating: "large", count: 30_000), expectedFingerprint: old.fingerprint) }
        #expect(try await store.loadPayload(id: id, at: now).canonicalData == old.canonicalData)
        #expect(try await store.search(.init()).items.count == 2)
    }

    /// 过期记录不可复活；提交后故障重启能读取完整新态，不误称已回滚。
    @Test func expiryAndPostCommitRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let old = fixture("original"), id = insertedID(try await store.ingest(old, at: clock.now()))
        let failing = try HistoryStore(location: root, clock: clock, faults: ThrowAt(point: .reopen))
        await #expect(throws: StoreError.postCommitUnavailable) { try await failing.updateText(id: id, text: "committed", expectedFingerprint: old.payload.fingerprint) }
        let reopened = try HistoryStore(location: root, clock: clock)
        let committed = try await reopened.detail(id: id, at: clock.now())
        #expect(committed.payload.plainText == "committed" && committed.summary.copyCount == 1)
        clock.advance(31 * dayMS)
        await #expect(throws: StoreError.notFound) { try await reopened.updateText(id: id, text: "expired", expectedFingerprint: committed.payload.fingerprint) }
        #expect(try await reopened.search(.init()).items.isEmpty)
    }

    /// 成功替换后只回收失去最后引用的BLOB，不修改其他记录共享的原始表示。
    @Test func successfulEditPreservesSharedBlobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let old = fixture("shared"), id = insertedID(try await store.ingest(old, at: now))
        let rich = ClipboardPayload([.init([.init(SupportedType.string, Data("shared".utf8)), .init(SupportedType.html, Data("<b>shared</b>".utf8))])])
        let shared = insertedID(try await store.ingest(.init(payload: rich), at: now))
        try await store.updateText(id: id, text: "first correction", expectedFingerprint: old.payload.fingerprint)
        #expect(try await store.loadPayload(id: shared, at: now).canonicalData == rich.canonicalData)
        try await store.updateText(id: shared, text: "second correction", expectedFingerprint: rich.fingerprint)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM blobs") == 2)
        #expect(try db.scalarText("PRAGMA integrity_check") == "ok"); try db.close()
    }
}
