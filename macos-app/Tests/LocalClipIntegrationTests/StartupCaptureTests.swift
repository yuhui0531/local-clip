// 自动启动采集只验证临时SQLite和假剪贴板，不启动应用或读取用户内容，by AI.Coding。
import Foundation
import Testing
import LocalClipCore
@testable import LocalClipMac

/// 只暂停启动恢复或启用提交的返回，其余操作委托真实临时库，by AI.Coding。
private actor SuspendedStartupRepository: HistoryRepository {
    enum Phase: Sendable { case recovery, enableCommit }
    let store: HistoryStore
    let phase: Phase
    private var continuation: CheckedContinuation<Void, Never>?
    var suspended: Bool { continuation != nil }
    init(_ store: HistoryStore, phase: Phase) { self.store = store; self.phase = phase }
    /// 等待测试发出明确的恢复信号，不阻塞真实库actor，by AI.Coding。
    private func suspend() async { await withCheckedContinuation { continuation = $0 } }
    /// 释放一次启动等待，by AI.Coding。
    func release() { continuation?.resume(); continuation = nil }
    /// 挂起恢复之前不持有SQLite锁，允许当前用户暂停先完成，by AI.Coding。
    func recover() async throws -> RecoveryReport {
        if phase == .recovery { await suspend() }
        return try await store.recover()
    }
    /// 启用已提交但尚未返回时制造主线程交互边界，by AI.Coding。
    func updateCaptureSettings(_ settings: SettingsSnapshot) async throws -> SettingsSnapshot {
        let value = try await store.updateCaptureSettings(settings)
        if phase == .enableCommit && settings.captureEnabled { await suspend() }
        return value
    }
    /// 其余协议入口保持真实库语义，by AI.Coding。
    func settings() async throws -> SettingsSnapshot { try await store.settings() }
    /// 委托真实采集提交，by AI.Coding。
    func ingest(_ snapshot: ClipboardSnapshot, at: Instant) async throws -> IngestResult { try await store.ingest(snapshot, at: at) }
    /// 委托真实窗口查询，by AI.Coding。
    func search(_ request: SearchRequest) async throws -> SearchPage { try await store.search(request) }
    /// 委托真实详情，by AI.Coding。
    func detail(id: ClipID, at: Instant) async throws -> ClipDetail { try await store.detail(id: id, at: at) }
    /// 委托真实元数据，by AI.Coding。
    func metadata(id: ClipID, at: Instant) async throws -> ClipMetadata { try await store.metadata(id: id, at: at) }
    /// 委托真实载荷，by AI.Coding。
    func loadPayload(id: ClipID, at: Instant) async throws -> ClipboardPayload { try await store.loadPayload(id: id, at: at) }
    /// 委托真实预览，by AI.Coding。
    func preview(_ change: HistoryChange) async throws -> ChangePreview { try await store.preview(change) }
    /// 委托真实确认提交，by AI.Coding。
    func apply(_ token: UUID) async throws -> ChangeResult { try await store.apply(token) }
    /// 委托真实期限处理，by AI.Coding。
    func expire(at: Instant) async throws -> ChangeResult { try await store.expire(at: at) }
    /// 委托真实空间统计，by AI.Coding。
    func usage() async throws -> StorageUsage { try await store.usage() }
    /// 委托真实容量门禁，by AI.Coding。
    func canCapture() async throws -> Bool { try await store.canCapture() }
    /// 委托真实版本事件，by AI.Coding。
    func events() async -> AsyncStream<HistoryEvent> { await store.events() }
}

