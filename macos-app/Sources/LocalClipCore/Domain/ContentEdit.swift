// 编辑仅替换可完整提取的文字，不把文件或图片载荷转为空文本，by AI.Coding。
import Foundation

public enum ContentEditError: Error, Equatable, Sendable {
    case unsupportedContent, emptyText, tooLarge, contentChanged, duplicateContent
    /// 保存失败的原因用于编辑器就地提示，草稿仍由用户决定如何处理。
    public var message: String {
        switch self {
        case .unsupportedContent: "仅支持编辑文本和链接；图片、文件引用或含附件的内容不能替换为文字。"
        case .emptyText: "内容不能为空或仅包含空白。"
        case .tooLarge: "内容不能超过50 MiB。"
        case .contentChanged: "原内容已被修改，请保留草稿并重新打开记录后核对。"
        case .duplicateContent: "已有相同内容的记录，请修改内容或取消；现有记录不会合并。"
        }
    }
}

extension ClipboardPayload {
    // 固定附件模式只编译一次，保持转义奇偶与HTML判定语义，by AI.Coding。
    private static let rtfAttachment = try? NSRegularExpression(pattern: #"(\\+)(pict|object)\b"#, options: .caseInsensitive)
    private static let htmlAttachment = try? NSRegularExpression(pattern: #"<\s*(img|object|embed|svg|video|audio|iframe)\b"#, options: .caseInsensitive)
    /// 所有项目都只能含文字表示；富文本解码不完整或包含附件类型时整体拒绝。
    public var editableText: String? {
        let types: Set<String> = [SupportedType.string, SupportedType.url, SupportedType.rtf, SupportedType.html]
        guard !items.isEmpty, items.allSatisfy({ !$0.representations.isEmpty && $0.representations.allSatisfy { types.contains($0.type) } }) else { return nil }
        // 富文本内嵌的图片/对象并非独立表示，不能因有纯文本备用表示就丢弃附件。
        for representation in items.flatMap(\.representations) {
            if representation.type == SupportedType.rtf {
                let source = String(decoding: representation.data, as: UTF8.self)
                // 偶数反斜杠只是文字；奇数末尾仍是附件控制字，不能开放含附件编辑。
                if let controls = Self.rtfAttachment,
                   controls.matches(in: source, range: NSRange(source.startIndex..., in: source)).contains(where: { !$0.range(at: 1).length.isMultiple(of: 2) }) { return nil }
            }
            if representation.type == SupportedType.html {
                let source = String(decoding: representation.data, as: UTF8.self)
                if Self.htmlAttachment?.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil { return nil }
            }
        }
        return plainText
    }
    /// 修改后统一使用当前文本作为唯一表示，避免原URL/RTF/HTML残留导致复制旧内容。
    public var textEditWarning: String? {
        if items.count > 1 { return "保存后将合并为单条纯文本，原有分项和富文本格式将被替换。" }
        if items.contains(where: { $0.representations.contains { [SupportedType.rtf, SupportedType.html].contains($0.type) } }) {
            return "保存后将转为纯文本，原有富文本格式将被替换。"
        }
        return nil
    }
}
