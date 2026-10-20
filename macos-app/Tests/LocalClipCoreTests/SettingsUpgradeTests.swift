// 使用独立的旧版JSON契约验证全部设置在打开、重开和后续保存时保留；只操作临时库，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct SettingsUpgradeTests {
    /// 显式列出持久化字段，避免用当前编码器生成输入而掩盖字段改名或默认值覆盖。
    private func document(enabled: Bool) -> [String: Any] {
        ["appearanceValue": enabled ? "dark" : "light", "compactLayoutValue": enabled,
         "retentionDays": 17, "defaultFormat": "plainText", "pauseUntil": Int64(4_000_000_000_000),
         "pauseWhenExcludedFrontmost": enabled, "panelHeight": 410.0,
         "codeFilePasteEnabled": enabled, "moveUsedToFrontValue": enabled,
         "captureSounds": enabled, "showMenuIcon": enabled, "hideContents": enabled,
         "excludeFromSharing": enabled, "timingEnabled": enabled,
         "quickModifiers": 4096, "boardModifiers": 6144, "quotaBytes": 768 * MiB,
         "defaultAction": "copy", "captureEnabled": enabled,
         "excludedBundleIDs": ["local.fixture.private", "local.fixture.secret"],
         "autoCheckUpdatesValue": enabled,
         "smartPasteEditorBundleIDsValue": ["local.fixture.editor", "local.fixture.editor2"],
         "shortcut": ["keyCode": 8, "modifiers": 6400], "queueShortcutValue": ["keyCode": 11, "modifiers": 6144], "revision": 23,
         "imageTextSearchSince": Int64(1_700_000_000_000)]
    }

    /// 期望通过公开设置接口独立构造；整份快照比较包含可选字段的显式false与缺失差异。
    private func expected(enabled: Bool) -> SettingsSnapshot {
        var value = SettingsSnapshot()
        value.appearance = enabled ? .dark : .light; value.compactLayout = enabled
        value.retentionDays = 17; value.defaultFormat = .plainText; value.pauseUntil = 4_000_000_000_000
        value.pauseWhenExcludedFrontmost = enabled; value.panelHeight = 410
        value.smartCodeFilePaste = enabled; value.moveUsedToFront = enabled
        value.captureSounds = enabled; value.showMenuIcon = enabled; value.hideContents = enabled
        value.excludeFromSharing = enabled; value.timingEnabled = enabled
        value.quickModifiers = 4096; value.boardModifiers = 6144; value.quotaBytes = 768 * MiB
        value.defaultAction = .copy; value.captureEnabled = enabled
        value.excludedBundleIDs = ["local.fixture.private", "local.fixture.secret"]
        value.autoCheckUpdates = enabled
        value.smartPasteEditorBundleIDs = ["local.fixture.editor", "local.fixture.editor2"]
        value.shortcut = .init(keyCode: 8, modifiers: 6400); value.queueShortcut = .init(keyCode: 11, modifiers: 6144); value.revision = 23
        value.imageTextSearchSince = 1_700_000_000_000
        return value
    }

    /// 建立最小合法数据库后注入固定设置文档，只在UUID临时目录操作。
    private func seed(_ root: URL, document: [String: Any]) throws {
        _ = try HistoryStore(location: root)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        defer { try? db.close() }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: document, options: .sortedKeys), as: UTF8.self)
        try db.run("UPDATE settings SET schemaVersion=?,document=?", [.integer(Schema.version), .text(json)])
    }

    /// 应用版本更新而schema不变时，每个布尔设置均验证开与关，防止默认值覆盖。
    @Test(arguments: [true, false])
    func allSettingsSurviveUpdateAndLaterSave(enabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = document(enabled: enabled)
        var saved = expected(enabled: enabled)
        try saved.validate()
        // 新增存储属性时必须同步补充fixture，避免“全部设置”的覆盖范围静默过期。
        #expect(Set(Mirror(reflecting: saved).children.compactMap(\.label)) == Set(original.keys))
        try seed(root, document: original)
        let store = try HistoryStore(location: root, initialSettings: SettingsSnapshot())
        #expect(try await store.settings() == saved)

        // 新版本默认值不应覆盖旧值；普通偏好保存也不能丢掉其它字段。
        let reopened = try HistoryStore(location: root)
        #expect(try await reopened.settings() == saved)
        var edit = try await reopened.settings(); edit.captureSounds.toggle()
        saved.captureSounds.toggle(); saved.revision += 1
        #expect(try await reopened.updateCaptureSettings(edit) == saved)
        #expect(try await HistoryStore(location: root).settings() == saved)
    }

    /// 真实旧文档可缺少后加的可选设置；默认值只补缺失项，不得重置其它用户偏好。
    @Test func missingOptionalLegacyFieldsKeepOtherPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var old = document(enabled: true)
        for key in ["appearanceValue", "compactLayoutValue", "pauseUntil", "codeFilePasteEnabled",
                    "moveUsedToFrontValue", "autoCheckUpdatesValue", "smartPasteEditorBundleIDsValue", "queueShortcutValue", "imageTextSearchSince"] {
            old.removeValue(forKey: key)
        }
        try seed(root, document: old)
        let store = try HistoryStore(location: root)
        var value = try await store.settings()
        #expect(value.appearance == .system && !value.compactLayout && value.pauseUntil == nil && value.imageTextSearchSince == nil)
        #expect(!value.smartCodeFilePaste && value.smartPasteEditorBundleIDs.isEmpty)
        #expect(value.moveUsedToFront && value.autoCheckUpdates)
        // 比对旧文档全部字段，避免只断言新增默认值而漏掉已存在设置被覆盖。
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(encoded.keys) == Set(old.keys))
        for (key, expectedValue) in old {
            if let strings = expectedValue as? [String] {
                #expect(Set(encoded[key] as? [String] ?? []) == Set(strings))
            } else {
                #expect(NSDictionary(dictionary: [key: encoded[key] as Any]).isEqual(to: [key: expectedValue]))
            }
        }
        value.smartCodeFilePaste = true
        let saved = try await store.updateCaptureSettings(value)
        #expect(try await HistoryStore(location: root).settings() == saved)
        #expect(saved.smartCodeFilePaste)
    }
}