@MainActor struct StartupCaptureTests {
    /// 复用生产模型启动入口，系统边界全部替换成已有fake，by AI.Coding。
    private func model(_ store: HistoryStore, _ raw: RawBoard) -> HistoryViewModel {
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        return HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
    }
    /// 只等待明确的保存结果，不用固定延时冒充采集成功，by AI.Coding。
    private func waitFor(_ text: String, in store: HistoryStore) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init(text)).items.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await store.search(.init(text)).items.count == 1)
    }
    /// 更新后的真实模型启动与UI保存保留完整偏好；仅既定的会话暂停恢复会改变采集开关，by AI.Coding。
    @Test(arguments: [true, false])
    func relaunchAndPreferenceEditPreserveAllSettings(smartPaste: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = SettingsSnapshot()
        saved.appearance = .dark; saved.compactLayout = true
        saved.retentionDays = 17; saved.quotaBytes = 768 * MiB; saved.panelHeight = 410
        saved.defaultAction = .copy; saved.defaultFormat = .plainText
        saved.pauseUntil = SystemClock().now() + 600_000; saved.pauseWhenExcludedFrontmost = true
        saved.smartCodeFilePaste = smartPaste; saved.moveUsedToFront = false
        saved.captureSounds = true; saved.showMenuIcon = false; saved.hideContents = true
        saved.excludeFromSharing = true; saved.timingEnabled = true
        saved.quickModifiers = 4096; saved.boardModifiers = 6144; saved.captureEnabled = false
        saved.excludedBundleIDs = ["local.fixture.private"]
        saved.autoCheckUpdates = false; saved.smartPasteEditorBundleIDs = ["local.fixture.editor"]
        saved.shortcut = .init(keyCode: 8, modifiers: 6400); saved.revision = 23
        _ = try HistoryStore(location: root, initialSettings: saved)
        let store = try HistoryStore(location: root), raw = RawBoard(), model = model(store, raw)
        // 不注册系统快捷键，不读系统剪贴板，也不修改生产应用权限。
        model.registerShortcut = { _ in true }
        try await model.start(resumeCapture: true); model.capture.stop()
        saved.captureEnabled = true; saved.revision += 1
        #expect(model.settings == saved && model.capture.policy == saved)
        #expect(try await store.settings() == saved)
        #expect(raw.reads.isEmpty)

        // 修改无关偏好后等待实际提交，再重开库确认智能粘贴等其它设置没有被整份默认值覆盖。
        model.updateSettings { $0.captureSounds = false }
        saved.captureSounds = false; saved.revision += 1
        let deadline = ContinuousClock.now + .seconds(3)
        while model.settings.revision < saved.revision, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.settings == saved && model.capture.policy == saved)
        #expect(try await HistoryStore(location: root).settings() == saved)
    }
    /// 新启动自动监听后续变化，但不导入启动前的剪贴板，也不重复提交已启用设置，by AI.Coding。
    @Test func freshLaunchCapturesOnlyNewCopiesWithoutSettingsCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        raw.user("before-launch")
        let before = try await store.settings(), model = model(store, raw)
        try await model.start(resumeCapture: true); model.capture.stop()
        #expect(model.settings.captureEnabled && model.capture.policy.captureEnabled)
        #expect(try await store.settings().revision == before.revision)
        model.capture.tick()
        #expect(raw.reads.isEmpty); #expect(try await store.search(.init()).items.isEmpty)
        raw.user("after-launch"); model.capture.tick(); try await waitFor("after-launch", in: store)
        #expect(try await store.search(.init("before-launch")).items.isEmpty)
    }
    /// 上次手动暂停只影响那一轮；重启仅改采集开关，保留隐私设置且不补采，by AI.Coding。
    @Test func nextLaunchResumesManualPauseWithoutBackfill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.captureEnabled = false
        settings.excludedBundleIDs = ["local.excluded"]; settings.hideContents = true
        let store = try HistoryStore(location: root, initialSettings: settings), raw = RawBoard()
        raw.user("previous-session")
        let model = model(store, raw)
        try await model.start(resumeCapture: true); model.capture.stop()
        let actual = try await store.settings()
        var expected = settings; expected.captureEnabled = true; expected.revision = actual.revision
        #expect(actual == expected); #expect(actual.revision == settings.revision + 1)
        #expect(model.settings == actual && model.capture.policy == actual)
        model.capture.tick(); #expect(raw.reads.isEmpty)
        guard model.capture.policy.captureEnabled else { return }
        var paused = actual; paused.captureEnabled = false
        model.capture.updatePolicy(try await store.updateCaptureSettings(paused))
        raw.user("during-pause"); model.capture.tick(); #expect(raw.reads.isEmpty)
        let next = self.model(store, raw)
        try await next.start(resumeCapture: true); next.capture.stop()
        next.capture.tick(); #expect(raw.reads.isEmpty)
        raw.user("next-session"); next.capture.tick(); try await waitFor("next-session", in: store)
        #expect(try await store.search(.init()).items.map(\.preview) == ["next-session"])
        raw.count += 1; raw.items = [[SupportedType.string: Data("secret".utf8), "org.nspasteboard.ConcealedType": Data()]]
        raw.reads.removeAll(); next.capture.tick()
        #expect(raw.reads.isEmpty); #expect(next.capture.lastIgnored?.0 == .sensitive)
    }
    /// 自动恢复手动开关仍尊重尚未到期的定时暂停，不读取或保存正文，by AI.Coding。
    @Test func launchPreservesActiveScheduledPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.captureEnabled = false
        settings.pauseUntil = SystemClock().now() + 60_000
        let store = try HistoryStore(location: root, initialSettings: settings), raw = RawBoard()
        let model = model(store, raw)
        try await model.start(resumeCapture: true); model.capture.stop()
        #expect(model.settings.captureEnabled && model.capture.policy.captureEnabled)
        #expect(model.settings.pauseUntil == settings.pauseUntil)
        #expect(model.capture.state == "定时暂停")
        raw.user("scheduled-pause-copy"); model.capture.tick()
        #expect(raw.reads.isEmpty); #expect(try await store.search(.init()).items.isEmpty)
    }
    /// 当前会话暂停已提交后，恢复结束不能把它当成上次暂停自动覆盖，by AI.Coding。
    @Test func currentSessionPauseSurvivesSuspendedRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        let repository = SuspendedStartupRepository(store, phase: .recovery)
        let capture = CaptureCoordinator(board: MacPasteboardClient(access: raw), store: repository)
        let startup = Task { try await capture.start(resumeCapture: true) }
        // 并行全量测试负载下启动链可能超过3秒；只等正向信号，延长上限不拖慢通过路径。
        let deadline = ContinuousClock.now + .seconds(10)
        while await !repository.suspended, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let suspended = await repository.suspended; try #require(suspended)
        capture.requestPause()
        var paused = try await store.settings(); paused.captureEnabled = false
        paused = try await store.updateCaptureSettings(paused); capture.updatePolicy(paused)
        await repository.release(); try await startup.value; capture.stop()
        #expect(!capture.policy.captureEnabled); #expect(try await store.settings() == paused)
        raw.user("paused-during-recovery"); capture.tick()
        #expect(raw.reads.isEmpty); #expect(try await store.search(.init()).items.isEmpty)
    }
    /// 启用提交尚未返回时的暂停/恢复/普通编辑按原意图保存，不与启动争用旧版本，by AI.Coding。
    @Test(arguments: ["pause", "resume", "preference"])
    func queuedStartupIntentSurvivesEnableCommit(intent: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.captureEnabled = false
        let store = try HistoryStore(location: root, initialSettings: settings), raw = RawBoard()
        let board = MacPasteboardClient(access: raw), repository = SuspendedStartupRepository(store, phase: .enableCommit)
        let capture = CaptureCoordinator(board: board, store: repository)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        let startup = Task { try await model.start(resumeCapture: true) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await !repository.suspended, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let suspended = await repository.suspended; try #require(suspended)
        if intent == "preference" { model.updateSettings { $0.hideContents = true } }
        else { model.setCaptureEnabled(intent == "resume") }
        if intent == "pause" { raw.user("during-enable-commit"); capture.tick(); #expect(raw.reads.isEmpty) }
        await repository.release(); try await startup.value
        let saved = ContinuousClock.now + .seconds(10)
        while model.message != "设置已保存", ContinuousClock.now < saved { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.message == "设置已保存")
        #expect(model.settings.captureEnabled == (intent != "pause"))
        #expect(capture.policy.captureEnabled == (intent != "pause"))
        #expect(try await store.settings().captureEnabled == (intent != "pause"))
        if intent == "pause" {
            raw.user("after-startup-pause"); capture.tick()
            #expect(raw.reads.isEmpty); #expect(try await store.search(.init()).items.isEmpty)
        } else {
            if intent == "preference" { #expect(model.settings.hideContents) }
            raw.user("after-startup-enabled"); capture.tick(); try await waitFor("after-startup-enabled", in: store)
        }
        capture.stop()
    }
}
