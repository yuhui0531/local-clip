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
    /// 原图按需解码，超过像素上限不分配巨大位图；与缩略图一致按顺序尝试，某一格式损坏不遮蔽其它有效格式，by AI.Coding。
    public static func fullImage(_ payload: ClipboardPayload) -> Data? {
        payload.items.flatMap(\.representations).lazy.filter { [SupportedType.png, SupportedType.tiff, SupportedType.jpeg].contains($0.type) }.map(\.data).first { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
            return width > 0 && height > 0 && Int64(width) * Int64(height) <= 40_000_000
        }
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
    final class Coordinator { var content: NSAttributedString? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    /// 未声明颜色的文字使用系统文本色，深色外观下不再画成黑字；内容未变不重设，避免父视图刷新时重绘闪烁并丢失选区，by AI.Coding。
    func updateNSView(_ view: NSScrollView, context: Context) {
        if let last = context.coordinator.content, last.isEqual(to: content) { return }
        context.coordinator.content = content
        let text = NSMutableAttributedString(attributedString: content)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        }
        (view.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
    }
}
/// 文件预览方式按内容而非仅凭扩展名决定：可读文本直接显示正文并高亮，其余交给系统Quick Look；失败给出原因，by AI.Coding。
enum FilePreviewContent: Equatable, Sendable {
    case text(String, language: String?, truncated: Bool)
    case quickLook
    case failure(String)

    static let textLimit = 2 * 1024 * 1024

    /// 必须在后台调用；只读原件开头，不改变引用。
    static func classify(_ url: URL) -> Self {
        guard url.isFileURL else { return .failure("不是本地文件引用，无法预览") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            return .failure("原文件不存在：已被移动、重命名或删除。历史中只保存了文件引用，请重新复制原文件。")
        }
        if directory.boolValue { return .quickLook }
        // 其他应用的数据目录、受保护文件夹会被系统拒绝读取；提示原因而不是显示空白或只显示文件信息。
        guard FileManager.default.isReadableFile(atPath: url.path), let handle = try? FileHandle(forReadingFrom: url), (try? handle.close()) != nil else {
            return .failure("没有读取权限：macOS 阻止 LocalClip 读取此位置（例如其他应用的数据目录）。可在“系统设置 › 隐私与安全性”中授权后重试。")
        }
        // PDF按内容识别（含全ASCII的PDF），SVG显示图形；与卡片预览规则一致，不把它们当源码显示。
        if url.pathExtension.lowercased() == "svg" || CGPDFDocument(url as CFURL) != nil { return .quickLook }
        guard TextFilePreview.isCandidate(url.path), let text = TextFilePreview.read(url, limit: textLimit) else { return .quickLook }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return .text(text, language: SyntaxHighlighter.language(forFile: url), truncated: size > textLimit)
    }
}

// 空格与“预览”菜单共用的类Quick Look窗口：作为历史面板的子窗口，打开时不抢key，面板不会因失焦被收起，by AI.Coding。
@MainActor final class QuickPreview: NSObject, NSWindowDelegate {
    enum Item { case file(URL), image(NSImage, bytes: Int) }
    /// 正文与编辑器共用的着色范围上限；超出部分保持纯文字，长文件滚动与选择不受影响。
    static let highlightLimit = 200_000
    private var items: [Item] = []
    private var index = 0
    private var window: PreviewWindow?
    private var loading: Task<Void, Never>?
    private let caption = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "上一项", target: nil, action: nil)
    private let next = NSButton(title: "下一项", target: nil, action: nil)
    private let body = NSView()
    private lazy var quickLook: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)!
    private var imageView: ImageScrollView?
    private var appearance: NSKeyValueObservation?
    var isVisible: Bool { window?.isVisible == true }
    /// 打开期间切换“共享时隐藏”也立即生效，不等下次打开。
    func setSharing(excluded: Bool) { window?.sharingType = excluded ? .none : .readOnly }

    func show(_ values: [Item], parent: NSWindow?, excludeFromSharing: Bool) {
        guard !values.isEmpty else { return }
        let reopening = !isVisible
        items = values; index = 0
        let window = self.window ?? makeWindow()
        window.sharingType = excludeFromSharing ? .none : .readOnly
        if let parent, window.parent !== parent {
            window.parent?.removeChildWindow(window)
            window.level = parent.level; window.collectionBehavior = parent.collectionBehavior
            parent.addChildWindow(window, ordered: .above)
        }
        displayItem()
        if reopening { place(window, parent: parent) }
        window.orderFront(nil)
    }
    /// 关闭后若预览曾是key窗口，把键盘交还历史面板，避免焦点落空触发面板收起。
    func close() {
        loading?.cancel(); loading = nil; appearance = nil
        guard let window else { return }
        let parent = window.parent, wasKey = window.isKeyWindow
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        quickLook.previewItem = nil; imageView?.image = nil; items.removeAll()
        if wasKey, let parent, parent.isVisible { parent.makeKey() }
    }
    private func makeWindow() -> PreviewWindow {
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "LocalClip 预览"; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true; window.minSize = NSSize(width: 360, height: 260)
        window.onDismiss = { [weak self] in self?.close() }
        caption.lineBreakMode = .byTruncatingMiddle; caption.font = .systemFont(ofSize: 13, weight: .medium)
        info.lineBreakMode = .byTruncatingMiddle; info.font = .systemFont(ofSize: 11); info.textColor = .secondaryLabelColor
        for label in [caption, info] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        previous.target = self; previous.action = #selector(previousItem); next.target = self; next.action = #selector(nextItem)
        let titles = NSStackView(views: [caption, info]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        let controls = NSStackView(views: [previous, titles, next]); controls.orientation = .horizontal; controls.spacing = 12
        let stack = NSStackView(views: [controls, body]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24), controls.widthAnchor.constraint(equalTo: body.widthAnchor)])
        self.window = window; return window
    }
    /// 放在面板上方的可见区域；空间不足时整屏居中，图片按原始比例取合适大小。
    private func place(_ window: NSWindow, parent: NSWindow?) {
        guard let screen = parent?.screen ?? NSScreen.main else { window.center(); return }
        var area = screen.visibleFrame
        if let parent, parent.isVisible, area.maxY - parent.frame.maxY - 16 >= 300 { area.origin.y = parent.frame.maxY + 8; area.size.height = screen.visibleFrame.maxY - area.minY }
        var size = NSSize(width: 760, height: 560)
        if case .image(let image, _)? = items.first {
            size = NSSize(width: max(360, image.size.width + 24), height: max(260, image.size.height + 70))
        }
        size.width = min(size.width, area.width - 40); size.height = min(size.height, area.height - 20)
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }
    private func setBody(_ view: NSView) {
        guard view.superview !== body else { return }
        body.subviews.forEach { $0.removeFromSuperview() }
        view.frame = body.bounds; view.autoresizingMask = [.width, .height]; body.addSubview(view)
    }
    private func displayItem() {
        guard items.indices.contains(index) else { return }
        loading?.cancel(); loading = nil; appearance = nil
        previous.isHidden = items.count < 2; next.isHidden = items.count < 2
        previous.isEnabled = index > 0; next.isEnabled = index < items.count - 1
        let prefix = items.count > 1 ? "\(index + 1)/\(items.count) · " : ""
        switch items[index] {
        case .image(let image, let bytes):
            let pixels = image.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh) 像素" } ?? ""
            caption.stringValue = prefix + "图片"; info.stringValue = [pixels, HistoryViewModel.bytes(Int64(bytes)), "双击切换适应窗口/实际大小，触控板捏合缩放"].filter { !$0.isEmpty }.joined(separator: " · ")
            let view = imageView ?? ImageScrollView(); imageView = view
            setBody(view); view.image = image
        case .file(let url):
            caption.stringValue = prefix + url.lastPathComponent
            info.stringValue = url.deletingLastPathComponent().path
            setBody(message("正在读取…"))
            let current = index
            loading = Task { [weak self] in
                // 文件状态与大小在后台读取，慢卷不阻塞主线程。
                let (content, size) = await Task.detached(priority: .userInitiated) {
                    (FilePreviewContent.classify(url), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { HistoryViewModel.bytes(Int64($0)) })
                }.value
                guard let self, !Task.isCancelled, self.index == current else { return }
                if let size { self.info.stringValue = size + " · " + self.info.stringValue }
                switch content {
                case .quickLook: self.setBody(self.quickLook); self.quickLook.previewItem = url as NSURL
                case .failure(let text): self.setBody(self.message(text))
                case .text(let text, let language, let truncated):
                    let view = CodeTextView.make(text: text, editable: false)
                    self.setBody(view)
                    if truncated { self.info.stringValue += " · 仅显示前 \(HistoryViewModel.bytes(Int64(FilePreviewContent.textLimit)))" }
                    guard let highlight = await SyntaxHighlighter.detail.highlight(text, languageHint: language, limit: Self.highlightLimit),
                          !Task.isCancelled, self.index == current, let textView = view.documentView as? NSTextView else { return }
                    CodeTextView.apply(highlight, to: textView)
                    // 深浅色切换时按新外观重新着色。
                    self.appearance = textView.observe(\.effectiveAppearance) { textView, _ in
                        MainActor.assumeIsolated { CodeTextView.apply(highlight, to: textView) }
                    }
                }
            }
        }
    }
    private func message(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text); label.alignment = .center; label.textColor = .secondaryLabelColor
        let box = NSView(); label.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: box.centerXAnchor), label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                                     label.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -40)])
        return box
    }
    @objc private func previousItem() { index = max(0, index - 1); displayItem() }
    @objc private func nextItem() { index = min(items.count - 1, index + 1); displayItem() }
    /// Space/Esc/关闭按钮统一走owner的关闭，文本视图获得焦点时也不吞掉Space，by AI.Coding。
    final class PreviewWindow: NSPanel {
        var onDismiss: () -> Void = {}
        override func cancelOperation(_ sender: Any?) { onDismiss() }
        override func close() { onDismiss() }
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               event.keyCode == 49 || event.keyCode == 53, (firstResponder as? NSTextView)?.hasMarkedText() != true { onDismiss(); return }
            super.sendEvent(event)
        }
    }
}

