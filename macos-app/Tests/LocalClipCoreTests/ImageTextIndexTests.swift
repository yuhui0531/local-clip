// A2图片文字索引的存储契约：旧库补建、检索命中原图、内容版本绑定、删除/到期/隐藏/容量；只用临时库与合成数据，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

/// 只在布防后于COMMIT前抛错，用于模拟旧库补建失败。
private final class OnceFault: StorageFaultInjector, @unchecked Sendable {
    private let lock = NSLock(); private var armed: Bool
    init(armed: Bool) { self.armed = armed }
    func check(_ point: FaultPoint) throws {
        try lock.withLock { guard armed, point == .beforeReplace else { return }; armed = false; throw StoreError.diskFull }
    }
}

struct ImageTextIndexTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func image(_ byte: UInt8, _ size: Int = 64) -> Representation { .init(SupportedType.png, Data(repeating: byte, count: size)) }
    private func insert(_ store: HistoryStore, _ items: [PasteboardItemValue], at: Instant = SystemClock().now()) async throws -> ClipID {
        insertedID(try await store.ingest(.init(payload: .init(items)), at: at))
    }
    private func enable(_ store: HistoryStore, _ on: Bool = true, edit: (inout SettingsSnapshot) -> Void = { _ in }) async throws {
        var settings = try await store.settings(); settings.imageTextSearchSince = on ? 1 : nil; edit(&settings)
        _ = try await store.updateCaptureSettings(settings)
    }
    private func ids(_ store: HistoryStore, _ request: SearchRequest) async throws -> [ClipID] { try await store.search(request).items.map(\.id) }
    private func raw(_ root: URL, _ sql: String) throws -> Int64 {
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); defer { try? db.close() }
        try db.configure()
        if sql.hasPrefix("SELECT") || sql.hasPrefix("PRAGMA") { return try db.scalarInt(sql) }
        try db.exec(sql); return 0
    }

    /// 旧库（无image_text）打开时补建：版本号不变，历史条数、原始内容、收藏与分类归属一致。
    @Test func legacyStoreGainsTableWithoutTouchingHistory() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        var store: HistoryStore? = try HistoryStore(location: location)
        let text = try await insert(store!, [.init([.init(SupportedType.string, Data("legacy note".utf8))])])
        let picture = try await insert(store!, [.init([image(1)])])
        _ = try await store!.apply(try await store!.preview(.favorite(text, true)).token)
        let category = try await store!.createCategory(name: "旧分类", colorHex: "34C759")
        _ = try await store!.apply(try await store!.preview(.category([picture], category.id, true)).token)
        let before = (try await store!.search(.init()).items, try await store!.loadPayload(id: picture, at: SystemClock().now()))
        store = nil
        _ = try raw(location, "DROP TABLE image_text")
        #expect(try raw(location, "SELECT COUNT(*) FROM sqlite_master WHERE name='image_text'") == 0)
        let reopened = try HistoryStore(location: location)
        #expect(reopened.imageTextReady)
        #expect(try raw(location, "SELECT COUNT(*) FROM sqlite_master WHERE name='image_text'") == 1)
        #expect(try raw(location, "PRAGMA user_version") == Schema.version)
        #expect(try await reopened.search(.init()).items.map(\.id) == before.0.map(\.id))
        #expect(try await reopened.search(.init(favorites: true)).items.map(\.id) == [text])
        #expect(try await ids(reopened, .init(categoryIDs: [category.id])) == [picture])
        #expect(try await reopened.loadPayload(id: picture, at: SystemClock().now()) == before.1)
        #expect(try await reopened.search(.init()).items.map(\.copyCount) == before.0.map(\.copyCount))
    }

    /// 补建失败回滚：历史照常可读可搜，图片文字功能不可用；下次打开再补建成功。
    @Test func failedTableCreationKeepsStoreUsable() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        var store: HistoryStore? = try HistoryStore(location: location)
        let note = try await insert(store!, [.init([.init(SupportedType.string, Data("still searchable".utf8))])])
        let picture = try await insert(store!, [.init([image(2)])])
        store = nil; _ = try raw(location, "DROP TABLE image_text")
        let degraded = try HistoryStore(location: location, faults: OnceFault(armed: true))
        #expect(!degraded.imageTextReady)
        #expect(try raw(location, "SELECT COUNT(*) FROM sqlite_master WHERE name='image_text'") == 0)
        try await enable(degraded)
        #expect(try await ids(degraded, .init("searchable")) == [note])
        #expect(try await degraded.pendingImageText(since: nil).isEmpty)
        let saved = try await degraded.saveImageText(.init(clipID: picture, itemIndex: 0), digest: ContentFingerprint.hash(image(2).data), text: "x")
        #expect(!saved)
        let recovered = try HistoryStore(location: location)
        #expect(recovered.imageTextReady)
        #expect(try await recovered.pendingImageText(since: nil) == [.init(clipID: picture, itemIndex: 0)])
    }

    /// 搜索命中原图：多图片记录逐项索引，同一项多种图片表示只算一项；与图片类型、分类筛选组合；关闭后不命中，再开启复用索引。
    /// 识别结果不改变原payload、次数、收藏、分类与排序时间。
    @Test func ocrTextFindsOriginalImage() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try HistoryStore(location: location), now = SystemClock().now()
        let tiff = Representation(SupportedType.tiff, Data(repeating: 9, count: 80))
        let album = try await insert(store, [.init([image(3), tiff]), .init([image(4)])], at: now)
        let other = try await insert(store, [.init([image(5)])], at: now + 1)
        let note = try await insert(store, [.init([.init(SupportedType.string, Data("plain words".utf8))])], at: now + 2)
        try await enable(store)
        #expect(try await store.pendingImageText(since: nil) == [.init(clipID: other, itemIndex: 0), .init(clipID: album, itemIndex: 0), .init(clipID: album, itemIndex: 1)])
        #expect(try await store.pendingImageText(since: now + 1).map(\.clipID) == [other])
        let before = try await store.search(.init()).items, payload = try await store.loadPayload(id: album, at: now)
        #expect(try await store.saveImageText(.init(clipID: album, itemIndex: 1), digest: ContentFingerprint.hash(image(4).data), text: "Quarterly REVENUE 7319"))
        #expect(try await store.saveImageText(.init(clipID: album, itemIndex: 0), digest: ContentFingerprint.hash(tiff.data), text: "封面 标题"))
        #expect(try await store.saveImageText(.init(clipID: other, itemIndex: 0), digest: ContentFingerprint.hash(image(5).data), text: ""))
        #expect(try await store.pendingImageText(since: nil).isEmpty)
        #expect(try await ids(store, .init("revenue 7319")) == [album])
        #expect(try await ids(store, .init("封面")) == [album])
        #expect(try await ids(store, .init("revenue", kind: .image)) == [album])
        #expect(try await ids(store, .init("revenue", kind: .text)).isEmpty)
        let category = try await store.createCategory(name: "图", colorHex: "34C759"), empty = try await store.createCategory(name: "空", colorHex: "007AFF")
        _ = try await store.apply(try await store.preview(.category([album], category.id, true)).token)
        #expect(try await ids(store, .init("revenue", categoryIDs: [category.id])) == [album])
        #expect(try await ids(store, .init("revenue", categoryIDs: [empty.id])).isEmpty)
        #expect(try await ids(store, .init("plain")) == [note])
        let after = try await store.search(.init()).items
        #expect(after.map(\.id) == before.map(\.id) && after.map(\.lastCopiedAt) == before.map(\.lastCopiedAt) && after.map(\.copyCount) == before.map(\.copyCount))
        #expect(after.map(\.isFavorite) == before.map(\.isFavorite))
        #expect(try await store.loadPayload(id: album, at: now) == payload)
        try await enable(store, false)
        #expect(try await ids(store, .init("revenue")).isEmpty)
        #expect(try await store.saveImageText(.init(clipID: other, itemIndex: 0), digest: ContentFingerprint.hash(image(5).data), text: "late") == false)
        try await enable(store)
        #expect(try await ids(store, .init("revenue")) == [album])
        let reopened = try HistoryStore(location: location)
        #expect(try await ids(reopened, .init("revenue")) == [album])
        try await reopened.clearImageText()
        #expect(try await ids(reopened, .init("revenue")).isEmpty)
        #expect(try await reopened.pendingImageText(since: nil).count == 3)
    }

    /// 索引写入是派生数据：不递增storeRevision，用户在索引期间确认的预览仍可执行；写入后逐字输入的搜索立即看到新文字。
    /// 识别源只取该项图片表示，按PNG > TIFF > JPEG顺序，原图字节损坏时报告损坏而不是交给识别。
    @Test func indexWritesKeepPreviewsAndSourceIsPerItem() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try HistoryStore(location: location), now = SystemClock().now()
        let jpeg = Representation(SupportedType.jpeg, Data(repeating: 2, count: 48))
        let shot = try await insert(store, [.init([.init(SupportedType.string, Data("caption".utf8))]), .init([jpeg, image(1)])], at: now)
        try await enable(store)
        let job = ImageTextJob(clipID: shot, itemIndex: 1)
        #expect(try await store.imageTextSource(job, at: now) == [image(1), jpeg])
        #expect(try await ids(store, .init("inv")).isEmpty)
        let revision = try await store.search(.init()).revision, preview = try await store.preview(.favorite(shot, true))
        #expect(try await store.saveImageText(job, digest: ContentFingerprint.hash(image(1).data), text: "Invoice 7319"))
        #expect(try await store.search(.init()).revision == revision)
        #expect(try await ids(store, .init("invoice")) == [shot])
        _ = try await store.apply(preview.token)
        #expect(try await store.search(.init()).items.first?.isFavorite == true)
        _ = try raw(location, "UPDATE blobs SET payload=zeroblob(byteCount) WHERE digest='\(ContentFingerprint.hash(jpeg.data))'")
        await #expect(throws: StoreError.corruptPayload) { try await store.imageTextSource(job, at: now) }
    }

    /// 内容版本、删除、到期与隐藏：过期结果不写入、不命中；删除级联清除，撤销删除随记录恢复。
    @Test func staleDeletedExpiredAndHiddenResults() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try HistoryStore(location: location), now = SystemClock().now()
        let shot = try await insert(store, [.init([image(6)])], at: now)
        try await enable(store)
        let job = ImageTextJob(clipID: shot, itemIndex: 0), digest = ContentFingerprint.hash(image(6).data)
        #expect(try await store.saveImageText(job, digest: ContentFingerprint.hash(image(7).data), text: "wrong version") == false)
        #expect(try await store.saveImageText(job, digest: digest, text: "version one"))
        #expect(try await ids(store, .init("version one")) == [shot])
        // 原图表示被替换（例如旧版程序编辑）：旧结果不再命中，该项重新待识别。
        let replacement = Data(repeating: 8, count: 64)
        _ = try raw(location, "INSERT INTO blobs VALUES('\(ContentFingerprint.hash(replacement))',64,x'\(replacement.map { String(format: "%02x", $0) }.joined())'); UPDATE representations SET blobDigest='\(ContentFingerprint.hash(replacement))' WHERE clipID='\(shot)'; UPDATE store_meta SET storeRevision=storeRevision+1")
        #expect(try await ids(store, .init("version one")).isEmpty)
        #expect(try await store.pendingImageText(since: nil) == [job])
        #expect(try await store.saveImageText(job, digest: ContentFingerprint.hash(replacement), text: "version two"))
        #expect(try await ids(store, .init("version two")) == [shot])
        // 删除级联清除，删除后迟到的结果不能重建；撤销删除恢复记录与其索引。
        _ = try await store.apply(try await store.preview(.delete([shot])).token)
        #expect(try raw(location, "SELECT COUNT(*) FROM image_text") == 0)
        #expect(try await store.saveImageText(job, digest: ContentFingerprint.hash(replacement), text: "late") == false)
        #expect(try raw(location, "SELECT COUNT(*) FROM image_text") == 0)
        try await store.undoDelete()
        #expect(try await ids(store, .init("version two")) == [shot])
        // 隐藏内容期间不写入。
        try await enable(store) { $0.hideContents = true }
        #expect(try await store.saveImageText(job, digest: ContentFingerprint.hash(replacement), text: "hidden") == false)
        // 到期记录不待识别、不写入。
        let expiringRoot = root(); defer { try? FileManager.default.removeItem(at: expiringRoot) }
        let expiring = try HistoryStore(location: expiringRoot, initialSettings: { var value = SettingsSnapshot(); value.retentionDays = 1; value.imageTextSearchSince = 1; return value }())
        let old = try await insert(expiring, [.init([image(10)])], at: now - 3 * dayMS)
        #expect(try await expiring.pendingImageText(since: nil).isEmpty)
        #expect(try await expiring.saveImageText(.init(clipID: old, itemIndex: 0), digest: ContentFingerprint.hash(image(10).data), text: "expired") == false)
    }

    /// 容量：索引写入超出预算时停止且不淘汰历史；新采集需要空间时先丢弃可重建的索引，不淘汰旧历史。
    @Test func capacityNeverEvictsHistoryForIndex() async throws {
        let location = root(); defer { try? FileManager.default.removeItem(at: location) }
        var settings = SettingsSnapshot(); settings.quotaBytes = 512 * 1024; settings.imageTextSearchSince = 1
        let store = try HistoryStore(location: location, initialSettings: settings), now = SystemClock().now()
        let first = try await insert(store, [.init([image(11, 50 * 1024)])], at: now)
        let job = ImageTextJob(clipID: first, itemIndex: 0), digest = ContentFingerprint.hash(image(11, 50 * 1024).data)
        await #expect(throws: StoreError.quotaExceeded) { try await store.saveImageText(job, digest: digest, text: String(repeating: "overflow ", count: 60_000)) }
        #expect(try await store.search(.init()).items.map(\.id) == [first])
        #expect(try raw(location, "SELECT COUNT(*) FROM image_text") == 0)
        #expect(try await store.saveImageText(job, digest: digest, text: String(repeating: "fits ", count: 40_000)))
        let second = try await insert(store, [.init([image(12, 200 * 1024)])], at: now + 1)
        #expect(Set(try await store.search(.init()).items.map(\.id)) == [first, second])
        #expect(try raw(location, "SELECT COUNT(*) FROM image_text") == 0)
    }
}
