// 采集队列、独立暂停状态与精确自写过滤，by AI.Coding。
import AppKit
import LocalClipCore
@MainActor public final class CaptureCoordinator {
    private let board: any PasteboardClient
    private let store: any HistoryRepository
    private let clock: any ClipClock
    public private(set) var policy = SettingsSnapshot()
    public private(set) var state = "准备中"
    public private(set) var lastIgnored: (SkipReason, Instant)?
    public private(set) var capacityBlocked = false
    private var baseline: Int
    private var ownReceipt: WriteReceipt?
    private var polling: Task<Void, Never>?
    private var draining: Task<Void, Never>?
    private var queue: [ClipboardSnapshot] = []
    private var queueBytes: Int64 = 0
    private var timedPauseActive = false
    private var pausePending = false
    private var captureEpoch = UUID()
    public var onState: ((String) -> Void)?
    public var onCommit: (() -> Void)?
    // 通过隐私策略后只使来源缓存失效，提交事件发布列表后才读取来源，by AI.Coding。
    public var onSourcePending: ((SourceAttribution) -> Void)?
    public init(board: any PasteboardClient, store: any HistoryRepository, clock: any ClipClock = SystemClock()) {
        self.board = board; self.store = store; self.clock = clock; baseline = board.changeCount
    }
    /// 恢复和到期清理结束后才从当前计数建立启动基线。
    public func start() async throws {
        _ = try await store.recover(); policy = try await store.settings(); _ = try await store.expire(at: clock.now())
        capacityBlocked = try await !store.canCapture()
        baseline = board.changeCount; setState(!policy.captureEnabled ? "用户暂停" : capacityBlocked ? "容量已满" : "正常")
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { break }
                await self.poll()
            }
        }
    }
    /// 停止轮询不主动替换系统剪贴板。
    public func stop() { polling?.cancel(); polling = nil; draining?.cancel(); draining = nil; rebaseline() }
    /// 配置更新保留已采集队列；只有暂停状态转变需要丢弃和重建基线。
    public func updatePolicy(_ policy: SettingsSnapshot) {
        let now = clock.now()
        let wasPaused = pausePending || !self.policy.captureEnabled || (self.policy.pauseUntil ?? 0) > now
        let isPaused = !policy.captureEnabled || (policy.pauseUntil ?? 0) > now
        self.policy = policy; pausePending = false
        if wasPaused != isPaused || isPaused { rebaseline() }
        timedPauseActive = (policy.pauseUntil ?? 0) > now
        setState(!policy.captureEnabled ? "用户暂停" : capacityBlocked ? "容量已满" : "正常")
    }
    /// 暂停、恢复和容量状态转变才失效在途快照，普通设置不能吞复制。
    public func rebaseline() {
        captureEpoch = UUID(); baseline = board.changeCount; queue.removeAll(); queueBytes = 0
    }
    /// 用户请求暂停即阻止在途快照，持久化完成前不假装配置已经保存。
    public func requestPause() { pausePending = true; rebaseline(); setState("正在暂停") }
    /// 写入阶段同步在 MainActor 内完成，计数与指纹是精确收据。
    public func recordOwnWrite(_ receipt: WriteReceipt) { ownReceipt = receipt }
    /// 容量恢复不覆盖主动暂停；不会重采旧剪贴板。
    public func refreshCapacity() async {
        do {
            let blocked = try await !store.canCapture()
            if blocked != capacityBlocked { capacityBlocked = blocked; rebaseline() }
            setState(!policy.captureEnabled ? "用户暂停" : capacityBlocked ? "容量已满" : "正常")
        } catch { setState("存储异常") }
    }
    /// 每轮仅观察一次变化，有界队列不吞掉已排队内容。
    private func readyToRead() -> Bool {
        let timed = (policy.pauseUntil ?? 0) > clock.now()
        if timed != timedPauseActive { timedPauseActive = timed; rebaseline(); setState(timed ? "定时暂停" : "正常"); return false }
        if timed || pausePending || !policy.captureEnabled || capacityBlocked { baseline = board.changeCount; return false }
        return true
    }
    public func tick() {
        guard readyToRead() else { return }
        handle(board.capture(after: baseline, policy: policy))
    }
    /// 系统IPC等待期间不占主线程；暂停世代失效后不发布旧读取结果。
    public func poll() async {
        guard readyToRead() else { return }
        let epoch = captureEpoch
        let outcome = await board.captureAsync(after: baseline, policy: policy)
        guard !Task.isCancelled, epoch == captureEpoch, !pausePending, policy.captureEnabled else { return }
        handle(outcome)
    }
    private func handle(_ outcome: CaptureOutcome) {
        switch outcome {
        case .noChange: return
        case .skipped(let reason, let count):
            baseline = count
            if let receipt = ownReceipt, receipt.count == count { ownReceipt = nil; ignored(.selfWrite); return }
            ownReceipt = nil; if reason == .excluded && policy.pauseWhenExcludedFrontmost { setState("排除应用在前台，未采集") }; ignored(reason)
        case .snapshot(let snapshot):
            baseline = snapshot.changeCount
            guard !pausePending, policy.captureEnabled else { ignored(.paused); return }
            if let receipt = ownReceipt, receipt.count == snapshot.changeCount, board.matches(receipt) { ownReceipt = nil; ignored(.selfWrite); return }
            // 失败写入造成的空/半份也只忽略该精确计数，随后用户计数立即有效。
            if let receipt = ownReceipt, !receipt.successful, receipt.count == snapshot.changeCount { ownReceipt = nil; ignored(.selfWrite); return }
            ownReceipt = nil
            guard queue.count < 8, queueBytes + snapshot.payload.byteCount <= 64 * MiB else { ignored(.busy); return }
            queue.append(snapshot); queueBytes += snapshot.payload.byteCount
            if draining == nil { draining = Task { [weak self] in await self?.drain() } }
        }
    }
    /// 入库前后台解码后复查当前策略及版本；不在主线程解析图片或哈希。
    private func drain() async {
        while !queue.isEmpty && !Task.isCancelled {
            let epoch = captureEpoch
            let raw = queue.removeFirst(); queueBytes -= raw.payload.byteCount
            let started = ContinuousClock.now
            var snapshot = await Task.detached(priority: .utility) { ContentDecoder.decode(raw) }.value
            if policy.timingEnabled { StageTiming.record("capture_decode", since: started, count: snapshot.payload.items.count) }
            guard !pausePending, policy.captureEnabled, (policy.pauseUntil ?? 0) <= clock.now(), epoch == captureEpoch else { ignored(.paused); continue }
            do {
                // UI偏好、收藏、分类提交不改变复制资格；用最新策略重新校验并盖章。
                var result: IngestResult?
                for _ in 0..<3 {
                    let persisted = try await store.settings()
                    guard epoch == captureEpoch, !pausePending else { break }
                    if let reason = persisted.rejection(source: snapshot.source, types: snapshot.payload.items.map(\.declaredTypes)) {
                        result = .skipped(reason); break
                    }
                    snapshot.policyRevision = persisted.revision
                    onSourcePending?(snapshot.source)
                    do { result = try await store.ingest(snapshot, at: snapshot.capturedAt); break }
                    catch StoreError.policyChanged { continue }
                }
                guard let result else { ignored(epoch == captureEpoch ? .busy : .paused); continue }
                switch result {
                case .inserted, .deduplicated:
                    setState("正常"); if policy.captureSounds { NSSound(named: "Pop")?.play() }; onCommit?()
                    do { _ = try await store.expire(at: clock.now()) }
                    catch { setState("已记录；期限清理失败，未报告释放") }
                case .skipped(let reason): ignored(reason)
                }
            } catch StoreError.policyChanged { ignored(.paused) }
            catch StoreError.quotaExceeded {
                do {
                    capacityBlocked = try await !store.canCapture()
                    if capacityBlocked { rebaseline() }
                    setState(capacityBlocked ? "容量已满，未记录新内容" : "容量不足，本条未记录")
                } catch { setState("容量状态读取失败，未记录") }
            }
            catch StoreError.diskFull { setState("磁盘空间不足，未记录") }
            catch { setState("存储异常，未记录") }
        }
        draining = nil
    }
    /// 忽略状态只有类别与时间，不包含正文或 URL。
    private func ignored(_ reason: SkipReason) { lastIgnored = (reason, clock.now()); onState?(state) }
    /// 暂停优先展示，独立容量状态仍保留。
    private func setState(_ value: String) { state = pausePending ? "正在暂停" : (policy.pauseUntil ?? 0) > clock.now() ? "定时暂停" : policy.captureEnabled ? value : "用户暂停"; onState?(state) }
}
