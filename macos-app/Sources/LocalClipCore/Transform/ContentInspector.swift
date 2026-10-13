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
}
