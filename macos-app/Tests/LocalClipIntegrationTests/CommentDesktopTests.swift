// 仅显式授权时展示测试窗口；临时历史和假剪贴板隔离用户数据，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
import ServiceManagement
@testable import LocalClipMac

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct CommentDesktopTests {
    /// 同一应用保持激活、复用设置宿主时，外部状态必须重新读取；不注册真实登录项。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_COMMENT_DESKTOP"] == "1"))
    func settingsReopenRefreshesLoginWithoutAppActivation() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let (root, _, model) = try await setup()
        var status = SMAppService.Status.notRegistered
        var reads = 0
        let login = LoginItemService(readStatus: { reads += 1; return status })
        let host = NSHostingView(rootView: SettingsView(model: model, login: login, section: .general, fitWindow: { _ in }))
        host.sizingOptions = []
        let window = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close(); previous?.activate(options: []); try? FileManager.default.removeItem(at: root) }
        show(window, host)
        try await wait { reads > 0 }
        try await Task.sleep(for: .milliseconds(250))
        window.resignKey(); window.close()
        try await Task.sleep(for: .milliseconds(100))
        let initialReads = reads
        status = .requiresApproval
        // 仅重开窗口，不发布应用激活通知，不重建SwiftUI宿主。
        window.makeKeyAndOrderFront(nil)
        // Swift Testing宿主不保证系统焦点；显式执行真实窗口生命周期，验证通知到现有视图的路径。
        window.becomeKey()
        try await wait { reads > initialReads }
        // SwiftUI Text 不保证映射为 NSTextField；渲染另留图核验，不依赖内部视图类型。
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.settings.retentionDays == 30)
        try snapshot(host, "settings-login-refreshed")
    }
    private func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "wait from line \(line)")
    }
    private func setup(_ count: Int = 1) async throws -> (URL, HistoryStore, HistoryViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root)
        for n in 0..<count { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("desktop-fixture-\(n)".utf8))])])), at: SystemClock().now() + Int64(n)) }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        try await wait { model.items.count >= min(count, 6) && !model.historyBusy }
        return (root, store, model)
    }
    private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, type) }
    }
    private func show(_ window: NSWindow, _ host: NSView) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeKey(); host.layoutSubtreeIfNeeded()
    }
    private func key(_ code: UInt16, _ text: String, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        // 测试宿主常拿不到前台激活，非 key 窗口的 sendEvent 会先结束字段编辑；正在编辑时直接交给字段编辑器，by AI.Coding。
        if let editor = window.firstResponder as? NSTextView { editor.keyDown(with: event) } else { window.sendEvent(event) }
    }
    private func type(_ text: String, into field: NSTextField, window: NSWindow) throws {
        // 已在编辑时不再 makeFirstResponder：重复设置会先结束当前编辑会话，触发 onCancel 撤销改名，by AI.Coding。
        if field.currentEditor() == nil { try #require(window.makeFirstResponder(field)) }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    private func snapshot(_ host: NSView, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LOCALCLIP_COMMENT_DESKTOP_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded(); host.window?.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    /// 真实 TextField 和 Return 验证失败草稿及旧保存结果；失焦与 Esc 另在完整应用验证。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_COMMENT_DESKTOP"] == "1"))
    func visibleRenamePreservesDraftAcrossSubmissions() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let (root, store, model) = try await setup()
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close(); previous?.activate(options: []); try? FileManager.default.removeItem(at: root) }
        show(window, host)
        let id = try #require(model.items.first?.id)
        // 等初次搜索焦点交接结束，再开始用户编辑，避免测试抢在窗口激活前操作。
        try await Task.sleep(for: .milliseconds(250))
        window.makeFirstResponder(nil)
        model.beginRename(id)
        try await wait { views(host, NSTextField.self).contains { $0.placeholderString == "名称" } }
        let field = try #require(views(host, NSTextField.self).first { $0.placeholderString == "名称" })
        let invalid = String(repeating: "x", count: 1025)
        // 等原生字段完成首次异步聚焦再输入，与真实用户时序一致；抢先输入会被随后的聚焦结束编辑，by AI.Coding。
        try await wait { field.currentEditor() != nil }
        try type(invalid, into: field, window: window); try key(36, "\r", in: window)
        try await wait { model.message.contains("重命名失败") }
        #expect(model.renamingID == id && field.stringValue == invalid)
        try snapshot(host, "rename-failed-draft")
        try type("submitted-native", into: field, window: window); try key(36, "\r", in: window)
        try type("continued-native-draft", into: field, window: window)
        try await wait { model.items.first?.title == "submitted-native" }
        #expect(model.renamingID == id && field.stringValue == "continued-native-draft")
        try key(36, "\r", in: window)
        try await wait { model.renamingID == nil && model.items.first?.title == "continued-native-draft" }
        #expect(try await store.metadata(id: id, at: SystemClock().now()).summary.title == "continued-native-draft")
        try snapshot(host, "rename-saved-after-continued-input")
    }

    /// 宿主滚动位置真的改变，而非只检查模型发布了滚动请求。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_COMMENT_DESKTOP"] == "1"))
    func visibleLocationRevealsSameSelection() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let (root, _, model) = try await setup(12)
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close(); previous?.activate(options: []); try? FileManager.default.removeItem(at: root) }
        show(window, host)
        try await wait { views(host, NSScrollView.self).contains { ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width } }
        let scroll = try #require(views(host, NSScrollView.self).first { ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width })
        let id = try #require(model.items.last?.id)
        model.select(id)
        try await wait { scroll.contentView.bounds.minX > 0 }
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        try await wait { scroll.contentView.bounds.minX == 0 }
        model.jumpToHistory()
        try await wait { !model.historyBusy && scroll.contentView.bounds.minX > 0 }
        let target = try #require(views(host, HistoryDragBridge.DragView.self).first { $0.id == id })
        #expect(!target.visibleRect.isEmpty && model.selectedID == id)
        try snapshot(host, "located-same-selection")
        model.query = "desktop-fixture"; model.searchChanged(debounce: false)
        try await wait { !model.historyBusy }
        let before = model.items
        model.jumpToHistory(category: "missing")
        try await wait { !model.historyBusy }
        #expect(model.query == "desktop-fixture" && model.items == before)
    }

    /// 保留同一设置宿主关闭重开，重复非法值必须再次出现在实际原生标签。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_COMMENT_DESKTOP"] == "1"))
    func visibleSettingsRepeatValidationAfterReopen() async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let (root, _, model) = try await setup()
        let host = NSHostingView(rootView: SettingsView(model: model, login: LoginItemService(), section: .storage, fitWindow: { _ in })); host.sizingOptions = []
        let window = SettingsWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close(); previous?.activate(options: []); try? FileManager.default.removeItem(at: root) }
        show(window, host)
        try await Task.sleep(for: .milliseconds(250))
        try await wait { views(host, NSTextField.self).contains { $0.isEditable && $0.stringValue == "30" } }
        let field = try #require(views(host, NSTextField.self).first { $0.isEditable && $0.stringValue == "30" })
        for attempt in 0..<2 {
            try type("999", into: field, window: window); try key(36, "\r", in: window)
            try await wait { views(host, NSTextField.self).contains { $0.stringValue.contains("保留天数需为1–365") } }
            #expect(model.settings.retentionDays == 30)
            try snapshot(host, "settings-invalid-\(attempt)")
            if attempt == 0 {
                window.close()
                try await wait { !views(host, NSTextField.self).contains { $0.stringValue.contains("保留天数需为1–365") } }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
