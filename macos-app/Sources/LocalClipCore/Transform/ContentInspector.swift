// 剪贴板内容的纯规则判断：导出文件格式、文件名与Markdown识别；不依赖AppKit，便于单测，by AI.Coding。
import Foundation
public enum ContentInspector {
    /// highlight.js语言名到常见扩展名；只含卡片识别集合内的语言，by AI.Coding。
    public static let codeExtensions: [String: String] = [
        "json": "json", "java": "java", "python": "py", "javascript": "js", "typescript": "ts", "yaml": "yaml",
        "xml": "xml", "css": "css", "bash": "sh", "swift": "swift", "sql": "sql", "cpp": "cpp", "csharp": "cs",
        "go": "go", "ruby": "rb", "php": "php", "rust": "rs", "ini": "ini", "markdown": "md"]
    /// 导出租约只接受这些文字扩展名，防止拼接出路径，by AI.Coding。
    public static let textExtensions: Set<String> = Set(codeExtensions.values).union(["txt", "md", "rtf", "html"])
    public enum ExportFormat: Equatable, Sendable {
        /// 写UTF-8纯文本（无BOM、保留原换行）。
        case plain(String)
        /// 原样写出已保存的表示字节。
        case original(type: String, fileExtension: String)
        public var fileExtension: String { switch self { case .plain(let value): value; case .original(_, let value): value } }
    }
    /// 代码与Markdown优先于RTF/HTML：AI对话与编辑器复制的代码通常附带HTML，开发者要的是源码文件，by AI.Coding。
    public static func exportFormat(plainText: String, language: String?, types: [String], markup: String?) -> ExportFormat {
        let rich = types.contains(SupportedType.rtf) || types.contains(SupportedType.html)
        if let language, let ext = codeExtensions[language], !rich || looksLikeCodeMarkup(markup ?? "") {
            // highlight.js把HTML归为xml；完整网页仍按.html保存。
            if language == "xml", plainText.prefix(512).lowercased().contains("<html") || plainText.prefix(512).lowercased().contains("<!doctype html") { return .plain("html") }
            return .plain(ext)
        }
        if looksLikeMarkdown(plainText) { return .plain("md") }
        if types.contains(SupportedType.rtf) { return .original(type: SupportedType.rtf, fileExtension: "rtf") }
        if types.contains(SupportedType.html) { return .original(type: SupportedType.html, fileExtension: "html") }
        return .plain("txt")
    }
    /// 富文本只有带代码排版标记时才按源码导出，邮件等正文仍保留RTF格式。
    /// ponytail: 关键词启发式，含行内<code>的对话正文可能被当源码；误判明显时改为比较代码块占正文比例。
    public static func looksLikeCodeMarkup(_ markup: String) -> Bool {
        let value = markup.prefix(65_536).lowercased()
        return ["<pre", "<code", "monospace", "menlo", "monaco", "courier", "sfmono", "sf mono", "consolas", "jetbrains mono", "fira code"].contains { value.contains($0) }
    }
    /// 标题、代码围栏、列表、链接四种特征至少命中两种才算Markdown，单个"#"或"-"不足以判定，by AI.Coding。
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.prefix(16_384).split(whereSeparator: \.isNewline).prefix(400).map(String.init)
        func matches(_ line: String, _ pattern: String) -> Bool { line.range(of: pattern, options: .regularExpression) != nil }
        var signals = 0
        if lines.contains(where: { matches($0, "^#{1,6} \\S") }) { signals += 1 }
        if lines.contains(where: { $0.hasPrefix("```") || $0.hasPrefix("~~~") }) { signals += 1 }
        if lines.filter({ matches($0, "^\\s*([-*+]|\\d+\\.) \\S") }).count >= 2 { signals += 1 }
        if lines.contains(where: { matches($0, "\\[[^\\]]+\\]\\([^)\\s]+\\)") }) { signals += 1 }
        return signals >= 2
    }
    /// 有自定义名称用名称，否则用最近复制时间；不再使用UUID，便于用户辨认，by AI.Coding。
    public static func exportBaseName(title: String?, copiedAt: Instant) -> String {
        if let title, let name = sanitizedFileName(title) { return name }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "LocalClip-" + formatter.string(from: Date(timeIntervalSince1970: Double(copiedAt) / 1000))
    }
    /// 路径分隔、冒号与控制字符换成"-"，去掉开头的点避免隐藏文件，按字符截到200字节以内。
    public static func sanitizedFileName(_ value: String) -> String? {
        var name = String(value.map { $0 == "/" || $0 == ":" || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) } ? "-" : $0 })
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= 200 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
    /// 一次拖出多个文件时追加从1开始的序号。
    public static func fileName(base: String, index: Int?, fileExtension: String) -> String {
        base + (index.map { "-\($0)" } ?? "") + "." + fileExtension
    }
    /// 目标已有同名文件时依次尝试"名称 2.ext"…"名称 99.ext"，绝不覆盖；全部占用返回nil，by AI.Coding。
    public static func availableURL(_ url: URL, exists: (URL) -> Bool) -> URL? {
        guard exists(url) else { return url }
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        for number in 2...99 {
            let candidate = folder.appendingPathComponent(stem + " \(number)" + (ext.isEmpty ? "" : "." + ext))
            if !exists(candidate) { return candidate }
        }
        return nil
    }

    // MARK: F17 开发者内容识别：卡片只看≤180字符预览，详情看完整正文；只读，不改记录，by AI.Coding。
    /// highlight.js语言名的展示名，卡片标题用它替换"文本"。
    public static let languageNames: [String: String] = [
        "json": "JSON", "java": "Java", "python": "Python", "javascript": "JavaScript", "typescript": "TypeScript", "yaml": "YAML",
        "xml": "XML", "css": "CSS", "bash": "Shell", "swift": "Swift", "sql": "SQL", "cpp": "C++", "csharp": "C#",
        "go": "Go", "ruby": "Ruby", "php": "PHP", "rust": "Rust", "ini": "INI", "markdown": "Markdown"]
    public struct RGBA: Equatable, Sendable {
        public let red: Int, green: Int, blue: Int
        public let alpha: Double
        public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) + (alpha < 1 ? String(format: "%02X", Int((alpha * 255).rounded())) : "") }
        public var rgb: String { alpha < 1 ? "rgba(\(red), \(green), \(blue), \(Self.trim(alpha)))" : "rgb(\(red), \(green), \(blue))" }
        public var hsl: String {
            let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
            let high = max(r, g, b), low = min(r, g, b), lightness = (high + low) / 2, delta = high - low
            var hue = 0.0, saturation = 0.0
            if delta > 0 {
                saturation = delta / (1 - abs(2 * lightness - 1))
                hue = high == r ? 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) : high == g ? 60 * ((b - r) / delta + 2) : 60 * ((r - g) / delta + 4)
                if hue < 0 { hue += 360 }
            }
            let body = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
            return alpha < 1 ? "hsla(\(body), \(Self.trim(alpha)))" : "hsl(\(body))"
        }
        private static func trim(_ value: Double) -> String { String(format: "%.3g", value) }
    }
    /// 卡片徽标：每张卡片最多一个，按JWT → UUID → 时间戳 → 颜色 → Base64的顺序命中即停。
    public enum Detection: Equatable, Sendable {
        case jwt, uuid(version: Int?), timestamp(Date), color(RGBA), base64
        public var badge: String {
            switch self {
            case .jwt: return "JWT"
            case .uuid(let version): return version.map { "UUID v\($0)" } ?? "UUID"
            case .timestamp(let date):
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
                // 同年只显示月日时分，跨年补上年份，避免误读。
                let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
                formatter.dateFormat = sameYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
                return formatter.string(from: date)
            case .color(let value): return value.hex
            case .base64: return "Base64"
            }
        }
        public var kindName: String {
            switch self { case .jwt: "JWT"; case .uuid: "UUID"; case .timestamp: "时间戳"; case .color: "颜色"; case .base64: "Base64" }
        }
    }
    /// 卡片识别：除颜色函数外只认去首尾空白后不含空白的单个token；预览被截断时只能识别JWT（凭头部判断）。
    public static func inspect(_ text: String, truncated: Bool) -> Detection? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384 else { return nil }
        let single = !value.contains(where: \.isWhitespace)
        if single, jwtParts(value, complete: !truncated) != nil { return .jwt }
        guard !truncated else { return nil }
        if single, value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil {
            let digit = Int(String(value[value.index(value.startIndex, offsetBy: 14)]), radix: 16) ?? 0
            return .uuid(version: (1...8).contains(digit) ? digit : nil)
        }
        if single, let date = timestamp(value) { return .timestamp(date) }
        if let color = color(value) { return .color(color) }
        if single, isBase64Text(value) { return .base64 }
        return nil
    }
    /// 10位秒或13位毫秒，换算后须在2000–2100年之间；8位日期等其他位数不算。
    public static func timestamp(_ value: String) -> Date? {
        guard value.count == 10 || value.count == 13, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let number = Double(value) else { return nil }
        let seconds = value.count == 13 ? number / 1000 : number
        guard (946_684_800...4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    /// #RGB、#RRGGBB、#RRGGBBAA、rgb()/rgba()、hsl()/hsla()；分量越界即不算颜色。
    public static func color(_ text: String) -> RGBA? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil {
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            let bytes = stride(from: 0, to: digits.count, by: 2).map { Int(String(Array(digits)[$0..<$0 + 2]), radix: 16)! }
            return RGBA(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? Double(bytes[3]) / 255 : 1)
        }
        func numbers(_ pattern: String) -> [Double]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: value).flatMap { Double(value[$0]) } ?? -1
            }
        }
        let alpha = "(?:\\s*,\\s*(\\d*\\.?\\d+))?\\s*\\)$"
        if let parts = numbers("^rgba?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})" + alpha) {
            let a = parts[3] < 0 ? 1 : parts[3]
            guard parts[0...2].allSatisfy({ $0 <= 255 }), (0...1).contains(a) else { return nil }
            return RGBA(red: Int(parts[0]), green: Int(parts[1]), blue: Int(parts[2]), alpha: a)
        }
        if let parts = numbers("^hsla?\\(\\s*(\\d{1,3}(?:\\.\\d+)?)\\s*,\\s*(\\d{1,3}(?:\\.\\d+)?)%\\s*,\\s*(\\d{1,3}(?:\\.\\d+)?)%" + alpha) {
            let a = parts[3] < 0 ? 1 : parts[3]
            guard parts[0] <= 360, parts[1] <= 100, parts[2] <= 100, (0...1).contains(a) else { return nil }
            let s = parts[1] / 100, l = parts[2] / 100, c = (1 - abs(2 * l - 1)) * s
            let x = c * (1 - abs((parts[0] / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
            let (r, g, b): (Double, Double, Double) = switch Int(parts[0] / 60) % 6 {
            case 0: (c, x, 0); case 1: (x, c, 0); case 2: (0, c, x); case 3: (0, x, c); case 4: (x, 0, c); default: (c, 0, x) }
            return RGBA(red: Int(((r + m) * 255).rounded()), green: Int(((g + m) * 255).rounded()), blue: Int(((b + m) * 255).rounded()), alpha: a)
        }
        return nil
    }
    /// JWT头部须能base64url解码为含alg的JSON；complete时要求三段且载荷为JSON对象。
    static func jwtParts(_ value: String, complete: Bool) -> [String]? {
        guard value.hasPrefix("eyJ") else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !complete || parts.count == 3,
              let header = jsonObject(base64url: parts[0]), header["alg"] != nil else { return nil }
        if complete { guard jsonObject(base64url: parts[1]) != nil else { return nil } }
        return parts
    }
    static func base64urlData(_ part: String) -> Data? {
        var value = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
    static func jsonObject(base64url part: String) -> [String: Any]? {
        base64urlData(part).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    /// 至少16字符、解码为可打印UTF-8；纯十六进制串（哈希、提交号）不算。
    static func isBase64Text(_ value: String) -> Bool {
        guard value.count >= 16, !value.allSatisfy(\.isHexDigit) else { return false }
        return (try? TextTransform.base64Decode(value)) != nil
    }

    /// 详情"识别结果"：完整正文的类型、明细行与可直接执行的转换。
    public struct Inspection: Equatable, Sendable {
        public struct Row: Equatable, Sendable {
            public let label: String, value: String
            /// 多行等宽内容（如JWT的JSON）。
            public let block: Bool
            init(_ label: String, _ value: String, block: Bool = false) { self.label = label; self.value = value; self.block = block }
        }
        public struct Action: Equatable, Sendable { public let title: String, transform: TextTransform }
        public var kind: String
        public var rows: [Row] = []
        public var color: RGBA?
        public var note: String?
        public var actions: [Action] = []
    }
    public static func inspectFull(_ text: String, language: String?, now: Date = Date()) -> Inspection? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch inspect(value, truncated: false) {
        case .jwt: if let result = jwtInspection(value, now: now) { return result }
        case .uuid(let version):
            return .init(kind: "UUID", rows: [.init("版本", version.map { "v\($0)" } ?? "未知")])
        case .timestamp(let date):
            return .init(kind: "时间戳", rows: timeRows(date, now: now, unit: value.count == 13 ? "毫秒" : "秒"),
                         actions: [.init(title: "转为 ISO 8601 后粘贴", transform: .timestampToISO)])
        case .color(let color):
            return .init(kind: "颜色", rows: [.init("HEX", color.hex), .init("RGB", color.rgb), .init("HSL", color.hsl)], color: color,
                         actions: [.init(title: "转为 rgb() 后粘贴", transform: .colorToRGB), .init(title: "转为 hex 后粘贴", transform: .colorToHex)])
        case .base64:
            let decoded = (try? TextTransform.base64Decode(value)) ?? ""
            return .init(kind: "Base64", rows: [.init("解码", String(decoded.prefix(2000)), block: true)], actions: [.init(title: "解码后粘贴", transform: .base64Decode)])
        case nil: break
        }
        if let first = value.first, first == "{" || first == "[" {
            do {
                try TextTransform.validateJSON(value)
                let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
                let shape = (object as? [String: Any]).map { ("对象", "\($0.count) 个键") } ?? (object as? [Any]).map { ("数组", "\($0.count) 个元素") } ?? ("值", "")
                return .init(kind: "JSON", rows: [.init("合法", "是"), .init("顶层", shape.0 + (shape.1.isEmpty ? "" : "，" + shape.1))],
                             actions: [.init(title: "格式化后粘贴", transform: .formatJSON)])
            } catch let error as TransformError {
                if language == "json" { return .init(kind: "JSON", rows: [.init("合法", "否：" + error.message.replacingOccurrences(of: "不是有效 JSON：", with: ""))]) }
            } catch {}
        }
        if let url = ClipboardPayload.webLink(value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var rows: [Inspection.Row] = [.init("协议", parts.scheme ?? ""), .init("主机", parts.host ?? "")]
            if !parts.path.isEmpty { rows.append(.init("路径", parts.percentEncodedPath.removingPercentEncoding ?? parts.path)) }
            for item in (parts.queryItems ?? []).prefix(30) { rows.append(.init("?" + item.name, item.value ?? "")) }
            return .init(kind: "链接", rows: rows)
        }
        let lines = text.reduce(into: 1) { if $1.isNewline { $0 += 1 } }
        return .init(kind: language.flatMap { languageNames[$0] }.map { "代码 · " + $0 } ?? "文本",
                     rows: [.init("行数", "\(lines)"), .init("字符", "\(text.count)")],
                     actions: [.init(title: "Markdown 代码块后粘贴", transform: .markdownCodeBlock)])
    }
    static func timeRows(_ date: Date, now: Date, unit: String) -> [Inspection.Row] {
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = .current; local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let utc = DateFormatter(); utc.locale = local.locale; utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        return [.init("单位", unit), .init("本地时间", local.string(from: date)), .init("UTC", utc.string(from: date)),
                .init("ISO 8601", iso.string(from: date)), .init("相对", relative(date, now: now))]
    }
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
    /// 只解码不验签；exp/iat/nbf换算为本地时间并给出是否过期。
    static func jwtInspection(_ value: String, now: Date) -> Inspection? {
        guard let parts = jwtParts(value, complete: true), let header = base64urlData(parts[0]), let payload = base64urlData(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        var rows: [Inspection.Row] = [.init("Header", TextTransform.reflowJSON(String(decoding: header, as: UTF8.self), pretty: true), block: true),
                                      .init("Payload", TextTransform.reflowJSON(String(decoding: payload, as: UTF8.self), pretty: true), block: true)]
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = .current; local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for (key, label) in [("iat", "签发"), ("nbf", "生效"), ("exp", "过期")] {
            guard let seconds = (claims[key] as? NSNumber)?.doubleValue else { continue }
            let date = Date(timeIntervalSince1970: seconds)
            rows.append(.init(label, local.string(from: date)))
            if key == "exp" { rows.append(.init("状态", date < now ? "已过期（\(relative(date, now: now))）" : "\(relative(date, now: now))过期")) }
        }
        return .init(kind: "JWT", rows: rows, note: "未验证签名", actions: [.init(title: "粘贴 Payload JSON", transform: .jwtPayload)])
    }
}
