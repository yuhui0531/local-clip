// 字面检索、期限、确认、配额与派生失效的真实文件集成，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct SearchRetentionQuotaTests {
    /// SQL文本绑定必须保留内嵌NUL；上下文按字素映射原始NFD和emoji。
    @Test func AC05_embeddedNULAndCanonicalContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let original = "before\u{0}After cafe\u{301} 👩🏽‍💻 end"
        let id = insertedID(try await store.ingest(fixture(original), at:SystemClock().now()))
        for query in ["after", "\u{0}After", "Café", "👩🏽‍💻"] {
            let page = try await store.search(.init(query))
            #expect(page.items.map(\.id) == [id])
            #expect(page.items.first?.context == SearchNormalizer.context(original, literal: query))
        }
        #expect(try await store.detail(id:id,at:SystemClock().now()).payload.items[0].plainText == original)
        #expect(SearchNormalizer.context(original,literal:"Café").contains("cafe\u{301}"))
        #expect(SearchNormalizer.context(original,literal:"👩🏽‍💻").contains("👩🏽‍💻"))
        #expect(try await store.search(.init("CAFÉ")).items.isEmpty)
    }
    /// 所有符号都是正文；长文尾部和NFC上下文不能漏。
    @Test func AC05_literalSearchAndPagination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock)
        let texts = ["今天整理需求，明天处理代码。", "foo_bar 50% \"quotes\" \\ a->b\nsecond line", "https://example.invalid/path?a=1&b=2#section", String(repeating: "prefix", count: 500) + "TAIL-END", "cafe\u{301} 🥳"]
        var ids: [ClipID] = []
        for text in texts { ids.append(insertedID(try await store.ingest(fixture(text), at: clock.now()))); clock.advance(1) }
        for (query, index) in [("需求",0),("代",0),("foo_bar",1),("50%",1),("\"quotes\"",1),("\\",1),("a->b",1),("a=1&b=2",2),("TAIL-END",3),("Café",4),("🥳",4)] {
            let page = try await store.search(.init(query))
            #expect(page.items.map(\.id) == [ids[index]])
            #expect(page.items.first?.context.isEmpty == false)
            #expect(page.items.first?.context == SearchNormalizer.context(texts[index], literal: query))
        }
        for index in 0..<55 { _ = try await store.ingest(fixture("page-\(index)"), at: clock.now()); clock.advance(1) }
        let first = try await store.search(.init("page-")); #expect(first.items.count == 50)
        let second = try await store.search(.init("page-", cursor: first.next)); #expect(second.items.count == 5)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        _ = try await store.ingest(fixture("page-new"), at: clock.now())
        do { _ = try await store.search(.init("page-", cursor: first.next)); Issue.record("旧分页未失效") } catch { #expect(error as? StoreError == .invalidCursor) }
    }
    /// 字面扩展只复查前一结果ID，排序、摘要上下文与全量查询完全一致，by AI.Coding。
    @Test func extendedLiteralSearchPreservesFullRankingAndContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let pairs = [
            ("需求", "需求管理"), ("代", "代码"), ("foo_bar", "foo_bar ="), ("50%", "50%;"),
            ("a->b", "a->b;"), ("?a=1&b=2", "?a=1&b=2#section"), ("END-9999", "END-9999-tail"),
            ("fixture-1234", "fixture-1234 extended"), ("missing-literal", "missing-literal-suffix"),
            ("The local", "The local clipboard")
        ]
        for (literal, extended) in pairs {
            _ = try await store.ingest(fixture("prefix-only: \(literal)"), at: clock.now()); clock.advance(1)
            _ = try await store.ingest(fixture("extended: \(extended)"), at: clock.now()); clock.advance(1)
        }
        for (literal, extended) in pairs {
            let previous = try await store.search(.init(literal))
            #expect(previous.items.count >= 1)
            #if DEBUG
            let narrowedBefore = await store.narrowedSearchCount
            #endif
            let request = SearchRequest(extended)
            let narrowed = try await store.search(request)
            let full = try await store.search(request, onlyIDs: nil)
            #expect(narrowed.items.map { ($0.id, $0.context) }.map { "\($0.0)|\($0.1)" } == full.items.map { ($0.id, $0.context) }.map { "\($0.0)|\($0.1)" })
            #if DEBUG
            #expect(await store.narrowedSearchCount == narrowedBefore + 1)
            #endif
        }
        let longTail = "The local " + String(repeating: "unrelated body ", count: 24) + "The local clipboard destination"
        let longTailID = insertedID(try await store.ingest(fixture(longTail), at: clock.now())); clock.advance(1)
        _ = try await store.search(.init("The local"))
        let tailRequest = SearchRequest("The local clipboard")
        let narrowedTail = try await store.search(tailRequest)
        let fullTail = try await store.search(tailRequest, onlyIDs: nil)
        #expect(narrowedTail.items.map(\.id) == fullTail.items.map(\.id))
        #expect(narrowedTail.items.contains { $0.id == longTailID })
        #expect(narrowedTail.items.map(\.context) == fullTail.items.map(\.context))
        #expect(narrowedTail.items.first { $0.id == longTailID }?.context.contains("destination") == true)

        let sourcePayload = ClipboardPayload([.init([.init(SupportedType.string, Data("source-only marker".utf8))])])
        let sourceSnapshot = ClipboardSnapshot(payload: sourcePayload, source: .init(bundleID: "test.source", name: "The local clipboard source"))
        let sourceID = insertedID(try await store.ingest(sourceSnapshot, at: clock.now())); clock.advance(1)
        _ = try await store.search(.init("The local"))
        let sourceRequest = SearchRequest("The local clipboard source")
        let narrowedSource = try await store.search(sourceRequest)
        let fullSource = try await store.search(sourceRequest, onlyIDs: nil)
        #expect(narrowedSource.items.map { ($0.id, $0.context) }.map { "\($0.0)|\($0.1)" } == fullSource.items.map { ($0.id, $0.context) }.map { "\($0.0)|\($0.1)" })
        #expect(narrowedSource.items.first?.id == sourceID)
        #expect(narrowedSource.items.first?.context == "The local clipboard source")
        _ = try await store.search(.init("The local"))
        let updatedSource = ClipboardSnapshot(payload: sourcePayload, source: .init(bundleID: "test.source", name: "The local refreshed source"))
        _ = try await store.ingest(updatedSource, at: clock.now())
        let refreshed = try await store.search(.init("The local"))
        #expect(refreshed.items.first { $0.id == sourceID }?.context == "The local refreshed source")
    }
    /// 到期即不可访问；收藏例外；取消过期收藏需要确认。
    @Test func AC12_AC19_AC20_retentionAndExpiredUnfavorite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock)
        let ordinary = insertedID(try await store.ingest(fixture("ordinary"), at: clock.now()))
        let favorite = insertedID(try await store.ingest(fixture("favorite"), at: clock.now()))
        let p = try await store.preview(.favorite(favorite, true)); _ = try await store.apply(p.token)
        clock.advance(30 * dayMS - 1)
        #expect(try await store.search(.init()).items.count == 2)
        clock.advance(1)
        #expect(try await store.search(.init()).items.map(\.id) == [favorite])
        do { _ = try await store.loadPayload(id: ordinary, at: clock.now()); Issue.record("到期仍可恢复") } catch { #expect(error as? StoreError == .notFound) }
        let cancelled = try await store.preview(.favorite(favorite, false)); #expect(cancelled.requiresConfirmation)
        #expect(try await store.detail(id: favorite, at: clock.now()).summary.isFavorite)
        let confirmed = try await store.preview(.favorite(favorite, false)); _ = try await store.apply(confirmed.token)
        #expect(try await store.search(.init()).items.isEmpty)
        #expect(try await store.expire(at: clock.now()).removed == 1)
    }
    /// 新复制续期而浏览与原始载荷读取不续期。
    @Test func AC19_lastValidUserCopyOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock)
        let id = insertedID(try await store.ingest(fixture("renew"), at: clock.now())); clock.advance(29 * dayMS)
        _ = try await store.loadPayload(id: id, at: clock.now())
        let before = try await store.detail(id: id, at: clock.now()).summary.lastCopiedAt
        _ = try await store.ingest(fixture("renew"), at: clock.now())
        #expect(try await store.detail(id: id, at: clock.now()).summary.lastCopiedAt > before)
        clock.advance(2 * dayMS)
        #expect(try await store.search(.init()).items.count == 1)
    }
    /// 预览后收藏变化则旧确认无效，取消设置不写数据库。
    @Test func AC27_staleConfirmationAndSettingsPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock)
        let id = insertedID(try await store.ingest(fixture("confirm"), at: clock.now()))
        let cancelled = try await store.preview(.retention(1)); #expect(cancelled.requiresConfirmation)
        #expect(try await store.settings().retentionDays == 30)
        let stale = try await store.preview(.clearOrdinary)
        let favorite = try await store.preview(.favorite(id, true)); _ = try await store.apply(favorite.token)
        do { _ = try await store.apply(stale.token); Issue.record("旧token删除新收藏") } catch { #expect(error as? StoreError == .stalePreview) }
        let days = try await store.preview(.retention(7)); _ = try await store.apply(days.token)
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.settings().retentionDays == 7)
        #expect(try await reopened.detail(id: id, at: clock.now()).summary.isFavorite)
    }
    /// 不能容纳新记录时已有普通条目与收藏都保留；成功才原子淘汰。
    @Test func AC13_AC17_AC26_impossibleSaveKeepsOldContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.quotaBytes = MiB
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock, initialSettings: settings)
        func image(_ byte: UInt8, _ size: Int) -> ClipboardSnapshot { .init(payload: .init([.init([.init(SupportedType.png, Data(repeating: byte, count: size))])])) }
        let favorite = insertedID(try await store.ingest(image(1, 180_000), at: clock.now()))
        _ = try await store.apply(store.preview(.favorite(favorite, true)).token)
        clock.advance(1)
        let ordinary = insertedID(try await store.ingest(image(2, 70_000), at: clock.now()))
        settings = try await store.settings(); settings.quotaBytes = try await store.usage().measuredTotal + 64 * 1024
        await store.waitForPageCacheWarmupForTesting()
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try db.configure(); try Schema.writeSettings(db, settings); try db.close()
        let old = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        do { _ = try await store.ingest(image(3, 300_000), at: clock.now()); Issue.record("不可能容量仍成功") } catch { #expect(error as? StoreError == .quotaExceeded) }
        #expect(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite")) == old)
        #expect(Set(try await store.search(.init()).items.map(\.id)) == Set([favorite, ordinary]))
        clock.advance(1)
        let new = insertedID(try await store.ingest(image(4, 110_000), at: clock.now()))
        #expect(try await store.usage().measuredTotal <= settings.quotaBytes)
        #expect(try await store.search(.init()).items.contains { $0.id == new })
        #expect(try await store.detail(id: favorite, at: clock.now()).summary.isFavorite)
    }
    /// 已删条目、在途派生和旧分页都无法复活；索引丢失仍能搜正文。
    @Test func AC14_AC25_deletedContentAndCacheFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("FULL-TAIL-需求"), at: SystemClock().now()))
        let detail = try await store.detail(id: id, at: SystemClock().now())
        await store.waitForPageCacheWarmupForTesting()
        let strategy = try CommitStrategy(root: root)
        try strategy.read { try $0.exec("DELETE FROM text_content") }
        #expect(try await store.search(.init("需求")).items.count == 1)
        let deletion = try await store.preview(.delete([id])); _ = try await store.apply(deletion.token)
        #expect(try await store.cacheThumbnail(id: id, revision: detail.revision, data: Data([1,2,3])) == false)
        #expect(try await store.search(.init("需求")).items.isEmpty)
        do { _ = try await store.detail(id: id, at: SystemClock().now()); Issue.record("删除仍有详情") } catch { #expect(error as? StoreError == .notFound) }
        #expect(try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM blobs") } == 0)
        #expect(try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM thumbnails") } == 0)
    }
    /// 标记或旧配置在存储入口复查，零正文残留。
    @Test func AC11_AC22_policyRecheckedAtIngest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        var privateInput = fixture("UNIQUE-SECRET-NOT-ON-DISK")
        privateInput.payload.items[0].declaredTypes = ["org.nspasteboard.TransientType"]
        #expect(try await store.ingest(privateInput, at: SystemClock().now()) == .skipped(.sensitive))
        #expect(!(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))).contains(Data("UNIQUE-SECRET-NOT-ON-DISK".utf8)))
        var settings = try await store.settings(); settings.captureEnabled = false
        _ = try await store.updateCaptureSettings(settings)
        #expect(try await store.ingest(fixture("paused"), at: SystemClock().now()) == .skipped(.paused))
        #expect(try await store.search(.init()).items.isEmpty)
    }
}
