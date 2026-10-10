// 批量输出在后台生成，原始历史不改写，by AI.Coding。
import AppKit
import LocalClipCore
public enum OutputComposer {
    /// 文字按记录与项目顺序组合；混合内容保留每项，不能丢弃非文本内容。
    public static func combine(_ records: [ClipboardPayload], format: OutputFormat) throws -> ClipboardPayload {
        guard !records.isEmpty else { throw StoreError.notFound }
        let items = records.flatMap(\.items)
        guard format != .plainText || items.allSatisfy({ $0.plainText != nil }) else { throw StoreError.corruptPayload }
        if format == .original, records.count == 1 { return records[0] }
        let textual = items.allSatisfy { $0.plainText != nil && $0.fileURL == nil && $0.representations.allSatisfy { [SupportedType.string, SupportedType.url, SupportedType.rtf, SupportedType.html].contains($0.type) } }
        if format == .plainText || textual {
            let plain = items.compactMap(\.plainText).joined(separator: "\n")
            var representations = [Representation(SupportedType.string, Data(plain.utf8))]
            if format == .original {
                let attributed = NSMutableAttributedString(string: "")
                for (index, item) in items.enumerated() {
                    if index > 0 { attributed.append(NSAttributedString(string: "\n")) }
                    attributed.append(RichContent.attributed(item))
                }
                let range = NSRange(location: 0, length: attributed.length)
                if let data = attributed.rtf(from: range, documentAttributes: [:]) { representations.append(.init(SupportedType.rtf, data)) }
                let html = try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
                representations.append(.init(SupportedType.html, html))
            }
            return .init([.init(representations, plainText: plain)])
        }
        // 系统多项消费由目标决定；输出保留完整有序项目。
        return .init(items)
    }
}
