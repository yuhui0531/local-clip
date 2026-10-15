// LC-V01：减少同步哈希不能绕过损坏、过期与取消检查，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct DragPayloadIntegrityTests {
    @Test(arguments: ["payload", "byteCount"])
    func corruptBlobCannotPublishEvenAnExistingPath(_ field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("original bytes"), at: SystemClock().now()))
        let access = try await store.exportAccess(id: id)
        let accepted = try access.materializeDragFile(index: 0, type: SupportedType.string, fileName: "accepted.png")
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        if field == "payload" { try db.run("UPDATE blobs SET payload=?", [.blob(Data("modified bytes".utf8))]) }
        else { try db.exec("PRAGMA ignore_check_constraints=ON; UPDATE blobs SET byteCount=byteCount+1") }
        try db.close()
        for name in ["accepted.png", "fresh.png"] {
            #expect(throws: StoreError.corruptPayload) { try access.materializeDragFile(index: 0, type: SupportedType.string, fileName: name) }
        }
        #expect(try Data(contentsOf: accepted.url) == Data("original bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: accepted.url.deletingLastPathComponent().appendingPathComponent("fresh.png").path))
    }

    @Test(arguments: [false, true])
    func expiredOrCancelledAccessCannotPublish(_ cancelled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(1_000_000), store = try HistoryStore(location: root, clock: clock)
        let id = insertedID(try await store.ingest(fixture("leased bytes"), at: clock.now()))
        let access = try await store.exportAccess(id: id)
        if cancelled { access.cancel() } else { clock.advance(600_000) }
        #expect(throws: StoreError.notFound) { try access.materializeDragFile(index: 0, type: SupportedType.string, fileName: "expired.png") }
        #expect(try await store.dragFilesBytes() == 0)
    }
}
