// 类型共存不证明等价；原始表示、历史身份及共享BLOB必须保留。
import Foundation
import Testing
@testable import LocalClipCore

struct ImageCompactionTests {
    private func image(_ tiff: Bool) -> ClipboardSnapshot {
        var reps = [Representation(SupportedType.png, Data(repeating: 1, count: 1000))]
        if tiff { reps.append(.init(SupportedType.tiff, Data(repeating: 2, count: 20_000))) }
        return .init(payload: .init([.init(reps)]))
    }
    @Test func ingestPreservesUnprovenRepresentations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let id = insertedID(try await store.ingest(image(true), at: now))
        #expect(try await store.detail(id: id, at: now).payload.canonicalData == image(true).payload.canonicalData)
        #expect(try await store.ingest(image(true), at: now + 1) == .deduplicated(id))
        let pngOnlyID = insertedID(try await store.ingest(image(false), at: now + 1))
        #expect(pngOnlyID != id)
        #expect(image(true).payload.withoutRedundantTIFF == image(true).payload)
        #expect(image(true).payload.items[0].withoutRedundantTIFF == image(true).payload.items[0])
        // TIFF单独存在时没有可替代的PNG，必须保留。
        let lone = insertedID(try await store.ingest(.init(payload: .init([.init([.init(SupportedType.tiff, Data([9]))])])), at: now + 2))
        #expect(try await store.detail(id: lone, at: now + 2).payload.items[0].representations.map(\.type) == [SupportedType.tiff])
    }
    @Test func existingRecordsAreNotCompacted() async throws {
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
        let before = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        #expect(try await store.compactRedundantImages() == 0)
        #expect(try await store.compactRedundantImages() == 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite")) == before)
        #expect(try await store.detail(id: id, at: now).payload.canonicalData == legacy.canonicalData)
        #expect(try await store.ingest(image(true), at: now + 1) == .deduplicated(id))
        let check = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try check.scalarInt("SELECT COUNT(*) FROM blobs WHERE byteCount=20000") == 1)
        try check.close()
    }
}
