// highlight.js离线语法引擎；剪贴板文字只作为参数，不执行、不访问网络，by AI.Coding。
import Foundation
import JavaScriptCore
import LocalClipCore

public struct SyntaxSpan: Sendable { public let range: NSRange; public let style: String }
public struct SyntaxHighlight: Sendable {
    public let language: String
    public let spans: [SyntaxSpan]
    public let analyzedUTF16Count: Int
}
public actor SyntaxHighlighter {
    public static let shared = SyntaxHighlighter()
    // 详情独立引擎，长文不会阻塞卡片高亮。
    public static let detail = SyntaxHighlighter()
    public static let characterLimit = 8192
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
        let parser = SpanParser(); let xml = XMLParser(data: Data(("<root>" + html.replacingOccurrences(of: "\r", with: "&#13;") + "</root>").utf8))
        xml.delegate = parser; xml.shouldResolveExternalEntities = false
        guard xml.parse(), parser.text == prefix, !parser.spans.isEmpty else { remember(key, result: nil); return nil }
        let highlighted = SyntaxHighlight(language: language, spans: parser.spans, analyzedUTF16Count: prefix.utf16.count)
        remember(key, result: highlighted); return highlighted
    }
    /// 只识别语言、不生成着色范围，阈值与卡片相同；导出文件在拖动开始时据此决定扩展名。
    /// 识别耗时随样本长度增长（2048字符约50ms），调用方可取较短样本，by AI.Coding。
    public func language(of text: String, sample: Int = 2048) -> String? {
        guard let (_, detection) = Self.bounded(text, languageHint: nil), let context = engine(),
              let function = context.objectForKeyedSubscript("localClipLanguage"),
              let result = function.call(withArguments: [detection, sample]), result.isString else { return nil }
        return result.toString()
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
