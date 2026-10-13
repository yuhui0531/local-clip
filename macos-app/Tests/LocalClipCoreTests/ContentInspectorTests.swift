// 导出格式、文件名与Markdown识别的纯规则，覆盖PRD F15格式表与边界，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct ContentInspectorTests {
    private let plain = [SupportedType.string]
    private let rtf = [SupportedType.rtf, SupportedType.string]
    private let html = [SupportedType.html, SupportedType.string]

    /// 格式表自上而下命中即止：代码 → Markdown → RTF → HTML → 纯文本，by AI.Coding。
    @Test func exportFormatFollowsPRDTable() {
        #expect(ContentInspector.exportFormat(plainText: "{\"a\":1}", language: "json", types: plain, markup: nil) == .plain("json"))
        #expect(ContentInspector.exportFormat(plainText: "let a = 1", language: "swift", types: plain, markup: nil) == .plain("swift"))
        // AI对话与编辑器复制的代码带HTML，等宽或pre标记时仍按源码导出。
        #expect(ContentInspector.exportFormat(plainText: "let a = 1", language: "swift", types: html, markup: "<pre><code class=\"language-swift\">") == .plain("swift"))
        #expect(ContentInspector.exportFormat(plainText: "let a = 1", language: "swift", types: html, markup: "<div style=\"font-family: Menlo, monospace\">") == .plain("swift"))
        // 邮件正文即使被误识别出语言，也因缺少代码排版标记而保留RTF。
        #expect(ContentInspector.exportFormat(plainText: "Hello team", language: "ini", types: rtf, markup: "{\\rtf1{\\fonttbl\\f0 Helvetica;}") == .original(type: SupportedType.rtf, fileExtension: "rtf"))
        #expect(ContentInspector.exportFormat(plainText: "Hello", language: nil, types: [SupportedType.html], markup: "<p>Hello</p>") == .original(type: SupportedType.html, fileExtension: "html"))
        #expect(ContentInspector.exportFormat(plainText: "# Title\n\n- a\n- b", language: nil, types: html, markup: "<h1>Title</h1>") == .plain("md"))
        #expect(ContentInspector.exportFormat(plainText: "just words", language: nil, types: plain, markup: nil) == .plain("txt"))
        #expect(ContentInspector.exportFormat(plainText: "<!DOCTYPE html><html></html>", language: "xml", types: plain, markup: nil) == .plain("html"))
        #expect(ContentInspector.exportFormat(plainText: "<a><b/></a>", language: "xml", types: plain, markup: nil) == .plain("xml"))
        // 未知语言名不得拼出任意扩展名。
        #expect(ContentInspector.exportFormat(plainText: "x", language: "../../evil", types: plain, markup: nil) == .plain("txt"))
    }

    @Test func everyExportExtensionIsWhitelisted() {
        for ext in ContentInspector.codeExtensions.values { #expect(ContentInspector.textExtensions.contains(ext)) }
        for ext in ["txt", "md", "rtf", "html"] { #expect(ContentInspector.textExtensions.contains(ext)) }
        #expect(!ContentInspector.textExtensions.contains { $0.contains("/") || $0.contains(".") })
    }

    @Test func markdownNeedsTwoSignals() {
        #expect(ContentInspector.looksLikeMarkdown("# Title\n\n```swift\nlet a = 1\n```"))
        #expect(ContentInspector.looksLikeMarkdown("- one\n- two\n\nSee [docs](https://example.com)"))
        #expect(ContentInspector.looksLikeMarkdown("1. first\r\n2. second\r\n## Next"))
        #expect(!ContentInspector.looksLikeMarkdown("# just a heading"))
        #expect(!ContentInspector.looksLikeMarkdown("- one item\nplain text"))
        #expect(!ContentInspector.looksLikeMarkdown("#hashtag and -dash"))
        #expect(!ContentInspector.looksLikeMarkdown(""))
    }

    @Test func codeMarkupMarkers() {
        #expect(ContentInspector.looksLikeCodeMarkup("<PRE>x</PRE>"))
        #expect(ContentInspector.looksLikeCodeMarkup("{\\fonttbl\\f0\\fmodern Menlo-Regular;}"))
        #expect(!ContentInspector.looksLikeCodeMarkup("<p style=\"font-family: Helvetica\">Hi</p>"))
        #expect(!ContentInspector.looksLikeCodeMarkup(""))
    }

    /// 名称优先；非法字符替换、隐藏文件前缀去除、按字符截到200字节以内，by AI.Coding。
    @Test func baseNameUsesTitleOrTimestamp() throws {
        #expect(ContentInspector.exportBaseName(title: "API 响应", copiedAt: 0) == "API 响应")
        #expect(ContentInspector.exportBaseName(title: "a/b:c\nd\u{0}e", copiedAt: 0) == "a-b-c-d-e")
        #expect(ContentInspector.exportBaseName(title: "..env", copiedAt: 0) == "env")
        let stamp = ContentInspector.exportBaseName(title: nil, copiedAt: 1_760_313_600_000)
        #expect(stamp.range(of: "^LocalClip-\\d{8}-\\d{6}$", options: .regularExpression) != nil)
        #expect(ContentInspector.exportBaseName(title: "   ", copiedAt: 1_760_313_600_000) == stamp)
        let long = try #require(ContentInspector.sanitizedFileName(String(repeating: "汉", count: 100) + "😀"))
        #expect(long.utf8.count <= 200 && long.allSatisfy { $0 == "汉" })
        #expect(String(repeating: "汉", count: 66) == long)
    }

    @Test func fileNamesAndCollisions() {
        #expect(ContentInspector.fileName(base: "a", index: nil, fileExtension: "json") == "a.json")
        #expect(ContentInspector.fileName(base: "a", index: 2, fileExtension: "json") == "a-2.json")
        let folder = URL(fileURLWithPath: "/tmp/x")
        let free = folder.appendingPathComponent("a.json")
        #expect(ContentInspector.availableURL(free) { _ in false } == free)
        let taken: Set<String> = ["a.json", "a 2.json"]
        #expect(ContentInspector.availableURL(free) { taken.contains($0.lastPathComponent) }?.lastPathComponent == "a 3.json")
        #expect(ContentInspector.availableURL(free) { _ in true } == nil)
    }
}
