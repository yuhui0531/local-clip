// 无窗口、无系统剪贴板、无目标应用事件；验证原生验收发现的输入及异步契约，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

private final class AcceptanceClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = SystemClock().now()
    func now() -> Instant { lock.withLock { value } }
    func advance(_ amount: Instant) { lock.withLock { value += amount } }
}

private actor AcceptanceRecognitionGate {
    private var pending: [Int: CheckedContinuation<[String], Never>] = [:]
    var started = 0
    func recognize() async -> [String] {
        started += 1
        let request = started
        return await withCheckedContinuation { pending[request] = $0 }
    }
    func finish(_ request: Int, text: String) { pending.removeValue(forKey: request)?.resume(returning: [text]) }
}

@MainActor struct NonInteractiveAcceptanceTests {
    @Test func searchTabUsesNativeFocusAndReturnStillEntersResults() {
        var entries = 0, navigation = 0, closes = 0
        let field = SearchField(text: .constant(""), focus: UUID(), onChange: {},
            onNavigate: { navigation += $0 }, onEnter: { entries += 1 }, onEscape: { closes += 1 })
        let delegate = field.makeCoordinator(), control = NSSearchField(), editor = NSTextView()
        for selector in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))] {
            #expect(!delegate.control(control, textView: editor, doCommandBy: selector))
        }
        #expect(entries == 0)
        #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(entries == 1)
        editor.setMarkedText("拼", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
                         #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!delegate.control(control, textView: editor, doCommandBy: selector))
        }
        #expect(entries == 1 && navigation == 0 && closes == 0)
    }

    @Test func focusedControlsKeepActivationAndNavigationKeys() throws {
        let results = NSResponder(), menu = NSPopUpButton(), button = NSButton(), editor = NSTextView()
        // 包括Space、Return、Shift-Return、方向键、删除，防止错误预览/粘贴/删除所选历史。
        for keyCode: UInt16 in [49, 36, 76, 123, 124, 125, 126, 51, 117] {
            for flags: NSEvent.ModifierFlags in [[], .shift] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
                for control in [menu as NSResponder, button] {
                    #expect(AppDelegate.preservesFocusedControlKeys(event, firstResponder: control, resultsResponder: results))
                }
                #expect(!AppDelegate.preservesFocusedControlKeys(event, firstResponder: results, resultsResponder: results))
                #expect(!AppDelegate.preservesFocusedControlKeys(event, firstResponder: editor, resultsResponder: results))
            }
        }
        // 应用级Cmd-F、Cmd-C和已有组合快捷键不被这个无修饰导航规则禁用。
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(!AppDelegate.preservesFocusedControlKeys(copy, firstResponder: button, resultsResponder: results))
    }

    @Test(arguments: ["expiry", "persisted-hide", "superseded-old-first", "superseded-new-first"])
    func ocrLateCompletionCannotPublishStaleContent(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceptanceClock(), gate = AcceptanceRecognitionGate()
        let store = try HistoryStore(location: root, clock: clock), raw = RawBoard()
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store, clock: clock)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture, clock: clock),
            derived: DerivedContentService(store: store), clock: clock)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data([1, 2, 3]))])])), at: clock.now()) else { throw StoreError.notFound }
        try await model.start(); capture.stop()
        model.recognizeImageText = { _ in await gate.recognize() }
        raw.user("initial"); let count = raw.count
        func waitForStart(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while await gate.started < count, ContinuousClock.now < deadline { await Task.yield() }
            try #require(await gate.started == count)
        }
        model.copyImageText(id: id)
        let first = try #require(model.imageTextTask)
        try await waitForStart(1)
        if scenario.hasPrefix("superseded") {
            model.copyImageText(id: id)
            let second = try #require(model.imageTextTask)
            try await waitForStart(2)
            if scenario == "superseded-old-first" {
                await gate.finish(1, text: "stale"); await first.value
                #expect(raw.count == count)
                await gate.finish(2, text: "latest"); await second.value
            } else {
                await gate.finish(2, text: "latest"); await second.value
                await gate.finish(1, text: "stale"); await first.value
            }
            #expect(raw.count == count + 1)
            #expect(raw.items.first?[SupportedType.string] == Data("latest".utf8))
        } else {
            if scenario == "expiry" { clock.advance(31 * dayMS) }
            else {
                var settings = try await store.settings(); settings.hideContents = true
                _ = try await store.updateCaptureSettings(settings)
            }
            await gate.finish(1, text: "stale"); await first.value
            #expect(raw.count == count)
            #expect(raw.items.first?[SupportedType.string] == Data("initial".utf8))
        }
    }
}
