// 外观旧快照、持久化与未展示窗口的关闭回归，不读取生产数据，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct SettingsAppearanceTests {
    /// 设置中的中文组合输入先处理Esc；组合结束后同一按键仍可关闭窗口，by AI.Coding。
    @Test func settingsEscapePreservesMarkedText() throws {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { closed = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(editor.hasMarkedText())
        window.sendEvent(escape)
        #expect(!closed)
        editor.unmarkText()
        window.sendEvent(escape)
        #expect(closed)
    }

    /// 工具栏外观按钮按跟随系统→浅色→深色循环，三态图标互不相同，by AI.Coding。
    @Test func toolbarThemeButtonCycles() {
        #expect(HistoryView.nextAppearance(.system) == .light)
        #expect(HistoryView.nextAppearance(.light) == .dark)
        #expect(HistoryView.nextAppearance(.dark) == .system)
        #expect(Set(AppAppearance.allCases.map(HistoryView.appearanceSymbol)).count == 3)
    }

    /// 旧JSON缺少新字段时保留默认值；所有主题与紧凑选择可往返保存。
    @Test func appearanceDefaultsAndPersistence() async throws {
        let original = try JSONEncoder().encode(SettingsSnapshot())
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        document.removeValue(forKey: "appearanceValue"); document.removeValue(forKey: "compactLayoutValue")
        let old = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(old.appearance == .system); #expect(!old.compactLayout)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for appearance in AppAppearance.allCases {
            var settings = try await store.settings()
            settings.appearance = appearance; settings.compactLayout = true
            _ = try await store.updateCaptureSettings(settings)
            let reopened = try HistoryStore(location: root)
            let saved = try await reopened.settings()
            #expect(saved.appearance == appearance); #expect(saved.compactLayout)
        }
    }

    /// 实际NSWindow关闭通知证明失焦保留、显式取消关闭，by AI.Coding。
    @Test func settingsWindowCancellationAndFocus() async throws {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.delegate = window
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { closed = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.resignKey()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!closed)
        window.becomeKey(); window.resignKey()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!closed)
        // LC-012：失焦保留设置上下文；显式取消才发出关闭通知，by AI.Coding。
        window.cancelOperation(nil)
        #expect(closed)
        let escapeWindow = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: true)
        escapeWindow.isReleasedWhenClosed = false
        var escapeClosed = false
        let escapeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: escapeWindow, queue: .main) { _ in
            MainActor.assumeIsolated { escapeClosed = true }
        }
        defer { NotificationCenter.default.removeObserver(escapeObserver) }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: escapeWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        escapeWindow.sendEvent(escape)
        #expect(escapeClosed)
    }
}
