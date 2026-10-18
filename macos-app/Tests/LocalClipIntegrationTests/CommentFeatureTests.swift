// 已确认功能链路边界使用假剪贴板和临时文件，不操作桌面，by AI.Coding。
import AppKit
import ImageIO
import Carbon
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct CommentFeatureTests {
    /// 普通文件和非文本目标属于正常文件粘贴，不产生智能转换失败提示。
    @Test(arguments: ["png", "pdf", "zip", "swift-directory", "missing-code-nontext"])
    func ordinaryFilesDoNotWarn(_ kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(kind.contains("code") || kind.contains("directory") ? "sample.swift" : "sample." + kind)
        if kind == "swift-directory" { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
        else if kind != "missing-code-nontext" { try Data("original".utf8).write(to: file) }
        var settings = SettingsSnapshot(); settings.smartCodeFilePaste = true
        let store = try HistoryStore(location: root.appendingPathComponent("store"), initialSettings: settings)
        let original = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: original), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications()
        apps.targetKind = kind == "missing-code-nontext" ? .files : .text
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        #expect(await paste.perform(.init(ids: [id], action: .directPaste, target: apps.remembered)) == .commandSent)
        #expect(paste.smartPasteNotice == nil)
        #expect(raw.items.first?[SupportedType.fileURL] == Data(file.absoluteString.utf8))
    }

    /// XML 非法控制字只影响解析副本，原文 UTF-16 范围仍可正确着色。
    @Test func codeControlsRemainHighlightable() async throws {
        let source = "let value = \"a\u{1B}b\u{0C}中😀\"\r\n"
        let result = try #require(await SyntaxHighlighter.detail.highlight(source, languageHint: "swift"))
        #expect(result.analyzedUTF16Count == source.utf16.count)
        #expect(result.spans.allSatisfy { NSMaxRange($0.range) <= source.utf16.count })
    }
    /// 缓存与新引擎逐样本对照，含未识别结果和淘汰后重算，不串样本长度。
    @Test func languageCachePreservesDetectionAcrossSamples() async {
        let cached = SyntaxHighlighter()
        let code = "func greet(name: String) -> String {\n    return \"Hello \" + name\n}\n"
        for sample in [1, 512, 2048, 0, -1, 512] {
            let expected = await SyntaxHighlighter().language(of: code, sample: sample)
            #expect(await cached.language(of: code, sample: sample) == expected)
            #expect(await cached.language(of: code, sample: sample) == expected)
        }
        for index in 0..<66 { _ = await cached.language(of: "ordinary prose \(index)") }
        #expect(await cached.language(of: code) == SyntaxHighlighter().language(of: code))
    }

    /// 前台状态恢复仅清除排除提示，排除间切换与暂停不被误标正常。
    @Test func activationClearsOnlyStaleExcludedStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.pauseWhenExcludedFrontmost = true; settings.excludedBundleIDs = ["local.private", "local.private2"]
        let store = try HistoryStore(location: root, initialSettings: settings)
        let raw = RawBoard(), capture = CaptureCoordinator(board: MacPasteboardClient(access: raw), store: store)
        capture.updatePolicy(settings)
        raw.items = [[SupportedType.string: Data("private".utf8), "org.nspasteboard.source": Data("local.private".utf8)]]; raw.count += 1
        capture.tick()
        #expect(capture.state == "排除应用在前台，未采集")
        capture.applicationDidActivate("local.private2")
        #expect(capture.state == "排除应用在前台，未采集")
        capture.applicationDidActivate("local.allowed")
        #expect(capture.state == "正常" && raw.reads.allSatisfy { $0 != SupportedType.string })
        capture.requestPause(); capture.applicationDidActivate("local.allowed")
        #expect(capture.state == "正在暂停")
    }

    /// 跳过轮询间隙的排除来源，同时保留先前已采集的正常队列。
    @Test(arguments: [true, false])
    func excludedDeparturePreservesAllowedQueue(_ enabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.pauseWhenExcludedFrontmost = enabled; settings.excludedBundleIDs = ["local.private"]
        let store = try HistoryStore(location: root, initialSettings: settings)
        let raw = RawBoard(), capture = CaptureCoordinator(board: MacPasteboardClient(access: raw), store: store)
        capture.updatePolicy(settings)
        raw.user("allowed-before"); capture.tick()
        raw.user("between-polls"); capture.applicationDidDeactivate("local.private"); capture.tick()
        raw.user("allowed-after"); capture.tick()
        let expected = enabled ? 2 : 3
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.count < expected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let values = try await store.search(.init()).items.map(\.preview)
        #expect(values.contains("allowed-before") && values.contains("allowed-after"))
        #expect(values.contains("between-polls") == !enabled)
        capture.stop()
    }

    /// 取消转换后恢复原文件；用户新复制和已到期记录均不得覆盖。
    @Test(arguments: ["cancel", "new-copy", "expired", "cancel-target-change"])
    func convertedPasteFailurePreservesOwnership(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.swift"); try Data("let value = 42".utf8).write(to: file)
        let clock = CommentClock()
        var settings = SettingsSnapshot(); settings.smartCodeFilePaste = true; settings.retentionDays = 1
        let store = try HistoryStore(location: root.appendingPathComponent("store"), clock: clock, initialSettings: settings)
        let original = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: original), at: clock.now()) else { Issue.record("fixture"); return }
        let raw = CommentWriteBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications(); apps.targetKind = .text
        let capture = CaptureCoordinator(board: board, store: store, clock: clock)
        let paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture, clock: clock)
        var operation: Task<PasteResult, Never>?
        var converted = false
        raw.onWrite = { payload in
            guard payload.fileURLs == nil else { return }
            converted = true
            if mode == "expired" { clock.advance(2 * dayMS) }
            else {
                operation?.cancel()
                if mode == "new-copy" { raw.raw.user("new-user-copy") }
                if mode == "cancel-target-change" { apps.permitted = false }
            }
        }
        operation = Task { await paste.perform(.init(ids: [id], action: .directPaste, target: apps.remembered)) }
        let result = await operation!.value
        #expect(converted && apps.events == 0)
        if case .failed = result {} else { Issue.record("failure must not send paste") }
        if mode == "new-copy" { #expect(raw.raw.items.first?[SupportedType.string] == Data("new-user-copy".utf8)) }
        else if mode == "expired" { #expect(raw.raw.items.first?[SupportedType.fileURL] == nil) }
        else { #expect(raw.raw.items.first?[SupportedType.fileURL] == Data(file.absoluteString.utf8)) }
    }

    /// 逐个方向检查原帧元数据传给 OCR，包括四种镜像。
    @Test(arguments: Array(1...8)) func imageOrientation(_ orientation: Int) throws {
        let png = try ImageFixtures.image(width: 8, height: 4)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, SupportedType.tiff as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try ImageTextRecognizer.decode(.init([.init([.init(SupportedType.tiff, bytes as Data)])]))
        #expect(decoded.orientation.rawValue == UInt32(orientation))
        #expect(decoded.image.width == 8 && decoded.image.height == 4)
    }

    @Test func timeoutAndShortcutLabels() {
        #expect(FinderLookupError.from(code: -1712).message.contains("超时"))
        #expect(FinderLookupError.from(code: -1743).message.contains("允许"))
        for (code, label) in [(kVK_LeftArrow, "←"), (kVK_Escape, "Esc"), (kVK_Delete, "⌫"), (kVK_F1, "F1"), (kVK_F20, "F20")] {
            #expect(HotKeyService.label(.init(keyCode: UInt32(code), modifiers: 0)) == label)
        }
    }

    /// 文件承诺直接写临时目录，不执行真实拖拽；悬空链接也必须避让。
    @Test func exportAvoidsDanglingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root.appendingPathComponent("store"))
        let text = Data("plain export words".utf8)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, text)])])), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let writer = try #require(try await ContentExportProvider.writers(ids: [id], store: store, token: "test", register: { _ in }).first)
        let provider = try #require(ContentExportProvider.promiseProvider(for: writer)), delegate = try #require(provider.delegate)
        let destination = root.appendingPathComponent("result.txt"), missing = root.appendingPathComponent("missing.txt")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: missing)
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { @Sendable in continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try Data(contentsOf: root.appendingPathComponent("result 2.txt")) == text)
    }

}

/// 精确模拟写入成功之后的取消边界，不接触系统剪贴板。
@MainActor private final class CommentWriteBoard: PasteboardAccess {
    let raw = RawBoard()
    var onWrite: ((ClipboardPayload) -> Void)?
    var count: Int { raw.count }
    var types: [[String]]? { raw.types }
    func data(item: Int, type: String) -> Data? { raw.data(item: item, type: type) }
    func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool {
        let success = raw.write(payload, fingerprint: fingerprint)
        onWrite?(payload)
        return success
    }
}
private final class CommentClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Instant = SystemClock().now()
    func now() -> Instant { lock.withLock { value } }
    func advance(_ delta: Instant) { lock.withLock { value += delta } }
}
