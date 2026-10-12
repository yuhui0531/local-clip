// v3旧库在临时目录重建后打开，验证无损升级、名称迁移与备份，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct SchemaUpgradeTests {
    @Test func v3StoreUpgradesWithoutLoss() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = SystemClock().now()
        var settings = SettingsSnapshot(); settings.retentionDays = 7; settings.panelHeight = 290
        let id = insertedID(try await HistoryStore(location: root, initialSettings: settings).ingest(fixture("upgrade-body"), at: now))
        // 还原成v3形态：无名称列、名称存于设置文档、三处版本号为3。
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        var document = try JSONSerialization.jsonObject(with: Data(try db.scalarText("SELECT document FROM settings").utf8)) as! [String: Any]
        document["clipTitlesValue"] = [id: "旧名称"]
        try db.exec("ALTER TABLE clips DROP COLUMN title; ALTER TABLE clips DROP COLUMN normalizedTitle; UPDATE store_meta SET schemaVersion=3; PRAGMA user_version=3;")
        try db.run("UPDATE settings SET schemaVersion=3,document=?", [.text(String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self))])
        try db.close()

        let store = try HistoryStore(location: root)
        #expect(try await store.metadata(id: id, at: now).summary.title == "旧名称")
        #expect(try await store.settings().retentionDays == 7)
        #expect(try await store.search(.init("旧名称")).items.map(\.id) == [id])
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)
        #expect(backups.count == 1)
        // 备份保持原v3库，可用于回退。
        let backup = try SQLiteConnection(root.appendingPathComponent("Backups/" + backups[0]), readonly: true)
        #expect(try backup.scalarInt("PRAGMA user_version") == 3)
        try backup.close()
        // 再次打开已是v4，不再生成新备份。
        _ = try HistoryStore(location: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path).count == 1)
    }
}
