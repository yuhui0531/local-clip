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
    private enum LanguageResult { case detected(String), none }
    private var languageCache: [String: LanguageResult] = [:]
    private var languageOrder: [String] = []
    private var context: JSContext?
    private var attemptedLoad = false
    private var cache: [String: SyntaxHighlight] = [:]
    private var misses: Set<String> = []
    private var order: [String] = []
    /// 独立于任何设置；仅分析有界前缀，详情仍保留完整文字。缓存只保存摘要键与范围，by AI.Coding。
    public func highlight(_ text: String, languageHint: String? = nil) -> SyntaxHighlight? {
        guard let (prefix, sample) = Self.bounded(text, languageHint: languageHint) else { return nil }
        let key = (languageHint ?? "auto") + ":" + ContentFingerprint.hash(Data(prefix.utf8))
        if let result = cache[key] { return result }
        if misses.contains(key) { return nil }
        guard let context = engine(), let function = context.objectForKeyedSubscript("localClipHighlight"),
              let result = function.call(withArguments: [prefix, languageHint ?? "", sample]), !result.isUndefined,
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
    /// 只识别语言、不生成着色范围，阈值与卡片相同；导出文件在拖动开始时据此决定扩展名。
    /// 识别耗时随样本长度增长（2048字符约50ms），调用方可取较短样本，by AI.Coding。
    public func language(of text: String, sample: Int = 2048) -> String? {
        guard let (_, detection) = Self.bounded(text, languageHint: nil) else { return nil }
        // 样本长度也参与身份；缓存未识别结果，不保存原始正文。
        let key = "\(sample):" + ContentFingerprint.hash(Data(detection.utf8))
        if let cached = languageCache[key] {
            if case .detected(let value) = cached { return value }
            return nil
        }
        let result = engine()?.objectForKeyedSubscript("localClipLanguage")?.call(withArguments: [detection, sample])
        let language = result?.isString == true ? result?.toString() : nil
        languageCache[key] = language.map(LanguageResult.detected) ?? LanguageResult.none
        languageOrder.append(key)
        if languageOrder.count > 64 { languageCache.removeValue(forKey: languageOrder.removeFirst()) }
        return language
    }
    /// 有界前缀不截断代理对；单行URL、纯路径与中文正文不参加语言猜测，防止被识别为Ruby/Swift代码。
    /// 返回着色用前缀与语言猜测样本（已抹掉路径）；有语言提示时样本不用。
    private static func bounded(_ text: String, languageHint: String?) -> (String, String)? {
        var units = Array(text.utf16.prefix(characterLimit))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        let prefix = String(decoding: units, as: UTF16.self)
        guard !prefix.isEmpty, !(languageHint == nil && !prefix.contains("\n") &&
            ["http", "https", "mailto"].contains(URL(string: prefix.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() ?? "")) else { return nil }
        if languageHint != nil { return (prefix, prefix) }
        return ContentInspector.languageSample(prefix).map { (prefix, $0) }
    }
    /// 引擎仅载入一次，使用官方自动识别/高亮接口和固定语言集合，by AI.Coding。
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
        const localClipLanguages = ['json','java','python','javascript','typescript','yaml','xml','css','bash','swift','sql','cpp','csharp','go','ruby','php','rust','ini','markdown'].filter(x => hljs.getLanguage(x));
        // 有界前缀只负责识别，完整有界正文用已确定语言高亮。
        // 相关度<3视为正文：偶然命中通常只有1-2分，真实代码片段通常≥3；代价是print('x')这类极短代码不再识别。
        function localClipLanguage(text, sample) {
          const detected = hljs.highlightAuto(text.slice(0, sample || 2048), localClipLanguages);
          return detected.relevance < 3 || !detected.language ? undefined : detected.language;
        }
        function localClipHighlight(text, hint, detection) {
          if (hint && hljs.getLanguage(hint)) return hljs.highlight(text, {language: hint, ignoreIllegals: true});
          const language = localClipLanguage(detection);
          return language ? hljs.highlight(text, {language: language, ignoreIllegals: true}) : undefined;
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
