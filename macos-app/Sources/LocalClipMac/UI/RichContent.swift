// 本地富格式与系统文件预览；HTML不执行脚本、不加载资源，by AI.Coding。
import AppKit
import SwiftUI
import Quartz
import ImageIO
import LocalClipCore
public enum RichContent {
    /// RTF使用原生解码；HTML仅处理本地样式文字，不调用Web或HTML导入器。
    public static func attributed(_ item: PasteboardItemValue) -> NSAttributedString {
        if let rtf = item.representations.first(where: { $0.type == SupportedType.rtf }), let value = NSAttributedString(rtf: rtf.data, documentAttributes: nil) { return value }
        guard let html = item.representations.first(where: { $0.type == SupportedType.html }), let source = String(data: html.data, encoding: .utf8) else { return NSAttributedString(string: item.plainText ?? "") }
        let safe = source.replacingOccurrences(of: "(?is)<(script|style|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: "(?s)<[^>]*>|[^<]+") else { return NSAttributedString(string: item.plainText ?? "") }
        let result = NSMutableAttributedString(string: "")
        var stack: [(String, [NSAttributedString.Key: Any])] = []
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        for match in regex.matches(in: safe, range: NSRange(safe.startIndex..., in: safe)) {
            guard let range = Range(match.range, in: safe) else { continue }
            let token = String(safe[range])
            if token.hasPrefix("<") {
                let tag = token.lowercased().replacingOccurrences(of: "[<>/]", with: "", options: .regularExpression).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                if ["br", "p", "div", "li"].contains(tag), result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
                if token.hasPrefix("</") {
                    if let index = stack.lastIndex(where: { $0.0 == tag }) { attributes = stack[index].1; stack.removeSubrange(index...) }
                } else {
                    stack.append((tag, attributes))
                    var traits: NSFontTraitMask = []
                    if ["b", "strong"].contains(tag) || token.contains("font-weight: bold") || token.contains("font-weight: 700") { traits.insert(.boldFontMask) }
                    if ["i", "em"].contains(tag) || token.contains("font-style: italic") { traits.insert(.italicFontMask) }
                    if tag == "u" { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
                    if !traits.isEmpty { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits) }
                    if tag == "code" || tag == "pre" { attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
                    if let expression = try? NSRegularExpression(pattern: "(?i)(?:color\\s*:\\s*|color=[\"']?)(#[0-9a-f]{6})"), let color = expression.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)), let r = Range(color.range(at: 1), in: token) { attributes[.foregroundColor] = colorValue(String(token[r])) }
                }
            } else {
                let text = BasicTextDecoder.extract(.init(SupportedType.html, Data(token.utf8))) ?? token
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        return result
    }
    /// 颜色字段仅接受本地RGB，不解析URL或可执行样式。
    public static func colorValue(_ hex: String) -> NSColor {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x34C759
        return NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
    }
    /// 原图按需解码，超过像素上限不分配巨大位图。
    public static func fullImage(_ payload: ClipboardPayload) -> Data? {
        guard let data = payload.items.flatMap(\.representations).first(where: { [SupportedType.png, SupportedType.tiff, SupportedType.jpeg].contains($0.type) })?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, Int64(width)*Int64(height) <= 40_000_000 else { return nil }
        return data
    }
}
struct RichTextPreview: NSViewRepresentable {
    let content: NSAttributedString
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.drawsBackground = false; text.isRichText = true
        text.textContainerInset = NSSize(width: 8, height: 8); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { (view.documentView as? NSTextView)?.textStorage?.setAttributedString(content) }
}
@MainActor final class FilePreview: NSObject, QLPreviewPanelDataSource {
    private var urls: [URL] = []
    /// 仅预览存在的原件，引用失效时不尝试恢复文件本体。
    func show(_ values: [URL]) {
        urls = values.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }
}
