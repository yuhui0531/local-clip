// 只读拖放载荷桥，任何读取前后检查当前版本和可见性，by AI.Coding。
import Foundation
public final class ClipExportAccess: Sendable {
    public let id: ClipID
    public let revision: Int64
    public let types: [String]
    private let database: URL
    init(database: URL, id: ClipID, revision: Int64, types: [String]) { self.database = database; self.id = id; self.revision = revision; self.types = types }
    /// 每次打开只读连接；删除、到期或其他持久变更立即使旧提供者失效。
    public func data(type: String) throws -> Data {
        guard types.contains(type) else { throw StoreError.notFound }
        let db = try SQLiteConnection(database, readonly: true)
        defer { try? db.close() }
        try validate(db)
        let rows = try db.rows("SELECT payload FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND type=? ORDER BY itemIndex", [.text(id), .text(type)])
        // 同记录多项文本提供按项拼接的纯文本；二进制多项由原始项目提供者逐项输出。
        guard let data = rows.first?.data("payload") else { throw StoreError.notFound }
        let current = try SQLiteConnection(database, readonly: true); defer { try? current.close() }; try validate(current)
        return data
    }
    public func itemData(index: Int, type: String) throws -> Data {
        let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db)
        guard let row = try db.rows("SELECT payload FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND itemIndex=? AND type=?", [.text(id), .integer(Int64(index)), .text(type)]).first else { throw StoreError.notFound }
        let current = try SQLiteConnection(database, readonly: true); defer { try? current.close() }; try validate(current)
        return row.data("payload")
    }
    public func itemTypes() throws -> [[String]] {
        let db = try SQLiteConnection(database, readonly: true); defer { try? db.close() }; try validate(db)
        let rows = try db.rows("SELECT itemIndex,type FROM representations WHERE clipID=? ORDER BY itemIndex,type", [.text(id)])
        let groups = Dictionary(grouping: rows) { Int($0.int("itemIndex")) }
        return groups.keys.sorted().map { groups[$0]!.map { $0.text("type") } }
    }
    private func validate(_ db: SQLiteConnection) throws {
        guard try db.scalarInt("PRAGMA user_version") == Schema.version, try db.scalarInt("SELECT storeRevision FROM store_meta") == revision else { throw StoreError.stalePreview }
        let settings = try Schema.readSettings(db)
        guard try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=? AND (isFavorite=1 OR EXISTS(SELECT 1 FROM clip_categories WHERE clipID=clips.id) OR lastCopiedAtMs>?)", [.text(id), .integer(settings.retentionDays == 0 ? Int64.min : SystemClock().now() - Int64(settings.retentionDays)*dayMS)]) == 1 else { throw StoreError.notFound }
    }
}
