// 同图PNG+TIFF只保存PNG；旧记录整理后内容可读、身份可去重、BLOB被回收，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct ImageCompactionTests {
    private func image(_ tiff: Bool) -> ClipboardSnapshot {
        var reps = [Representation(SupportedType.png, Data(repeating: 1, count: 1000))]
        if tiff { reps.append(.init(SupportedType.tiff, Data(repeating: 2, count: 20_000))) }
        return .init(payload: .init([.init(reps)]))
    }
    @Test func ingestDropsRedundantTIFF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let id = insertedID(try await store.ingest(image(true), at: now))
        #expect(try await store.detail(id: id, at: now).payload.items[0].representations.map(\.type) == [SupportedType.png])
        // 只有PNG的同图视为同一条记录。
        #expect(try await store.ingest(image(false), at: now + 1) == .deduplicated(id))
        // TIFF单独存在时没有可替代的PNG，必须保留。
        let lone = insertedID(try await store.ingest(.init(payload: .init([.init([.init(SupportedType.tiff, Data([9]))])])), at: now + 2))
        #expect(try await store.detail(id: lone, at: now + 2).payload.items[0].representations.map(\.type) == [SupportedType.tiff])
    }
    @Test func existingRecordsAreCompacted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = SystemClock().now()
        let id = insertedID(try await HistoryStore(location: root).ingest(image(false), at: now))
        // 还原旧版写法：同项多存一份TIFF，内容身份包含TIFF。
        let legacy = image(true).payload, tiff = legacy.items[0].representations[1]
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(ContentFingerprint.hash(tiff.data)), .integer(Int64(tiff.data.count)), .blob(tiff.data)])
        try db.run("INSERT INTO representations VALUES(?,0,?,?)", [.text(id), .text(tiff.type), .text(ContentFingerprint.hash(tiff.data))])
        try db.run("UPDATE clips SET contentHash=? WHERE id=?", [.text(legacy.fingerprint), .text(id)])
        try db.close()

        let store = try HistoryStore(location: root)
        #expect(try await store.compactRedundantImages() == 1)
        #expect(try await store.compactRedundantImages() == 0)
        #expect(try await store.detail(id: id, at: now).payload.items[0].representations.map(\.type) == [SupportedType.png])
        #expect(try await store.ingest(image(true), at: now + 1) == .deduplicated(id))
        let check = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try check.scalarInt("SELECT COUNT(*) FROM blobs WHERE byteCount=20000") == 0)
        try check.close()
    }
}