/// 只读代码视图与编辑器共用：等宽字体、非连续布局保证大文件滚动流畅，高亮只改颜色不改文字，by AI.Coding。
@MainActor enum CodeTextView {
    static let fontSize: CGFloat = 12.5
    static func make(text: String, editable: Bool) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = editable; view.isSelectable = true; view.isRichText = false; view.importsGraphics = false; view.allowsUndo = editable
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular); view.textColor = .labelColor; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false; view.isAutomaticLinkDetectionEnabled = false
        view.layoutManager?.allowsNonContiguousLayout = true
        view.string = text
        return scroll
    }
    /// 只在文字未变时着色；颜色写入textStorage但不经过撤销管理器，撤销/重做只记录用户输入。
    static func apply(_ highlight: SyntaxHighlight, to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let length = storage.length
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: min(length, highlight.analyzedUTF16Count)))
        for span in highlight.spans where NSMaxRange(span.range) <= length {
            storage.addAttribute(.foregroundColor, value: SyntaxStyle.color(span.style, dark: dark), range: span.range)
        }
        storage.endEditing()
    }
}

/// 图片按适应窗口显示并居中；双击在适应/实际大小间切换，窗口缩放时未手动缩放则继续适应，by AI.Coding。
@MainActor final class ImageScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var fitting = true
    var image: NSImage? {
        didSet {
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
            fitting = true; fit()
        }
    }
    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView(); drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        allowsMagnification = true; minMagnification = 0.02; maxMagnification = 16
        imageView.imageScaling = .scaleAxesIndependently; documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom)); doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }
    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); if fitting { fit() } }
    override func magnify(with event: NSEvent) { fitting = false; super.magnify(with: event) }
    private var fitScale: CGFloat {
        guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, bounds.width / size.width, bounds.height / size.height)
    }
    private func fit() { magnification = fitScale }
    @objc private func toggleZoom() {
        fitting.toggle()
        if fitting || abs(fitScale - 1) < 0.01 { fitting = true; fit() } else { magnification = 1 }
    }
    private final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposed)
            guard let document = documentView else { return rect }
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
            return rect
        }
    }
}
