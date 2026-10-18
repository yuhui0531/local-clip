// 已核验 comments 的数据保护与派生内容边界；仅临时库与文件，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct CommentFixesTests {
    /// 收藏/分类操作只能删除已预览的目标，不能顺带清理其他过期记录。
    @Test(arguments: ["favorites", "category", "deleteCategory"])
    func scopedChangesKeepUnrelatedExpiredRows(_ action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let unrelated = insertedID(try await store.ingest(fixture("unrelated"), at: clock.now()))
        let target = insertedID(try await store.ingest(fixture("target"), at: clock.now()))
        let category = try await store.createCategory(name: "keep", colorHex: "34C759")
        _ = try await store.apply(store.preview(.favorite(target, true)).token)
        _ = try await store.apply(store.preview(.category([target], category.id, true)).token)
        clock.advance(31 * dayMS)
        let change: HistoryChange = action == "favorites" ? .favorites([target], true) : action == "category" ? .category([target], category.id, false) : .deleteCategory(category.id)
        let preview = try await store.preview(change)
        #expect(preview.affectedCount == 0)
        #expect(try await store.apply(preview.token).removed == 0)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=?", [.text(unrelated)]) == 1)
        try db.close()
    }

    /// 预览后仅时钟跨越到期边界，也必须重新确认，拒绝时不能部分更新。
    @Test(arguments: ["favorite", "favorites", "category", "deleteCategory", "retention"])
    func timeDriftRequiresNewPreview(_ action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let id = insertedID(try await store.ingest(fixture("protected"), at: clock.now()))
        let category = try await store.createCategory(name: "protect", colorHex: "34C759")
        if action == "favorite" || action == "favorites" { _ = try await store.apply(store.preview(.favorite(id, true)).token) }
        if action == "category" || action == "deleteCategory" { _ = try await store.apply(store.preview(.category([id], category.id, true)).token) }
        clock.advance(30 * dayMS - 1)
        let change: HistoryChange
        switch action {
        case "favorite": change = .favorite(id, false)
        case "favorites": change = .favorites([id], false)
        case "category": change = .category([id], category.id, false)
        case "deleteCategory": change = .deleteCategory(category.id)
        default: change = .retention(30)
        }
        let preview = try await store.preview(change)
        #expect(preview.affectedCount == 0)
        clock.advance(1)
        await #expect(throws: StoreError.stalePreview) { try await store.apply(preview.token) }
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=?", [.text(id)]) == 1)
        try db.close()
    }

    /// 撤销旧记录必须让缺失全文索引重新修复，不能延续空库的完整缓存。
    @Test func undoRechecksMissingTextIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), store = try HistoryStore(location: root, clock: clock)
        let id = insertedID(try await store.ingest(fixture(String(repeating: "prefix ", count: 100) + "UNIQUE-TAIL"), at: clock.now()))
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.exec("DELETE FROM text_content"); try db.close()
        _ = try await store.apply(store.preview(.delete([id])).token)
        #expect(try await store.search(.init("UNIQUE-TAIL")).items.isEmpty)
        try await store.undoDelete()
        #expect(try await store.search(.init("UNIQUE-TAIL")).items.map(\.id) == [id])
    }

    /// 实体只解释原输入的一层，不重复展开；兼容十六进制大小写。
    @Test func htmlEntitiesDecodeOnce() {
        #expect(HTMLText.extract("&#38;amp; &amp;lt; &#X4E2D; &#x1F600; &#1114112;") == "&amp; &lt; 中 😀 &#1114112;")
        #expect(HTMLText.extract("<script>secret</script><p>&lt;x&gt;&nbsp;&quot;&apos;</p>") == "<x> \"'\n")
    }

    /// 偶数个反斜杠为字面文字，奇数个仍包含真实附件控制字。
    @Test(arguments: [1, 2, 3, 4])
    func rtfAttachmentEscapes(_ slashes: Int) {
        let rtf = "{\\rtf1 " + String(repeating: "\\", count: slashes) + "pict word}"
        let payload = ClipboardPayload([.init([.init(SupportedType.rtf, Data(rtf.utf8)), .init(SupportedType.string, Data("word".utf8))], plainText: "word")])
        #expect((payload.editableText != nil) == slashes.isMultiple(of: 2))
    }

    /// 显示标签必须与最后生效单值一致，未知前缀规则保持不变。
    @Test func repeatedFiltersShowEffectiveValue() {
        let parsed = SearchQueryParser.parse("type:text type:image after:7d after:3d before:1d before:2d", sources: [], categories: [], now: 100 * dayMS)
        #expect(parsed.kind == .image && parsed.labels == ["类型 图片", "最近 3 天", "2 天前"])
    }

    /// 外部修改过的拖出副本必须保留；新的索取仍取得历史原始字节。
    @Test func changedDragFileUsesNewPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("original".utf8)
        let first = try DragFileStorage.write(data, root: root, fileName: "image.png")
        #expect(try DragFileStorage.write(data, root: root, fileName: "image.png").url == first.url)
        try Data("external edit".utf8).write(to: first.url)
        let next = try DragFileStorage.write(data, root: root, fileName: "image.png")
        #expect(next.url != first.url && next.created)
        #expect(try Data(contentsOf: next.url) == data)
        #expect(try String(contentsOf: first.url, encoding: .utf8) == "external edit")
        try DragFileStorage.remove([next.url], root: root)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
    }
    /// 超过转换上限仍保留详情识别和统计，仅移除必然失败的动作。
    @Test func oversizedInspectionKeepsDetailsWithoutActions() throws {
        let value = "{\"data\":\"" + String(repeating: "a", count: TextTransform.byteLimit) + "\"}"
        let inspection = try #require(ContentInspector.inspectFull(value, language: "json"))
        #expect(!inspection.rows.isEmpty && inspection.actions.isEmpty)
        #expect(ContentInspector.inspectFull("{\"data\":1}", language: "json")?.actions.isEmpty == false)
    }

}
