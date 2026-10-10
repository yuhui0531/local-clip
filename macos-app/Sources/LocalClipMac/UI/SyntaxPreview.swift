// 卡片和详情共用离线语法范围；高亮始终开启，没有设置开关参数，by AI.Coding。
import AppKit
import SwiftUI

@MainActor enum SyntaxStyle {
    static func attributed(_ text: String, highlight: SyntaxHighlight, size: CGFloat, dark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.labelColor])
        for span in highlight.spans where NSMaxRange(span.range) <= result.length {
            let color: NSColor
            switch span.style {
            case let s where s.contains("comment"): color = dark ? .systemGray : NSColor(srgbRed: 0.39, green: 0.45, blue: 0.50, alpha: 1)
            case let s where s.contains("string") || s.contains("regexp"): color = dark ? .systemGreen : NSColor(srgbRed: 0.10, green: 0.43, blue: 0.28, alpha: 1)
            case let s where s.contains("number") || s.contains("literal"): color = dark ? .systemOrange : NSColor(srgbRed: 0.69, green: 0.35, blue: 0.07, alpha: 1)
            case let s where s.contains("keyword") || s.contains("built_in") || s.contains("type"): color = dark ? .systemPink : .systemPurple
            case let s where s.contains("attr") || s.contains("title") || s.contains("name"): color = .systemBlue
            default: color = .labelColor
            }
            result.addAttribute(.foregroundColor, value: color, range: span.range)
        }
        return result
    }
}
struct SyntaxText: View {
    let text: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @State private var highlighted: SyntaxHighlight?
    @State private var source = ""
    var body: some View {
        Group {
            if source == text, let highlighted { Text(AttributedString(SyntaxStyle.attributed(text, highlight: highlighted, size: size, dark: scheme == .dark))) }
            else { Text(text).font(.system(size: size)) }
        }.task(id: text) {
            highlighted = nil; source = text
            let result = await SyntaxHighlighter.shared.highlight(text)
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }
}
struct SyntaxDetailPreview: View {
    let content: NSAttributedString
    @Environment(\.colorScheme) private var scheme
    @State private var highlighted: SyntaxHighlight?
    @State private var source = ""
    var body: some View {
        RichTextPreview(content: source == content.string && highlighted != nil
            ? SyntaxStyle.attributed(content.string, highlight: highlighted!, size: 13, dark: scheme == .dark)
            : content)
        .task(id: content.string) {
            highlighted = nil; source = content.string
            let result = await SyntaxHighlighter.shared.highlight(content.string)
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }
}
