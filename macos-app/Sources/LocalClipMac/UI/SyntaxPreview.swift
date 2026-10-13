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
    var spacing: CGFloat = 3
    var onLanguage: (String?) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var highlighted: SyntaxHighlight?
    @State private var source = ""
    /// 高亮器是actor，缓存命中也要异步；主线程留一份结果，重新出现的卡片首帧即是高亮正文，by AI.Coding。
    @MainActor private static var recent: [String: SyntaxHighlight] = [:]
    var body: some View {
        Group {
            if let ready = source == text ? highlighted : Self.recent[text] {
                // 窄卡片按词软换行，并以源行缩进作为续行悬挂缩进，by AI.Coding。
                SyntaxCardPreview(content: SyntaxLineCache.content(text, highlight: ready, size: size, dark: scheme == .dark, spacing: spacing))
            }
            else { Text(text).font(.system(size: size)) }
        }.task(id: text) {
            if let cached = Self.recent[text] { highlighted = cached; source = text; onLanguage(cached.language); return }
            highlighted = nil; source = text; onLanguage(nil)
            let result = await SyntaxHighlighter.shared.highlight(text)
            guard !Task.isCancelled else { return }
            highlighted = result; onLanguage(result?.language)
            // ponytail: 满128条整体清空，需要更细的淘汰时换LRU。
            if let result { if Self.recent.count >= 128 { Self.recent.removeAll() }; Self.recent[text] = result }
        }
    }
}

/// 同一正文、语法范围、配色和字号复用一次构造的行切片，避免逐行重建全文，by AI.Coding。
@MainActor enum SyntaxLineCache {
    private final class Lines: NSObject {
        let content: NSAttributedString
        init(_ content: NSAttributedString) { self.content = content }
    }
    private static let cache: NSCache<NSString, Lines> = {
        let value = NSCache<NSString, Lines>()
        value.countLimit = 64
        value.totalCostLimit = 12 * 1024 * 1024
        return value
    }()

    static func content(_ text: String, highlight: SyntaxHighlight, size: CGFloat, dark: Bool, spacing: CGFloat) -> NSAttributedString {
        let spanKey = highlight.spans.map { "\($0.range.location):\($0.range.length):\($0.style)" }.joined(separator: ";")
        let key = NSString(string: "\(text)\u{1f}\(highlight.language)\u{1f}\(spanKey)\u{1f}\(dark)\u{1f}\(size.bitPattern)\u{1f}\(spacing.bitPattern)")
        if let cached = cache.object(forKey: key) { return cached.content }

        let source = SyntaxStyle.attributed(text, highlight: highlight, size: size, dark: dark)
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let tabWidth = spaceWidth * 4
        let string = text as NSString
        let output = NSMutableAttributedString(string: "")
        var offset = 0
        while offset < string.length {
            var start = 0, end = 0, contentsEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: offset, length: 0))
            let range = NSRange(location: start, length: end - start)
            let line = string.substring(with: NSRange(location: start, length: contentsEnd - start))
            let attributed = NSMutableAttributedString(attributedString: source.attributedSubstring(from: range))
            if attributed.length > 0 {
                let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(CGFloat.zero) {
                    $1 == "\t" ? (floor($0 / tabWidth) + 1) * tabWidth : $0 + spaceWidth
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = []
                paragraph.defaultTabInterval = tabWidth
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = indent
                // 按词折行，标识符不从中间断开；超宽单词仍由排版器强制断开，by AI.Coding。
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.lineSpacing = spacing
                paragraph.paragraphSpacing = 0
                attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
            }
            output.append(attributed)
            guard end > offset else { break }
            offset = end
        }
        cache.setObject(Lines(output), forKey: key, cost: max(1, text.utf16.count * 2))
        return output
    }
}
/// AppKit绘制保留段落缩进与字符换行；透明命中仍交给卡片拖动桥，by AI.Coding。
struct SyntaxCardPreview: NSViewRepresentable {
    let content: NSAttributedString
    func makeNSView(context: Context) -> Preview { Preview() }
    func updateNSView(_ view: Preview, context: Context) {
        if !view.content.isEqual(to: content) { view.content = content; view.needsDisplay = true }
    }
    final class Preview: NSView {
        var content = NSAttributedString(string: "")
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            content.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
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
            let result = await SyntaxHighlighter.detail.highlight(content.string)
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }
}
