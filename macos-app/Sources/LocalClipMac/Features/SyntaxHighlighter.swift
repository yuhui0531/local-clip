// highlight.js离线语法引擎；剪贴板文字只作为参数，不执行、不访问网络，by AI.Coding。
import Foundation
import JavaScriptCore
import LocalClipCore

public struct SyntaxSpan: Sendable { public let range: NSRange; public let style: String }
public struct SyntaxHighlight: Sendable {
    // 同一高亮结果复用身份，渲染缓存不必每次拼接全部范围。
    let cacheIdentity: String
    public let language: String
    public let spans: [SyntaxSpan]
    public let analyzedUTF16Count: Int
    /// 不可变范围仅构造一次缓存身份，等价结果仍命中原渲染缓存，by AI.Coding。
    init(language: String, spans: [SyntaxSpan], analyzedUTF16Count: Int) {
        self.language = language; self.spans = spans; self.analyzedUTF16Count = analyzedUTF16Count
        cacheIdentity = spans.map { "\($0.range.location):\($0.range.length):\($0.style)" }.joined(separator: ";")
    }
}
public actor SyntaxHighlighter {
    public static let shared = SyntaxHighlighter()
    // 详情独立引擎，长文不会阻塞卡片高亮。
    public static let detail = SyntaxHighlighter()
    public static let characterLimit = 8192
    private var languageCache: [String: LanguageGuess] = [:]
    private var languageOrder: [String] = []
    private var context: JSContext?
    private var attemptedLoad = false
    private var cache: [String: SyntaxHighlight] = [:]
    private var misses: Set<String> = []
    private var order: [String] = []
    /// 独立于任何设置；仅分析有界前缀，详情仍保留完整文字。缓存只保存摘要键与范围，by AI.Coding。
    /// 显式提示只授权着色；无提示时由共用判定决定语言，前缀截断时结论只用于展示。
    /// limit仅供文件预览与编辑器放宽着色范围；卡片与详情沿用默认上限，by AI.Coding。
    public func highlight(_ text: String, languageHint: String? = nil, limit: Int = characterLimit) -> SyntaxHighlight? {
        guard let prefix = Self.bounded(text, limit: limit) else { return nil }
        let truncated = prefix.utf16.count < text.utf16.count
        let key = (languageHint ?? "auto:\(truncated)") + ":" + ContentFingerprint.hash(Data(prefix.utf8))
        if let result = cache[key] { return result }
        if misses.contains(key) { return nil }
        guard let language = languageHint ?? LanguageDetector.detect(prefix, truncated: truncated).language,
              let context = engine(), let function = context.objectForKeyedSubscript("localClipHighlight"),
              let result = function.call(withArguments: [prefix, language]), !result.isUndefined,
              let object = result.toDictionary(), let language = object["language"] as? String,
              let html = object["value"] as? String else { remember(key, result: nil); return nil }
        let parser = SpanParser(); let xml = XMLParser(data: Data(("<root>" + Self.xmlCompatible(html).replacingOccurrences(of: "\r", with: "&#13;") + "</root>").utf8))
        xml.delegate = parser; xml.shouldResolveExternalEntities = false
        guard xml.parse(), parser.text == Self.xmlCompatible(prefix), !parser.spans.isEmpty else { remember(key, result: nil); return nil }
        let highlighted = SyntaxHighlight(language: language, spans: parser.spans, analyzedUTF16Count: prefix.utf16.count)
        remember(key, result: highlighted); return highlighted
    }
    /// 只替换解析副本中的 XML 非法单码元字符，保留所有 UTF-16 偏移及原始正文。
    private static func xmlCompatible(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            let code = scalar.value
            return (code >= 0x20 && code != 0xFFFE && code != 0xFFFF) || [9, 10, 13].contains(code) ? scalar : " "
        }))
    }
    /// 完整内容的语言判定（不着色）：导出、Markdown围栏与详情只能使用结果的 `verifiedLanguage`。
    /// 键含完整正文摘要、长度与范围；缓存未识别结果，不保存原始正文，by AI.Coding。
    public func guess(of text: String, truncated: Bool = false) -> LanguageGuess {
        let key = "\(truncated):\(text.utf16.count):" + ContentFingerprint.hash(Data(text.utf8))
        if let cached = languageCache[key] { return cached }
        let result = LanguageDetector.detect(text, truncated: truncated)
        languageCache[key] = result
        languageOrder.append(key)
        if languageOrder.count > 64 { languageCache.removeValue(forKey: languageOrder.removeFirst()) }
        return result
    }
    /// 有界前缀不截断代理对；URL、路径与正文的保护由共用判定负责。
    private static func bounded(_ text: String, limit: Int) -> String? {
        var units = Array(text.utf16.prefix(limit))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        let prefix = String(decoding: units, as: UTF16.self)
        return prefix.isEmpty ? nil : prefix
    }
    /// 文件扩展名到内置highlight.js语言；未知扩展名返回nil，交给内容判定，by AI.Coding。
    public static func language(forFile url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if name == "makefile" || name == "gnumakefile" { return "makefile" }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "bash" }
        return fileLanguages[url.pathExtension.lowercased()]
    }
    private static let fileLanguages: [String: String] = [
        "json": "json", "jsonc": "json", "xml": "xml", "html": "xml", "htm": "xml", "svg": "xml", "plist": "xml", "vue": "xml", "svelte": "xml",
        "yaml": "yaml", "yml": "yaml", "py": "python", "pyw": "python", "java": "java", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript", "sql": "sql",
        "sh": "bash", "bash": "bash", "zsh": "bash", "swift": "swift", "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "hpp": "cpp", "cxx": "cpp",
        "cs": "csharp", "go": "go", "rs": "rust", "rb": "ruby", "php": "php", "kt": "kotlin", "kts": "kotlin", "gradle": "kotlin",
        "m": "objectivec", "mm": "objectivec", "lua": "lua", "pl": "perl", "r": "r", "css": "css", "scss": "scss", "less": "less",
        "md": "markdown", "markdown": "markdown", "ini": "ini", "toml": "ini", "cfg": "ini", "conf": "ini", "properties": "ini",
        "graphql": "graphql", "gql": "graphql", "diff": "diff", "patch": "diff"]
    /// 引擎仅载入一次，只使用官方指定语言高亮接口，by AI.Coding。
    private func engine() -> JSContext? {
        if attemptedLoad { return context }
        attemptedLoad = true
        // SwiftPM生成器在.app顶层找bundle，而打包约定在Contents/Resources；应用直接定位封装资源，by AI.Coding。
        let url: URL?
        if Bundle.main.bundleURL.pathExtension == "app" {
            url = Bundle.main.resourceURL?.appendingPathComponent("LocalClip_LocalClipMac.bundle/highlight.min.js")
        } else {
            url = Bundle.module.url(forResource: "highlight.min", withExtension: "js")
        }
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8), let js = JSContext() else { return nil }
        js.evaluateScript(source)
        guard js.exception == nil else { return nil }
        js.evaluateScript("""
        // 语言由Swift侧判定或显式提示给出；highlight.js只负责着色，不再自动猜测。
        function localClipHighlight(text, language) {
          return hljs.getLanguage(language) ? hljs.highlight(text, {language: language, ignoreIllegals: true}) : undefined;
        }
        """)
        guard js.exception == nil else { return nil }
        context = js; return js
    }
    private func remember(_ key: String, result: SyntaxHighlight?) {
        if let result { cache[key] = result } else { misses.insert(key) }
        order.append(key)
        // 最大64份有界文字，避免横向浏览时缓存无限增长，by AI.Coding。
        if order.count > 64 { let old = order.removeFirst(); cache.removeValue(forKey: old); misses.remove(old) }
    }
}
// 官方输出只有转义文字和span；XML解析范围后再次逐字验证，不渲染HTML，by AI.Coding。
private final class SpanParser: NSObject, XMLParserDelegate {
    var text = ""
    var spans: [SyntaxSpan] = []
    private var styles: [String] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "span" { styles.append(attributes["class"] ?? "") }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "span", !styles.isEmpty { styles.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let start = text.utf16.count; text.append(string)
        if let style = styles.last, !style.isEmpty { spans.append(.init(range: NSRange(location: start, length: string.utf16.count), style: style)) }
    }
}
