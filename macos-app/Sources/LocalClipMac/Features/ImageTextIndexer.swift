// 图片文字搜索的后台索引：复用本地Vision识别，串行逐项处理；只写派生索引，不写剪贴板、不新增历史，by AI.Coding。
import Foundation
import LocalClipCore

@MainActor final class ImageTextIndexer {
    private let store: HistoryStore
    /// 单项识别边界；生产为本地Vision，测试注入可控识别器。
    var recognize: @Sendable (ClipboardPayload) async throws -> [String] = { try await ImageTextRecognizer.recognize($0, qos: .utility) }
    var clock: any ClipClock = SystemClock()
    /// 补建进度与结束原因；只在补建或有明确原因时回调，自动处理新图片不刷屏；nil表示清除补建进度。
    var onStatus: ((String?) -> Void)?
    private(set) var task: Task<Void, Never>?
    private(set) var backfilling = false
    /// 容量不足后自动模式不再反复识别，直到用户手动建立索引、重开或清除索引、重启；磁盘不足是瞬时错误，下次提交成功的变更即恢复，by AI.Coding。
    var halted = false
    /// 运行中又有新变更：收尾前再查一轮，不漏掉最后一次查询之后入库的新图片。
    private var rerun = false
    private var generation = UUID()
    init(store: HistoryStore) { self.store = store }

    /// backfill为true处理全部已有图片（用户明确触发）；否则只处理since之后复制的图片。
    /// 运行中再次调用不重启、不丢弃在途识别；请求补建时当前任务从下一批起扩大到全部已有图片。
    func start(since: Instant, backfill: Bool) {
        if backfill { halted = false } else if halted { return }
        if task != nil { if backfill { backfilling = true } else { rerun = true }; return }
        backfilling = backfill; rerun = false
        let id = UUID(); generation = id
        task = Task { [weak self] in await self?.run(since: since, generation: id) }
    }
    /// 关闭功能、隐藏内容、用户停止或清除索引时取消；已发出的识别结果在入库前被丢弃。
    func stop(status: String? = "已停止图片文字索引") {
        guard task != nil else { return }
        let visible = backfilling || status != nil
        task?.cancel(); task = nil; generation = UUID(); backfilling = false
        if visible { onStatus?(status) }
    }
    private func run(since: Instant, generation id: UUID) async {
        // skipped只含本轮未写入、仍可能待识别的项；写入成功的项不再出现在待识别结果中。
        var done = 0, skipped = Set<ImageTextJob>()
        func finish(_ status: String?) {
            guard id == generation else { return }
            let visible = backfilling || status != nil
            task = nil; backfilling = false
            if visible { onStatus?(status) }
        }
        do {
            while true {
                // 同一轮内不重复尝试；仍待识别说明内容在识别期间变化、已失效或损坏，下一轮再处理。
                let all = backfilling
                let jobs = try await store.pendingImageText(since: all ? nil : since, limit: skipped.count + 8).filter { !skipped.contains($0) }
                // 查询期间用户请求补建：本轮只查了新图片，改按全部已有图片再查一次，不提前报告完成。
                guard let job = jobs.first else {
                    if !all && backfilling { continue }
                    if rerun { rerun = false; continue }
                    break
                }
                try Task.checkCancellation(); guard id == generation else { return }
                if backfilling { onStatus?("正在为已有图片建立文字索引，已处理 \(done) 项") }
                // 单条记录删除、到期或损坏只跳过该项，不中止整个队列。
                let source: [Representation]
                do { source = try await store.imageTextSource(job, at: clock.now()) }
                catch is CancellationError { return }
                catch { skipped.insert(job); continue }
                guard let result = await Self.recognizeItem(source, recognize: recognize) else { skipped.insert(job); continue }
                try Task.checkCancellation(); guard id == generation else { return }
                if try await store.saveImageText(job, digest: result.digest, text: result.text) { done += 1 } else { skipped.insert(job) }
            }
            finish(backfilling ? "已有图片文字索引完成，本次处理 \(done) 项" : nil)
        } catch is CancellationError { return }
        catch StoreError.quotaExceeded { halted = true; finish("存储空间不足，已停止图片文字索引；历史未受影响") }
        catch StoreError.diskFull { finish("磁盘空间不足，已停止图片文字索引；历史未受影响") }
        catch { finish("图片文字索引未完成，可稍后继续") }
    }
    /// 同一图片项的PNG/TIFF/JPEG只取第一个可解码表示；无文字、损坏或超限记为空结果，不再重试。
    /// 返回nil表示该项没有内嵌图片或识别被取消，不写入任何结果。
    nonisolated static func recognizeItem(_ candidates: [Representation], recognize: @Sendable (ClipboardPayload) async throws -> [String]) async -> (digest: String, text: String)? {
        guard let first = candidates.first else { return nil }
        for representation in candidates {
            if Task.isCancelled { return nil }
            do {
                let lines = try await recognize(ClipboardPayload([.init([representation])]))
                return (ContentFingerprint.hash(representation.data), lines.joined(separator: "\n"))
            } catch let failure as ImageTextRecognizer.Failure where failure.message == "未识别到文字" {
                return (ContentFingerprint.hash(representation.data), "")
            } catch { continue }
        }
        return Task.isCancelled ? nil : (ContentFingerprint.hash(first.data), "")
    }
}
