// 原生 RTF 与无网络 HTML 纯文字提取，by AI.Coding。
import AppKit
import LocalClipCore
public enum ContentDecoder {
    /// HTML 不交给 AppKit HTML importer，避免远程资源加载。
    public static func extract(_ representation: Representation) -> String? {
        if representation.type == SupportedType.rtf { return NSAttributedString(rtf: representation.data, documentAttributes: nil)?.string }
        return BasicTextDecoder.extract(representation)
    }
    /// 后台只操作不可变 Data 和局部解码对象。
    public static func decode(_ snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var snapshot = snapshot
        for index in snapshot.payload.items.indices {
            let item = snapshot.payload.items[index]
            // 文件引用优先以路径展示；原始URL字节仍作为独立表示保存。
            for type in [SupportedType.fileURL, SupportedType.string, SupportedType.url, SupportedType.rtf, SupportedType.html] {
                if let value = item.representations.first(where: { $0.type == type }), let text = extract(value) {
                    snapshot.payload.items[index].plainText = text; break
                }
            }
        }
        return snapshot
    }
}
