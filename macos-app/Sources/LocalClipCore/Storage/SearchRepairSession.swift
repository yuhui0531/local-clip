// 单次搜索的可取消派生索引；只读原库，临时表随连接关闭回收，by AI.Coding。
import Foundation

final class SearchRepairSession {
    let db: SQLiteConnection
    private(set) var repaired = 0
    private var cursor: (id: ClipID, index: Int64)?
    private static let textTypes = "'public.utf8-plain-text','public.url','public.rtf','public.html','public.file-url'"

    /// 临时索引使用SQLite文件页，避免缺索引全文常驻内存；不持有跨await读事务。
    init(database: URL) throws {
        db = try SQLiteConnection(database, readonly: true)
        try db.exec("PRAGMA temp_store=FILE; PRAGMA cache_size=-2048; CREATE TEMP TABLE search_repair(clipID TEXT,itemIndex INTEGER,plainText TEXT,normalizedText TEXT,PRIMARY KEY(clipID,itemIndex))")
    }

    /// 每次最多8个缺失项目；只读取可提取文字的表示，不读取同项的图片BLOB。
    func repairBatch(extract: (PasteboardItemValue) -> String?) throws -> Int {
        try Task.checkCancellation()
        let after = cursor == nil ? "" : " AND (r.clipID,r.itemIndex)>(?,?)"
        let values: [SQLValue] = cursor.map { [.text($0.id), .integer($0.index)] } ?? []
        let missing = try db.rows("""
            SELECT DISTINCT r.clipID,r.itemIndex FROM representations r
            LEFT JOIN text_content t ON t.clipID=r.clipID AND t.itemIndex=r.itemIndex
            LEFT JOIN search_repair s ON s.clipID=r.clipID AND s.itemIndex=r.itemIndex
            WHERE t.clipID IS NULL AND s.clipID IS NULL AND r.type IN(\(Self.textTypes))\(after)
            ORDER BY r.clipID,r.itemIndex LIMIT 8
            """, values)
        if missing.isEmpty, cursor != nil {
            // 每轮仅重查一次前段，包含让出actor期间恢复到游标之前的旧记录，by AI.Coding。
            cursor = nil
            return try repairBatch(extract: extract)
        }
        for row in missing {
            try Task.checkCancellation()
            let id = row.text("clipID"), index = row.int("itemIndex")
            let item = try Self.textItem(db, id: id, index: index)
            let text = extract(item) ?? ""
            try db.run("INSERT INTO search_repair VALUES(?,?,?,?)", [.text(id), .integer(index), .text(text), .text(SearchNormalizer.normalize(text))])
            cursor = (id, index)
        }
        repaired += missing.count
        return missing.count
    }

    /// 仅派生搜索使用选择性读取；每份已读表示仍验证长度及内容哈希。
    static func textItem(_ db: SQLiteConnection, id: ClipID, index: Int64) throws -> PasteboardItemValue {
        let rows = try db.rows("SELECT type,payload,byteCount,blobDigest FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND itemIndex=? AND type IN(\(textTypes))", [.text(id), .integer(index)])
        let representations = try rows.map { row -> Representation in
            try Task.checkCancellation()
            let data = row.data("payload")
            guard Int64(data.count) == row.int("byteCount"), ContentFingerprint.hash(data) == row.text("blobDigest") else { throw StoreError.corruptPayload }
            return .init(row.text("type"), data)
        }
        return .init(representations)
    }

    /// 后台补建可能已写入部分索引；优先持久索引，不重复同一项目。
    var indexedSQL: String {
        repaired == 0 ? "text_content" : "(SELECT * FROM text_content UNION ALL SELECT s.* FROM search_repair s WHERE NOT EXISTS(SELECT 1 FROM text_content t WHERE t.clipID=s.clipID AND t.itemIndex=s.itemIndex))"
    }
}
