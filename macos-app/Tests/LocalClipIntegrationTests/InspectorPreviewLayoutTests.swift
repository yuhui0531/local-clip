// LC-F01：短文紧凑、长文有界测量，验证使用完整内容且重复求值不随全文尺寸增长，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipMac

@MainActor struct InspectorPreviewLayoutTests {
    /// 长段、换行与Unicode均保留原文，常见短文仍使用紧凑高度。
    @Test func shortContentKeepsCompactLayout() {
        for text in ["", "hello", "第一行\nsecond line", "👩🏽‍💻 café"] {
            let content = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
            #expect((52..<200).contains(InspectorPreviewLayout.height(for: content)))
            #expect(content.string == text)
        }
        let wrapped = NSAttributedString(string: String(repeating: "wide ", count: 300), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        #expect((150...200).contains(InspectorPreviewLayout.height(for: wrapped)))
    }

    /// 100KiB/300KiB/1MiB原文仍可传给预览，重复高度计算只走长度检查，by AI.Coding。
    @Test(arguments: [100 * 1024, 300 * 1024, 1024 * 1024])
    func longContentUsesBoundedViewport(size: Int) {
        let text = String(repeating: "x", count: size) + "\nEND-OF-CONTENT"
        let content = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let begin = ContinuousClock.now
        for _ in 0..<1_000 { #expect(InspectorPreviewLayout.height(for: content) == 200) }
        #expect(begin.duration(to: .now) < .seconds(1))
        // 不裁剪传给SyntaxDetailPreview的内容，末尾标记仍可用于滚动/选择/复制。
        #expect(SyntaxDetailPreview(content: content).content.string == text)
    }
}
