// 真实临时 SQLite + fake 系统边界闭环，不代替真实应用接收，by AI.Coding。
import Foundation
import Testing
import LocalClipCore
@testable import LocalClipMac
@MainActor final class FakeApplications: ApplicationClient {
    var targetKind: PasteTargetKind = .unknown
    var classifications = 0
    var classificationsBeforeRestore = 0
    var restoreCount = 0
    func pasteTargetKind(_ target: TargetToken) -> PasteTargetKind {
        classifications += 1
        if restoreCount == 0 { classificationsBeforeRestore += 1 }
        return targetKind
    }
    var permitted = true
    let remembered = TargetToken(pid: 123, bundleID: "local.target", launchedAt: 100)
    var current: TargetToken?
    var alive = true
    var activationOK = true
    var onActivate: (() -> Void)?
    var onRestore: (() -> Void)?
    var events = 0
    var activations = 0
    /// 目标 identity 保存完整 token。
    func target() -> TargetToken? { current }
    func isAlive(_ target: TargetToken) -> Bool { alive && target == remembered }
    func isFrontmost(_ target: TargetToken) -> Bool { isAlive(target) && current == target }
    /// 可注入用户切焦点或复制。
    func activate(_ target: TargetToken) -> Bool { activations += 1; if activationOK { current = target }; onActivate?(); return activationOK }
    var pasteFailureReason: String? { nil }
    func requestPastePermission() {}
    func isPasteFocusReady(_ target: TargetToken) -> Bool { isFrontmost(target) }
    func restorePasteFocus(_ target: TargetToken) -> Bool { restoreCount += 1; onRestore?(); return isFrontmost(target) }
    func sendPaste(_ target: TargetToken, ifClipboardUnchanged stillValid: () -> Bool) -> Bool { guard stillValid(), permitted, isFrontmost(target) else { return false }; events += 1; return true }
}
@MainActor struct EndToEndTests {
    /// 大条目预拒绝只影响本条，不吞掉随后可以容纳的小条目。
    @Test func AC13_AC17_largeRejectionAllowsSmallNextCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.quotaBytes = 512 * 1024
        let store = try HistoryStore(location: root, initialSettings: settings)
        func payload(_ byte: UInt8, _ size: Int) -> ClipboardSnapshot { .init(payload: .init([.init([.init(SupportedType.png, Data(repeating: byte, count: size))])])) }
        guard case .inserted(let favoriteID) = try await store.ingest(payload(1, 200 * 1024), at: SystemClock().now()) else { Issue.record("缺quota fixture"); return }
        let preview = try await store.preview(.favorite(favoriteID, true)); _ = try await store.apply(preview.token)
        _ = try await store.ingest(payload(2, 48 * 1024), at: SystemClock().now())
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        try await capture.start(); capture.stop()
        raw.count += 1; raw.items = [[SupportedType.png: Data(repeating: 3, count: 400 * 1024)]]; capture.tick()
        let rejected = ContinuousClock.now + .seconds(3)
        while !capture.state.contains("未记录"), ContinuousClock.now < rejected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(capture.state.contains("未记录")); #expect(!capture.capacityBlocked)
        #expect(try await store.search(.init()).items.count == 2)
        raw.user("SMALL-NEXT-COPY"); capture.tick()
        let saved = ContinuousClock.now + .seconds(3)
        while try await store.search(.init("SMALL-NEXT-COPY")).items.isEmpty, ContinuousClock.now < saved { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init("SMALL-NEXT-COPY")).items.count == 1)
        #expect(try await store.detail(id: favoriteID, at: SystemClock().now()).summary.isFavorite)
    }
    /// 同一个主线程轮次的超量变化：8份保留，新到的两份明确繁忙跳过。
    @Test func AC11_busyQueueAndPauseDuringRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); let raw = RawBoard(); let board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store); try await capture.start(); capture.stop()
        for index in 0..<10 { raw.user("queue-\(index)"); capture.tick() }
        #expect(capture.lastIgnored?.0 == .busy)
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.count < 8, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init()).items.count == 8)
        raw.onRead = { _, _ in var settings = capture.policy; settings.captureEnabled = false; capture.updatePolicy(settings) }
        raw.user("MUST-NOT-SAVE"); capture.tick(); try await Task.sleep(for: .milliseconds(100))
        #expect(try await store.search(.init("MUST-NOT-SAVE")).items.isEmpty)
        #expect(capture.state == "用户暂停")
    }
    /// 稳态采集、搜索、恢复，自写A不新增且紧接用户B不漏。
    @Test func AC01_AC06_AC09_captureRestoreAndImmediateUserCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root, extractor: ContentDecoder.extract)
        let raw = RawBoard(); let board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store)
        try await capture.start(); capture.stop()
        raw.user("LOCALCLIP-TEST-A"); capture.tick()
        let firstDeadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.isEmpty, ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let first = try await store.search(.init()); #expect(first.items.count == 1)
        guard let firstID = first.items.first?.id else { return }
        let paste = PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture)
        #expect(await paste.perform(.init(ids: [firstID])) == .copied)
        capture.tick(); try await Task.sleep(for: .milliseconds(30))
        #expect(try await store.detail(id: firstID, at: SystemClock().now()).summary.copyCount == 1)
        _ = await paste.perform(.init(ids: [firstID]))
        raw.user("LOCALCLIP-TEST-B"); capture.tick()
        let secondDeadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.count != 2, ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init()).items.count == 2)
    }
    /// 暂停不补采、恢复只观察新的计数。
    @Test func AC11_pauseNoBackfill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root); let raw = RawBoard(); let board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store); try await capture.start(); capture.stop()
        var settings = try await store.settings(); settings.captureEnabled = false
        capture.updatePolicy(try await store.updateCaptureSettings(settings)); raw.user("A"); capture.tick()
        settings = try await store.settings(); settings.captureEnabled = true
        capture.updatePolicy(try await store.updateCaptureSettings(settings)); capture.tick()
        #expect(try await store.search(.init()).items.isEmpty)
        raw.user("B"); capture.tick()
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init()).items.count == 1)
    }
    /// 事件四类状态精确断言，不创建 delivered。
    @Test func AC07_AC08_AC24_directPasteSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let input = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.string, Data("A".utf8))], plainText: "A")]))
        guard case .inserted(let id) = try await store.ingest(input, at: SystemClock().now()) else { Issue.record("缺fixture"); return }
        let raw = RawBoard(); let board = MacPasteboardClient(access: raw); let apps = FakeApplications()
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let request = PasteRequest(ids: [id], action: .directPaste, target: apps.remembered)
        // 失败时输出实际结果，便于区分超时回退、剪贴板变化或权限路径，by AI.Coding。
        let first = await paste.perform(request)
        #expect(first == .commandSent, "实际结果：\(first)"); #expect(apps.events == 1)
        apps.permitted = false
        if case .fallback = await paste.perform(request) {} else { Issue.record("缺权限未回退") }; #expect(apps.events == 1)
        apps.permitted = true; apps.alive = false
        if case .fallback = await paste.perform(request) {} else { Issue.record("退出未回退") }; #expect(apps.events == 1)
        apps.alive = true; apps.current = nil; apps.activationOK = false
        if case .fallback = await paste.perform(request) {} else { Issue.record("激活失败未回退") }
        apps.activationOK = true; apps.onActivate = { apps.current = .init(pid: 456, bundleID: "local.other", launchedAt: 200) }
        if case .fallback = await paste.perform(request) {} else { Issue.record("焦点变化未回退") }; #expect(apps.events == 1)
        apps.current = nil; apps.onActivate = { raw.user("USER-B") }
        #expect(await paste.perform(request) == .failed("剪贴板已变化，请重新选择")); #expect(apps.events == 1)
        #expect(raw.items[0][SupportedType.string] == Data("USER-B".utf8))
        apps.current = nil; apps.onActivate = {
            apps.current = .init(pid: 456, bundleID: "local.other", launchedAt: 200)
            raw.user("USER-B-COMBINED")
        }
        #expect(await paste.perform(request) == .failed("剪贴板已变化，请重新选择")); #expect(apps.events == 1)
        #expect(raw.items[0][SupportedType.string] == Data("USER-B-COMBINED".utf8))
        apps.onActivate = nil; raw.writeOK = false
        #expect(await paste.perform(request) == .failed("复制失败，请重试")); #expect(apps.events == 1)
        let reused = PasteRequest(ids: [id], action: .directPaste, target: .init(pid: 123, bundleID: "local.target", launchedAt: 999))
        raw.writeOK = true
        if case .fallback = await paste.perform(reused) {} else { Issue.record("PID重用未回退") }; #expect(apps.events == 1)
    }
    /// HTML只在本地词法提取；原始支持格式仍保留。
    @Test func AC21_E07_richAndPlain() {
        let html = "<b>中文</b><br>next<img src='https://example.invalid/image'><script>bad()</script>"
        #expect(ContentDecoder.extract(.init(SupportedType.html, Data(html.utf8))) == "中文\nnext")
        let rtf = Data("{\\rtf1\\ansi test \\b bold\\b0\\par next}".utf8)
        #expect(ContentDecoder.extract(.init(SupportedType.rtf, rtf)) == "test bold\nnext")
    }
}
