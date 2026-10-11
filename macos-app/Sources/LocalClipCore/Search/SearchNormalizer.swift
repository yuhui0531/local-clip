// 字面 NFC / ASCII 折叠；不解释符号或分词，by AI.Coding。
import Foundation
public enum SearchNormalizer {
    /// 仅英文 ASCII 折叠，避免扩展 Unicode 映射改变偏移。
    public static func normalize(_ value: String) -> String {
        var bytes = Array(value.precomposedStringWithCanonicalMapping.utf8)
        for index in bytes.indices where bytes[index] >= 65 && bytes[index] <= 90 { bytes[index] += 32 }
        return String(decoding: bytes, as: UTF8.self)
    }
    /// 在原文字素上寻找映射后的命中，不拿规范化字节偏移截原文。
    public static func context(_ original: String, literal: String) -> String {
        guard !literal.isEmpty else { return String(original.prefix(180)) }
        return context(original, normalized: normalize(original), literal: literal)
    }
    /// 索引正文已经规范化，命中片段复用它，避免再次规范化长文，by AI.Coding。
    static func context(_ original: String, normalized: String, literal: String) -> String {
        guard !literal.isEmpty else { return String(original.prefix(180)) }
        guard let range = normalized.range(of: normalize(literal), options: .literal) else { return String(original.prefix(180)) }
        // NFC及ASCII折叠保持字素次序；按字素序号映射，避免每个字符单独规范化。
        let position = normalized[..<range.lowerBound].count
        let length = normalized[range].count
        let start = original.index(original.startIndex, offsetBy: max(0, position - 35), limitedBy: original.endIndex) ?? original.endIndex
        let end = original.index(original.startIndex, offsetBy: position + length + 79, limitedBy: original.endIndex) ?? original.endIndex
        return (start > original.startIndex ? "…" : "") + String(original[start..<end]) + (end < original.endIndex ? "…" : "")
    }
}
public enum BasicTextDecoder {
    /// 基础格式纯文字解码；RTF 由 Mac 层注入无网络解码器。
    public static func extract(_ representation: Representation) -> String? {
        // 文件名和路径参与字面检索，索引仅来自引用，不读取文件内容。
        if representation.type == SupportedType.fileURL {
            return PasteboardItemValue([representation]).fileURL?.path
        }
        if representation.type == SupportedType.string || representation.type == SupportedType.url {
            return String(data: representation.data, encoding: .utf8)
        }
        if representation.type == SupportedType.html, let html = String(data: representation.data, encoding: .utf8) { return HTMLText.extract(html) }
        return nil
    }
}
public enum HTMLText {
    /// 本地词法提取，绝不创建浏览器或访问外部图片、脚本、样式。
    public static func extract(_ html: String) -> String {
        var value = html
        for tag in ["script", "style", "head"] {
            value = value.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])\\s*>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?s)<!--.*?-->|<[^>]*>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
        for (key, replacement) in entities { value = value.replacingOccurrences(of: key, with: replacement) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                let token = (value as NSString).substring(with: match.range(at: 1))
                let number = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: value) { value.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return value.replacingOccurrences(of: "&amp;", with: "&")
    }
}
