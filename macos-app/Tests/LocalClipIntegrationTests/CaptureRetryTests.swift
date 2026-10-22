// A4：明确未提交的磁盘不足有限重试；临时SQLite + 注入存储故障 + fake剪贴板，不填满磁盘、不触碰用户剪贴板，by AI.Coding。
import Foundation
import Testing
import LocalClipCore
@testable import LocalClipMac

/// 只在测试布防后于指定提交点抛错；beforeReplace在事务内、COMMIT之前，afterReplace在COMMIT之后。
private final class StoreFault: StorageFaultInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0, point = FaultPoint.beforeReplace, error = StoreError.diskFull, thrown = 0
    func arm(_ count: Int, at point: FaultPoint = .beforeReplace, error: StoreError = .diskFull) {
        lock.withLock { remaining = count; self.point = point; self.error = error; thrown = 0 }
    }
    var failures: Int { lock.withLock { thrown } }
    func check(_ point: FaultPoint) throws {
        try lock.withLock {
            guard point == self.point, remaining > 0 else { return }
            remaining -= 1; thrown += 1; throw error
        }
    }
}

/// 重试屏障：到达计数，打开前挂起。
@MainActor private final class RetryGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0, passed = 0
    private var isOpen = false
    func wait() async {
        arrivals += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        passed += 1
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
@MainActor struct CaptureRetryTests {
    private struct Harness { let root: URL, store: HistoryStore, fault: StoreFault, raw: RawBoard, capture: CaptureCoordinator, states: Box }
    private final class Box { var states: [String] = []; var source = SourceAttribution(bundleID: "local.a4.old", name: "OldSource") }
    private func harness(delay: Duration = .milliseconds(20)) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fault = StoreFault(), store = try HistoryStore(location: root, faults: fault), raw = RawBoard(), box = Box()
        let board = MacPasteboardClient(access: raw, observedSource: { _ in box.source })
        let capture = CaptureCoordinator(board: board, store: store)
        capture.retryDelay = delay
        try await capture.start(); capture.stop()
        capture.onState = { box.states.append($0) }
        return .init(root: root, store: store, fault: fault, raw: raw, capture: capture, states: box)
    }
    private func until(_ predicate: () async throws -> Bool, seconds: Int = 5, line: Int = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await predicate(), "line \(line)")
    }
    private func items(_ store: HistoryStore, _ text: String) async throws -> [ClipSummary] { try await store.search(.init(text)).items }

    /// 复现造数据漏条：轮询落在 clearContents 与写入之间时看到空板，写入后计数不变；30 条须全部入库，by AI.Coding。
    @Test func pollBetweenClearAndWriteKeepsCopy() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        for index in 1...30 {
            h.raw.count += 1; h.raw.items = []; h.capture.tick()
            h.raw.items = [[SupportedType.string: Data("SEED-\(index)".utf8)]]; h.capture.tick()
            // 每条等入库再写下一条，排除有界队列 .busy 丢弃的干扰。
            try await until { try await items(h.store, "SEED").count == index }
        }
    }
    /// 隔离证明：注入点在COMMIT之前，失败后库内无记录、修订号不变；之后同一快照（原captureID）补存一次，复制次数为1。
    @Test func diskFullBeforeCommitIsRetriedOnce() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let revision = try await h.store.search(.init()).revision
        h.fault.arm(1)
        await #expect(throws: StoreError.diskFull) { try await h.store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("A4-PROBE".utf8))])])), at: SystemClock().now()) }
        let after = try await h.store.search(.init()).revision
        #expect(try await items(h.store, "A4-PROBE").isEmpty && after == revision)
        h.fault.arm(1)
        h.raw.user("A4-ONCE"); h.capture.tick()
        try await until { try await items(h.store, "A4-ONCE").count == 1 }
        #expect(h.fault.failures == 1 && h.states.states.contains("磁盘空间不足，稍后重试保存") && h.capture.state == "正常")
        #expect(try await items(h.store, "A4-ONCE").first?.copyCount == 1)
    }

    /// 持续失败：首次加3次重试后如实报告未记录，不再继续；随后新复制照常保存，旧快照不会被补存。
    @Test func persistentFailureStopsAfterBound() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        h.fault.arm(100)
        h.raw.user("A4-LOST"); h.capture.tick()
        // 退避合计不足0.2秒；完整并行套件中主线程被其他测试占用时放宽等待上限，不改变断言，by AI.Coding。
        try await until({ h.capture.state == "磁盘空间不足，未记录" }, seconds: 15)
        #expect(h.fault.failures == 1 + CaptureCoordinator.maxRetryAttempts)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.fault.failures == 1 + CaptureCoordinator.maxRetryAttempts)
        h.fault.arm(0)
        h.raw.user("A4-NEXT"); h.capture.tick()
        try await until { try await items(h.store, "A4-NEXT").count == 1 }
        #expect(try await items(h.store, "A4-LOST").isEmpty)
    }

    /// 等待重试期间暂停：快照作废不再落库；添加排除来源：重试前用最新策略复核后拒绝。
    /// 重试由屏障放行，不依赖退避计时与测试步骤之间的时间窗口。
    @Test func pauseOrExclusionCancelsPendingRetry() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        var gate = RetryGate(); h.capture.retryBarrier = { [g = gate] in await g.wait() }
        h.fault.arm(1)
        h.raw.user("A4-PAUSED"); h.capture.tick()
        // 等重试任务真正停在屏障上再暂停；负载下任务启动晚于状态文字，先暂停会让它根本到不了屏障。
        try await until { h.capture.state == "磁盘空间不足，稍后重试保存" && gate.arrivals == 1 }
        h.capture.requestPause()
        gate.open()
        try await until { gate.passed == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await items(h.store, "A4-PAUSED").isEmpty && h.fault.failures == 1)

        var settings = try await h.store.settings(); settings.captureEnabled = true
        settings = try await h.store.updateCaptureSettings(settings); h.capture.updatePolicy(settings)
        gate = RetryGate(); h.capture.retryBarrier = { [g = gate] in await g.wait() }
        h.fault.arm(1)
        h.raw.user("A4-EXCLUDED"); h.capture.tick()
        try await until { h.capture.state == "磁盘空间不足，稍后重试保存" }
        settings.excludedBundleIDs.insert("local.a4.old")
        settings = try await h.store.updateCaptureSettings(settings); h.capture.updatePolicy(settings)
        gate.open()
        try await until { h.capture.lastIgnored?.0 == .excluded }
        #expect(try await items(h.store, "A4-EXCLUDED").isEmpty && h.fault.failures == 1)
    }

    /// 重试等待期间用户再次复制相同内容：新复制正常记录；旧快照补存只计一次，不回退时间、来源与分类次序。
    @Test func sameContentCopiedDuringRetryKeepsNewestFacts() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let gate = RetryGate(); h.capture.retryBarrier = { await gate.wait() }
        let other = try await h.store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("A4-OTHER".utf8))])])), at: SystemClock().now())
        guard case .inserted(let otherID) = other else { throw StoreError.notFound }
        h.fault.arm(1)
        h.raw.user("A4-SAME"); h.capture.tick()
        try await until { h.capture.state == "磁盘空间不足，稍后重试保存" }
        h.states.source = SourceAttribution(bundleID: "local.a4.new", name: "NewSource")
        try await Task.sleep(for: .milliseconds(5))
        h.raw.user("A4-SAME"); h.capture.tick()
        try await until { try await items(h.store, "A4-SAME").count == 1 }
        let fresh = try #require(try await items(h.store, "A4-SAME").first)
        #expect(fresh.copyCount == 1 && gate.arrivals == 1 && gate.passed == 0)
        // 分类内先放入该条，再放入另一条：另一条在前。
        let category = try await h.store.createCategory(name: "A4", colorHex: "34C759")
        for id in [fresh.id, otherID] { _ = try await h.store.apply(try await h.store.preview(.category([id], category.id, true)).token) }
        #expect(try await h.store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [otherID, fresh.id])
        gate.open()
        try await until { try await items(h.store, "A4-SAME").first?.copyCount == 2 }
        let merged = try #require(try await items(h.store, "A4-SAME").first)
        #expect(merged.lastCopiedAt == fresh.lastCopiedAt && merged.firstCopiedAt == fresh.firstCopiedAt)
        #expect(try await h.store.detail(id: merged.id, at: SystemClock().now()).summary.source.name == "NewSource")
        #expect(try await h.store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [otherID, fresh.id])
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await items(h.store, "A4-SAME").first?.copyCount == 2 && h.fault.failures == 1)
    }
    /// 补存先于第二次复制落库的顺序：第二次复制时复制次数已是2，与全量套件中原第107行失败所见一致；
    /// 旧日志只说明时间窗口不可靠，不能确定当时的唯一顺序。此顺序下最终事实仍正确：只计两次、时间与来源取最新复制。
    @Test func retryBeforeSecondCopyStillKeepsNewestFacts() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let gate = RetryGate(); h.capture.retryBarrier = { await gate.wait() }
        h.fault.arm(1)
        h.raw.user("A4-ORDER"); h.capture.tick()
        try await until { h.capture.state == "磁盘空间不足，稍后重试保存" }
        gate.open()
        try await until { try await items(h.store, "A4-ORDER").count == 1 }
        let retried = try #require(try await items(h.store, "A4-ORDER").first)
        h.states.source = SourceAttribution(bundleID: "local.a4.new", name: "NewSource")
        try await Task.sleep(for: .milliseconds(5))
        h.raw.user("A4-ORDER"); h.capture.tick()
        try await until { try await items(h.store, "A4-ORDER").first?.copyCount == 2 }
        let merged = try #require(try await items(h.store, "A4-ORDER").first)
        #expect(retried.copyCount == 1 && merged.lastCopiedAt > retried.lastCopiedAt && merged.firstCopiedAt == retried.firstCopiedAt)
        #expect(try await h.store.detail(id: merged.id, at: SystemClock().now()).summary.source.name == "NewSource" && h.fault.failures == 1)
    }

    /// COMMIT之后才失败：存储进入不可用态，采集如实报告结果未确认，不自动重放；重开后只有一条且只计一次。
    @Test func postCommitFailureIsNotReplayed() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        h.fault.arm(1, at: .afterReplace, error: .ioFailure)
        h.raw.user("A4-COMMITTED"); h.capture.tick()
        try await until { h.capture.state == "存储需恢复，本条结果尚未确认" }
        try await Task.sleep(for: .milliseconds(200))
        // 若被重放，会再次进入保存并给出“未记录”；只出现一次“未确认”说明没有重放。
        #expect(h.fault.failures == 1 && h.states.states.filter { $0.hasPrefix("存储需恢复") } == ["存储需恢复，本条结果尚未确认"])
        h.raw.user("A4-AFTER"); h.capture.tick()
        try await until { h.capture.state == "存储需恢复，未记录" }
        let reopened = try HistoryStore(location: h.root)
        let saved = try await reopened.search(.init("A4-COMMITTED")).items
        #expect(saved.count == 1 && saved.first?.copyCount == 1)
    }

    /// 等待补存期间用户删除历史：丢弃待补存快照，不把刚删除的内容写回；状态不残留“稍后重试”。
    @Test func deleteDuringRetryDiscardsSnapshot() async throws {
        let h = try await harness(); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let gate = RetryGate(); h.capture.retryBarrier = { await gate.wait() }
        h.fault.arm(1)
        h.raw.user("A4-DELETED"); h.capture.tick()
        try await until { h.capture.state == CaptureCoordinator.retryingState }
        h.capture.updatePolicy(try await h.store.settings())
        #expect(h.capture.state == CaptureCoordinator.retryingState)
        h.capture.discardPendingRetries()
        #expect(h.capture.state == "正常")
        gate.open()
        try await until { gate.passed == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await items(h.store, "A4-DELETED").isEmpty && h.fault.failures == 1)
    }
}
