// 手动排序使用临时库，核对复制身份、分页与重开后的持久事实，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct HistoryReorderTests {
    /// 多选跨页移动保留顺序，分类与全局相互独立，最近复制排序仍使用原时间。
    @Test func persistentOrderAndCategoryIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        var ids: [ClipID] = []
        for index in 0..<8 {
            ids.append(insertedID(try await store.ingest(fixture("manual-\(index)"), at: clock.now())))
            clock.advance(1000)
        }
        let original = try await store.detail(id: ids[0], at: clock.now()).summary
        let category = try await store.createCategory(name: "Manual", colorHex: "34C759")
        _ = try await store.apply(try await store.preview(.category(ids, category.id, true)).token)
        try await store.reorderItems([ids[0], ids[2], ids[0]], categoryID: nil, relativeTo: ids[6], after: false)
        let expected = [ids[7], ids[0], ids[2], ids[6], ids[5], ids[4], ids[3], ids[1]]
        #expect(try await store.search(.init(sort: .manual)).items.map(\.id) == expected)
        #expect(try await store.search(.init()).items.map(\.id) == Array(ids.reversed()))
        #expect(try await store.search(.init(categoryIDs: [category.id], sort: .manual)).items.map(\.id) == ids)
        try await store.reorderItems([ids[1], ids[3]], categoryID: category.id, relativeTo: ids[6], after: true)
        #expect(try await store.search(.init(categoryIDs: [category.id], sort: .manual)).items.map(\.id) == [ids[0], ids[2], ids[4], ids[5], ids[6], ids[1], ids[3], ids[7]])
        #expect(try await store.search(.init("manual", categoryIDs: [category.id], sort: .manual)).items.map(\.id) == [ids[0], ids[2], ids[4], ids[5], ids[6], ids[1], ids[3], ids[7]])
        let reopened = try HistoryStore(location: root, clock: clock)
        var request = SearchRequest(pageSize: 3, sort: .manual)
        var paged: [ClipID] = []
        repeat {
            let page = try await reopened.search(request); paged += page.items.map(\.id); request.cursor = page.next
        } while request.cursor != nil
        #expect(paged == expected)
        #expect(try await reopened.firstOffset(of: [ids[0]], in: .init(sort: .manual)) == 1)
        let summary = try await reopened.detail(id: ids[0], at: clock.now()).summary
        #expect(summary.lastCopiedAt == original.lastCopiedAt && summary.copyCount == original.copyCount)
        #expect(try await reopened.search(.init("manual", sort: .manual)).items.map(\.id) == expected)
    }

    /// 删除撤销保留位置，新复制置前；无效锚点与自身投放不能写入半份顺序。
    @Test func copyUndoAndInvalidDrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        var ids: [ClipID] = []
        for index in 0..<4 {
            ids.append(insertedID(try await store.ingest(fixture("undo-manual-\(index)"), at: clock.now())))
            clock.advance(1000)
        }
        try await store.reorderItems([ids[0]], categoryID: nil, relativeTo: ids[3], after: false)
        let expected = [ids[0], ids[3], ids[2], ids[1]]
        let before = try await store.search(.init(sort: .manual))
        try await store.reorderItems([ids[0]], categoryID: nil, relativeTo: ids[0], after: false)
        #expect(try await store.search(.init(sort: .manual)).revision == before.revision)
        await #expect(throws: StoreError.notFound) { try await store.reorderItems([ids[1]], categoryID: nil, relativeTo: "missing", after: true) }
        #expect(try await store.search(.init(sort: .manual)).items.map(\.id) == expected)
        _ = try await store.apply(try await store.preview(.delete([ids[0]])).token)
        let fresh = insertedID(try await store.ingest(fixture("new-manual"), at: clock.now()))
        try await store.undoDelete()
        #expect(try await store.search(.init(sort: .manual)).items.map(\.id) == [fresh] + expected)
        clock.advance(1000)
        _ = try await store.ingest(fixture("undo-manual-1"), at: clock.now())
        #expect(try await store.search(.init(sort: .manual)).items.map(\.id) == [ids[1], fresh, ids[0], ids[3], ids[2]])
        try await store.touch(ids: [ids[2], ids[3]], at: clock.now())
        #expect(try await store.search(.init(sort: .manual)).items.prefix(2).map(\.id) == [ids[2], ids[3]])
    }
    /// v5升级保持内容与时间，升级及排序提交前故障均回滚到完整旧态。
    @Test func migrationAndReorderRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        var ids: [ClipID] = []
        for index in 0..<3 {
            ids.append(insertedID(try await store.ingest(fixture("migration-\(index)"), at: clock.now())))
            clock.advance(1000)
        }
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.exec("DROP INDEX manual_order; ALTER TABLE clips DROP COLUMN manualPosition; UPDATE settings SET schemaVersion=5; UPDATE store_meta SET schemaVersion=5; PRAGMA user_version=5")
        try db.close()
        #expect(throws: StoreError.diskFull) { _ = try HistoryStore(location: root, clock: clock, faults: ThrowAt(point: .beforeReplace)) }
        let old = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        #expect(try old.scalarInt("PRAGMA user_version") == 5)
        #expect(try old.rows("PRAGMA table_info(clips)").allSatisfy { $0.text("name") != "manualPosition" })
        try old.close()
        let migrated = try HistoryStore(location: root, clock: clock)
        #expect(try await migrated.search(.init(sort: .manual)).items.map(\.id) == Array(ids.reversed()))
        #expect(try await migrated.detail(id: ids[0], at: clock.now()).payload.plainText == "migration-0")
        let failing = try HistoryStore(location: root, clock: clock, faults: ThrowAt(point: .beforeReplace))
        let before = try await migrated.search(.init(sort: .manual))
        await #expect(throws: StoreError.diskFull) { try await failing.reorderItems([ids[0]], categoryID: nil, relativeTo: ids[2], after: false) }
        let after = try await migrated.search(.init(sort: .manual))
        #expect(after.revision == before.revision && after.items.map(\.id) == before.items.map(\.id))
    }

}
