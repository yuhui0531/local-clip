// 已提交故障、垃圾占用与收藏超额真实文件验证，by AI.Coding。
import Foundation
import Darwin
import Testing
@testable import LocalClipCore
struct FailureBoundaryTests {
    /// 全库恰好到容量但普通载荷可淘汰时，探测不得全局暂停或改变原库。
    @Test func AC13_AC17_capacityProbePreservesReleasableFullStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try HistoryStore(location: root)
        let oldID = insertedID(try await initial.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data(repeating: 9, count: 128 * 1024))])])), at: SystemClock().now()))
        var settings = try await initial.settings(); settings.quotaBytes = try await initial.usage().measuredTotal
        // 专用fixture注入精确小上限；正式设置仍接受100–4096MiB。
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try db.configure(); try Schema.writeSettings(db, settings); try db.close()
        let store = try HistoryStore(location: root)
        let file = root.appendingPathComponent("History/history.sqlite"), before = try Data(contentsOf: file)
        #expect(try await store.usage().measuredTotal == settings.quotaBytes)
        #expect(try await store.canCapture())
        #expect(try Data(contentsOf: file) == before)
        #expect(try await store.detail(id: oldID, at: SystemClock().now()).summary.id == oldID)
        _ = try await store.ingest(fixture("SMALL-AT-FULL"), at: SystemClock().now())
        #expect(try await store.search(.init("SMALL-AT-FULL")).items.count == 1)
        #expect(try await store.usage().measuredTotal <= settings.quotaBytes)
    }
    /// 一个字节垃圾也占文件系统块；计量不能只报告一个字节。
    @Test func AC25_allocationBlocksAreCounted() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try HistoryStore(location:root)
        let file=root.appendingPathComponent("Staging/single-byte")
        try Data([1]).write(to:file); var info=stat()
        #expect(Darwin.lstat(file.path,&info) == 0)
        #expect(try await store.usage().pending >= max(Int64(info.st_size),Int64(info.st_blocks)*512))
        #expect(try await store.usage().pending > 1)
    }
    /// 正文能放下而全文缓存不能时，丢缓存也不得丢旧收藏和原格式。
    @Test func AC25_indexBudgetPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.quotaBytes = 100 * MiB
        let store = try HistoryStore(location: root, initialSettings: settings)
        for byte in [UInt8(21),22] {
            let input = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.png, Data(repeating: byte, count: 30 * 1_048_576))])]))
            let id = insertedID(try await store.ingest(input, at: SystemClock().now()))
            let preview = try await store.preview(.favorite(id, true)); _ = try await store.apply(preview.token)
        }
        let text = String(repeating: "x", count: 16 * 1_048_576) + "CACHE-MISSING-TAIL"
        let id = insertedID(try await store.ingest(fixture(text), at: SystemClock().now()))
        #expect(try await store.search(.init()).items.count == 3)
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).items[0].representations[0].data == Data(text.utf8))
        #expect(try await store.search(.init("CACHE-MISSING-TAIL")).items.first?.id == id)
        #expect(try await store.usage().measuredTotal <= 100 * MiB)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM text_content") == 0); try db.close()
    }
    /// 操作系统实际拒绝回收时文件仍被计量，恢复不能报已释放。
    @Test func AC25_realCleanupPermissionFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pending = root.appendingPathComponent("Staging/locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: pending.path); try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 65536).write(to: pending.appendingPathComponent("candidate.sqlite"))
        try FileManager.default.setAttributes([.posixPermissions:0o555], ofItemAtPath: pending.path)
        _ = try await store.recover()
        #expect(try await store.usage().pending == 65536)
        #expect(FileManager.default.fileExists(atPath: pending.appendingPathComponent("candidate.sqlite").path))
    }
    /// 提交后不可用不谎报回滚，重启同操作ID不重复增加次数。
    @Test func AC15_AC26_E08_postCommitUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let original = try HistoryStore(location: root, clock: clock)
        _ = try await original.ingest(fixture("old"), at: clock.now())
        let failing = try HistoryStore(location: root, clock: clock, faults: ThrowAt(point: .reopen))
        let input = fixture("new", id: "known-operation")
        do { _ = try await failing.ingest(input, at: clock.now()); Issue.record("未报告提交后故障") } catch { #expect(error as? StoreError == .postCommitUnavailable) }
        do { _ = try await failing.search(.init()); Issue.record("不可用仍查询") } catch { #expect(error as? StoreError == .postCommitUnavailable) }
        let reopened = try HistoryStore(location: root, clock: clock)
        #expect(try await reopened.search(.init()).items.count == 2)
        let result = try await reopened.ingest(input, at: clock.now())
        #expect(try await reopened.detail(id: insertedID(result), at: clock.now()).summary.copyCount == 1)
    }
    /// 无法清理的真实文件纳入总量；恢复不报告虚假释放。
    @Test func AC25_pendingFilesAreMeasured() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let pending = root.appendingPathComponent("Staging/pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 65536).write(to: pending.appendingPathComponent("candidate.sqlite"))
        let usage = try await store.usage()
        #expect(usage.pending == 65536)
        #expect(usage.measuredTotal == usage.favoritePayload + usage.normalPayload + usage.common + usage.pending)
        _ = try await store.recover()
        #expect(try await store.usage().pending == 0)
    }
    /// 收藏占用超过新上限仍保留，下调预览取消与确认不同。
    @Test func AC27_favoritesOverQuotaAndDryPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        var ids: [ClipID] = []
        for byte in [UInt8(1), 2, 3] {
            let input = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.png, Data(repeating: byte, count: 40 * 1_048_576))])]))
            let id = insertedID(try await store.ingest(input, at: SystemClock().now())); ids.append(id)
            let p = try await store.preview(.favorite(id, true)); _ = try await store.apply(p.token)
        }
        let before = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        let preview = try await store.preview(.quota(100 * MiB))
        #expect(preview.requiresConfirmation); #expect(preview.affectedCount == 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite")) == before)
        _ = try await store.apply(preview.token)
        #expect(try await store.settings().quotaBytes == 100 * MiB)
        #expect(try await store.usage().measuredTotal > 100 * MiB)
        #expect(try await !store.canCapture())
        #expect(Set(try await store.search(.init()).items.map(\.id)) == Set(ids))
        do { _ = try await store.ingest(fixture("new"), at: SystemClock().now()); Issue.record("超额仍采集") } catch { #expect(error as? StoreError == .policyChanged) }
        var input = fixture("new"); input.policyRevision = try await store.settings().revision
        do { _ = try await store.ingest(input, at: SystemClock().now()); Issue.record("收藏超额仍新增") } catch { #expect(error as? StoreError == .quotaExceeded) }
    }
}
