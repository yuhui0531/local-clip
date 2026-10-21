// 历史模型v6保存独立手动位置；v5在单一事务内升级，未知版本拒绝打开，by AI.Coding。
import Foundation
enum Schema {
    static let version: Int64 = 6
    /// 初次建库完整执行；未知版本拒绝而非盲目覆盖。
    static func create(_ db: SQLiteConnection, settings: SettingsSnapshot) throws {
        try db.exec("""
        CREATE TABLE clips(
          id TEXT PRIMARY KEY, contentHash TEXT NOT NULL UNIQUE,
          firstCopiedAtMs INTEGER NOT NULL,lastCopiedAtMs INTEGER NOT NULL,
          copyCount INTEGER NOT NULL CHECK(copyCount>=1),kind TEXT NOT NULL,
          isFavorite INTEGER NOT NULL CHECK(isFavorite IN(0,1)),
          sourceBundleID TEXT,sourceName TEXT NOT NULL,sourceBasis TEXT NOT NULL,
          previewText TEXT NOT NULL,title TEXT,normalizedTitle TEXT,manualPosition INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE items(clipID TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
          itemIndex INTEGER NOT NULL CHECK(itemIndex>=0), declaredTypes TEXT NOT NULL,
          PRIMARY KEY(clipID,itemIndex));
        CREATE TABLE blobs(digest TEXT PRIMARY KEY,byteCount INTEGER NOT NULL CHECK(byteCount>=0),
          payload BLOB NOT NULL,CHECK(length(payload)=byteCount));
        CREATE TABLE representations(clipID TEXT NOT NULL,itemIndex INTEGER NOT NULL,
          type TEXT NOT NULL,blobDigest TEXT NOT NULL REFERENCES blobs(digest),
          PRIMARY KEY(clipID,itemIndex,type),
          FOREIGN KEY(clipID,itemIndex) REFERENCES items(clipID,itemIndex) ON DELETE CASCADE);
        CREATE TABLE text_content(clipID TEXT NOT NULL,itemIndex INTEGER NOT NULL,
          plainText TEXT NOT NULL,normalizedText TEXT NOT NULL,
          PRIMARY KEY(clipID,itemIndex),FOREIGN KEY(clipID,itemIndex) REFERENCES items(clipID,itemIndex) ON DELETE CASCADE);
        CREATE TABLE thumbnails(clipID TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
          revision INTEGER NOT NULL,encodedImage BLOB NOT NULL,byteCount INTEGER NOT NULL,CHECK(length(encodedImage)=byteCount));
        CREATE TABLE settings(singletonID INTEGER PRIMARY KEY CHECK(singletonID=1),
          schemaVersion INTEGER NOT NULL,document TEXT NOT NULL);
        CREATE TABLE store_meta(singletonID INTEGER PRIMARY KEY CHECK(singletonID=1),
          schemaVersion INTEGER NOT NULL,storeRevision INTEGER NOT NULL,lastOperationID TEXT NOT NULL);
        INSERT INTO store_meta VALUES(1,\(version),0,'');
        CREATE INDEX recent ON clips(lastCopiedAtMs DESC,id);
        CREATE INDEX manual_order ON clips(manualPosition,id);
        CREATE INDEX favorites ON clips(isFavorite,lastCopiedAtMs,firstCopiedAtMs,id);
        CREATE INDEX blob_references ON representations(blobDigest);
        PRAGMA user_version=\(version);
        """)
        try createCategories(db)
        try db.exec(imageTextSQL)
        try writeSettings(db, settings)
    }
    /// 旧库升级保留复制身份和原顺序；结构、版本与配置标记一并提交或回滚。
    static func migrateV5(_ db: SQLiteConnection) throws {
        guard try db.scalarInt("SELECT schemaVersion FROM settings WHERE singletonID=1") == 5,
              try db.scalarInt("SELECT schemaVersion FROM store_meta WHERE singletonID=1") == 5 else { throw StoreError.incompatibleSchema }
        try db.exec("""
        ALTER TABLE clips ADD COLUMN manualPosition INTEGER NOT NULL DEFAULT 0;
        WITH ordered AS (SELECT id,ROW_NUMBER() OVER (ORDER BY lastCopiedAtMs DESC,id) AS position FROM clips)
        UPDATE clips SET manualPosition=(SELECT position FROM ordered WHERE ordered.id=clips.id);
        CREATE INDEX manual_order ON clips(manualPosition,id);
        UPDATE settings SET schemaVersion=6;
        UPDATE store_meta SET schemaVersion=6;
        PRAGMA user_version=6;
        """)
    }
    /// 图片文字索引是可重建的派生数据：按记录与图片项保存，blobDigest绑定识别所用的原图表示，表示被替换后旧结果自动失效。
    /// v5已有的派生扩展继续按需补建；normalizedText为空表示无文字或无法识别，不再重试，by AI.Coding。
    static let imageTextSQL = """
    CREATE TABLE IF NOT EXISTS image_text(clipID TEXT NOT NULL,itemIndex INTEGER NOT NULL,blobDigest TEXT NOT NULL,normalizedText TEXT NOT NULL,
      PRIMARY KEY(clipID,itemIndex),FOREIGN KEY(clipID,itemIndex) REFERENCES items(clipID,itemIndex) ON DELETE CASCADE);
    """
    /// 分类与归属同库保存，删除历史会级联移除归属，原始表示不重复存储。
    private static func createCategories(_ db: SQLiteConnection) throws {
        try db.exec("""
        CREATE TABLE categories(id TEXT PRIMARY KEY,name TEXT NOT NULL,
          normalizedName TEXT NOT NULL UNIQUE,createdAtMs INTEGER NOT NULL,colorHex TEXT NOT NULL,position INTEGER NOT NULL);
        CREATE TABLE clip_categories(categoryID TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
          clipID TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,position INTEGER NOT NULL,PRIMARY KEY(categoryID,clipID));
        CREATE INDEX clip_category_memberships ON clip_categories(clipID,categoryID);
        """)
    }
    /// 配置是单例事实；JSON 仅编码结构化字段，不存第二份设置副本。
    static func writeSettings(_ db: SQLiteConnection, _ settings: SettingsSnapshot) throws {
        let document = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO settings VALUES(1,?,?)", [.integer(version), .text(document)])
    }
    /// 当前模型完整解码；不接受其他版本。
    static func readSettings(_ db: SQLiteConnection) throws -> SettingsSnapshot {
        guard let row = try db.rows("SELECT * FROM settings WHERE singletonID=1").first,
              row.int("schemaVersion") == version else { throw StoreError.incompatibleSchema }
        return try JSONDecoder().decode(SettingsSnapshot.self, from: Data(row.text("document").utf8))
    }
}
