// 指定c097591报告的删除契约回归，使用可丢弃数据库，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct SpecifiedReviewTests {
    /// 重复ID只占一个撤销位置；不存在的ID不增加受影响数。
    @Test func duplicateDeletionIDsRemainUndoable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("duplicate-delete"), at: SystemClock().now()))
        let preview = try await store.preview(.delete(Array(repeating: id, count: 4097) + ["absent"]))
        #expect(preview.affectedCount == 1)
        #expect(!preview.requiresConfirmation)
        _ = try await store.apply(preview.token)
        #expect(await store.undoAvailable())
        try await store.undoDelete()
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).plainText == "duplicate-delete")
    }

    /// 原始载荷和索引合计超过撤销预算时，预览必须要求事前确认且不修改数据库。
    @Test func overBudgetDeletionRequiresConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        var ids: [ClipID] = []
        for byte in [UInt8(1), 2] {
            let payload = ClipboardPayload([.init([.init(SupportedType.png, Data(repeating: byte, count: 26 * Int(MiB)))])])
            ids.append(insertedID(try await store.ingest(.init(payload: payload), at: SystemClock().now())))
        }
        let database = root.appendingPathComponent("History/history.sqlite")
        let before = try Data(contentsOf: database)
        let preview = try await store.preview(.delete(ids))
        #expect(preview.requiresConfirmation)
        #expect(preview.affectedCount == 2)
        #expect(preview.message.contains("不可撤销"))
        #expect(try Data(contentsOf: database) == before)
        _ = try await store.apply(preview.token)
        #expect(!(await store.undoAvailable()))
    }
}
