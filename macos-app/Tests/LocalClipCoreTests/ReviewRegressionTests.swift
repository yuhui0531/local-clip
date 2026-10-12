// 独立审查缺陷的真实SQLite回归，不依赖用户历史，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct ReviewStorageRegressionTests {
    /// 浏览锚点复用真实搜索条件；已删除和不属于当前字面/收藏/来源过滤的ID不能保留。
    @Test func windowAnchorsRespectQueryMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let matching = insertedID(try await store.ingest(fixture("anchor-needle"), at: SystemClock().now()))
        let other = insertedID(try await store.ingest(fixture("unrelated"), at: SystemClock().now()))
        let ids: Set<ClipID> = [matching, other, "deleted-id"]
        #expect(try await store.matchingIDs(ids, in: .init("needle")).ids == [matching])
        #expect(try await store.matchingIDs(ids, in: .init("needle", favorites: true)).ids.isEmpty)
        #expect(try await store.matchingIDs(ids, in: .init(sourceBundleID: "local.unmatched")).ids.isEmpty)
        let favorite = try await store.preview(.favorite(matching, true)); _ = try await store.apply(favorite.token)
        #expect(try await store.matchingIDs(ids, in: .init("needle", favorites: true)).ids == [matching])
        let deletion = try await store.preview(.delete([matching])); _ = try await store.apply(deletion.token)
        #expect(try await store.matchingIDs(ids, in: .init("needle")).ids.isEmpty)
    }
    /// 拖出与图片文件租约不随无关提交失效，删除仍立即拒绝读取。
    @Test func dragSurvivesUnrelatedCommitsAndRejectsDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("drag-original"), at: SystemClock().now()))
        let access = try await store.exportAccess(id: id)
        _ = try await store.ingest(fixture("unrelated-copy"), at: SystemClock().now())
        var settings = try await store.settings(); settings.captureSounds = true
        _ = try await store.updateCaptureSettings(settings)
        #expect(try access.itemData(index: 0, type: SupportedType.string) == Data("drag-original".utf8))
        let file = try await store.writeExport(Data([1,2,3]), id: id, revision: access.revision)
        #expect(try Data(contentsOf: file) == Data([1,2,3]))
        let deletion = try await store.preview(.delete([id])); _ = try await store.apply(deletion.token)
        #expect(throws: StoreError.notFound) { try access.itemData(index: 0, type: SupportedType.string) }
    }
    /// 配额压力只级联删除被淘汰记录的索引，其余完整全文继续可查。
    @Test func quotaKeepsSurvivingTextIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.quotaBytes = 2 * MiB
        let store = try HistoryStore(location: root, initialSettings: settings)
        for index in 0..<20 {
            _ = try await store.ingest(fixture("indexed-\(index)-" + String(repeating: "x", count: 16_000) + "-TAIL"), at: SystemClock().now() + Int64(index))
        }
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data(repeating: 7, count: 1_200_000))])])), at: SystemClock().now() + 100)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        let surviving = try db.scalarInt("SELECT COUNT(*) FROM clips WHERE kind='text'")
        #expect(surviving > 0); #expect(surviving < 20)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM text_content") == surviving)
        #expect(try await store.search(.init("-TAIL")).items.count == Int(surviving))
        #expect(try await store.usage().measuredTotal <= settings.quotaBytes)
        try db.close()
    }
    /// 缩略图首次生成后落库一次；不递增历史修订，重复缓存不再写库，by AI.Coding。
    @Test func thumbnailsDoNotCommitHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("thumbnail-fixture"), at: SystemClock().now()))
        let metadata = try await store.metadata(id: id, at: SystemClock().now())
        let path = root.appendingPathComponent("History/history.sqlite")
        #expect(try await store.cacheThumbnail(id: id, revision: metadata.revision, data: Data([0])))
        let before = try Data(contentsOf: path)
        for value in 1..<20 { #expect(try await store.cacheThumbnail(id: id, revision: metadata.revision, data: Data([UInt8(value)]))) }
        #expect(try Data(contentsOf: path) == before)
        let reopened = try HistoryStore(location: root)
        #expect(try await reopened.thumbnail(id: id, at: SystemClock().now()) == Data([0]))
        #expect(try await store.thumbnail(id: id, at: SystemClock().now()) == Data([19]))
        #expect(try await store.metadata(id: id, at: SystemClock().now()).revision == metadata.revision)
        let deletion = try await store.preview(.delete([id])); _ = try await store.apply(deletion.token)
        #expect(try await store.cacheThumbnail(id: id, revision: metadata.revision, data: Data([9])) == false)
    }
    /// 无关提交不会使同一不可变记录的缩略图任务过期，by AI.Coding。
    @Test func thumbnailSurvivesUnrelatedIngest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("thumbnail-stable"), at: SystemClock().now()))
        let metadata = try await store.metadata(id: id, at: SystemClock().now())
        _ = try await store.ingest(fixture("thumbnail-unrelated"), at: SystemClock().now() + 1)
        #expect(try await store.cacheThumbnail(id: id, revision: metadata.revision, data: Data([4, 2])) == true)
        #expect(try await store.thumbnail(id: id, at: SystemClock().now()) == Data([4, 2]))
    }
    /// 旧版缺失索引按批补齐，不淘汰正文；查询仍能按原格式回退。
    @Test func missingIndexRebuiltInBoundedBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for index in 0..<7 { _ = try await store.ingest(fixture("rebuild-\(index)-tail"), at: SystemClock().now()) }
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try db.configure(); try db.exec("DELETE FROM text_content"); try db.close()
        #expect(try await store.search(.init("tail")).items.count == 7)
        #expect(try await store.rebuildSearchIndex(limit: 3) == 3)
        #expect(try await store.rebuildSearchIndex(limit: 3) == 3)
        #expect(try await store.rebuildSearchIndex(limit: 3) == 1)
        #expect(try await store.rebuildSearchIndex(limit: 3) == 0)
        #expect(try await store.search(.init("tail")).items.count == 7)
    }
    /// 部分使用的数据页删除后也不能在库文件中留下可见原文。
    @Test func deletedTextIsZeroedInDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), secret = "LC16-UNIQUE-DELETED-PLAINTEXT-98A7C6"
        for index in 0..<30 { _ = try await store.ingest(fixture("neighbour-\(index)"), at: SystemClock().now()) }
        let id = insertedID(try await store.ingest(fixture(secret), at: SystemClock().now()))
        let deletion = try await store.preview(.delete([id])); _ = try await store.apply(deletion.token)
        let bytes = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        #expect(!bytes.contains(Data(secret.utf8))); #expect(!bytes.contains(Data(secret.lowercased().utf8)))
        #expect(await store.undoAvailable())
        try await store.undoDelete()
        #expect(try await store.search(.init(secret)).items.first?.id == id)
    }
}
