// 纯文本网址归为链接，富文本即使正文是网址也归为文本，by AI.Coding。
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
    /// 富文本也是文本：RTF/HTML归入文本筛选，原始表示不丢失，by AI.Coding。
    @Test func richTextIsText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let rtf = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.rtf, Data("{\\rtf1 rich}".utf8)), .init(SupportedType.string, Data("rich".utf8))])]))
        let html = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.html, Data("<b>https://example.com</b>".utf8)), .init(SupportedType.string, Data("https://example.com".utf8))])]))
        #expect(rtf.payload.kind == .text && html.payload.kind == .text)
        let ids = [insertedID(try await store.ingest(rtf, at: now)), insertedID(try await store.ingest(html, at: now)), insertedID(try await store.ingest(fixture("plain"), at: now))]
        #expect(Set(try await store.search(.init(kind: .text)).items.map(\.id)) == Set(ids))
        #expect(try await store.loadPayload(id: ids[0], at: now).items[0].representations.contains { $0.type == SupportedType.rtf })
    }
}
