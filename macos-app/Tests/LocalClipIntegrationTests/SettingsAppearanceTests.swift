// 外观旧快照、持久化与未展示窗口的关闭回归，不读取生产数据，by AI.Coding。
import AppKit
import SwiftUI
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct SettingsAppearanceTests {
    /// 隐藏窗口承载真实设置表单，验证传统滚动条不再占位且长内容仍可滚动，by AI.Coding。
    @Test(arguments: SettingsSection.allCases) func settingsFormHidesLegacyScroller(section: SettingsSection) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        let host = NSHostingView(rootView: SettingsView(model: model, login: LoginItemService(), section: section, fitWindow: { _ in }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        let scroll = try #require(scrollViews(host).first)
        #expect(scroll.scrollerStyle == .overlay)
        #expect((scroll.verticalScroller?.alphaValue ?? 0) == 0)
        // 模拟系统“始终显示滚动条”，再触发偏好变更通知，检查原生滚动条状态。
        scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false; scroll.hasVerticalScroller = true
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.alphaValue == 0)
        if section == .general { #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 40) }
        if (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 40 {
            let clip = scroll.contentView
            let before = clip.bounds
            var proposed = before; proposed.origin.y += 40
            #expect(clip.constrainBoundsRect(proposed).origin.y > clip.constrainBoundsRect(before).origin.y)
            #expect(scroll.verticalScroller?.alphaValue == 0)
        }
    }
    /// 自适应设置窗口能完整容纳表单时，不存在可滚动范围或弹性位移，by AI.Coding。
    @Test(arguments: SettingsSection.allCases) func fittedSettingsGeometry(section: SettingsSection) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        let window = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView(model: model, login: LoginItemService(), section: section, fitWindow: { [weak window] in window?.fitContent(height: $0) }))
        host.sizingOptions = []; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        let scroll = try #require(scrollViews(host).first)
        let document = try #require(scroll.documentView)
        let available = scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        // 屏幕不足时仍应能滚动；屏幕充足时直接验证上下两端无法滚动。
        if document.bounds.height <= available + 0.5 {
            #expect(scroll.verticalScrollElasticity == .none)
            let clip = scroll.contentView
            let before = clip.bounds
            let base = clip.constrainBoundsRect(before).origin.y
            // 直接检查 AppKit 对滚动范围的约束；不会投递系统输入。
            for delta: CGFloat in [-40, 40] {
                var proposed = before; proposed.origin.y += delta
                #expect(abs(clip.constrainBoundsRect(proposed).origin.y - base) < 0.5)
            }
        } else {
            let screenHeight = try #require((window.screen ?? NSScreen.main)?.visibleFrame.height)
            #expect(window.frame.height >= screenHeight - 1)
        }

    }
    /// 超长内容按指定屏幕范围约束，使用虚拟几何值而不依赖真实显示器，by AI.Coding。
    @Test func settingsWindowFitsVisibleScreen() {
        let visible = NSRect(x: 100, y: 50, width: 1000, height: 700)
        let current = NSRect(x: 150, y: 200, width: 620, height: 350)
        let frame = SettingsWindow.fittedFrame(current: current, requestedHeight: 2000, frameExtra: 28, visible: visible)
        #expect(frame.height == visible.height)
        #expect(frame.minY >= visible.minY && frame.maxY <= visible.maxY)
        let short = SettingsWindow.fittedFrame(current: current, requestedHeight: 300, frameExtra: 28, visible: visible)
        #expect(short.height == 328 && short.maxY == current.maxY)
    }
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

    /// 工具栏外观按钮按当前实际显示切到相反的深浅色，不经过“跟随系统”，by AI.Coding。
    @Test func toolbarThemeButtonToggles() {
        #expect(HistoryView.toggledAppearance(showingDark: false) == .dark)
        #expect(HistoryView.toggledAppearance(showingDark: true) == .light)
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
