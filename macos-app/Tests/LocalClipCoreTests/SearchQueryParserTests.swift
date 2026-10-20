// F20搜索前缀：识别边界、字面保留、来源/分类解析与日期范围；纯函数，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct SearchQueryParserTests {
    private let sources = [SourceAttribution(bundleID: "com.apple.dt.Xcode", name: "Xcode"), SourceAttribution(bundleID: "com.apple.Safari", name: "Safari"),
                           SourceAttribution(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview"), SourceAttribution(bundleID: nil, name: "未知", basis: "unknown")]
    private let categories = [ClipCategory(id: "c1", name: "工作"), ClipCategory(id: "c2", name: "脚本"), ClipCategory(id: "c3", name: "Project Alpha"),
                              ClipCategory(id: "c4", name: "项目 甲"), ClipCategory(id: "c5", name: "a\"b\\c")]
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

    /// A1-1/2/3：英文双引号值可含空格，与其他条件和普通词同时生效；来源取完整名不误配前缀，by AI.Coding。
    @Test func quotedValuesAllowSpaces() {
        let combined = parse("in:\"Project Alpha\" type:text hello")
        #expect(combined.categoryIDs == ["c3"] && combined.kind == .text && combined.literal == "hello" && combined.problems.isEmpty)
        #expect(combined.labels == ["类型 文本", "分类 Project Alpha"])
        #expect(parse("IN:\"project alpha\"").categoryIDs == ["c3"] && parse("IN:\"project alpha\"").literal == "")
        #expect(parse("in:\"Project Alpha\" in:工作 in:\"项目 甲\"").categoryIDs == ["c1", "c3", "c4"])
        #expect(parse("app:\"Safari Technology Preview\"").sourceBundleID == "com.apple.SafariTechnologyPreview")
        #expect(parse("app:\"Safari\"").sourceBundleID == "com.apple.Safari")
        #expect(parse("note after:\"2026-10-01\" x").literal == "note x" && parse("after:\"2026-10-01\"").from != nil)
        #expect(parse("in:\"不存在 分类\" foo").problems == ["未找到分类 不存在 分类"] && parse("in:\"不存在 分类\" foo").literal == "foo")
    }

    /// A1-5：引号未闭合不应用该条件及其后的内部前缀，剩余全文保留为普通词并提示未生效，by AI.Coding。
    @Test func unclosedQuoteStaysLiteral() {
        let value = parse("in:\"Project Alpha type:text")
        #expect(value.literal == "in:\"Project Alpha type:text" && value.categoryIDs.isEmpty && value.kind == nil && value.labels.isEmpty)
        #expect(value.problems == ["in: 的引号未闭合，按普通文字搜索"])
        let partial = parse("type:image in:\"Project Alpha is:fav")
        #expect(partial.kind == .image && !partial.favorites && partial.literal == "in:\"Project Alpha is:fav")
        #expect(parse("in:\"").literal == "in:\"" && parse("in:\"").categoryIDs.isEmpty)
    }

    /// A1-4/6：空值、不支持值、引号后粘连字符、转义与路径反斜杠均按规则保留，不悄悄应用错误条件，by AI.Coding。
    @Test func quotedEdgeCases() {
        for text in ["in:\"\"", "in:\" \"", "type:\"no such\"", "in:\"Project Alpha\"x", "is:\"fav later\"", "path \"C:\\dir\" a::b"] {
            let value = parse(text)
            #expect(value.literal == text && value.labels.isEmpty && value.problems.isEmpty && value.categoryIDs.isEmpty, "\(text)")
        }
        #expect(parse("in:\"a\\\"b\\\\c\"").categoryIDs == ["c5"])
        #expect(parse("in:\"a\\nb\"").problems == ["未找到分类 a\\nb"])
        #expect(parse("in:\"C:\\Users\\x\"").problems == ["未找到分类 C:\\Users\\x"])
        #expect(parse("\"in:工作\" std::vector https://a.b/?q=\"x y\"").literal == "in:工作 std::vector https://a.b/?q=\"x y\"")
    }
}
