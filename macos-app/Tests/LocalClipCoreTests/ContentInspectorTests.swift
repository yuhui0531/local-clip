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
        #expect(ContentInspector.exportFormat(plainText: "let a = 1", language: "swift", types: html, markup: "<pre><code class=\"language-swift\">let a = 1</code></pre>") == .plain("swift"))
        #expect(ContentInspector.exportFormat(plainText: "let a = 1", language: "swift", types: html, markup: "<div style=\"font-family: Menlo, monospace\">let a = 1</div>") == .plain("swift"))
        // 邮件正文即使被误识别出语言，也因缺少代码排版标记而保留RTF。
        #expect(ContentInspector.exportFormat(plainText: "Hello team", language: "ini", types: rtf, markup: "{\\rtf1{\\fonttbl\\f0 Helvetica;}") == .original(type: SupportedType.rtf, fileExtension: "rtf"))
        #expect(ContentInspector.exportFormat(plainText: "Hello", language: nil, types: [SupportedType.html], markup: "<p>Hello</p>") == .original(type: SupportedType.html, fileExtension: "html"))
        #expect(ContentInspector.exportFormat(plainText: "# Title\n\n- a\n- b", language: "markdown", types: html, markup: "<h1>Title</h1>") == .plain("md"))
        // Markdown只来自共用判定：未确定时不再由独立规则转换，富文本保留原表示。
        #expect(ContentInspector.exportFormat(plainText: "# Title\n\n- a\n- b", language: nil, types: html, markup: "<h1>Title</h1>") == .original(type: SupportedType.html, fileExtension: "html"))
        #expect(ContentInspector.exportFormat(plainText: "# Title\n\n- a\n- b", language: nil, types: plain, markup: nil) == .plain("txt"))
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

    /// 等宽字体、行内<code>、局部<pre>都只是线索：代码排版必须覆盖整份正文才允许富文本转源码。
    @Test func codeMarkupMustCoverTheWholeText() {
        let code = "func add(a: Int, b: Int) -> Int {\n    return a + b\n}"
        #expect(ContentInspector.codeMarkupCovers("<pre><code>\(code.replacingOccurrences(of: ">", with: "&gt;"))</code></pre>", plainText: code))
        #expect(ContentInspector.codeMarkupCovers("<meta charset='utf-8'><div style=\"color: #d4d4d4;font-family: Menlo, Monaco, 'Courier New', monospace;white-space: pre;\"><div><span>\(code)</span></div></div>", plainText: code))
        #expect(ContentInspector.codeMarkupCovers("{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Menlo-Regular;\\f1\\fnil\\fcharset0 SFMono-Bold;}\n\\f0 x}", plainText: code))
        let prose = "Please review the export function and send the report."
        #expect(!ContentInspector.codeMarkupCovers("<p>Please review the <code>export</code> function and send the report.</p>", plainText: prose))
        #expect(!ContentInspector.codeMarkupCovers("<p>Intro paragraph explaining the change in detail.</p><pre>x = 1</pre><p>More text follows here.</p>", plainText: "Intro paragraph explaining the change in detail.\nx = 1\nMore text follows here."))
        #expect(!ContentInspector.codeMarkupCovers("<p style=\"font-family: Helvetica\">Hi <span style=\"font-family: Menlo\">x</span></p>", plainText: "Hi x"))
        #expect(!ContentInspector.codeMarkupCovers("<p>Hi</p><span style=\"font-family: Menlo\">x</span>", plainText: "Hi x"))
        #expect(!ContentInspector.codeMarkupCovers("{\\rtf1{\\fonttbl{\\f0\\fswiss Helvetica;}{\\f1\\fmodern Menlo-Regular;}}}", plainText: prose))
        #expect(!ContentInspector.codeMarkupCovers("<preview>\(prose)</preview>", plainText: prose))
        #expect(!ContentInspector.codeMarkupCovers("", plainText: prose))
        // 等宽字体的普通正文：排版覆盖成立，但正文判定不是代码，导出仍保留RTF。
        let monoProse = "{\\rtf1{\\fonttbl\\f0\\fnil Menlo-Regular;}\\f0 \(prose)}"
        #expect(ContentInspector.codeMarkupCovers(monoProse, plainText: prose))
        #expect(ContentInspector.exportFormat(plainText: prose, language: LanguageDetector.detect(prose).verifiedLanguage, types: rtf, markup: monoProse) == .original(type: SupportedType.rtf, fileExtension: "rtf"))
        // 局部代码的HTML正文：即使正文碰巧被判为代码，排版也不覆盖整篇，保留HTML。
        #expect(ContentInspector.exportFormat(plainText: "x = 1", language: "python", types: html, markup: "<p>See</p><code>x = 1</code><p>and more text here</p>") == .original(type: SupportedType.html, fileExtension: "html"))
        #expect(!ContentInspector.codeMarkupCovers("<p>See</p><code>x = 1</code><p>and more text here</p>", plainText: "x = 1"))
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
        #expect(ContentInspector.codeMarkupCovers("<PRE>x</PRE>", plainText: "x"))
        #expect(ContentInspector.codeMarkupCovers("{\\rtf1{\\fonttbl\\f0\\fmodern Menlo-Regular;}}", plainText: "x"))
        #expect(!ContentInspector.codeMarkupCovers("<p style=\"font-family: Helvetica\">Hi</p>", plainText: "Hi"))
        #expect(!ContentInspector.codeMarkupCovers("", plainText: "x"))
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

    // MARK: F17 开发者内容识别
    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsIm5hbWUiOiJcdTZkNGJcdThiZDUiLCJpYXQiOjE2OTAwMDAwMDAsImV4cCI6MTcwMDAwMDAwMH0.c2lnbmF0dXJl"

    /// AC1/AC2与识别顺序：单token、位数与年份范围、截断预览只认JWT，by AI.Coding。
    @Test func cardDetection() throws {
        #expect(ContentInspector.inspect("1760313600", truncated: false) == .timestamp(Date(timeIntervalSince1970: 1_760_313_600)))
        #expect(ContentInspector.inspect(" 1760313600123\n", truncated: false) == .timestamp(Date(timeIntervalSince1970: 1_760_313_600.123)))
        #expect(ContentInspector.inspect("20261013", truncated: false) == nil)
        #expect(ContentInspector.inspect("9999999999", truncated: false) == nil)
        #expect(ContentInspector.inspect("1760313600", truncated: true) == nil)
        #expect(ContentInspector.inspect(jwt, truncated: false) == .jwt)
        #expect(ContentInspector.inspect(String(jwt.prefix(60)), truncated: true) == .jwt)
        #expect(ContentInspector.inspect("eyJub3QiOiJqd3QifQ.e30.x", truncated: false) == nil)
        #expect(ContentInspector.inspect("f47ac10b-58cc-4372-a567-0e02b2c3d479", truncated: false) == .uuid(version: 4))
        #expect(ContentInspector.inspect("F47AC10B-58CC-0372-A567-0E02B2C3D479", truncated: false) == .uuid(version: nil))
        #expect(ContentInspector.inspect("aGVsbG8gd29ybGQgZnJvbSBMb2NhbENsaXA=", truncated: false) == .base64)
        #expect(ContentInspector.inspect("a94a8fe5ccb19ba61c4c0873d391e987982fbbd3", truncated: false) == nil)
        #expect(ContentInspector.inspect("internationalization", truncated: false) == nil)
        #expect(ContentInspector.inspect("hello world", truncated: false) == nil)
        #expect(ContentInspector.inspect("", truncated: false) == nil)
        #expect(ContentInspector.Detection.uuid(version: 4).badge == "UUID v4")
        let badge = ContentInspector.Detection.timestamp(Date(timeIntervalSince1970: 1_760_313_600)).badge
        #expect(badge.range(of: "^(\\d{4}-)?\\d{2}-\\d{2} \\d{2}:\\d{2}$", options: .regularExpression) != nil, "\(badge)")
    }

    /// 截图样本：含路径的中文说明、纯路径不是代码；带中文注释的代码仍识别，分析副本不改原文，by AI.Coding。
    @Test func pathsAndCJKProseAreNotCode() throws {
        let path = "/Users/ronny/VscodeProjects/rea/macos-app/docs/reviews/LocalClip_Comprehensive_Review_2026-10-14.md"
        for text in [path, "  ~/Downloads/a.txt\n", "请根据review comments **\(path) 进行修复。**  注意，切记功能", "今天下午三点开会，记得带电脑。", "See /usr/local/bin/foo for details"] {
            #expect(LanguageDetector.detect(text).language == nil, "\(text)")
        }
        let code = "// 获取用户列表\nfunction getUsers() { return api.get('/users'); }"
        let copy = code
        #expect(LanguageDetector.detect(code).language == "javascript")
        #expect(code == copy)
        #expect(!LanguageDetector.mask("See /usr/local/bin/foo").contains("/usr"))
    }

    /// AC4与颜色写法互转：hex、rgb()/rgba()、hsl()，越界不算颜色，by AI.Coding。
    @Test func colors() throws {
        let green = try #require(ContentInspector.color("#34C759"))
        #expect(green == .init(red: 52, green: 199, blue: 89, alpha: 1))
        #expect(green.hex == "#34C759" && green.rgb == "rgb(52, 199, 89)" && green.hsl == "hsl(135, 59%, 49%)")
        #expect(ContentInspector.inspect("#34C759", truncated: false) == .color(green))
        #expect(ContentInspector.color("#abc")?.hex == "#AABBCC")
        #expect(ContentInspector.color("rgb( 52 , 199, 89 )") == green)
        let half = try #require(ContentInspector.color("rgba(0, 0, 0, 0.5)"))
        #expect(half.hex == "#00000080" && half.rgb == "rgba(0, 0, 0, 0.5)")
        #expect(ContentInspector.color("hsl(135, 59%, 49%)") == .init(red: 51, green: 199, blue: 88, alpha: 1))
        #expect(ContentInspector.color("hsla(0, 100%, 50%, 0.5)")?.hex == "#FF000080")
        #expect(ContentInspector.color("rgb(300, 0, 0)") == nil)
        #expect(ContentInspector.color("#12345") == nil)
        #expect(ContentInspector.inspect("rgb(52, 199, 89)", truncated: false) == .color(green))
    }

    /// AC3与详情区块：JWT头/载荷、过期与未验签提示；时间戳、JSON、链接、代码的明细与动作，by AI.Coding。
    @Test func detailInspection() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let token = try #require(ContentInspector.inspectFull(jwt, language: nil, now: now))
        #expect(token.kind == "JWT" && token.note == "未验证签名")
        #expect(token.rows.first { $0.label == "Header" }?.value.contains("\"alg\": \"HS256\"") == true)
        #expect(token.rows.first { $0.label == "Payload" }?.value.contains("\"sub\": \"42\"") == true)
        #expect(token.rows.first { $0.label == "状态" }?.value.hasPrefix("已过期") == true)
        #expect(token.actions.map(\.transform) == [.jwtPayload])
        let time = try #require(ContentInspector.inspectFull("1760313600", language: nil, now: now))
        #expect(time.kind == "时间戳" && time.rows.map(\.label) == ["单位", "本地时间", "UTC", "ISO 8601", "相对"])
        #expect(time.rows.first { $0.label == "UTC" }?.value == "2025-10-13 00:00:00 UTC")
        #expect(time.actions.map(\.transform) == [.timestampToISO])
        let json = try #require(ContentInspector.inspectFull("{\"a\": 1, \"b\": [1]}", language: "json"))
        #expect(json.kind == "JSON" && json.rows.map(\.value) == ["是", "对象，2 个键"] && json.actions.map(\.transform) == [.formatJSON])
        #expect(ContentInspector.inspectFull("{\"a\": oops}", language: "json")?.rows.first?.value.hasPrefix("否") == true)
        let link = try #require(ContentInspector.inspectFull("https://example.com/a/b?x=1&y=%E4%B8%AD", language: nil))
        #expect(link.kind == "链接" && link.actions.isEmpty)
        #expect(link.rows.map { $0.label + "=" + $0.value } == ["协议=https", "主机=example.com", "路径=/a/b", "?x=1", "?y=中"])
        let code = try #require(ContentInspector.inspectFull("let a = 1\nlet b = 2", language: "swift"))
        #expect(code.kind == "代码 · Swift" && code.rows.map(\.value) == ["2", "19"] && code.actions.map(\.transform) == [.markdownCodeBlock])
        #expect(ContentInspector.inspectFull("  \n", language: nil) == nil)
    }

    /// AC6代理指标：卡片识别单次耗时；可选执行，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INSPECT_PERF"] == "1"))
    func cardDetectionTiming() throws {
        let samples = [jwt, "1760313600", "#34C759", "f47ac10b-58cc-4372-a567-0e02b2c3d479", "aGVsbG8gd29ybGQgZnJvbSBMb2NhbENsaXA=",
                       "let value = items.map { $0.name }.joined(separator: \", \")", String(repeating: "普通中文预览 ", count: 20)]
        let begin = ContinuousClock.now
        for index in 0..<7000 { _ = ContentInspector.inspect(samples[index % samples.count], truncated: false) }
        let elapsed = ContinuousClock.now - begin
        let perCard = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / 7000
        if let output = ProcessInfo.processInfo.environment["LOCALCLIP_INSPECT_PERF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: ["perCardMs": perCard, "count": 7000]).write(to: URL(fileURLWithPath: output))
        }
        #expect(perCard < 1)
    }
    /// 审查R1/R2：等宽作用域须实际包住全部可见正文，且解码后的代码区与纯文本逐字对应（忽略空白）；超出验证预算保留原表示。
    @Test func codeMarkupMustMatchTheExportedText() {
        let sql = "SELECT id FROM users WHERE active = 1;"
        for markup in ["<span style=\"font-family: Menlo\"></span><p>\(sql)</p>",
                       "<pre>This report explains the quarter forecast in full detail.</pre>",
                       "<span style=\"font-family: Menlo\"></span>" + String(repeating: " ", count: 65_536) + "<p style=\"font-family: Arial\">\(sql)</p>",
                       "<pre>\(sql)</pre><p>Thanks</p>", "<pre>SELECT id FROM users;</pre>", "<pre>\(sql)\(sql)</pre>",
                       "<div style=\"font-family: Menlo\"><p style=\"font-family: Helvetica\">\(sql)</p></div>",
                       "<pre>" + sql + String(repeating: " ", count: 65_536) + "</pre>"] {
            #expect(!ContentInspector.codeMarkupCovers(markup, plainText: sql), "\(markup.prefix(80))")
            #expect(ContentInspector.exportFormat(plainText: sql, language: "sql", types: html, markup: markup) == .original(type: SupportedType.html, fileExtension: "html"))
        }
        // 实体、<br>、NBSP、标签拆分、注释与head不影响对应关系；中文、emoji与CRLF逐字对应。
        let code = "if (a < b && c) {\n  run();\n}"
        #expect(ContentInspector.codeMarkupCovers("<pre><code><span>if</span> (a &lt; b &amp;&amp; c) {<br>&nbsp;&nbsp;run();\n}</code></pre>", plainText: code))
        #expect(ContentInspector.codeMarkupCovers("<pre>if (a < b && c) {\n  run();\n}</pre>", plainText: code))
        #expect(ContentInspector.codeMarkupCovers("<html><head><style>p{}</style></head><body><!-- note --><pre>\(sql)</pre></body></html>", plainText: sql))
        #expect(ContentInspector.codeMarkupCovers("<font face=\"Courier New\">\(sql)</font>", plainText: sql))
        #expect(ContentInspector.codeMarkupCovers("<pre>\r\n\(sql)\r\n</pre>", plainText: sql + "\r\n"))
        let unicode = "let 标题 = \"😀\""
        #expect(ContentInspector.codeMarkupCovers("<pre>let 标题 = &quot;&#x1F600;&quot;</pre>", plainText: unicode))
        #expect(!ContentInspector.codeMarkupCovers("<pre>let 标题 = \"😃\"</pre>", plainText: unicode))
        // 未闭合标签或注释：无法验证，保留原表示。
        #expect(!ContentInspector.codeMarkupCovers("<pre>\(sql)</pre><span style=\"x", plainText: sql))
        #expect(!ContentInspector.codeMarkupCovers("<pre>\(sql)</pre><!-- <p>hidden", plainText: sql))
    }
}
