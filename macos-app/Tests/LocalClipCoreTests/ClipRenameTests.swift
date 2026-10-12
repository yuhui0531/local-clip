// 名称仅在临时SQLite中验证，覆盖身份、重开、设置竞态及删除撤销，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct ClipRenameTests {
    /// 每个提交前故障点仍保留原库及原名，不回退为默认名称，by AI.Coding。
    @Test(arguments: [FaultPoint.candidateCreated, .candidateWritten, .candidateValidated, .beforeReplace])
    func renameFailuresAreAtomic(point: FaultPoint) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let id = insertedID(try await store.ingest(fixture("failure-name"), at: now))
        try await store.renameClip(id: id, title: "Original")
        await store.waitForPageCacheWarmupForTesting()
        let database = root.appendingPathComponent("History/history.sqlite"), before = try Data(contentsOf: database)
        let failing = try HistoryStore(location: root, faults: ThrowAt(point: point))
        await #expect(throws: StoreError.diskFull) { try await failing.renameClip(id: id, title: "Replacement") }
        #expect(try Data(contentsOf: database) == before)
        #expect(try await store.metadata(id: id, at: now).summary.title == "Original")
        await #expect(throws: StoreError.invalidSettings) {
            try await store.renameClip(id: id, title: "a" + String(repeating: "\u{301}", count: 1024))
        }
    }
    /// 配额拒绝不能丢名称/历史，之后真实采集淘汰只清理已删除ID的名称，by AI.Coding。
    @Test func quotaRefusalAndEvictionCleanNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        var ids: [ClipID] = []
        for byte in [UInt8(1), 2, 3] {
            let payload = ClipboardPayload([.init([.init(SupportedType.png, Data(repeating: byte, count: 160 * 1024))])])
            let id = insertedID(try await store.ingest(.init(payload: payload), at: now + Int64(byte)))
            ids.append(id); try await store.renameClip(id: id, title: "Image \(byte)")
        }
        await store.waitForPageCacheWarmupForTesting()
        var lowered = try await store.settings(); lowered.quotaBytes = 350 * 1024
        let file = root.appendingPathComponent("History/history.sqlite")
        let db = try SQLiteConnection(file); try db.configure(); try Schema.writeSettings(db, lowered); try db.close()
        let constrained = try HistoryStore(location: root), before = try Data(contentsOf: file)
        await #expect(throws: StoreError.quotaExceeded) { try await constrained.renameClip(id: ids[0], title: "No room") }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await constrained.search(.init()).items.count == 3)
        _ = try await constrained.ingest(fixture("capture-trims-oldest"), at: now + 10)
        let surviving = Set(try await constrained.search(.init()).items.map(\.id))
        #expect(!surviving.contains(ids[0]))
        let titles = try await constrained.settings().clipTitles
        #expect(Set(titles.keys).isSubset(of: surviving))
        for id in surviving.intersection(ids) { #expect(titles[id] != nil) }
    }
    /// 所有格式共用名称，重开和分类/收藏视图不改变内容或排序，by AI.Coding。
    @Test func namesPersistForEveryKindWithoutChangingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let payloads: [ClipboardPayload] = [
            fixture("rename-text").payload,
            .init([.init([.init(SupportedType.url, Data("https://example.invalid".utf8))])]),
            .init([.init([.init(SupportedType.html, Data("<b>rich</b>".utf8))])]),
            .init([.init([.init(SupportedType.png, Data([1, 2, 3]))])]),
            .init([.init([.init(SupportedType.fileURL, Data("file:///tmp/rename-fixture.swift".utf8))])]),
            .init([.init([.init(SupportedType.png, Data([4, 5])), .init(SupportedType.string, Data("mixed".utf8))])])]
        var ids: [ClipID] = []
        for payload in payloads { ids.append(insertedID(try await store.ingest(.init(payload: payload), at: clock.now()))); clock.advance(10) }
        let category = try await store.createCategory(name: "rename-group", colorHex: "123456")
        let membership = try await store.preview(.category(ids, category.id, true)); _ = try await store.apply(membership.token)
        let favourite = try await store.preview(.favorites(ids, true)); _ = try await store.apply(favourite.token)
        let before = try await store.search(.init()), policy = try await store.settings()
        for (i, id) in ids.enumerated() { try await store.renameClip(id: id, title: "Name \(i)") }
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.settings().revision == policy.revision)
        #expect(try await reopened.search(.init()).items.map(\.id) == before.items.map(\.id))
        for (i, id) in ids.enumerated() {
            let detail = try await reopened.detail(id: id, at: clock.now()), old = before.items.first { $0.id == id }!
            #expect(detail.summary.title == "Name \(i)")
            #expect(detail.summary.lastCopiedAt == old.lastCopiedAt && detail.summary.copyCount == old.copyCount)
            #expect(detail.payload.canonicalData == payloads[i].canonicalData)
            #expect(detail.categoryIDs == [category.id] && detail.summary.isFavorite)
        }
        #expect(try await reopened.search(.init(favorites: true)).items.allSatisfy { $0.title != nil })
        var scoped = SearchRequest(); scoped.categoryIDs = [category.id]
        #expect(try await reopened.search(scoped).items.map(\.id) == ids)
        #expect(try await reopened.ingest(.init(payload: payloads[0]), at: clock.now()) == .deduplicated(ids[0]))
        #expect(try await reopened.metadata(id: ids[0], at: clock.now()).summary.title == "Name 0")
    }
    /// 旧偏好快照不能覆盖名称；删除清理与撤销只恢复本批名称，by AI.Coding。
    @Test func stalePreferencesDeleteUndoAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let a = insertedID(try await store.ingest(fixture("rename-A"), at: now))
        let b = insertedID(try await store.ingest(fixture("rename-B"), at: now + 1))
        var stale = try await store.settings()
        try await store.renameClip(id: a, title: "  Cafe\u{301}  ")
        stale.hideContents = true; _ = try await store.updateCaptureSettings(stale)
        #expect(try await store.metadata(id: a, at: now).summary.title == "Café")
        let deletion = try await store.preview(.delete([a])); _ = try await store.apply(deletion.token)
        #expect(try await store.settings().clipTitles[a] == nil)
        try await store.renameClip(id: b, title: "Other")
        try await store.undoDelete()
        #expect(try await store.settings().hideContents)
        #expect(try await store.metadata(id: a, at: now).summary.title == "Café")
        #expect(try await store.metadata(id: b, at: now).summary.title == "Other")
        try await store.renameClip(id: a, title: " \n ")
        #expect(try await store.metadata(id: a, at: now).summary.title == nil)
        await #expect(throws: StoreError.invalidSettings) { try await store.renameClip(id: b, title: "bad\0name") }
        for separator in ["\u{2028}", "\u{2029}"] {
            await #expect(throws: StoreError.invalidSettings) { try await store.renameClip(id: b, title: "first" + separator + "second") }
        }
        #expect(try await store.metadata(id: b, at: now).summary.title == "Other")
        await store.waitForPageCacheWarmupForTesting()
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
        #expect(try db.scalarInt("PRAGMA user_version") == Schema.version); try db.close()
    }
}
