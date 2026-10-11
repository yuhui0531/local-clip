// 只读拖放载荷桥，任何读取前后检查当前版本和可见性，by AI.Coding。
import Foundation
import Synchronization
public final class ClipExportAccess: Sendable {
    public let id: ClipID
    public let revision: Int64
    public let types: [String]
    private let active = Mutex(true)
    private let expires = SystemClock().now() + 600_000
    public func cancel() { active.withLock { $0 = false } }
    public func checkValid() throws { let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db) }
    private let database: URL
    private let contentHash: String
    init(database: URL, id: ClipID, revision: Int64, types: [String], contentHash: String) { self.database = database; self.id = id; self.revision = revision; self.types = types; self.contentHash = contentHash }
    /// 每个项目独立延迟读取，版本复查后才向目标返回真实格式。
    public func itemData(index: Int, type: String) throws -> Data {
        let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db)
        guard let row = try db.rows("SELECT payload,digest,byteCount FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND itemIndex=? AND type=?", [.text(id), .integer(Int64(index)), .text(type)]).first else { throw StoreError.notFound }
        let bytes = row.data("payload")
        guard Int64(bytes.count) == row.int("byteCount"), ContentFingerprint.hash(bytes) == row.text("digest") else { throw StoreError.corruptPayload }
        let current = try SQLiteConnection(database, readonly: true); defer { try? current.close() }; try validate(current)
        return bytes
    }
    public func itemTypes() throws -> [[String]] {
        let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db)
        let rows = try db.rows("SELECT itemIndex,type FROM representations WHERE clipID=? ORDER BY itemIndex,type", [.text(id)])
        let groups = Dictionary(grouping: rows) { Int($0.int("itemIndex")) }
        return groups.keys.sorted().map { groups[$0]!.map { $0.text("type") } }
    }
    private func validate(_ db: SQLiteConnection) throws {
        guard active.withLock({ $0 }), SystemClock().now() < expires else { throw StoreError.notFound }
        // 拖放验证不可变内容身份；无关采集或设置提交不使当前记录失效。
        guard try db.scalarInt("PRAGMA user_version") == Schema.version else { throw StoreError.stalePreview }
        guard try db.scalarText("SELECT contentHash FROM clips WHERE id=?", [.text(id)]) == contentHash else { throw StoreError.notFound }
        let settings = try Schema.readSettings(db)
        guard try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=? AND (isFavorite=1 OR EXISTS(SELECT 1 FROM clip_categories WHERE clipID=clips.id) OR lastCopiedAtMs>?)", [.text(id), .integer(settings.retentionDays == 0 ? Int64.min : SystemClock().now() - Int64(settings.retentionDays)*dayMS)]) == 1 else { throw StoreError.notFound }
    }
}
