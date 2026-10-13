// 纯文本网址归为链接，旧库在打开时补正，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct TextLinkKindTests {
    @Test func plainTextURLIsLink() {
        #expect(fixture("https://github.com/yuhui0531/local-clip/releases/tag/v0.3.22").payload.kind == .url)
        #expect(fixture("  http://example.com/路径?q=1\n").payload.kind == .url)
        #expect(fixture("优化营商环境").payload.kind == .text)
        #expect(fixture("see https://example.com").payload.kind == .text)
        #expect(fixture("https://a.com\nhttps://b.com").payload.kind == .text)
        #expect(fixture("mailto:a@b.com").payload.kind == .text)
        #expect(fixture("https://").payload.kind == .text)
        #expect(ClipboardPayload.webLink("www.example.com")?.absoluteString == "http://www.example.com")
        #expect(fixture("github.com/yuhui0531/local-clip").payload.kind == .url)
        #expect(fixture("example.co.uk/a?q=中文").payload.kind == .url)
        for text in ["README.md", "main.swift", "v0.3.22", "1.2.3.4", "a@b.com", "foo.bar", "index.html"] {
            #expect(fixture(text).payload.kind == .text, "\(text)")
        }
    }
}
