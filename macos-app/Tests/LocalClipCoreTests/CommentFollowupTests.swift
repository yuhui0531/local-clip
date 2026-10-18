// 剩余搜索优化保持逐字输出与原始载荷，仅操作临时库，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct CommentFollowupTests {
    /// 与旧字素算法对照，覆盖组合字符、emoji、NUL及长文尾部。
    @Test func contextRetainsExactWindow() {
        for original in ["e\u{301} 😀\0 " + String(repeating: "a", count: 200) + " Needle end", String(repeating: "中文", count: 100) + "Needle", "Needle"] {
            let normalized = SearchNormalizer.normalize(original), literal = "needle"
            let range = normalized.range(of: literal, options: .literal)!
            let position = normalized[..<range.lowerBound].count, length = normalized[range].count
            let start = original.index(original.startIndex, offsetBy: max(0, position - 35), limitedBy: original.endIndex) ?? original.endIndex
            let end = original.index(original.startIndex, offsetBy: position + length + 79, limitedBy: original.endIndex) ?? original.endIndex
            let expected = (start > original.startIndex ? "…" : "") + String(original[start..<end]) + (end < original.endIndex ? "…" : "")
            #expect(SearchNormalizer.context(original, normalized: normalized, literal: literal) == expected)
        }
    }
    /// 解码失败不丢字节，也无需每次补建；纯图片不写伪文本索引。
    @Test func undecodableTextIsIndexedWithoutChangingPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        for type in [SupportedType.string, SupportedType.rtf, SupportedType.png] {
            let bytes = Data([0xFF, 0xFE, 0x01])
            let id = insertedID(try await store.ingest(.init(payload: .init([.init([.init(type, bytes)])])), at: now))
            let detail = try await store.detail(id: id, at: now)
            #expect(detail.payload.items.first?.representations.first?.data == bytes)
            let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
            #expect(try db.scalarInt("SELECT COUNT(*) FROM text_content WHERE clipID=?", [.text(id)]) == (type == SupportedType.png ? 0 : 1))
            try db.close()
        }
        #expect(try await store.rebuildSearchIndex() == 0)
    }
    /// 大正文尾部摘要使用索引而不改变原文窗口；无文本的旧预览仍可显示。
    @Test func longContextAndEmptyFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let text = String(repeating: "A", count: Int(MiB) + 20) + " e\u{301}😀 Needle-END"
        let id = insertedID(try await store.ingest(fixture(text), at: now))
        #expect(try await store.search(.init("needle-end")).items.first?.context == SearchNormalizer.context(text, literal: "needle-end"))
        #expect(try await store.detail(id: id, at: now).payload.plainText == text)
        // 多项混合保留 compactMap 的既有拼接，不将无效 RTF 的占位换行映射到正文偏移。
        let mixed = ClipboardPayload([.init([.init(SupportedType.rtf, Data([0xFF]))]), .init([.init(SupportedType.string, Data((text + " mixed-tail").utf8))]), .init([.init(SupportedType.png, Data([3]))])])
        let mixedID = insertedID(try await store.ingest(.init(payload: mixed), at: now))
        let found = try await store.search(.init("mixed-tail"))
        #expect(found.items.first?.id == mixedID && found.items.first?.context == SearchNormalizer.context(text + " mixed-tail", literal: "mixed-tail"))
        let imageID = insertedID(try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data([1, 2]))])])), at: now))
        try await store.renameClip(id: imageID, title: "legacy-title")
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.run("UPDATE clips SET previewText=? WHERE id=?", [.text("legacy preview"), .text(imageID)]); try db.close()
        #expect(try await store.search(.init("legacy-title")).items.first?.context == "legacy preview")
    }
}
