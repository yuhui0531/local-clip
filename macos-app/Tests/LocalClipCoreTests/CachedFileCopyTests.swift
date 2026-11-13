// 使用隔离临时文件和真实历史库验证缓存文件副本，不访问桌面或系统剪贴板，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct CachedFileCopyTests {
    /// 复刻旧库、同路径再复制、缓存清理和重启，覆盖原样复制、拖出、另存与删除撤销。
    @Test func cachedFileSurvivesSourceRemoval() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("Store")
        _ = try HistoryStore(location: storeRoot)
        let database = storeRoot.appendingPathComponent("History/history.sqlite")
        let db = try SQLiteConnection(database)
        try db.exec("DROP TABLE file_copies")
        try db.close()

        let clock = TestClock()
        let store = try HistoryStore(location: storeRoot, clock: clock)
        let source = root.appendingPathComponent("mac_cache 图片.png")
        let latest = Data([0x00, 0xff, 0x7f, 0x80])
        let payload = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(source.absoluteString.utf8))])])
        try Data([1]).write(to: source)
        let id = insertedID(try await store.ingest(.init(payload: payload), at: clock.now()))
        try #require(!id.isEmpty)
        #expect(try await store.loadPayload(id: id, at: clock.now()).fileURLs == [source])
        try latest.write(to: source)
        clock.advance(1)
        #expect(try await store.ingest(.init(payload: payload), at: clock.now()) == .deduplicated(id))
        try fm.removeItem(at: source)

        let reopened = try HistoryStore(location: storeRoot, clock: clock)
        let detail = try await reopened.detail(id: id, at: clock.now())
        #expect(detail.payload.fileURLs == [source])
        #expect(detail.savedFileCopyIndexes == [0])
        let dragFiles = storeRoot.appendingPathComponent("DragFiles")
        #expect(!fm.fileExists(atPath: dragFiles.path))
        let restoredPayload = try await reopened.loadPayload(id: id, at: clock.now())
        let restored = try #require(restoredPayload.fileURLs?.first)
        #expect(restored.path.hasPrefix(dragFiles.path + "/"))
        #expect(restored.lastPathComponent == source.lastPathComponent)
        #expect(try Data(contentsOf: restored) == latest)
        let access = try await reopened.exportAccess(id: id)
        #expect(try access.savedFileName(index: 0) == source.lastPathComponent)
        #expect(try access.savedFileData(index: 0) == latest)
        // 清理输出目录后，拖放仍可从历史重新生成完整文件。
        try await reopened.clearDragFiles()
        let dragData = try access.itemData(index: 0, type: SupportedType.fileURL)
        let dragged = try #require(PasteboardItemValue([.init(SupportedType.fileURL, dragData)]).fileURL)
        #expect(try Data(contentsOf: dragged) == latest)
        let deletion = try await reopened.preview(.delete([id]))
        _ = try await reopened.apply(deletion.token)
        let check = try SQLiteConnection(database, readonly: true)
        #expect(try check.scalarInt("SELECT COUNT(*) FROM file_copies") == 0)
        try check.close()
        try await reopened.undoDelete()
        #expect(try await reopened.exportAccess(id: id).savedFileData(index: 0) == latest)
    }
}
