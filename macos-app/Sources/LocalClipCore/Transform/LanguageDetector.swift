// 文本／代码判定的唯一入口：先验证文档或代码结构，再验证语言专有依据；不执行输入、不访问网络，by AI.Coding。
import Foundation

/// 判定结果：语言名为nil表示普通文本或证据不足；只有完整输入的结论才能决定扩展名与格式转换。
public struct LanguageGuess: Equatable, Sendable {
    /// highlight.js 语言名，只取自 `ContentInspector.codeExtensions` 的键。
    public let language: String?
    /// 判定覆盖了完整输入；预览、截断前缀或超出预算的结果只可用于展示。
    public let complete: Bool
    /// 只是诊断候选（如结构像JSON但解析失败）：可着色、可在详情提示错误，但不是可输出的结论。
    public let diagnosticOnly: Bool
    public init(language: String?, complete: Bool, diagnosticOnly: Bool = false) {
        self.language = language; self.complete = complete; self.diagnosticOnly = diagnosticOnly
    }
    /// 导出扩展名、富文本转源码与Markdown围栏标签只能使用此值。
    public var verifiedLanguage: String? { complete && !diagnosticOnly ? language : nil }
}

public enum LanguageDetector {
    /// 完整判定的预算（UTF-16码元，密集代码约60ms）；超出时只取 `displayLimit` 前缀供展示并标记为不完整，JSON另走完整解析。
    public static let completeLimit = 32_768
    public static let displayLimit = 8_192

    /// `truncated` 表示调用方传入的已是截断样本（如卡片预览、高亮前缀），结论不得代表全文。
    public static func detect(_ text: String, truncated: Bool = false) -> LanguageGuess {
        let total = text.utf16.count
        // 超过预算的完整JSON仍能用系统解析器一次验证，保留大JSON的源码导出。
        if !truncated, total > completeLimit, text.utf8.count <= TextTransform.byteLimit, parsesAsJSONContainer(text) {
            return .init(language: "json", complete: true)
        }
        let cut = truncated || total > completeLimit
        var sample = text
        if total > completeLimit {
            var units = Array(text.utf16.prefix(displayLimit))
            if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
            sample = String(decoding: units, as: UTF16.self)
        }
        // 截断处不是自然结束：丢弃最后一个可能不完整的行。
        if cut, let newline = sample.lastIndex(where: \.isNewline) { sample = String(sample[..<newline]) }
        let name = language(of: sample, complete: !cut)
        // JSON只有解析器完整验证才可输出；结构候选（非法JSON）只供展示与详情诊断。
        return .init(language: name, complete: !cut, diagnosticOnly: !cut && name == "json" && !parsesAsJSONContainer(sample))
    }

    // MARK: 判定流程

    private static func language(of raw: String, complete: Bool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let masked = mask(raw)
        let lines = splitLines(masked)
        // 1. Markdown文档：围栏只说明其中是代码，整篇仍是Markdown。
        if isMarkdown(raw, maskedLines: lines) { return "markdown" }
        // 2. JSON：完整输入用解析器；截断或非法时只认带引号键的对象/数组结构（诊断候选，由detect标记为不可输出）。
        if trimmed.first == "{" || trimmed.first == "[" {
            if complete, parsesAsJSONContainer(trimmed) { return "json" }
            if looksLikeJSON(trimmed: trimmed, masked: masked, lines: lines, complete: complete) { return "json" }
        }
        // 3. XML/HTML/PHP 文档：首尾为标签且标签配对；单独的 `<?php` 不能确认整篇类型，交给代码规则。
        if isMarkupDocument(trimmed: trimmed, masked: masked) { return masked.contains("<?php") ? "php" : "xml" }
        // 4. 结构化配置：所有行都符合格式且有层级或节，平铺字段说明不算；块文本与值里的说明文字不按正文否决。
        if isYAML(lines) { return "yaml" }
        if isINI(lines) { return "ini" }
        // 5. 正文行占比超过两成时，整体不是代码；说明夹代码按文本处理。
        let kinds = classifyLines(lines)
        guard !kinds.isEmpty, kinds.filter({ $0 == .prose }).count * 5 <= kinds.count else { return nil }
        // 6. 代码语言：每个候选独立通过专有依据；仍有多个候选时返回未确定，不按顺序硬选。
        // 一次转成UTF-16存储，所有规则共用，避免每条正则重复桥接整段文字。
        let units = Array(masked.utf16), text = NSString(characters: units, length: units.count)
        var passed = Set(Language.allCases.filter { passes($0, text, lines: lines, raw: raw) })
        // JS/TS共用依据只算一次：有TS专有语法时是TypeScript，否则需要JS依据。
        let typeScript = hits(typeScriptOnly, text), javaScript = hits(javaScriptWeak, text), javaScriptDefinite = hits(javaScriptStrong, text) > 0
        if typeScript >= 1, typeScript + javaScript + (javaScriptDefinite ? 1 : 0) >= 2 { passed.insert(.typescript) }
        else if typeScript == 0, javaScriptDefinite || javaScript >= 2 { passed.insert(.javascript) }
        guard passed.count == 1 else { return nil }
        return passed.first?.rawValue
    }

    private static func parsesAsJSONContainer(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first, let last = value.last, (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) != nil
    }

