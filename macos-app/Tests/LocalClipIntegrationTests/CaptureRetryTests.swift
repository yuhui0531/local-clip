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
        try await until { h.capture.state == "磁盘空间不足，未记录" }
        #expect(h.fault.failures == 1 + CaptureCoordinator.maxRetryAttempts)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.fault.failures == 1 + CaptureCoordinator.maxRetryAttempts)
        h.fault.arm(0)
        h.raw.user("A4-NEXT"); h.capture.tick()
        try await until { try await items(h.store, "A4-NEXT").count == 1 }
        #expect(try await items(h.store, "A4-LOST").isEmpty)
    }

    /// 等待重试期间暂停：快照作废不再落库；添加排除来源：重试前用最新策略复核后拒绝。
    @Test func pauseOrExclusionCancelsPendingRetry() async throws {
        let h = try await harness(delay: .milliseconds(200)); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        h.fault.arm(1)
        h.raw.user("A4-PAUSED"); h.capture.tick()
        try await until { h.capture.state == "磁盘空间不足，稍后重试保存" }
        h.capture.requestPause()
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await items(h.store, "A4-PAUSED").isEmpty && h.fault.failures == 1)

        var settings = try await h.store.settings(); settings.captureEnabled = true
        settings = try await h.store.updateCaptureSettings(settings); h.capture.updatePolicy(settings)
        h.fault.arm(1)
        h.raw.user("A4-EXCLUDED"); h.capture.tick()
        try await until { h.capture.state == "磁盘空间不足，稍后重试保存" }
        settings.excludedBundleIDs.insert("local.a4.old")
        settings = try await h.store.updateCaptureSettings(settings); h.capture.updatePolicy(settings)
        try await until { h.capture.lastIgnored?.0 == .excluded }
        #expect(try await items(h.store, "A4-EXCLUDED").isEmpty && h.fault.failures == 1)
    }

    /// 重试等待期间用户再次复制相同内容：新复制正常记录；旧快照补存只计一次，不回退时间、来源与分类次序。
    @Test func sameContentCopiedDuringRetryKeepsNewestFacts() async throws {
        let h = try await harness(delay: .milliseconds(600)); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
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
        #expect(fresh.copyCount == 1)
        // 分类内先放入该条，再放入另一条：另一条在前。
        let category = try await h.store.createCategory(name: "A4", colorHex: "34C759")
        for id in [fresh.id, otherID] { _ = try await h.store.apply(try await h.store.preview(.category([id], category.id, true)).token) }
        #expect(try await h.store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [otherID, fresh.id])
        try await until { try await items(h.store, "A4-SAME").first?.copyCount == 2 }
        let merged = try #require(try await items(h.store, "A4-SAME").first)
        #expect(merged.lastCopiedAt == fresh.lastCopiedAt && merged.firstCopiedAt == fresh.firstCopiedAt)
        #expect(try await h.store.detail(id: merged.id, at: SystemClock().now()).summary.source.name == "NewSource")
        #expect(try await h.store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [otherID, fresh.id])
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await items(h.store, "A4-SAME").first?.copyCount == 2 && h.fault.failures == 1)
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
        let h = try await harness(delay: .milliseconds(200)); defer { h.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        h.fault.arm(1)
        h.raw.user("A4-DELETED"); h.capture.tick()
        try await until { h.capture.state == CaptureCoordinator.retryingState }
        h.capture.updatePolicy(try await h.store.settings())
        #expect(h.capture.state == CaptureCoordinator.retryingState)
        h.capture.discardPendingRetries()
        #expect(h.capture.state == "正常")
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await items(h.store, "A4-DELETED").isEmpty && h.fault.failures == 1)
    }
}
