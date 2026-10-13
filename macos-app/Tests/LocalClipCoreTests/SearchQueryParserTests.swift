// F20搜索前缀：识别边界、字面保留、来源/分类解析与日期范围；纯函数，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct SearchQueryParserTests {
    private let sources = [SourceAttribution(bundleID: "com.apple.dt.Xcode", name: "Xcode"), SourceAttribution(bundleID: "com.apple.Safari", name: "Safari"),
                           SourceAttribution(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview"), SourceAttribution(bundleID: nil, name: "未知", basis: "unknown")]
    private let categories = [ClipCategory(id: "c1", name: "工作"), ClipCategory(id: "c2", name: "脚本")]
    private let now: Instant = 1_760_313_600_000
    private func parse(_ text: String) -> ParsedQuery { SearchQueryParser.parse(text, sources: sources, categories: categories, now: now) }

    /// AC1/AC3：前缀映射到筛选字段，并从字面词里去掉，其余字符原样保留，by AI.Coding。
    @Test func prefixesMapToFilters() {
        let value = parse("app:xcode type:image")
        #expect(value.literal == "" && value.kind == .image && value.sourceBundleID == "com.apple.dt.Xcode")
        #expect(value.labels == ["来源 Xcode", "类型 图片"])
        let categories = parse("in:工作 in:脚本 foo")
        #expect(categories.categoryIDs == ["c1", "c2"] && categories.literal == "foo" && categories.labels == ["分类 工作、脚本"])
        let mixed = parse("error  code is:fav TYPE:文本")
        #expect(mixed.literal == "error  code" && mixed.favorites && mixed.kind == .text)
        #expect(parse("app:com.apple.dt.xcode").sourceBundleID == "com.apple.dt.Xcode")
    }

    /// AC2/AC5：非前缀输入完全不变；引号前缀按字面检索并去掉引号，by AI.Coding。
    @Test func literalInputsStayLiteral() {
        for text in ["https://example.com", "myapp:foo", "std::vector", "app:", "type:unknown", "is:open", "after:yesterday", "a  b ", "\"quoted\"", "x:y"] {
            let value = parse(text)
            #expect(value.literal == text && value.labels.isEmpty && value.problems.isEmpty, "\(text)")
        }
        #expect(parse("\"is:fav\"").literal == "is:fav" && !parse("\"is:fav\"").favorites)
        #expect(parse("note \"app:xcode\"").literal == "note app:xcode")
    }

    /// AC4与日期：Nd为距今，日期按本地日开始；before为不含上界，by AI.Coding。
    @Test func dateBounds() throws {
        #expect(parse("after:7d").from == now - 7 * dayMS && parse("after:7d").labels == ["最近 7 天"])
        #expect(parse("before:30d").until == now - 30 * dayMS)
        let day = try #require(parse("after:2026-10-01").from)
        #expect(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(day) / 1000)).timeIntervalSince1970 * 1000 == Double(day))
        #expect(parse("after:2026-02-30").literal == "after:2026-02-30")
    }

    /// 来源多义或不存在、分类不存在：不应用该条件并给出原因，前缀仍从字面词中去掉，by AI.Coding。
    @Test func unresolvedPrefixesReportProblems() {
        let ambiguous = parse("app:saf foo")
        #expect(ambiguous.sourceBundleID == nil && ambiguous.literal == "foo")
        #expect(ambiguous.problems == ["来源“saf”匹配多个：Safari、Safari Technology Preview"])
        #expect(parse("app:safari").sourceBundleID == "com.apple.Safari")
        #expect(parse("app:nothing").problems == ["未找到来源 nothing"])
        #expect(parse("in:不存在").problems == ["未找到分类 不存在"] && parse("in:不存在").categoryIDs.isEmpty)
        #expect(parse("app:未知").sourceBundleID == "")
    }
}
