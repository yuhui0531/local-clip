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
}
