// 用户主动开启的阶段耗时，日志不含剪贴板内容，by AI.Coding。
import Foundation
import OSLog
public enum StageTiming {
    private static let logger = Logger(subsystem: "local.localclip", category: "stages")
    /// 调用点使用固定阶段名，仅输出数量与毫秒，不作性能验收结论。
    public static func record(_ stage: String, since start: ContinuousClock.Instant, count: Int) {
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        logger.info("stage=\(stage, privacy: .public) count=\(count) ms=\(milliseconds)")
    }
}
