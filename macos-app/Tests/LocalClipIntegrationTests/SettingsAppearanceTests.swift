// 外观旧快照、持久化与未展示窗口的关闭回归，不读取生产数据，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct SettingsAppearanceTests {
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

    /// 实际NSWindow关闭通知证明取消命令和失焦关闭生效，返回焦点撤销待关闭任务。
    @Test func settingsWindowCancellationAndFocus() async throws {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.delegate = window
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { closed = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.windowDidResignKey(.init(name: NSWindow.didResignKeyNotification, object: window))
        window.windowDidBecomeKey(.init(name: NSWindow.didBecomeKeyNotification, object: window))
        try await Task.sleep(for: .milliseconds(250))
        #expect(!closed)
        window.windowDidResignKey(.init(name: NSWindow.didResignKeyNotification, object: window))
        try await Task.sleep(for: .milliseconds(250))
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
