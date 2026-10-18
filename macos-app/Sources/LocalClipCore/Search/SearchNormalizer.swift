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
        let startOffset = max(0, position - 35)
        let start = original.index(original.startIndex, offsetBy: startOffset, limitedBy: original.endIndex) ?? original.endIndex
        // 从片段起点继续前进，避免尾部命中时再次遍历整篇长文；仍按字素截取。
        let end = original.index(start, offsetBy: position - startOffset + length + 79, limitedBy: original.endIndex) ?? original.endIndex
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
        // 只匹配原输入的一层实体，顺序拼接，避免重复展开及逐实体搬移整段正文。
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&amp;": "&"]
        guard let regex = try? NSRegularExpression(pattern: "&(?:lt|gt|quot|apos|nbsp|amp|#(?:[xX][0-9A-Fa-f]+|[0-9]+));") else { return value }
        let source = value as NSString
        var output = "", offset = 0
        for match in regex.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let token = source.substring(with: match.range)
            if let decoded = entities[token] { output += decoded }
            else {
                let digits = token.dropFirst(2).dropLast()
                let hex = digits.first == "x" || digits.first == "X"
                let number = UInt32(hex ? String(digits.dropFirst()) : String(digits), radix: hex ? 16 : 10)
                output += number.flatMap(UnicodeScalar.init).map(String.init) ?? token
            }
            offset = NSMaxRange(match.range)
        }
        output += source.substring(from: offset)
        return output
    }
}
