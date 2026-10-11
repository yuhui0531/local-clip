// 分类最新拖入及有效用户复制置前；只使用临时SQLite，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct CategoryOrderTests {
    /// 添加沿用生产预览/提交入口，测试拖入多选的原始顺序和已有成员再次置前。
    private func include(_ ids: [ClipID], in category: ClipCategory, store: HistoryStore) async throws {
        let preview = try await store.preview(.category(ids, category.id, true))
        _ = try await store.apply(preview.token)
    }

    /// 新批次放在左端，去重保留输入顺序；跨页、重开及手动排序均保持持久事实。
    @Test func newestCategoryBatchFirstAndStable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let category = try await store.createCategory(name: "提示词", colorHex: "AF52DE")
        let other = try await store.createCategory(name: "Other", colorHex: "34C759")
        var ids: [ClipID] = []
        for index in 0..<6 {
            ids.append(insertedID(try await store.ingest(fixture("order-\(index)"), at: clock.now())))
            clock.advance(1000)
        }
        try await include([ids[0], ids[1]], in: category, store: store)
        try await include([ids[2]], in: category, store: store)
        try await include([ids[4], ids[3], ids[4]], in: category, store: store)
        try await include([ids[0]], in: other, store: store)
        let request = SearchRequest(pageSize: 2, categoryIDs: [category.id])
        let first = try await store.search(request)
        #expect(first.items.map(\.id) == [ids[4], ids[3]])
        let firstCursor = try #require(first.next)
        var following = request; following.cursor = firstCursor
        let second = try await store.search(following)
        #expect(second.items.map(\.id) == [ids[2], ids[0]])
        let secondCursor = try #require(second.next)
        following.cursor = secondCursor
        #expect(try await store.search(following).items.map(\.id) == [ids[1]])

        // 已在分类中的项目再次拖入仍置前，不能产生重复归属或刷新复制时间。
        let original = try await store.detail(id: ids[0], at: clock.now()).summary
        try await include([ids[0], ids[3]], in: category, store: store)
        let expected = [ids[0], ids[3], ids[4], ids[2], ids[1]]
        #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == expected)
        let detail = try await store.detail(id: ids[0], at: clock.now())
        #expect(detail.categoryIDs == [category.id, other.id])
        #expect(detail.summary.lastCopiedAt == original.lastCopiedAt)
        #expect(detail.summary.copyCount == original.copyCount)
        await #expect(throws: StoreError.invalidCursor) { try await store.search(following) }
        #expect(try await store.search(.init()).items.map(\.id) == Array(ids.reversed()))

        try await store.moveItem(id: ids[0], categoryID: category.id, delta: 1)
        let manual = [ids[3], ids[0], ids[4], ids[2], ids[1]]
        #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == manual)
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.search(.init(categoryIDs: [category.id])).items.map(\.id) == manual)
        let removal = try await reopened.preview(.category([ids[3]], category.id, false))
        _ = try await reopened.apply(removal.token)
        #expect(try await reopened.search(.init(categoryIDs: [category.id])).items.map(\.id) == [ids[0], ids[4], ids[2], ids[1]])
    }

    /// 重复有效用户复制同时置前历史和所有归属分类；仅一条记录且不改变首次复制时间。
    @Test func userRecopyPromotesEveryCategory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let first = try await store.createCategory(name: "First", colorHex: "34C759")
        let second = try await store.createCategory(name: "Second", colorHex: "AF52DE")
        let a = insertedID(try await store.ingest(fixture("recopy-a"), at: clock.now()))
        clock.advance(1000)
        let b = insertedID(try await store.ingest(fixture("recopy-b"), at: clock.now()))
        clock.advance(1000)
        let c = insertedID(try await store.ingest(fixture("recopy-c"), at: clock.now()))
        for category in [first, second] { try await include([b, a, c], in: category, store: store) }
        let original = try await store.detail(id: a, at: clock.now()).summary
        clock.advance(1000)
        let copy = fixture("recopy-a")
        #expect(try await store.ingest(copy, at: clock.now()) == .deduplicated(a))
        #expect(try await store.search(.init()).items.map(\.id) == [a, c, b])
        for category in [first, second] {
            #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [a, b, c])
        }
        let summary = try await store.detail(id: a, at: clock.now()).summary
        #expect(summary.firstCopiedAt == original.firstCopiedAt)
        #expect(summary.lastCopiedAt == clock.now()); #expect(summary.copyCount == 2)
        // 同一capture立即重放不能重复递增或改变持久版本。
        let after = try await store.search(.init(categoryIDs: [first.id]))
        _ = try await store.ingest(copy, at: clock.now())
        #expect(try await store.search(.init(categoryIDs: [first.id])).revision == after.revision)
        #expect(try await store.detail(id: a, at: clock.now()).summary.copyCount == 2)
        // 手动排序仍有效；下一次真实用户复制再次将该项目置前。
        try await store.moveItem(id: a, categoryID: first.id, delta: 1)
        #expect(try await store.search(.init(categoryIDs: [first.id])).items.map(\.id) == [b, a, c])
        clock.advance(1000)
        _ = try await store.ingest(fixture("recopy-a"), at: clock.now())
        #expect(try await store.search(.init(categoryIDs: [first.id])).items.map(\.id) == [a, b, c])
        #expect(try await store.detail(id: a, at: clock.now()).summary.copyCount == 3)
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.search(.init(categoryIDs: [second.id])).items.map(\.id) == [a, b, c])
    }

    /// 删除头部后新增再撤销，不能复用待恢复位置而让UUID决定新旧顺序，by AI.Coding。
    @Test func undoHeadDeletionKeepsNewDropFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let category = try await store.createCategory(name: "Undo", colorHex: "34C759")
        var ids: [ClipID] = []
        for text in ["undo-head", "undo-tail", "new-drop"] {
            ids.append(insertedID(try await store.ingest(fixture(text), at: clock.now())))
            clock.advance(1000)
        }
        try await include([ids[0], ids[1]], in: category, store: store)
        let deletion = try await store.preview(.delete([ids[0]]))
        _ = try await store.apply(deletion.token)
        #expect(await store.undoAvailable())
        try await include([ids[2]], in: category, store: store)
        try await store.undoDelete()
        #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [ids[2], ids[0], ids[1]])
        // 直接核对持久位置，避免随机UUID刚好掩盖相同位置的缺陷。
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarInt("SELECT COUNT(DISTINCT position) FROM clip_categories WHERE categoryID=?", [.text(category.id)]) == 3)
        try db.close()
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.search(.init(categoryIDs: [category.id])).items.map(\.id) == [ids[2], ids[0], ids[1]])
    }
}
