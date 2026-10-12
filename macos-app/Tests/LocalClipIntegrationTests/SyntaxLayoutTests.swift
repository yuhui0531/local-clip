// 原生代码预览保留正文、空行和换行缩进，不接管卡片拖动，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipMac

@MainActor struct SyntaxLayoutTests {
    private func content(_ text: String, spacing: CGFloat = 3, dark: Bool = false, size: CGFloat = 10) -> NSAttributedString {
        let highlight = SyntaxHighlight(language: "swift", spans: [], analyzedUTF16Count: text.utf16.count)
        return SyntaxLineCache.content(text, highlight: highlight, size: size, dark: dark, spacing: spacing)
    }
    @Test func sourceTerminatorsAndSpacingSurviveNativeDrawing() throws {
        let text = "    abcdefghijklmnopqrstuvwxyz\r\n\r\n\tsecond line\n\n"
        let normal = content(text), tiny = content(text, spacing: 0)
        #expect(normal.string == text)
        #expect(tiny.string == text)
        for index in 0..<normal.length {
            let font = try #require(normal.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            let paragraph = try #require(normal.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            #expect(font.pointSize == 10)
            #expect(paragraph.lineBreakMode == .byCharWrapping)
            #expect(paragraph.lineSpacing == 3)
            #expect(paragraph.paragraphSpacing == 0)
            let compact = try #require(tiny.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            #expect(compact.lineSpacing == 0 && compact.paragraphSpacing == 0)
        }
        let indent = try #require(normal.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(indent.firstLineHeadIndent == 0)
        #expect(indent.headIndent == (" " as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]).width * 4)
        #expect(content(text) === normal)
        #expect(content(text, dark: true) !== normal)
        #expect((content(text, size: 13).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 13)
    }
    @Test func narrowCodeWrapsAtTwentyColumnsAndLeavesDragHitTesting() throws {
        let text = "abcdefghijklmnopqrstuvwxy\n    ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let storage = NSTextStorage(attributedString: content(text, spacing: 0, size: 9.5))
        let layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 123, height: 1000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container); layout.ensureLayout(for: container)
        var first = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &first)
        #expect(first.length >= 20)
        let sourceStart = (text as NSString).range(of: "    ABC").location
        let firstIndentedGlyph = layout.glyphIndexForCharacter(at: sourceStart)
        var initial = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: firstIndentedGlyph, effectiveRange: &initial)
        let continuation = layout.location(forGlyphAt: NSMaxRange(initial))
        let firstContent = layout.location(forGlyphAt: firstIndentedGlyph + 4)
        #expect(abs(continuation.x - firstContent.x) < 0.1)
        // 前导制表符和空格/制表符混用必须按同一停止位置换行，by AI.Coding。
        for prefix in ["\t", "  \t", "\t  ", " \t\t"] {
            let value = NSTextStorage(attributedString: content(prefix + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", spacing: 0, size: 9.5))
            let manager = NSLayoutManager(), box = NSTextContainer(size: NSSize(width: 123, height: 1000))
            box.lineFragmentPadding = 0; value.addLayoutManager(manager); manager.addTextContainer(box)
            manager.ensureLayout(for: box)
            var range = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &range)
            let leading = manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: prefix.utf16.count))
            let wrapped = manager.location(forGlyphAt: NSMaxRange(range))
            #expect(abs(leading.x - wrapped.x) < 0.1)
        }
        func gap(_ text: String) -> CGFloat {
            let value = NSTextStorage(attributedString: content(text))
            let manager = NSLayoutManager(), box = NSTextContainer(size: NSSize(width: 123, height: 1000))
            box.lineFragmentPadding = 0; value.addLayoutManager(manager); manager.addTextContainer(box)
            manager.ensureLayout(for: box)
            var range = NSRange()
            let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &range)
            let next = manager.lineFragmentRect(forGlyphAt: NSMaxRange(range), effectiveRange: nil)
            return next.minY - first.minY
        }
        #expect(abs(gap("abc\nabc") - gap("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")) < 0.1)
        let preview = SyntaxCardPreview.Preview(frame: NSRect(x: 0, y: 0, width: 123, height: 80))
        preview.content = storage
        #expect(preview.hitTest(NSPoint(x: 20, y: 20)) == nil)
    }
}
