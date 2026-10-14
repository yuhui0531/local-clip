// 粘贴前的确定性文字转换；只作用于本次输出，原记录与历史不变，纯Foundation实现便于单测，by AI.Coding。
import Foundation
public struct TransformError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
public enum TextTransform: String, CaseIterable, Sendable {
    // 行号识别固定模式只编译一次；编译失败安全判为不适用，by AI.Coding。
    private static let numberedPattern = try? NSRegularExpression(pattern: "^[ \\t]*(\\d{1,6})(?:[ \\t]?\\|[ \\t]?|:[ \\t]?|\\.[ \\t]|[ \\t])")
    case markdownCodeBlock, dedent, trimWhitespace, stripPrompt, stripLineNumbers
    case formatJSON, minifyJSON
    case quoteString, unquoteString, base64Encode, base64Decode, urlEncode, urlDecode
    case camelCase, snakeCase, kebabCase, uppercase, lowercase, sortLines, uniqueLines
    /// F17识别专属：JWT载荷、时间戳⇄ISO 8601、颜色hex⇄rgb()，同样走转换后粘贴管线。
    case jwtPayload, timestampToISO, isoToTimestamp, colorToRGB, colorToHex
    /// 超过4MiB不转换，避免在粘贴前长时间占用后台与内存。
    public static let byteLimit = 4 * 1_048_576
    public var title: String {
        switch self {
        case .markdownCodeBlock: "Markdown 代码块"
        case .dedent: "去公共缩进"
        case .trimWhitespace: "清理空白"
        case .stripPrompt: "去命令提示符"
        case .stripLineNumbers: "去行号"
        case .formatJSON: "格式化 JSON"
        case .minifyJSON: "压缩 JSON"
        case .quoteString: "转为字符串字面量"
        case .unquoteString: "反转义字符串"
        case .base64Encode: "Base64 编码"
        case .base64Decode: "Base64 解码"
        case .urlEncode: "URL 编码"
        case .urlDecode: "URL 解码"
        case .camelCase: "camelCase"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .uppercase: "全大写"
        case .lowercase: "全小写"
        case .sortLines: "行排序"
        case .uniqueLines: "行去重"
        case .jwtPayload: "JWT 载荷 JSON"
        case .timestampToISO: "时间戳转 ISO 8601"
        case .isoToTimestamp: "ISO 8601 转时间戳"
        case .colorToRGB: "颜色转 rgb()"
        case .colorToHex: "颜色转 hex"
        }
    }
    /// 菜单分组：代码、JSON、编码、文本，组间加分隔线。
    public var group: Int {
        switch self {
        case .markdownCodeBlock, .dedent, .trimWhitespace, .stripPrompt, .stripLineNumbers: 0
        case .formatJSON, .minifyJSON: 1
        case .quoteString, .unquoteString, .base64Encode, .base64Decode, .urlEncode, .urlDecode: 2
        case .jwtPayload, .timestampToISO, .isoToTimestamp, .colorToRGB, .colorToHex: 4
        default: 3
        }
    }
    /// 菜单置灰依据；与apply使用同一判定，避免可选却必然失败，by AI.Coding。
    public func isApplicable(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= Self.byteLimit else { return false }
        switch self {
        case .dedent: return !Self.commonIndent(Self.lines(text)).isEmpty
        case .stripPrompt: return Self.lines(text).contains { Self.promptRange($0.content) != nil }
        case .stripLineNumbers: return Self.numberedPrefixes(Self.lines(text)) != nil
        case .formatJSON, .minifyJSON: return (try? Self.validateJSON(text)) != nil
        case .unquoteString: return (try? Self.unquote(text)) != nil
        case .base64Decode: return (try? Self.base64Decode(text)) != nil
        case .urlDecode: return (try? Self.urlDecode(text)) != nil
        case .sortLines, .uniqueLines: return Self.body(text).lines.count >= 2
        case .jwtPayload, .timestampToISO, .isoToTimestamp, .colorToRGB, .colorToHex: return (try? apply(text)) != nil
        default: return true
        }
    }
    /// language为highlight.js识别结果，只用于Markdown代码块标识。
    public func apply(_ text: String, language: String? = nil) throws -> String {
        guard text.utf8.count <= Self.byteLimit else { throw TransformError("内容过大（超过 4 MiB），无法转换") }
        switch self {
        case .markdownCodeBlock: return Self.codeBlock(text, language: language)
        case .dedent:
            let lines = Self.lines(text), indent = Self.commonIndent(lines)
            guard !indent.isEmpty else { throw notApplicable }
            return Self.join(lines.map { ($0.content.hasPrefix(indent) ? String($0.content.dropFirst(indent.count)) : $0.content, $0.ending) })
        case .trimWhitespace: return Self.trim(text)
        case .stripPrompt:
            let lines = Self.lines(text)
            guard lines.contains(where: { Self.promptRange($0.content) != nil }) else { throw notApplicable }
            return Self.join(lines.map { line in
                guard let range = Self.promptRange(line.content) else { return (line.content, line.ending) }
                var content = line.content; content.removeSubrange(range); return (content, line.ending)
            })
        case .stripLineNumbers:
            let lines = Self.lines(text)
            guard let prefixes = Self.numberedPrefixes(lines) else { throw notApplicable }
            return Self.join(zip(lines, prefixes).map { line, prefix in (String(line.content.dropFirst(prefix)), line.ending) })
        case .formatJSON: try Self.validateJSON(text); return Self.reflowJSON(text, pretty: true)
        case .minifyJSON: try Self.validateJSON(text); return Self.reflowJSON(text, pretty: false)
        case .quoteString: return Self.quote(text)
        case .unquoteString: return try Self.unquote(text)
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return try Self.base64Decode(text)
        // 按值编码（与encodeURIComponent一致），只保留RFC 3986非保留字符，&=?/等都会编码。
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? text
        case .urlDecode: return try Self.urlDecode(text)
        case .camelCase, .snakeCase, .kebabCase: return Self.join(Self.lines(text).map { (Self.recase($0.content, self), $0.ending) })
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .sortLines, .uniqueLines:
            let body = Self.body(text)
            guard body.lines.count >= 2 else { throw notApplicable }
            var seen = Set<String>()
            let lines = self == .sortLines ? body.lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending } : body.lines.filter { seen.insert($0).inserted }
            return lines.joined(separator: body.newline) + (body.trailing ? body.newline : "")
        case .jwtPayload:
            guard let parts = ContentInspector.jwtParts(text.trimmingCharacters(in: .whitespacesAndNewlines), complete: true),
                  let payload = ContentInspector.base64urlData(parts[1]) else { throw TransformError("不是完整的 JWT") }
            return Self.reflowJSON(String(decoding: payload, as: UTF8.self), pretty: true)
        case .timestampToISO:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = ContentInspector.timestamp(value) else { throw TransformError("不是 10 位秒或 13 位毫秒时间戳") }
            let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
            if value.count == 13 { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
            return formatter.string(from: date)
        case .isoToTimestamp:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines), formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return String(Int64(date.timeIntervalSince1970)) }
            // 带毫秒的时间转为13位毫秒时间戳，与"时间戳转 ISO 8601"互逆。
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else { throw TransformError("不是 ISO 8601 时间") }
            return String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        case .colorToRGB, .colorToHex:
            guard let color = ContentInspector.color(text) else { throw TransformError("不是可识别的颜色值") }
            return self == .colorToRGB ? color.rgb : color.hex
        }
    }
    private var notApplicable: TransformError { TransformError("当前内容不适用“\(title)”") }

    // MARK: 行处理：逐字符保留每行原换行符（LF/CRLF/CR），"\r\n"在Swift中是一个字符。
    typealias Line = (content: String, ending: String)
    static func lines(_ text: String) -> [Line] {
        var result: [Line] = [], current = ""
        for character in text {
            if character.isNewline { result.append((current, String(character))); current = "" } else { current.append(character) }
        }
        result.append((current, ""))
        return result
    }
    static func join(_ lines: [Line]) -> String { lines.map { $0.content + $0.ending }.joined() }
    private static func isBlank(_ value: String) -> Bool { value.allSatisfy { $0 == " " || $0 == "\t" } }
    /// 非空行共同的前导空白；空格与Tab不互换，混用时只取完全相同的前缀。
    static func commonIndent(_ lines: [Line]) -> String {
        var common: String?
        for line in lines where !isBlank(line.content) {
            let indent = String(line.content.prefix { $0 == " " || $0 == "\t" })
            guard let current = common else { common = indent; continue }
            common = String(zip(current, indent).prefix { $0 == $1 }.map(\.0))
            if common == "" { break }
        }
        return common ?? ""
    }
    /// 去首尾空行与行尾空白，保留其余行的原换行符；最后一行不带换行，便于直接粘贴。
    static func trim(_ text: String) -> String {
        var lines = lines(text).map { line -> Line in
            var content = line.content
            while let last = content.last, last == " " || last == "\t" { content.removeLast() }
            return (content, line.ending)
        }
        while let first = lines.first, first.content.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.content.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        lines[lines.count - 1].ending = ""
        return join(lines)
    }
    /// 行首"$ "或"% "（允许前导空白，保留缩进）。
    static func promptRange(_ line: String) -> Range<String.Index>? {
        guard let match = line.range(of: "^[ \\t]*[$%] ", options: .regularExpression) else { return nil }
        let indent = line[match].prefix { $0 == " " || $0 == "\t" }.count
        return line.index(match.lowerBound, offsetBy: indent)..<match.upperBound
    }
    /// 至少80%的非空行以严格递增的行号开头才判定为带行号代码；返回每行要去掉的字符数。
    /// 行号后只吃一个分隔空白，保留代码自身缩进，by AI.Coding。
    static func numberedPrefixes(_ lines: [Line]) -> [Int]? {
        guard let pattern = numberedPattern else { return nil }
        var prefixes: [Int] = [], numbered = 0, nonEmpty = 0, previous = -1
        for line in lines {
            let value = line.content as NSString
            if !isBlank(line.content) { nonEmpty += 1 }
            guard let match = pattern.firstMatch(in: line.content, range: NSRange(location: 0, length: value.length)),
                  let number = Int(value.substring(with: match.range(at: 1))) else { prefixes.append(0); continue }
            guard number > previous else { return nil }
            previous = number; numbered += 1
            prefixes.append(value.substring(with: match.range).count)
        }
        return numbered >= 2 && Double(numbered) >= Double(nonEmpty) * 0.8 ? prefixes : nil
    }
    /// 排序/去重的行集合：统一使用原文主要换行符，末尾空段不算一行。
    static func body(_ text: String) -> (lines: [String], newline: String, trailing: Bool) {
        var lines = lines(text).map(\.content)
        let trailing = lines.count > 1 && lines.last == ""
        if trailing { lines.removeLast() }
        return (lines, text.contains("\r\n") ? "\r\n" : "\n", trailing)
    }

    // MARK: Markdown代码块：围栏比正文最长的连续反引号多一个，至少三个。
    static func codeBlock(_ text: String, language: String?) -> String {
        var longest = 0, run = 0, previous: UInt8 = 0, crlf = false
        // 反引号与CRLF都是ASCII，一次按UTF-8字节扫描，1 MiB正文不逐字素遍历。
        for byte in text.utf8 {
            if byte == 0x60 { run += 1; longest = max(longest, run) } else { run = 0 }
            if previous == 0x0D, byte == 0x0A { crlf = true }
            previous = byte
        }
        let fence = String(repeating: "`", count: max(3, longest + 1)), newline = crlf ? "\r\n" : "\n"
        var tag = language ?? ""
        // highlight.js把HTML归为xml；完整网页标为html。
        if tag == "xml", text.prefix(512).lowercased().contains("<html") || text.prefix(512).lowercased().contains("<!doctype html") { tag = "html" }
        let body = text.last?.isNewline == true ? text : text + newline
        return fence + tag + newline + body + fence
    }

    // MARK: JSON：用JSONSerialization只校验并取得出错行列，输出按词法重排，保留键顺序、数字原文与转义。
    @discardableResult static func validateJSON(_ text: String) throws -> Bool {
        do { _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]); return true }
        catch {
            let detail = ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
            let numbers = ["line", "column"].compactMap { key in
                detail.range(of: key + " (\\d+)", options: .regularExpression).flatMap { Int(detail[$0].split(separator: " ")[1]) }
            }
            throw TransformError(numbers.count == 2 ? "不是有效 JSON：第 \(numbers[0]) 行第 \(numbers[1]) 列" : "不是有效 JSON")
        }
    }
    /// 只跟踪字符串与转义状态；空对象/数组保持紧凑，缩进两个空格。
    static func reflowJSON(_ text: String, pretty: Bool) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = [], depth = 0, index = 0, inString = false, escaped = false
        out.reserveCapacity(bytes.count + bytes.count / 4)
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        func newline() { guard pretty else { return }; out.append(0x0A); out.append(contentsOf: repeatElement(0x20, count: depth * 2)) }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if inString {
                out.append(byte)
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true; out.append(byte)
            case _ where isSpace(byte): continue
            case 0x7B, 0x5B:
                out.append(byte)
                var next = index
                while next < bytes.count, isSpace(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == byte + 2 { out.append(bytes[next]); index = next + 1 }
                else { depth += 1; newline() }
            case 0x7D, 0x5D: depth -= 1; newline(); out.append(byte)
            case 0x2C: out.append(byte); newline()
            case 0x3A: out.append(byte); if pretty { out.append(0x20) }
            default: out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: 字符串字面量与编码
    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    static func unquote(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
              let result = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) as? String else {
            throw TransformError("不是有效的字符串字面量")
        }
        return result
    }
    /// 兼容base64url与缺少补位；结果必须是不含NUL的UTF-8文字。
    static func base64Decode(_ text: String) throws -> String {
        var value = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard value.count >= 4, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else { throw TransformError("不是有效的 Base64") }
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { throw TransformError("不是有效的 Base64") }
        // 除换行与Tab外不允许控制字符，避免把普通单词误当Base64解出乱码。
        guard let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty,
              !decoded.unicodeScalars.contains(where: { $0.value < 0x20 && !["\n", "\r", "\t"].contains($0) }) else { throw TransformError("Base64 解码结果不是文本") }
        return decoded
    }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func urlDecode(_ text: String) throws -> String {
        guard text.contains("+") || text.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil,
              let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw TransformError("URL 解码失败：百分号编码无效") }
        return decoded
    }

    // MARK: 命名风格：按"_"、"-"、空白与大小写边界切词，保留行首缩进。
    static func words(_ value: String) -> [String] {
        var words: [String] = [], current = ""
        let characters = Array(value)
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character.isWhitespace { if !current.isEmpty { words.append(current); current = "" }; continue }
            if let previous = current.last, character.isUppercase {
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                // camelCase的小写→大写，以及HTTPServer中连续大写后接小写的边界。
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) { words.append(current); current = "" }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
    static func recase(_ line: String, _ style: TextTransform) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let parts = words(String(line.dropFirst(indent.count))).map { $0.lowercased() }
        guard !parts.isEmpty else { return line }
        switch style {
        case .camelCase: return indent + parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case .snakeCase: return indent + parts.joined(separator: "_")
        default: return indent + parts.joined(separator: "-")
        }
    }
}
/// 多选合并方式：除换行外只输出纯文本，每条记录是一个元素，按选择顺序合并，by AI.Coding。
public enum JoinStyle: String, CaseIterable, Sendable {
    case newline, blankLine, comma, space, sqlList, jsonArray, markdownList
    public var title: String {
        switch self {
        case .newline: "换行"
        case .blankLine: "空行分隔"
        case .comma: "逗号（a, b）"
        case .space: "空格（a b）"
        case .sqlList: "SQL 列表（'a', 'b'）"
        case .jsonArray: "JSON 数组（[\"a\", \"b\"]）"
        case .markdownList: "Markdown 列表（- a）"
        }
    }
    /// 换行沿用原有合并结果（含RTF/HTML），由OutputComposer原分支处理；这里只负责纯文本方式。
    public func join(_ values: [String]) -> String {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch self {
        case .newline: return values.joined(separator: "\n")
        case .blankLine: return values.joined(separator: "\n\n")
        case .comma: return trimmed.joined(separator: ", ")
        case .space: return trimmed.joined(separator: " ")
        case .sqlList: return trimmed.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
        case .jsonArray: return "[" + trimmed.map(TextTransform.quote).joined(separator: ", ") + "]"
        // 项内换行缩进两格，仍属同一列表项；CRLF等换行统一为LF。
        case .markdownList: return trimmed.map { "- " + TextTransform.lines($0).map(\.content).joined(separator: "\n  ") }.joined(separator: "\n")
        }
    }
}
