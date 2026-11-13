// 已提交故障、垃圾占用与收藏超额真实文件验证，by AI.Coding。
import Foundation
import Darwin
import Testing
@testable import LocalClipCore
struct FailureBoundaryTests {
    #if DEBUG
    /// 满配额的预演可复用；修订、派生写入和目录占用变化均须重新判定，by AI.Coding。
    @Test func fullQuotaCapacityPreviewReusesOnlyUnchangedInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot()
        settings.quotaBytes = 100 * MiB
        settings.imageTextSearchSince = 1
        let store = try HistoryStore(location: root, initialSettings: settings)
        let image = Data(repeating: 7, count: 256 * 1024)
        let at = SystemClock().now()
        let snapshot = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.png, image)])]))
        let imageID = insertedID(try await store.ingest(snapshot, at: at))
        let ordinaryID = insertedID(try await store.ingest(fixture("ordinary"), at: at))
        try #require(!imageID.isEmpty && !ordinaryID.isEmpty)
        let exports = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let filler = exports.appendingPathComponent("filler")
        try Data().write(to: filler)
        let handle = try FileHandle(forWritingTo: filler)
        defer { try? handle.close() }

        func resizeExport(_ size: Int64) throws { try handle.truncate(atOffset: UInt64(size)) }
        func expectPreview(_ count: Int) async throws {
            #expect(try await store.usage().measuredTotal >= settings.quotaBytes)
            let fresh = try HistoryStore(location: root)
            let result = try await store.canCapture()
            #expect(result == (try await fresh.canCapture()))
            #expect(await store.captureCapacityPreviewCount == count)
            #expect(try await store.canCapture() == result)
            #expect(await store.captureCapacityPreviewCount == count)
        }

        try resizeExport(settings.quotaBytes - 192 * 1024)
        try await expectPreview(1)
        #expect(try await store.canCapture())
        _ = try await store.apply(store.preview(.delete([ordinaryID])).token)
        try await expectPreview(2)
        _ = try await store.apply(store.preview(.favorite(imageID, true)).token)
        try await expectPreview(3)
        #expect(try await !store.canCapture())
        // 补写派生数据时暂时腾出空间，再恢复到满配额场景，by AI.Coding。
        try resizeExport(0)
        let metadata = try await store.metadata(id: imageID, at: at)
        #expect(try await store.cacheThumbnail(id: imageID, revision: metadata.revision, data: Data([1, 2, 3])))
        try resizeExport(settings.quotaBytes - 192 * 1024)
        try await expectPreview(4)
        try resizeExport(0)
        #expect(try await store.saveImageText(.init(clipID: imageID, itemIndex: 0), digest: ContentFingerprint.hash(image), text: "indexed text"))
        try resizeExport(settings.quotaBytes - 192 * 1024)
        try await expectPreview(5)
        try resizeExport(settings.quotaBytes - 208 * 1024)
        try await expectPreview(6)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        settings.quotaBytes -= 4096
        try Schema.writeSettings(db, settings)
        try db.close()
        try await expectPreview(7)
        try await store.clearImageText()
        try await expectPreview(8)
        _ = try await store.recover()
        try await expectPreview(9)
    }
    #endif

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
    /// 重复入库按表示摘要识别；载荷字节损坏由正文读取报告，by AI.Coding。
    @Test func duplicateChecksDescriptorsWithoutReadingStoredBlob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let at = SystemClock().now()
        let id = insertedID(try await store.ingest(fixture("original"), at: at))
        try #require(!id.isEmpty)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.exec("UPDATE blobs SET payload=zeroblob(byteCount)")
        try db.close()
        #expect(try await store.ingest(fixture("original"), at: at + 1) == .deduplicated(id))
        await #expect(throws: StoreError.corruptPayload) { try await store.detail(id: id, at: at + 1) }
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
    /// 保留检索规范化文字，压缩可从原格式还原的大文本副本，不丢旧收藏。
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
        #expect(try db.scalarInt("SELECT COUNT(*) FROM text_content") == 1); try db.close()
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
        #expect(try await store.usage().pending == 65536)
        let handle = try FileHandle(forWritingTo: pending.appendingPathComponent("candidate.sqlite"))
        try handle.truncate(atOffset: 131072)
        try handle.close()
        let usage = try await store.usage()
        #expect(usage.pending == 131072)
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
