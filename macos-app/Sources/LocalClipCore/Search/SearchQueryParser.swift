// 搜索框前缀条件：app:/type:/is:/in:/after:/before: 映射到现有筛选字段，其余文字原样走字面检索，by AI.Coding。
import Foundation
public struct ParsedQuery: Equatable, Sendable {
    /// 去掉已识别前缀后的字面检索词；没有前缀时与输入完全相同。
    public var literal: String
    public var kind: ClipKind?
    public var favorites = false
    public var sourceBundleID: String?
    public var categoryIDs: Set<String> = []
    public var from: Instant?
    public var until: Instant?
    /// 状态行显示的已生效条件，如"来源 Xcode"。
    public var labels: [String] = []
    /// 写了前缀但无法应用的原因，如"未找到来源 xx"；该条件不生效。
    public var problems: [String] = []
    public init(literal: String) { self.literal = literal }
}
public enum SearchQueryParser {
    private static let kinds: [String: ClipKind] = [
        "text": .text, "url": .url, "link": .url, "image": .image, "img": .image,
        "file": .file, "mixed": .mixed, "文本": .text, "链接": .url, "图片": .image, "文件": .file, "混合": .mixed]
    private static let kindNames: [ClipKind: String] = [.text: "文本", .url: "链接", .image: "图片", .file: "文件", .mixed: "混合"]
    /// 只有token开头是已知键、冒号后值非空且值可解析时才算前缀；英文双引号包住的前缀按字面检索（去掉引号）。
    public static func parse(_ text: String, sources: [SourceAttribution], categories: [ClipCategory], now: Instant) -> ParsedQuery {
        var result = ParsedQuery(literal: text)
        var removals: [Range<String.Index>] = [], replacements: [(Range<String.Index>, String)] = []
        var categoryNames: [String] = []
        var labelIndices: [String: Int] = [:]
        // 单值条件保持后值生效，同时原位更新其显示标签。
        func label(_ key: String, _ value: String) {
            if let index = labelIndices[key] { result.labels[index] = value }
            else { labelIndices[key] = result.labels.count; result.labels.append(value) }
        }
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let range = start..<index, token = String(text[range])
            if token.count > 2, token.hasPrefix("\""), token.hasSuffix("\""), key(String(token.dropFirst().dropLast())) != nil {
                replacements.append((range, String(token.dropFirst().dropLast()))); continue
            }
            guard let (name, value) = key(token) else { continue }
            switch name {
            case "type":
                guard let kind = kinds[value.lowercased()] else { continue }
                result.kind = kind; label(name, "类型 " + kindNames[kind]!)
            case "is":
                guard ["fav", "favorite", "favorites", "收藏"].contains(value.lowercased()) else { continue }
                result.favorites = true; result.labels.append("收藏")
            case "app":
                let needle = value.lowercased()
                let exact = sources.filter { $0.name.lowercased() == needle || $0.bundleID?.lowercased() == needle }
                let matches = exact.isEmpty ? sources.filter { $0.name.lowercased().hasPrefix(needle) || $0.bundleID?.lowercased().hasPrefix(needle) == true } : exact
                if matches.count == 1, let source = matches.first {
                    result.sourceBundleID = source.bundleID ?? ""; label(name, "来源 " + source.name)
                } else if matches.isEmpty { result.problems.append("未找到来源 " + value) }
                else { result.problems.append("来源“\(value)”匹配多个：" + matches.prefix(5).map(\.name).joined(separator: "、")) }
            case "in":
                if let category = categories.first(where: { $0.name.lowercased() == value.lowercased() }) {
                    result.categoryIDs.insert(category.id); categoryNames.append(category.name)
                } else { result.problems.append("未找到分类 " + value) }
            default:
                guard let bound = date(value, now: now, after: name == "after") else { continue }
                if name == "after" { result.from = bound.instant } else { result.until = bound.instant }
                label(name, bound.label)
            }
            removals.append(range)
        }
        if !categoryNames.isEmpty { result.labels.append("分类 " + categoryNames.joined(separator: "、")) }
        guard !removals.isEmpty || !replacements.isEmpty else { return result }
        // 从后往前改写：引号前缀换成内文，已识别前缀连同一个相邻空格删除，其余字符原样保留。
        var literal = text
        let edits = (removals.map { ($0, Optional<String>.none) } + replacements.map { ($0.0, Optional($0.1)) }).sorted { $0.0.lowerBound > $1.0.lowerBound }
        for (range, replacement) in edits {
            if let replacement { literal.replaceSubrange(range, with: replacement); continue }
            var removal = range
            if removal.upperBound < literal.endIndex, literal[removal.upperBound] == " " { removal = removal.lowerBound..<literal.index(after: removal.upperBound) }
            else if removal.lowerBound > literal.startIndex, literal[literal.index(before: removal.lowerBound)] == " " { removal = literal.index(before: removal.lowerBound)..<removal.upperBound }
            literal.removeSubrange(removal)
        }
        result.literal = literal
        return result
    }
    private static func key(_ token: String) -> (String, String)? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let name = token[..<colon].lowercased(), value = String(token[token.index(after: colon)...])
        guard ["app", "type", "is", "in", "after", "before"].contains(name), !value.isEmpty, !value.hasPrefix(":") else { return nil }
        return (name, value)
    }
    /// YYYY-MM-DD按本地日开始；Nd为距今N天。after取下界（含），before取上界（不含）。
    private static func date(_ value: String, now: Instant, after: Bool) -> (instant: Instant, label: String)? {
        if value.range(of: "^\\d{1,4}d$", options: .regularExpression) != nil, let days = Int64(value.dropLast()) {
            return (now - days * dayMS, after ? "最近 \(days) 天" : "\(days) 天前")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil, let day = formatter.date(from: value) else { return nil }
        return (Int64(Calendar.current.startOfDay(for: day).timeIntervalSince1970 * 1000), (after ? "从 " : "早于 ") + value)
    }
}
