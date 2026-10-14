// 本地富格式与系统文件预览；HTML不执行脚本、不加载资源，by AI.Coding。
import AppKit
import SwiftUI
import Quartz
import ImageIO
import LocalClipCore
public enum RichContent {
    // 固定匹配器只编译一次，HTML循环仍使用完全相同的匹配规则，by AI.Coding。
    private static let tokenPattern = try? NSRegularExpression(pattern: "(?s)<[^>]*>|[^<]+")
    private static let hrefPattern = try? NSRegularExpression(pattern: "(?i)href\\s*=\\s*[\"']([^\"']+)[\"']")
    private static let fontSizePattern = try? NSRegularExpression(pattern: "(?i)font-size\\s*:\\s*([0-9]+)(px|pt)")
    private static let colorPattern = try? NSRegularExpression(pattern: "(?i)(?:color\\s*:\\s*|color=[\"']?)(#[0-9a-f]{6})")
    /// RTF使用原生解码；HTML仅处理本地样式文字，不调用Web或HTML导入器。
    public static func attributed(_ item: PasteboardItemValue) -> NSAttributedString {
        if let rtf = item.representations.first(where: { $0.type == SupportedType.rtf }), let value = NSAttributedString(rtf: rtf.data, documentAttributes: nil) { return value }
        guard let html = item.representations.first(where: { $0.type == SupportedType.html }), let source = String(data: html.data, encoding: .utf8) else { return NSAttributedString(string: item.plainText ?? "") }
        let safe = source.replacingOccurrences(of: "(?is)<(script|style|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        guard let regex = tokenPattern else { return NSAttributedString(string: item.plainText ?? "") }
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
                    if tag == "a", let expression = hrefPattern, let match = expression.firstMatch(in: token, range: NSRange(token.startIndex...,in: token)), let range = Range(match.range(at:1),in: token), let url = URL(string: HTMLText.extract(String(token[range]))), ["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
                    if let expression = fontSizePattern, let match = expression.firstMatch(in: token, range: NSRange(token.startIndex...,in: token)), let range = Range(match.range(at:1),in: token), let size = Double(token[range]), (6...96).contains(size) { attributes[.font] = NSFontManager.shared.convert(attributes[.font] as? NSFont ?? font, toSize: size) }
                    if tag == "code" || tag == "pre" { attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
                    if let expression = colorPattern, let color = expression.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)), let r = Range(color.range(at: 1), in: token) { attributes[.foregroundColor] = colorValue(String(token[r])) }
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
    /// 未声明颜色的文字使用系统文本色，深色外观下不再画成黑字，by AI.Coding。
    func updateNSView(_ view: NSScrollView, context: Context) {
        let text = NSMutableAttributedString(attributedString: content)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        }
        (view.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
    }
}
// QLPreviewView嵌入自有窗口，不接管系统共享Quick Look控制器，by AI.Coding。
@MainActor final class FilePreview: NSObject {
    private var urls: [URL] = []
    private var index = 0
    private var panel: NSPanel?
    private var preview: QLPreviewView?
    private var label: NSTextField?
    /// 仅预览存在的原件，文件引用失效不尝试还原本体。
    func show(_ values: [URL], excludeFromSharing: Bool) {
        urls = values.filter { FileManager.default.fileExists(atPath: $0.path) }; index = 0
        guard !urls.isEmpty else { return }
        if panel == nil {
            let window = PreviewWindow(contentRect: NSRect(x:0,y:0,width:760,height:560), styleMask:[.titled,.closable,.resizable], backing:.buffered,defer:false)
            window.title = "LocalClip 文件预览"; window.isReleasedWhenClosed = false; window.center()
            let view = QLPreviewView(frame:.zero,style:.normal)!
            let previous = NSButton(title:"上一项",target:self,action:#selector(previousItem))
            let next = NSButton(title:"下一项",target:self,action:#selector(nextItem))
            let caption = NSTextField(labelWithString: ""); caption.lineBreakMode = .byTruncatingMiddle
            let controls = NSStackView(views:[previous,caption,next]); controls.orientation = .horizontal; controls.spacing = 12
            let stack = NSStackView(views:[controls,view]); stack.orientation = .vertical; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top:8,left:12,bottom:12,right:12)
            window.contentView = stack; view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-24),view.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
            preview = view; label = caption; panel = window
        }
        panel?.sharingType = excludeFromSharing ? .none : .readOnly
        displayItem(); panel?.makeKeyAndOrderFront(nil)
    }
    func close() { preview?.previewItem = nil; panel?.orderOut(nil); urls.removeAll() }
    private func displayItem() { guard urls.indices.contains(index) else { return }; preview?.previewItem = urls[index] as NSURL; label?.stringValue = "\(index+1)/\(urls.count) · " + urls[index].lastPathComponent }
    @objc private func previousItem() { index = max(0,index-1); displayItem() }
    @objc private func nextItem() { index = min(urls.count-1,index+1); displayItem() }
    private final class PreviewWindow: NSPanel {
        override func cancelOperation(_ sender: Any?) { orderOut(sender) }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 || event.keyCode == 49 { orderOut(nil) } else { super.keyDown(with:event) } }
    }
}
