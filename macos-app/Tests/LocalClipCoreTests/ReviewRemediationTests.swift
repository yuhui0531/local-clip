// LC-R06/R11：虚拟时间、持久设置与缓存删除边界，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct ReviewRemediationTests {
    /// 暂停以调用者时间判断，不能被宿主真实时间穿透；导出保留期限也跟随注入时钟。
    @Test func pauseAndExportFollowInjectedClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(1_000_000)
        var settings = SettingsSnapshot(); settings.pauseUntil = clock.now() + 100
        let store = try HistoryStore(location: root, clock: clock, initialSettings: settings)
        #expect(try await store.ingest(fixture("paused"), at: clock.now()) == .skipped(.paused))
        clock.advance(100)
        let id = insertedID(try await store.ingest(fixture("accepted"), at: clock.now()))
        #expect(!id.isEmpty)
        let access = try await store.exportAccess(id: id)
        #expect(try access.itemData(index: 0, type: SupportedType.string) == Data("accepted".utf8))
        clock.advance(600_000)
        #expect(throws: StoreError.notFound) { try access.checkValid() }
    }

    /// 设置提交与恢复后读取持久新值；删除后派生缓存不能让正文复活。
    @Test func settingsMutationRecoveryAndDeletionStayConsistent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let id = insertedID(try await store.ingest(fixture("cache count"), at: SystemClock().now()))
        #expect(try await store.textCharacterCount(id: id, at: SystemClock().now()) == 11)
        var settings = try await store.settings(); settings.hideContents = true
        let saved = try await store.updateCaptureSettings(settings)
        #expect(try await store.settings() == saved)
        _ = try await store.recover()
        #expect(try await store.settings() == saved)
        let preview = try await store.preview(.delete([id]))
        _ = try await store.apply(preview.token)
        do { _ = try await store.textCharacterCount(id: id, at: SystemClock().now()); Issue.record("Deleted content returned") }
        catch { #expect(error as? StoreError == .notFound) }
        #expect(try await store.integrityCheck())
    }
}
