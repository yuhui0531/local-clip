// 输出预算集中定义；超限整体拒绝，不截断项目或改变格式，by AI.Coding。
import Foundation
import LocalClipCore

enum OutputBudget: Error {
    case exceeded
    static let byteLimit: Int64 = 50 * MiB
    static let message = "所选内容超过50MiB输出预算；请减少选择或使用粘贴队列"

    /// 先以元数据累计原始表示和派生文字；不加载被拒绝的BLOB。
    static func preflight(_ ids: [ClipID], store: any HistoryRepository, at: Instant, transform: Bool) async throws {
        var total: Int64 = 0
        for id in ids {
            try Task.checkCancellation()
            let metadata = try await store.metadata(id: id, at: at)
            if transform && metadata.hasFileReferences { throw TransformError("文件记录无法转换") }
            if transform && !metadata.hasTextRepresentations { throw TransformError("所选内容包含无文本项目，无法转换") }
            guard metadata.outputByteCount <= byteLimit - total else { throw exceeded }
            total += metadata.outputByteCount
        }
    }

    /// 实际读取及合成后再次核对，预算内保持原始表示字节。
    static func validate(_ payloads: [ClipboardPayload]) throws {
        var total: Int64 = 0
        for payload in payloads {
            try Task.checkCancellation()
            guard payload.byteCount <= byteLimit - total else { throw exceeded }
            total += payload.byteCount
        }
    }
}
