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
    var onLanguage: (String?) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var highlighted: SyntaxHighlight?
    @State private var source = ""
    var body: some View {
        Group {
            if source == text, let highlighted {
                // 窄卡片按字符软换行，并以源行缩进作为续行悬挂缩进，by AI.Coding。
                let lines: [AttributedString] = SyntaxLineCache.lines(text, highlight: highlighted, size: size, dark: scheme == .dark)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(0..<lines.count), id: \.self) { (index: Int) in
                        Text(lines[index]).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            else { Text(text).font(.system(size: size)) }
        }.task(id: text) {
            highlighted = nil; source = text; onLanguage(nil)
            let result = await SyntaxHighlighter.shared.highlight(text)
            guard !Task.isCancelled else { return }
            highlighted = result; onLanguage(result?.language)
        }
    }
}

/// 同一正文、语法范围、配色和字号复用一次构造的行切片，避免逐行重建全文，by AI.Coding。
@MainActor private enum SyntaxLineCache {
    private final class Lines: NSObject {
        let values: [AttributedString]
        init(_ values: [AttributedString]) { self.values = values }
    }
    private static let cache: NSCache<NSString, Lines> = {
        let value = NSCache<NSString, Lines>()
        value.countLimit = 64
        value.totalCostLimit = 12 * 1024 * 1024
        return value
    }()

    static func lines(_ text: String, highlight: SyntaxHighlight, size: CGFloat, dark: Bool) -> [AttributedString] {
        let spanKey = highlight.spans.map { "\($0.range.location):\($0.range.length):\($0.style)" }.joined(separator: ";")
        let key = NSString(string: "\(text)\u{1f}\(highlight.language)\u{1f}\(spanKey)\u{1f}\(dark)\u{1f}\(size.bitPattern)")
        if let cached = cache.object(forKey: key) { return cached.values }

        let source = SyntaxStyle.attributed(text, highlight: highlight, size: size, dark: dark)
        let string = text as NSString
        var output: [AttributedString] = []
        var offset = 0
        while offset < string.length {
            var start = 0, end = 0, contentsEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: offset, length: 0))
            let range = NSRange(location: start, length: contentsEnd - start)
            let line = string.substring(with: range)
            let attributed = NSMutableAttributedString(attributedString: source.attributedSubstring(from: range))
            if attributed.length > 0 {
                let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(CGFloat.zero) {
                    $0 + ($1 == "\t" ? size * 2.4 : size * 0.6)
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = indent
                paragraph.lineBreakMode = .byCharWrapping
                attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
            }
            output.append(AttributedString(attributed))
            guard end > offset else { break }
            offset = end
        }
        if text.isEmpty || text.hasSuffix("\n") { output.append(AttributedString("")) }
        cache.setObject(Lines(output), forKey: key, cost: max(1, text.utf16.count * 2))
        return output
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
            let result = await SyntaxHighlighter.detail.highlight(content.string)
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }
}
