// 指定报告的原生菜单身份回归，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

/// 识别器可挂起，避免依赖机器OCR速度制造竞争，by AI.Coding。
private actor ReviewRecognitionGate {
    var started = false
    private var continuation: CheckedContinuation<[String], Never>?
    func recognize() async -> [String] {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: ["recognized"]); continuation = nil }
}

@MainActor struct SpecifiedReviewUITests {
    /// LC-002/007：隐藏、删除或新复制使挂起OCR结果无效，正常结果仍可复制。
    @Test(arguments: ["hide", "delete", "copy", "normal"])
    func ocrCompletionRevalidatesIntent(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard(), gate = ReviewRecognitionGate()
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data([1, 2, 3]))])])), at: SystemClock().now()) else { throw StoreError.notFound }
        try await model.start(); capture.stop()
        model.recognizeImageText = { _ in await gate.recognize() }
        raw.user("initial"); let before = raw.count
        model.copyImageText(id: id)
        let completion = try #require(model.imageTextTask)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.started), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.started)
        switch scenario {
        case "hide":
            model.updateSettings { $0.hideContents = true }
            while !model.settings.hideContents, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.settings.hideContents)
            model.select(id); model.showingDetail = true; model.detailVisibilityChanged(); model.quickLook()
            #expect(!model.showingDetail && model.detail == nil)
        case "delete": _ = try await store.apply(store.preview(.delete([id])).token)
        case "copy": raw.user("new-user-copy")
        default: break
        }
        await gate.finish()
        await completion.value
        if scenario == "normal" {
            #expect(raw.items.first?[SupportedType.string] == Data("recognized".utf8))
        } else {
            #expect(raw.count == before + (scenario == "copy" ? 1 : 0))
            #expect(raw.items.first?[SupportedType.string] == Data((scenario == "copy" ? "new-user-copy" : "initial").utf8))
        }
    }

    /// LC-015：原地改写、同路径原子替换、删除均使文件引用预览版本失效。
    @Test func fileReferenceVersionTracksExternalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("first".utf8).write(to: file)
        let first = try #require(FileReferencePreviewVersion.read([file]))
        #expect(first.isCurrent())
        try Data("changed-in-place".utf8).write(to: file)
        #expect(!first.isCurrent())
        let second = try #require(FileReferencePreviewVersion.read([file]))
        try Data("replacement".utf8).write(to: file, options: .atomic)
        #expect(!second.isCurrent())
        try FileManager.default.removeItem(at: file)
        #expect(FileReferencePreviewVersion.read([file]) == nil)
    }

    /// LC-004：总载荷超限时先失败；不写入任何一部分，也不改原历史。
    @Test func batchOutputRejectsBeforePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        let board = MacPasteboardClient(access: raw), apps = FakeApplications()
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        var ids: [ClipID] = []
        for byte in [UInt8(3), 4] {
            let payload = ClipboardPayload([.init([.init(SupportedType.png, Data(repeating: byte, count: 26 * Int(MiB)))])])
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else { throw StoreError.notFound }
            ids.append(id)
        }
        raw.user("new-user-copy")
        let count = raw.count
        #expect(await paste.perform(.init(ids: ids)) == .failed("所选内容超过50MiB输出预算；请减少选择或使用粘贴队列"))
        #expect(raw.count == count)
        #if DEBUG
        #expect(await store.outputPayloadLoads == 0)
        #endif
        #expect(try await store.search(.init()).items.count == 2)
    }

    /// 可选队列项和更新项不改变采集动作身份；复用实际NSMenu更新入口。
    @Test func captureMenuUsesActionIdentity() {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let expectedTitle = menu.items.first { $0.action == NSSelectorFromString("toggleCapture") }?.title
        let queue = NSMenuItem(title: "结束粘贴队列", action: NSSelectorFromString("stopPasteQueue"), keyEquivalent: "")
        menu.insertItem(queue, at: 2)
        delegate.menuNeedsUpdate(menu)
        #expect(queue.title == "结束粘贴队列")
        #expect(queue.action == NSSelectorFromString("stopPasteQueue"))
        #expect(menu.items.first { $0.action == NSSelectorFromString("toggleCapture") }?.title == expectedTitle)
    }
}
