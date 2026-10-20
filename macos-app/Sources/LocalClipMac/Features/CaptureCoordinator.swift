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
    /// 磁盘不足是唯一可确认未提交的瞬时错误：保留已解码快照（原captureID）有限重试；条数、字节、次数与退避都有上限，by AI.Coding。
    private var retries: [(snapshot: ClipboardSnapshot, epoch: UUID, attempt: Int)] = []
    private var retryTask: Task<Void, Never>?
    /// 首次重试等待；之后每次翻倍（默认1s/2s/4s，共3次）。测试可缩短。
    var retryDelay: Duration = .seconds(1)
    static let maxRetryAttempts = 3
    static let retryingState = "磁盘空间不足，稍后重试保存"
    /// 首次提交后不可用的那一条才是"结果未确认"；之后的复制在入口即被拒绝，确定未记录。
    private var storeUnavailable = false
    private var timedPauseActive = false
    private var pausePending = false
    // 新实例可恢复上次暂停；本次用户暂停一旦到达，启动不能再次覆盖，by AI.Coding。
    private var startupResumeAllowed = true
    private var captureEpoch = UUID()
    public var onState: ((String) -> Void)?
    public var onCommit: (() -> Void)?
    // 通过隐私策略后只使来源缓存失效，提交事件发布列表后才读取来源，by AI.Coding。
    public var onSourcePending: ((SourceAttribution) -> Void)?
    public init(board: any PasteboardClient, store: any HistoryRepository, clock: any ClipClock = SystemClock()) {
        self.board = board; self.store = store; self.clock = clock; baseline = board.changeCount
    }
    /// 恢复后按应用启动意图恢复手动开关，定时暂停与启动基线仍独立保留，by AI.Coding。
    public func start(resumeCapture: Bool = false) async throws {
        _ = try await store.recover()
        let stored = try await store.settings()
        if stored.revision >= policy.revision { policy = stored }
        // 已启用时不额外提交；只恢复手动暂停，不改隐私、期限或定时暂停，by AI.Coding。
        if resumeCapture && startupResumeAllowed && !pausePending && !policy.captureEnabled {
            var enabled = policy; enabled.captureEnabled = true
            let committed = try await store.updateCaptureSettings(enabled)
            // 等待提交时可能已有更新的暂停策略，不能发布旧版本，by AI.Coding。
            if committed.revision >= policy.revision { policy = committed }
        }
        _ = try await store.expire(at: clock.now())
        capacityBlocked = try await !store.canCapture()
        baseline = board.changeCount; timedPauseActive = (policy.pauseUntil ?? 0) > clock.now()
        setState(!policy.captureEnabled ? "用户暂停" : timedPauseActive ? "定时暂停" : capacityBlocked ? "容量已满" : "正常")
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
    /// 配置更新保留已采集队列；只有暂停状态转变需要丢弃和重建基线，by AI.Coding。
    public func updatePolicy(_ policy: SettingsSnapshot) {
        let now = clock.now()
        let wasPaused = pausePending || !self.policy.captureEnabled || (self.policy.pauseUntil ?? 0) > now
        let isPaused = !policy.captureEnabled || (policy.pauseUntil ?? 0) > now
        if !policy.captureEnabled { startupResumeAllowed = false }
        self.policy = policy; pausePending = false
        if wasPaused != isPaused || isPaused { rebaseline() }
        timedPauseActive = (policy.pauseUntil ?? 0) > now
        setState(!policy.captureEnabled ? "用户暂停" : capacityBlocked ? "容量已满" : retries.isEmpty ? "正常" : Self.retryingState)
    }
    /// 用户删除或清理历史后丢弃待补存快照，避免数秒后把刚删除的内容写回，by AI.Coding。
    public func discardPendingRetries() {
        guard !retries.isEmpty else { return }
        retries.removeAll(); retryTask?.cancel(); retryTask = nil
        setState(capacityBlocked ? "容量已满" : "正常")
    }
    /// 暂停、恢复和容量状态转变才失效在途快照，普通设置不能吞复制。
    public func rebaseline() {
        captureEpoch = UUID(); baseline = board.changeCount; queue.removeAll(); queueBytes = 0
        retries.removeAll(); retryTask?.cancel(); retryTask = nil
    }
    /// 离开排除应用时推进计数，覆盖两次轮询之间的复制；关闭该选项时不影响采集。
    public func applicationDidDeactivate(_ bundleID: String?) {
        guard policy.pauseWhenExcludedFrontmost, let bundleID, policy.excludedBundleIDs.contains(bundleID) else { return }
        // 已通过过滤的队列仍须入库，只跳过离开前尚未读取的剪贴板世代。
        baseline = board.changeCount
    }
    /// 激活事实只刷新滞留文案，不修改采集基线；排除应用之间切换仍保留提示，by AI.Coding。
    func applicationDidActivate(_ bundleID: String?) {
        guard state == "排除应用在前台，未采集", let bundleID,
              !policy.excludedBundleIDs.contains(bundleID) else { return }
        setState(capacityBlocked ? "容量已满" : "正常")
    }
    /// 用户请求暂停即阻止在途快照，持久化完成前不假装配置已经保存，by AI.Coding。
    public func requestPause() { startupResumeAllowed = false; pausePending = true; rebaseline(); setState("正在暂停") }
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
        // 精确自写收据先于正文读取，避免为随后丢弃的PNG恢复触发昂贵的TIFF生成。
        // matches读取标记期间也可能发生用户复制，因此再次核对计数，不能跳过新世代。
        if let receipt = ownReceipt, receipt.successful, board.changeCount == receipt.count,
           board.matches(receipt), board.changeCount == receipt.count {
            baseline = receipt.count; ownReceipt = nil; ignored(.selfWrite); return false
        }
        return true
    }
    public func tick() {
        guard readyToRead() else { return }
        handle(board.capture(after: baseline, policy: policy))
    }
    /// 系统IPC等待期间不占主线程；暂停世代失效后不发布旧读取结果。
    public func poll() async {
        guard readyToRead() else { return }
        let epoch = captureEpoch, readBaseline = baseline
        let outcome = await board.captureAsync(after: readBaseline, policy: policy)
        guard !Task.isCancelled, epoch == captureEpoch, readBaseline == baseline, !pausePending, policy.captureEnabled else { return }
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
            // 缩略图在同一后台阶段生成并随记录落库，展示时不再读取与解码原图，by AI.Coding。
            let snapshot = await Task.detached(priority: .utility) { () -> ClipboardSnapshot in
                var decoded = ContentDecoder.decode(raw)
                if [.image, .mixed].contains(decoded.payload.kind), case .image(let data) = ThumbnailRenderer.render(decoded.payload) { decoded.thumbnail = data }
                return decoded
            }.value
            if policy.timingEnabled { StageTiming.record("capture_decode", since: started, count: snapshot.payload.items.count) }
            guard capturable(epoch) else { ignored(.paused); continue }
            await save(snapshot, epoch: epoch, attempt: 0)
        }
        draining = nil
    }
    /// 暂停、定时暂停与世代失效后，在途或等待重试的快照都不能落库。
    private func capturable(_ epoch: UUID) -> Bool { !pausePending && policy.captureEnabled && (policy.pauseUntil ?? 0) <= clock.now() && epoch == captureEpoch }
    /// attempt：已失败次数；每次提交前都用最新持久策略重新校验暂停、排除与敏感规则。
    private func save(_ snapshot: ClipboardSnapshot, epoch: UUID, attempt: Int) async {
        var snapshot = snapshot
        do {
            // UI偏好、收藏、分类提交不改变复制资格；用最新策略重新校验并盖章。
            var result: IngestResult?
            for _ in 0..<3 {
                let persisted = try await store.settings()
                guard epoch == captureEpoch, !pausePending else { break }
                if let reason = persisted.rejection(source: snapshot.source, types: snapshot.payload.items.map(\.declaredTypes), at: clock.now()) {
                    result = .skipped(reason); break
                }
                snapshot.policyRevision = persisted.revision
                onSourcePending?(snapshot.source)
                do { result = try await store.ingest(snapshot, at: snapshot.capturedAt); break }
                catch StoreError.policyChanged { continue }
            }
            guard let result else { ignored(epoch == captureEpoch ? .busy : .paused); return }
            switch result {
            case .inserted, .deduplicated:
                // 只为新内容出声；虚拟机/远程桌面同步会反复写回相同内容，去重命中不响，by AI.Coding。
                if case .inserted = result, policy.captureSounds { NSSound(named: "Pop")?.play() }
                setState("正常"); onCommit?()
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
        // SQLITE_FULL与空间预检都在COMMIT成功之前，事务已回滚，可确认未提交；超出次数或上限后如实报告未记录。
        catch StoreError.diskFull { setState(scheduleRetry(snapshot, epoch: epoch, attempt: attempt + 1) ? Self.retryingState : "磁盘空间不足，未记录") }
        // 已提交但随后不可用：结果无法确认，不自动重放，等待存储恢复；此后的复制在入口即被拒绝。
        catch StoreError.postCommitUnavailable {
            setState(storeUnavailable ? "存储需恢复，未记录" : "存储需恢复，本条结果尚未确认"); storeUnavailable = true
        }
        catch { setState("存储异常，未记录") }
    }
    private func scheduleRetry(_ snapshot: ClipboardSnapshot, epoch: UUID, attempt: Int) -> Bool {
        guard attempt <= Self.maxRetryAttempts, epoch == captureEpoch, retries.count < 4,
              retries.reduce(snapshot.payload.byteCount, { $0 + $1.snapshot.payload.byteCount }) <= 64 * MiB else { return false }
        retries.append((snapshot, epoch, attempt))
        if retryTask == nil { retryTask = Task { [weak self] in await self?.runRetries() } }
        return true
    }
    /// 按入队顺序逐条退避重试；不阻塞新复制的drain，暂停或重建基线时整体作废。
    private func runRetries() async {
        while let attempt = retries.first?.attempt {
            do { try await Task.sleep(for: retryDelay * (1 << (attempt - 1))) } catch { return }
            // 计时器到点后才被取消时sleep不再抛错；先复核，再弹出实际要处理的条目。
            guard !Task.isCancelled else { return }
            guard !retries.isEmpty else { break }
            let next = retries.removeFirst()
            guard capturable(next.epoch) else { ignored(.paused); continue }
            await save(next.snapshot, epoch: next.epoch, attempt: next.attempt)
            if Task.isCancelled { return }
        }
        retryTask = nil
        // 最后一次补存以跳过结束时不残留"稍后重试"。
        if state == Self.retryingState { setState(capacityBlocked ? "容量已满" : "正常") }
    }
    /// 忽略状态只有类别与时间，不包含正文或 URL。
    private func ignored(_ reason: SkipReason) { lastIgnored = (reason, clock.now()); onState?(state) }
    /// 暂停优先展示，独立容量状态仍保留。
    private func setState(_ value: String) { state = pausePending ? "正在暂停" : (policy.pauseUntil ?? 0) > clock.now() ? "定时暂停" : policy.captureEnabled ? value : "用户暂停"; onState?(state) }
}