    /// 按字节切行（LF/CRLF），比逐字素切分快；去掉行尾CR，分析副本与原文行号对齐。
    private static func splitLines(_ text: String) -> [Substring] {
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { bytes in
            let line = Substring(bytes)
            return line.hasSuffix("\r") ? line.dropLast() : line
        }
    }

    // MARK: 分析副本：只用于判定，原文、路径与换行不变

    private static let urlToken = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]{0,31}://[^\\s\"'<>()]+")
    private static let unixPath = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_)\\]])(?:~|\\.{1,2})?(?:/[\\w.@+-]+){2,}/?")
    private static let windowsPath = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Za-z]:\\\\(?:[^\\\\\\s\"'<>|]+\\\\)*[^\\\\\\s\"'<>|]*")

    /// 抹掉URL、路径、字符串内容与注释：字符串保留引号和标点，使伪代码文字不成为依据，`$x`/`${}`等结构仍可见。
    static func mask(_ text: String) -> String {
        var value = text
        for regex in [urlToken, unixPath, windowsPath] {
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        }
        var output = String.UnicodeScalarView()
        output.reserveCapacity(value.unicodeScalars.count)
        var quote: Unicode.Scalar?, tripleQuote: Unicode.Scalar?, blockComment = false, htmlComment = false, lineComment = false, escaped = false
        var previous: Unicode.Scalar = "\n"
        let scalars = Array(value.unicodeScalars)
        var index = 0
        func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }
        func hide(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            CharacterSet.alphanumerics.contains(scalar) || scalar.value > 0x2E7F ? "_" : scalar
        }
        while index < scalars.count {
            let scalar = scalars[index]
            defer { previous = scalar; index += 1 }
            if scalar == "\n" || scalar == "\r" {
                // 普通引号未闭合即止于行尾；反引号模板/原始字符串跨行保持。
                output.append(scalar); lineComment = false; escaped = false
                if quote != "`" { quote = nil }
                continue
            }
            if lineComment { output.append(" "); continue }
            if htmlComment {
                if scalar == "-", peek(1) == "-", peek(2) == ">" { htmlComment = false; output.append(contentsOf: [" ", " ", " "]); index += 2 } else { output.append(" ") }
                continue
            }
            if blockComment {
                if scalar == "*", peek(1) == "/" { blockComment = false; output.append(" "); output.append(" "); index += 1 } else { output.append(" ") }
                continue
            }
            if let open = tripleQuote {
                if scalar == open, peek(1) == open, peek(2) == open { tripleQuote = nil; output.append(contentsOf: [scalar, scalar, scalar]); index += 2 }
                else { output.append(hide(scalar)) }
                continue
            }
            if let open = quote {
                if escaped { escaped = false; output.append(hide(scalar)); continue }
                if scalar == "\\" { escaped = true; output.append(scalar); continue }
                if scalar == open { quote = nil; output.append(scalar) } else { output.append(hide(scalar)) }
                continue
            }
            let atBoundary = previous == "\n" || CharacterSet.whitespaces.contains(previous)
            if (scalar == "\"" || scalar == "'"), peek(1) == scalar, peek(2) == scalar {
                tripleQuote = scalar; output.append(contentsOf: [scalar, scalar, scalar]); index += 2; continue
            }
            // 英文缩写中的撇号（don't）不是字符串起点。
            if scalar == "\"" || scalar == "`" || (scalar == "'" && !CharacterSet.letters.contains(previous)) {
                quote = scalar; output.append(scalar); continue
            }
            if scalar == "/", peek(1) == "*" { blockComment = true; output.append(" "); continue }
            if scalar == "/", peek(1) == "/", atBoundary || previous == ";" || previous == "}" { lineComment = true; output.append(" "); continue }
            if scalar == "<", peek(1) == "!", peek(2) == "-", peek(3) == "-" { htmlComment = true; output.append(" "); continue }
            if scalar == "#", atBoundary, peek(1) == nil || peek(1) == " " || peek(1) == "\t", !isDirective(scalars[(index + 1)...]) {
                lineComment = true; output.append(" "); continue
            }
            if scalar == "-", peek(1) == "-", atBoundary, peek(2) == " " { lineComment = true; output.append(" "); continue }
            output.append(scalar)
        }
        return String(output)
    }

    private static let directive = try! NSRegularExpression(pattern: "\\A[ \\t]+(?:include[ \\t]*[<\"]|(?:define|undef|ifdef|ifndef)[ \\t]+[A-Z_]|endif[ \\t]*$)")
    /// `# include <x.h>` 等带空格的预处理指令不是 `#` 注释；只看本行开头，不扫描全文。
    private static func isDirective(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
        var line = String.UnicodeScalarView()
        for scalar in rest.prefix(40) { if scalar == "\n" || scalar == "\r" { break }; line.append(scalar) }
        let text = String(line)
        return directive.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: 行分类：正文行与代码形状行

    private enum LineKind { case code, prose, neutral }
    private static let cjkRanges: [ClosedRange<UInt32>] = [0x3000...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF]
    private static let callShape = try! NSRegularExpression(pattern: "(?<![\\w$.])[A-Za-z_$][\\w$.]*\\([^()]{0,240}\\)(?=\\s*$|\\s*[;{:,)\\]]|\\.)")
    private static let assignmentShape = try! NSRegularExpression(pattern: "^\\s*(?:(?:let|const|var|val|my|local|export|auto|int|float|double|bool|string)\\s+)?[A-Za-z_$][\\w$.\\[\\]]*\\s*(?:[-+*/|&]?=|:=)\\s*[^=\\s]")
    private static let quotedKeyLine = try! NSRegularExpression(pattern: "^\"[^\"]*\"\\s*:")
    private static let dollarShape = try! NSRegularExpression(pattern: "\\$[A-Za-z_{(]")
    private static let operators = ["=>", "->", "::", ":=", "==", "!=", "&&", "||", "+=", "-=", "++", "</", "/>", "${", "$("]

    private static func classify(_ line: Substring) -> LineKind? {
        var slice = line
        while let first = slice.first, first == " " || first == "\t" { slice.removeFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice.removeLast() }
        guard !slice.isEmpty else { return nil }
        let text = String(slice)
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let words = tokens.filter(isWord).count
        let ratio = Double(words) / Double(tokens.count)
        if words >= 6, ratio >= 0.8 { return .prose }
        if hasCodeShape(text, tokens: tokens) { return .code }
        if words >= 3, ratio >= 0.6 { return .prose }
        let visible = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let cjk = visible.filter { scalar in cjkRanges.contains { $0.contains(scalar.value) } }.count
        if !visible.isEmpty, Double(cjk) / Double(visible.count) >= 0.3 { return .prose }
        return .neutral
    }

    /// 代码块头（以 `:` 或 `{` 结尾的代码行）之下更深缩进、且不以句读结束的行属于块体，例如 `return x if x is not None else y`。
    private static func classifyLines(_ lines: [Substring]) -> [LineKind] {
        var kinds: [LineKind] = [], headers: [Int] = []
        for line in lines {
            guard var kind = classify(line) else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            while let open = headers.last, indent <= open { headers.removeLast() }
            let last = line.last { !$0.isWhitespace }
            if kind == .prose, !headers.isEmpty, let last, !".!?。！？".contains(last) { kind = .code }
            if kind == .code, last == ":" || last == "{" { headers.append(indent) }
            kinds.append(kind)
        }
        return kinds
    }

    /// 自然语言单词：字母开头，其余小写，可带撇号与句读；全大写缩写、标识符与符号都不算。
    private static func isWord(_ token: Substring) -> Bool {
        var core = token[...]
        while let first = core.first, "([\"'“‘".contains(first) { core.removeFirst() }
        while let last = core.last, ",.;:!?)]\"'”’".contains(last) { core.removeLast() }
        guard let first = core.first, first.isASCII, first.isLetter else { return false }
        return core.dropFirst().allSatisfy { ($0.isASCII && $0.isLowercase) || $0 == "'" || $0 == "’" }
    }

    private static func hasCodeShape(_ text: String, tokens: [Substring]) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        if "{};([\\".contains(last) || text.hasSuffix("=>") || text.hasSuffix("->") || text.hasSuffix("):") { return true }
        if last == ":", let keyword = tokens.first, ["if", "elif", "else", "for", "while", "with", "try", "except", "finally", "def", "class", "case"].contains(keyword) { return true }
        if "}])".contains(first) || (first == "@" && text.dropFirst().first?.isLetter == true) { return true }
        if first == "<", let second = text.dropFirst().first, second.isLetter || "/!?".contains(second), text.contains(">") { return true }
        if ["#include", "#define", "#import", "#!", "#[", "#if", "#endif", "#pragma"].contains(where: text.hasPrefix) { return true }
        if operators.contains(where: text.contains) { return true }
        let range = NSRange(text.startIndex..., in: text)
        if [quotedKeyLine, dollarShape, callShape, assignmentShape].contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        // 命令行参数：小写命令后跟 -x/--flag。
        if let command = tokens.first, command.first?.isLowercase == true, command.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }),
           tokens.dropFirst().contains(where: isFlag) { return true }
        return false
    }
    private static func isFlag(_ token: Substring) -> Bool {
        let body = token.drop { $0 == "-" }
        guard (1...2).contains(token.count - body.count), let first = body.first, first.isASCII, first.isLetter else { return false }
        return body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: 文档类结构

    private static func isMarkdown(_ raw: String, maskedLines: [Substring]) -> Bool {
        let rawLines = raw.prefix(16_384).split(whereSeparator: \.isNewline)
        let fences = rawLines.filter { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasPrefix("```") || t.hasPrefix("~~~") }.count
        guard fences >= 2 || ContentInspector.looksLikeMarkdown(raw) else { return false }
        // 围栏外仍以代码形状为主（例如带标题注释的脚本）时不当作Markdown；分析副本与原文逐行对齐。
        var inFence = false, code = 0, classified = 0
        for (line, masked) in zip(splitLines(raw), maskedLines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, !t.hasPrefix("#") else { continue }
            switch classify(masked) { case .code: code += 1; classified += 1; case .prose, .neutral: classified += 1; case nil: break }
        }
        return code * 5 <= max(classified, 1)
    }

    private static let quotedKey = try! NSRegularExpression(pattern: "\"[^\"\\n]*\"\\s*:")
    private static let looseKey = try! NSRegularExpression(pattern: "(?m)^\\s*[A-Za-z_]\\w*\\s*:")
    private static let pythonLiteral = try! NSRegularExpression(pattern: "\\b(?:True|False|None)\\b")
    /// 结构像JSON：完整输入须以对应括号结束，不含Python字面值，也没有正文行。
    private static func looksLikeJSON(trimmed: String, masked: String, lines: [Substring], complete: Bool) -> Bool {
        if complete, trimmed.last != (trimmed.first == "{" ? "}" : "]") { return false }
        let range = NSRange(masked.startIndex..., in: masked)
        guard quotedKey.firstMatch(in: masked, range: range) != nil, looseKey.firstMatch(in: masked, range: range) == nil,
              pythonLiteral.firstMatch(in: masked, range: range) == nil, !lines.contains(where: { classify($0) == .prose }) else { return false }
        return !["function", "=>", ";\n", "};"].contains(where: masked.contains) && !masked.hasSuffix(";")
    }

    private static let tag = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][\\w:.-]*)(?:\\s[^<>]*)?>")
    private static func isMarkupDocument(trimmed: String, masked: String) -> Bool {
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return false }
        var opened = Set<String>(), closed = Set<String>(), count = 0
        for match in tag.matches(in: masked, range: NSRange(masked.startIndex..., in: masked)).prefix(4_096) {
            guard let nameRange = Range(match.range(at: 2), in: masked), let slash = Range(match.range(at: 1), in: masked) else { continue }
            let name = masked[nameRange].lowercased()
            if masked[slash].isEmpty { opened.insert(name) } else { closed.insert(name) }
            count += 1
        }
        if !opened.isDisjoint(with: closed) { return true }
        let lower = trimmed.prefix(64).lowercased()
        return count >= 1 && (lower.hasPrefix("<?xml") || lower.hasPrefix("<!doctype"))
    }

    private static let yamlKey = try! NSRegularExpression(pattern: "^(\\s*)(-\\s+)?(?:\"[^\"]*\"|'[^']*'|[A-Za-z_][\\w.-]*)\\s*:(?:\\s+(.*))?$")
    private static let yamlItem = try! NSRegularExpression(pattern: "^(\\s*)-(?:\\s+\\S.*)?$")
    /// 所有行都是键值、列表或文档标记，且至少有一层嵌套映射或文档分隔；平铺字段说明保留为文本。
    private static func isYAML(_ lines: [Substring]) -> Bool {
        var nested = false, marker = false, keys = 0
        var pendingParent: Int?   // 空值键的缩进
        var blockIndent: Int?     // `key: |` 块文本
        for line in lines {
            let text = String(line)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = text.prefix { $0 == " " }.count
            if let block = blockIndent { if indent > block { continue }; blockIndent = nil }
            if text == "---" || text == "..." { marker = true; continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = yamlKey.firstMatch(in: text, range: range) {
                keys += 1
                let isItem = match.range(at: 2).location != NSNotFound
                if let parent = pendingParent, indent > parent || (indent == parent && isItem) { nested = true }
                let value = Range(match.range(at: 3), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) } ?? ""
                pendingParent = value.isEmpty ? indent + (isItem ? 2 : 0) : nil
                if value == "|" || value == ">" || value.hasPrefix("|-") || value.hasPrefix(">-") { blockIndent = indent }
            } else if yamlItem.firstMatch(in: text, range: range) != nil {
                pendingParent = nil
            } else { return false }
        }
        return keys >= 2 && (nested || marker)
    }

    private static let iniSection = try! NSRegularExpression(pattern: "^\\[[\\w .:\"-]+\\]$")
    private static let iniPair = try! NSRegularExpression(pattern: "^[\\w.-]+\\s*=")
    private static func isINI(_ lines: [Substring]) -> Bool {
        var sections = 0, pairs = 0
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix(";") { continue }
            let range = NSRange(text.startIndex..., in: text)
            if iniSection.firstMatch(in: text, range: range) != nil { sections += 1 }
            else if iniPair.firstMatch(in: text, range: range) != nil { pairs += 1 }
            else { return false }
        }
        return sections >= 1 && pairs >= 1
    }

    // MARK: CSS：选择器＋声明块或已知属性声明

    private static let cssProperties: Set<String> = [
        "align-content", "align-items", "align-self", "animation", "animation-delay", "animation-duration", "animation-name", "animation-timing-function",
        "background", "background-color", "background-image", "background-position", "background-repeat", "background-size", "border", "border-bottom",
        "border-color", "border-left", "border-radius", "border-right", "border-style", "border-top", "border-width", "bottom", "box-shadow", "box-sizing",
        "color", "content", "cursor", "display", "fill", "filter", "flex", "flex-basis", "flex-direction", "flex-grow", "flex-shrink", "flex-wrap", "float",
        "font", "font-family", "font-size", "font-style", "font-weight", "gap", "grid", "grid-area", "grid-column", "grid-row", "grid-template-columns",
        "grid-template-rows", "height", "justify-content", "justify-items", "left", "letter-spacing", "line-height", "list-style", "margin", "margin-bottom",
        "margin-left", "margin-right", "margin-top", "max-height", "max-width", "min-height", "min-width", "object-fit", "opacity", "outline", "overflow",
        "overflow-x", "overflow-y", "padding", "padding-bottom", "padding-left", "padding-right", "padding-top", "pointer-events", "position", "right",
        "row-gap", "column-gap", "src", "stroke", "text-align", "text-decoration", "text-overflow", "text-transform", "top", "transform", "transition",
        "user-select", "vertical-align", "visibility", "white-space", "width", "word-break", "word-wrap", "z-index"]

    private static func isCSSDeclaration(_ part: Substring) -> Bool {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return false }
        let property = text[..<colon].trimmingCharacters(in: .whitespaces), value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.contains(":") || value.contains("url(") else { return false }
        if property.hasPrefix("--") { return property.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
        let name = ["-webkit-", "-moz-", "-ms-", "-o-"].first(where: property.hasPrefix).map { String(property.dropFirst($0.count)) } ?? property
        return cssProperties.contains(name)
    }

    /// 至少一个最内层块的内容全部是已知属性声明，且选择器只含选择器字符；单遍扫描，避免正则回溯。
    private static func hasCSSRule(_ masked: String) -> Bool {
        var selectorStart = masked.startIndex
        var open: (selector: Substring, body: String.Index)?
        for index in masked.indices {
            let next = masked.index(after: index)
            switch masked[index] {
            case "{": open = (masked[selectorStart..<index], next); selectorStart = next
            case "}":
                if let block = open, isCSSRule(selector: block.selector, body: masked[block.body..<index]) { return true }
                open = nil; selectorStart = next
            case ";": selectorStart = next
            default: break
            }
        }
        return false
    }
    private static let cssSelector = try! NSRegularExpression(pattern: "^[@\\w\\s.#:*>+~,\\[\\]=\"'()%^$|-]+$")
    private static let codeKeyword = try! NSRegularExpression(pattern: "\\b(function|if|for|while|class|return|switch|=>)\\b")
    private static func isCSSRule(selector raw: Substring, body: Substring) -> Bool {
        let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(selector.startIndex..., in: selector)
        guard !selector.isEmpty, cssSelector.firstMatch(in: selector, range: range) != nil, codeKeyword.firstMatch(in: selector, range: range) == nil else { return false }
        let parts = body.split(separator: ";").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !parts.isEmpty && parts.allSatisfy(isCSSDeclaration)
    }

    /// 无花括号的孤立声明：每个非空行都是 `已知属性: 值;`。
    private static func isCSSOnly(_ lines: [Substring]) -> Bool {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return !content.isEmpty && content.allSatisfy { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasSuffix(";") && text.dropLast().split(separator: ";").allSatisfy(isCSSDeclaration)
        }
    }

    // MARK: 代码语言专有依据

    private enum Language: String, CaseIterable {
        case java, python, javascript, typescript, css, bash, swift, sql, cpp, csharp, go, ruby, php, rust
    }
    /// strong 任一命中即成立；weak 需命中至少两种不同依据。共享语法不列入，避免公共关键词制造伪证据。
    /// excluded：出现即说明是另一种语言（如C#的using、Kotlin的fun），即使共享API命中也不成立。
    private struct Rule { var strong: [NSRegularExpression] = []; var weak: [NSRegularExpression] = []; var excluded: [NSRegularExpression] = [] }
    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.map { try! NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    }
    private static let shellCommands = "(?:sudo\\s+)?(?:echo|export|cd|ls|grep|awk|sed|cat|curl|wget|chmod|chown|mkdir|rm|cp|mv|git|npm|npx|yarn|pnpm|pip3?|brew|apt(?:-get)?|docker|kubectl|make|ssh|scp|tar|find|xargs|swift|xcodebuild|python3?|node|go|cargo|rtk|defaults|launchctl|open|killall|ps|kill|touch|ln|unzip|zip|du|df|head|tail|sort|less|man|which|env|source|alias)"
    private static let sqlClause = "(?:WHERE|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|NATURAL|ORDER|GROUP|LIMIT|OFFSET|HAVING|UNION|EXCEPT|INTERSECT|WINDOW|FOR)"
    private static let rules: [Language: Rule] = [
        .bash: Rule(
            strong: compile(["^\\s*(?:\\$\\s+)?" + shellCommands + "\\s+(?:[\\w.@:+=-]+\\s+){0,2}-{1,2}[A-Za-z][\\w-]*",
                             "^\\s*(?:if|elif|while)\\s+\\[\\[?\\s[^\\n]{0,240}\\]\\]?\\s*;\\s*(?:then|do)\\b",
                             "\\bfor\\s+\\w+\\s+in\\s[^\\n;]{0,240};\\s*do\\b"]),
            weak: compile(["\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", "\\$\\(", "(?:2>&1|&>|>>|2>|>\\s*/dev/null)",
                           "\\|\\s*(?:grep|awk|sed|xargs|sort|uniq|head|tail|wc|tee|cut|tr|less|jq)\\b", "^\\s*(?:fi|done|esac)\\s*;?\\s*$",
                           "^\\s*(?:export\\s+)?[A-Za-z_][A-Za-z0-9_]*=(?:[\"'$(]|\\S+\\s*$)", "^\\s*(?:\\$\\s+)?" + shellCommands + "\\s+\\S",
                           "&&\\s*" + shellCommands + "\\b"]),
            excluded: compile(["<\\?php\\b"])),
        .python: Rule(
            strong: compile(["^\\s*(?:async\\s+)?def\\s+[A-Za-z_]\\w*\\s*\\([^)\\n]{0,240}\\)\\s*(?:->\\s*[^:\\n]{1,120})?:\\s*$",
                             "^\\s*class\\s+[A-Z]\\w*\\s*(?:\\([^)\\n]{0,240}\\))?:\\s*$", "^\\s*from\\s+[a-z_.][\\w.]*\\s+import\\s+(?:\\*|\\(|[A-Za-z_][\\w, ]*$)",
                             "\\bif\\s+__name__\\s*=="]),
            weak: compile(["^\\s*(?:elif\\s[^\\n]{0,240}|else|try|finally|except(?:\\s[^\\n]{0,240})?|with\\s[^\\n]{0,240}\\sas\\s\\w+|for\\s+[\\w, ]+\\s+in\\s[^\\n]{0,240}|while\\s[^\\n]{0,240})\\s*:\\s*$",
                           "\\bself\\.\\w+", "^\\s*import\\s+[a-z_][\\w.]*(?:\\s+as\\s+\\w+)?\\s*$", "\\bprint\\(", "\\b(?:None|True|False)\\b",
                           "\\blambda\\s+[\\w, ]*:", "\\b(?:len|range|enumerate|isinstance)\\(", "^\\s*@[a-z_][\\w.]*\\s*$"])),
        .ruby: Rule(
            strong: compile(["^\\s*require(?:_relative)?\\s+[\"']", "\\battr_(?:accessor|reader|writer)\\s+:"]),
            weak: compile(["^\\s*def\\s+(?:self\\.)?[a-z_]\\w*[?!=]?(?:\\([^)\\n]{0,240}\\))?\\s*$", "^\\s*end\\s*$", "\\bdo\\s*\\|[\\w, ]+\\|",
                           "^\\s*puts\\s", "^\\s*(?:module|class)\\s+[A-Z]\\w*(?:\\s*<\\s*[A-Z][\\w:]*)?\\s*$", "#\\{", ":\\w+\\s*=>",
                           "\\.each(?:_with_index)?\\s*(?:do|\\{)", "^\\s*(?:unless|elsif)\\s"])),
        .php: Rule(
            strong: compile(["\\$this->\\w+"]),
            weak: compile(["<\\?php\\b", "\\$[a-z_]\\w*\\s*=[^=>]", "\\$\\w+->\\w+", "\\bfunction\\s+\\w+\\s*\\([^)\\n]{0,240}\\$\\w+", "(?:^\\s*|<\\?php\\s+)echo\\s+[\"'$]",
                           "\\barray\\(", "^\\s*namespace\\s+[\\w\\\\]+;", "^\\s*use\\s+[A-Z][\\w\\\\]+;"])),
        .java: Rule(
            strong: compile(["\\bpublic\\s+static\\s+void\\s+main\\s*\\(\\s*String", "\\bSystem\\.(?:out|err)\\.print",
                             "^\\s*package\\s+[a-z]\\w*(?:\\.\\w+)+\\s*;", "^\\s*import\\s+(?:static\\s+)?(?:java|javax|jakarta|org|com|android|lombok)\\.[\\w.]+(?:\\.\\*)?\\s*;"]),
            weak: compile(["@(?:Override|Autowired|Service|Component|RestController|Entity|Bean|FunctionalInterface)\\b",
                           "\\b(?:public|private|protected)\\s+(?:static\\s+)?(?:final\\s+)?(?:[A-Z]\\w*(?:<[^>\\n]{0,120}>)?(?:\\[\\])?|void|int|long|boolean|double|float|char)\\s+[a-z]\\w*\\s*\\(",
                           "\\bthrows\\s+[A-Z]\\w*", "\\bString(?:\\[\\])?\\s+[a-z]\\w*\\s*[=;,)]", "\\b(?:ArrayList|HashMap|HashSet)<",
                           "\\bboolean\\s+[a-z]\\w*\\s*[=;,)]", "\\.equals\\(", "\\bfinal\\s+[A-Z]\\w*\\s+[a-z]\\w*\\s*="]),
            excluded: compile(["^\\s*using\\s+[\\w.]+\\s*;", "\\bConsole\\.Write", "^\\s*namespace\\s+[A-Z]",
                               "^\\s*(?:(?:private|public|internal|override|suspend)\\s+)*fun\\s+\\w+\\s*\\(", "^\\s*(?:case\\s+)?object\\s+[A-Z]\\w*",
                               "^\\s*def\\s+\\w+", "\\bval\\s+\\w+", ":\\s*Unit\\b"])),
        .csharp: Rule(
            strong: compile(["^\\s*using\\s+System(?:\\.[\\w.]+)?\\s*;", "\\bConsole\\.Write(?:Line)?\\s*\\(", "^\\s*namespace\\s+[A-Z]\\w*(?:\\.\\w+)+\\s*[{;]?\\s*$",
                             "\\{\\s*get;\\s*(?:(?:private\\s+|protected\\s+)?(?:set|init);)?\\s*\\}"]),
            weak: compile(["\\b(?:public|private|internal|protected)\\s+(?:string|int|bool|double|decimal|long)\\s+[A-Z]\\w*\\b", "\\bstring\\[\\]",
                           "\\b(?:public|private|internal|protected)\\s+(?:static\\s+)?(?:async\\s+)?(?:override\\s+)?(?:void|int|string|bool|Task(?:<[^>\\n]{0,120}>)?|[A-Z]\\w*)\\s+[A-Z]\\w*\\s*\\(",
                           "\\bforeach\\s*\\(\\s*var\\b", "^\\s*\\[[A-Z]\\w*(?:\\([^)\\n]{0,240}\\))?\\]\\s*$", "\\b(?:string|bool)\\s+[a-z]\\w*\\s*[=;,)]",
                           "\\bawait\\s+\\w+Async\\(", "\\binternal\\s+(?:class|static|sealed)\\b"])),
        .cpp: Rule(
            strong: compile(["^\\s*#\\s*include\\s*[<\"]", "\\bstd::\\w+", "\\b(?:cout|cerr)\\s*<<", "^\\s*template\\s*<"]),
            weak: compile(["\\bint\\s+main\\s*\\(", "\\bnullptr\\b", "^\\s*#\\s*(?:define|ifndef|ifdef|endif|pragma)\\b", "\\b(?:unsigned|size_t|uint\\d+_t)\\b",
                           "\\bvirtual\\s", "\\b(?:printf|malloc|free|sizeof)\\s*\\(", "^\\s*(?:public|private|protected):\\s*$", "\\w->\\w+\\s*[(;=]"])),
        .go: Rule(
            strong: compile(["\\bfunc\\s+main\\s*\\(\\s*\\)", "\\bif\\s+err\\s*!=\\s*nil\\b", "\\bfmt\\.(?:Print|Sprint|Fprint|Errorf)",
                             // 参数为 `名称 类型`（无冒号），Swift/Kotlin 等用 `名称: 类型`。
                             "\\bfunc\\s+(?:\\([^)\\n]{0,120}\\)\\s*)?[A-Za-z_]\\w*\\s*\\(\\s*[A-Za-z_]\\w*(?:\\s*,\\s*[A-Za-z_]\\w*)*\\s+(?:\\*|\\[\\]|\\.\\.\\.)?[A-Za-z_][\\w.]*\\s*[,)]"]),
            weak: compile(["^\\s*package\\s+[a-z]\\w*\\s*$", "^\\s*import\\s+(?:\\(|\")",
                           "\\bfunc\\s+(?:\\(\\s*\\w+\\s+\\*?\\w+\\s*\\)\\s*)?[A-Za-z]\\w*\\s*\\([^)\\n:]{0,240}\\)[\\w*\\[\\]().,\\t ]*\\{",
                           ":=", "\\bgo\\s+func\\b", "\\bchan\\s+\\w", "\\bdefer\\s+\\w", "^\\s*type\\s+\\w+\\s+(?:struct|interface)\\s*\\{", "\\[\\]string\\b|\\bmap\\[string\\]"])),
        .rust: Rule(
            strong: compile(["\\bfn\\s+\\w+\\s*(?:<[^>\\n]{0,120}>)?\\s*\\([^)\\n]{0,240}\\)\\s*(?:->\\s*[^{\\n]{1,120})?\\{", "\\blet\\s+mut\\s",
                             "\\b(?:println|eprintln|format|vec|panic)!\\(", "^\\s*use\\s+(?:std|crate|super|self)::", "#\\[(?:derive|test|cfg)\\b",
                             "^\\s*impl(?:<[^>\\n]{0,120}>)?\\s+\\w+"]),
            weak: compile(["&str\\b", "\\b(?:Option|Result|Vec)<", "\\bmatch\\s+\\w+\\s*\\{", "\\bpub\\s+(?:fn|struct|enum|mod)\\b", "::new\\("])),
        .swift: Rule(
            strong: compile(["^\\s*import\\s+(?:UIKit|Foundation|SwiftUI|AppKit|Combine|XCTest|Testing)\\s*$",
                             "\\bfunc\\s+\\w+\\s*(?:<[^>\\n]{0,120}>)?\\s*\\([^)\\n]{0,240}\\w\\s*:\\s*[^)\\n]{0,240}\\)",
                             "\\bfunc\\s+\\w+\\s*(?:<[^>\\n]{0,120}>)?\\s*\\([^)\\n]{0,240}\\)\\s*(?:async\\s+)?(?:throws\\s+)?->\\s*[A-Z\\[(]",
                             "\\bguard\\s+let\\b", "\\bif\\s+let\\s+\\w+\\s*=", "@(?:State|Published|MainActor|ObservedObject|Binding|objc|escaping|StateObject)\\b"]),
            // `func`、`print(` 与Go等共享，不作依据。
            weak: compile(["\\b(?:let|var)\\s+\\w+\\s*:\\s*[A-Z\\[]\\w*", "(?<![\\w.])struct\\s+\\w+\\s*(?::\\s*[\\w, ]+)?\\s*\\{", "\\?\\?",
                           "^\\s*let\\s+\\w+\\s*="])),
        .sql: Rule(
            // 语句须在行首、分号或左括号之后开始，FROM表名后只能是别名、子句或语句结束，日志前缀与大写正文不成立。
            strong: compile(["(?i)(?:^|[;(])\\s*SELECT\\s+(?:DISTINCT\\s+)?(?:\\*|[\\w.]+(?:\\s+AS\\s+\\w+)?(?:\\s*,\\s*[\\w.()*]+(?:\\s+AS\\s+\\w+)?)*|COUNT\\s*\\([^)\\n]{0,240}\\))\\s+FROM\\s+[\\w.]+(?:\\s+(?:AS\\s+)?(?!" + sqlClause + "\\b)\\w+)?\\s*(?:$|[;)]|" + sqlClause + "\\b)",
                             "(?i)(?:^|[;(])\\s*INSERT\\s+INTO\\s+[\\w.]+\\s*(?:\\(|VALUES\\b|SELECT\\b)", "(?i)(?:^|;)\\s*UPDATE\\s+[\\w.]+\\s+SET\\s+[\\w.]+\\s*=",
                             "(?i)(?:^|;)\\s*DELETE\\s+FROM\\s+[\\w.]+\\s*(?:$|;|(?:WHERE|USING|RETURNING)\\b)", "(?i)(?:^|;)\\s*CREATE\\s+(?:TABLE|INDEX|VIEW|DATABASE|UNIQUE\\s+INDEX)\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?[\\w.]+",
                             "(?i)(?:^|;)\\s*ALTER\\s+TABLE\\s+[\\w.]+\\s+(?:ADD|DROP|ALTER|RENAME)\\b"]),
            weak: compile(["(?i)\\bWHERE\\s+[\\w.]+\\s*(?:=|<>|!=|<|>|\\bLIKE\\b|\\bIN\\b|\\bIS\\b)", "(?i)\\bJOIN\\s+[\\w.]+(?:\\s+\\w+)?\\s+ON\\b",
                           "\\bGROUP\\s+BY\\b", "\\bORDER\\s+BY\\s+[\\w.]+", "\\b(?:VARCHAR|INTEGER|PRIMARY\\s+KEY|NOT\\s+NULL)\\b"])),
        .css: Rule(),
        .typescript: Rule(), .javascript: Rule()
    ]
    private static let typeScriptOnly = compile([
        "(?<![\\w\"'])[A-Za-z_$][\\w$]*\\??\\s*:\\s*(?:string|number|boolean|any|unknown|never|void|object|bigint)(?:\\[\\])?\\s*(?:[,;)=|&{>]|$)",
        "^\\s*(?:export\\s+)?interface\\s+[A-Z]\\w*(?:<[^>\\n]{0,120}>)?\\s*(?:extends\\s+[\\w<>, .]+)?\\{",
        "^\\s*(?:export\\s+)?type\\s+[A-Z]\\w*(?:<[^>\\n]{0,120}>)?\\s*=", "\\bas\\s+(?:const|string|number|any|unknown)\\b",
        "\\b(?:private|public|protected|readonly)\\s+\\w+\\s*\\??:\\s*\\w", "\\)\\s*:\\s*(?:Promise<|void\\b|string\\b|number\\b|boolean\\b)"])
    private static let javaScriptStrong = compile(["\\bfunction\\s*\\*?\\s*[\\w$]+\\s*\\([^)$\\n]{0,240}\\)\\s*\\{"])
    private static let javaScriptWeak = compile([
        "\\b(?:const|let|var)\\s+[A-Za-z_$\\[{][\\w$, \\]}]*\\s*=[^=]", "\\([^)\\n]{0,240}\\)\\s*=>", "\\bconsole\\.(?:log|error|warn|info)\\(",
        "\\brequire\\(\\s*[\"']", "\\bmodule\\.exports\\b|\\bexports\\.\\w+\\s*=", "\\b(?:document|window)\\.\\w+", "===|!==",
        "^\\s*import\\s+(?:[\\w*{}\\s,]+\\s+from\\s+)?[\"']", "^\\s*export\\s+(?:default|const|function|class|async)\\b",
        "\\.then\\(|\\bawait\\s+fetch\\(|\\bnew\\s+Promise\\(", "`[^`\\n]{0,240}\\$\\{"])

    private static func has(_ regex: NSRegularExpression, _ text: NSString) -> Bool {
        regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) != nil
    }
    private static func hits(_ regexes: [NSRegularExpression], _ text: NSString) -> Int { regexes.reduce(0) { $0 + (has($1, text) ? 1 : 0) } }

    private static let shebang = try! NSRegularExpression(pattern: "\\A#!\\s*/(?:usr/)?(?:local/)?bin/(?:env\\s+)?(?:ba|z|k|da)?sh\\b")
    private static func passes(_ language: Language, _ masked: NSString, lines: [Substring], raw: String) -> Bool {
        switch language {
        case .css: return hasCSSRule(masked as String) || isCSSOnly(lines)
        case .typescript, .javascript: return false   // 由调用方一次性计算
        case .bash where shebang.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil: return true
        default:
            guard let rule = rules[language] else { return false }
            guard !rule.excluded.contains(where: { has($0, masked) }) else { return false }
            return rule.strong.contains { has($0, masked) } || hits(rule.weak, masked) >= 2
        }
    }
}
