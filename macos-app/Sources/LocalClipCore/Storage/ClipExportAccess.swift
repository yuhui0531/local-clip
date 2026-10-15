// 只读拖放载荷桥，任何读取前后检查当前版本和可见性，by AI.Coding。
import Foundation
import Synchronization
public final class ClipExportAccess: Sendable {
    public let id: ClipID
    public let revision: Int64
    public let types: [String]
    private let active = Mutex(true)
    private let clock: any ClipClock
    private let expires: Instant
    public func cancel() { active.withLock { $0 = false } }
    public func checkValid() throws { let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db) }
    private let database: URL
    private let contentHash: String
    /// 拖放租约和可见性共用存储时钟，虚拟时间不被系统时间穿透，by AI.Coding。
    init(database: URL, id: ClipID, revision: Int64, types: [String], contentHash: String, clock: any ClipClock = SystemClock()) {
        self.database = database; self.id = id; self.revision = revision; self.types = types; self.contentHash = contentHash
        self.clock = clock; expires = clock.now() + 600_000
    }
    /// 每个项目独立延迟读取，版本复查后才向目标返回真实格式。
    public func itemData(index: Int, type: String) throws -> Data {
        try itemPayload(index: index, type: type).data
    }
    private func itemPayload(index: Int, type: String) throws -> VerifiedExportPayload {
        let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db)
        // 与主存储连接使用相同的有界映射；不支持映射时SQLite继续使用普通读取，by AI.Coding。
        try db.exec("PRAGMA mmap_size=201326592")
        guard let row = try db.rows("SELECT payload,digest,byteCount FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND itemIndex=? AND type=?", [.text(id), .integer(Int64(index)), .text(type)]).first else { throw StoreError.notFound }
        let payload = try VerifiedExportPayload(row.data("payload"), expectedDigest: row.text("digest"), expectedByteCount: row.int("byteCount"))
        let current = try SQLiteConnection(database, readonly: true); defer { try? current.close() }; try validate(current)
        return payload
    }
    public func itemTypes() throws -> [[String]] {
        let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db)
        let rows = try db.rows("SELECT itemIndex,type FROM representations WHERE clipID=? ORDER BY itemIndex,type", [.text(id)])
        let groups = Dictionary(grouping: rows) { Int($0.int("itemIndex")) }
        return groups.keys.sorted().map { groups[$0]!.map { $0.text("type") } }
    }
    /// 目标请求文件URL时同步兑现；不等待actor/主线程任务，避免pasteboard回调死锁，by AI.Coding。
    public func materializeDragFile(index: Int, type: String, fileName: String) throws -> (url: URL, created: Bool) {
        let root = database.deletingLastPathComponent().deletingLastPathComponent()
        let payload = try itemPayload(index: index, type: type)
        let file = try DragFileStorage.write(payload, root: root, fileName: fileName)
        do { try checkValid(); return file }
        catch {
            // 写入中记录被删除/会话取消时，不发布路径，也不删此前已交给外部应用的文件。
            if file.created { try? DragFileStorage.remove([file.url], root: root) }
            throw error
        }
    }
    private func validate(_ db: SQLiteConnection) throws {
        guard active.withLock({ $0 }), clock.now() < expires else { throw StoreError.notFound }
        // 拖放验证不可变内容身份；无关采集或设置提交不使当前记录失效。
        guard try db.scalarInt("PRAGMA user_version") == Schema.version else { throw StoreError.stalePreview }
        guard try db.scalarText("SELECT contentHash FROM clips WHERE id=?", [.text(id)]) == contentHash else { throw StoreError.notFound }
        let settings = try Schema.readSettings(db)
        let cutoff = retentionCutoff(settings: settings, at: clock.now())
        guard try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=? AND (? IS NULL OR (\(protectedSQL)) OR lastCopiedAtMs>?)",
                               [.text(id), cutoff.map(SQLValue.integer) ?? .null, cutoff.map(SQLValue.integer) ?? .null]) == 1 else { throw StoreError.notFound }
    }
}

// 校验结果与不可变字节一起传递；拖出文件不再重复哈希，也不接受未经校验的摘要，by AI.Coding。
struct VerifiedExportPayload {
    let data: Data
    let digest: String
    init(_ data: Data) {
        self.data = data
        digest = ContentFingerprint.hash(data)
    }
    init(_ data: Data, expectedDigest: String, expectedByteCount: Int64) throws {
        guard Int64(data.count) == expectedByteCount else { throw StoreError.corruptPayload }
        self.init(data)
        guard digest == expectedDigest else { throw StoreError.corruptPayload }
    }
}
