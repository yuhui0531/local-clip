// 退出路由与焦点生命周期回归只用本进程菜单、虚拟可见窗口和假终止请求，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipMac

@MainActor private final class FocusTestWindow: NSWindow {
    override var isVisible: Bool { true }
}

@MainActor struct QuitFocusTests {
    /// 明确目标的菜单动作调用共享退出入口，不终止测试或用户进程，by AI.Coding。
    @Test func statusQuitTargetsApplicationAction() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        var requests = 0
        delegate.requestTermination = { requests += 1 }
        let item = try #require(delegate.makeStatusMenu().items.first { $0.keyEquivalent == "q" })
        #expect(item.target === delegate)
        #expect(item.action == #selector(AppDelegate.quitApplication(_:)))
        guard item.target === delegate, item.action == #selector(AppDelegate.quitApplication(_:)) else { return }
        #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
        #expect(requests == 1)
    }
    /// Cmd-Q在菜单栏图标不可用时仍能退出，Shift/其他命令保持原有语义，by AI.Coding。
    @Test func commandQuitUsesSharedAction() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        var requests = 0
        delegate.requestTermination = { requests += 1 }
        func event(_ flags: NSEvent.ModifierFlags, _ text: String = "q") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: 12))
        }
        #expect(delegate.handleQuitShortcut(try event(.command)))
        #expect(requests == 1)
        #expect(!delegate.handleQuitShortcut(try event([.command, .shift])))
        #expect(!delegate.handleQuitShortcut(try event(.command, "c")))
        #expect(!delegate.handleQuitShortcut(try event([])))
        #expect(requests == 1)
    }
    /// 明确点击外部时菜单不能永久挡住关闭，拖动和确认仍先完成，by AI.Coding。
    @Test func externalInteractionDismissesAfterProtectedWork() {
        _ = NSApplication.shared
        var focus = HistoryPanelFocusState()
        let menu = NSMenu()
        focus.menuBegan(ObjectIdentifier(menu)); focus.externalInteraction()
        #expect(focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: false))
        #expect(!focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: true, confirming: false, hasModal: false))
        #expect(!focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: true, hasModal: false))
        #expect(!focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: true))
        #expect(focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: false))
    }
    /// 置顶时外部点击与失焦都不收起面板；取消置顶后恢复原规则。
    @Test func pinnedPanelIgnoresFocusLoss() {
        var focus = HistoryPanelFocusState()
        focus.externalInteraction()
        #expect(!focus.shouldDismiss(panelIsKey: false, ownsKeyWindow: false, dragging: false, confirming: false, hasModal: false, pinned: true))
        #expect(focus.shouldDismiss(panelIsKey: false, ownsKeyWindow: false, dragging: false, confirming: false, hasModal: false, pinned: false))
    }
    /// 面板兜底的Esc与取消命令走统一收起回调，不再绕过状态复位。
    @Test func panelCancelRoutesThroughDismissal() throws {
        _ = NSApplication.shared
        let panel = ClipPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        var cancels = 0
        panel.onCancel = { cancels += 1 }
        panel.cancelOperation(nil)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.keyDown(with: escape)
        #expect(cancels == 2)
    }
    /// 用户重新进入面板会取消离开意图，自动恢复key不能取消已发生的外部点击，by AI.Coding。
    @Test func ownedInputSupersedesPendingOutsideClick() {
        var focus = HistoryPanelFocusState()
        focus.externalInteraction()
        #expect(focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: false))
        focus.ownedInteraction()
        #expect(!focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: false))
        #expect(focus.shouldDismiss(panelIsKey: false, ownsKeyWindow: false, dragging: false, confirming: false, hasModal: false))
        #expect(!focus.shouldDismiss(panelIsKey: false, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: false))
    }
    /// 异步全局监视迟到的旧点击不能覆盖用户已经返回面板的输入，by AI.Coding。
    @Test func delayedExternalEventCannotOverrideNewerOwnedInput() {
        var focus = HistoryPanelFocusState()
        focus.externalInteraction(at: 10)
        let returnedToPanel = focus.ownedInteraction(at: 12)
        #expect(returnedToPanel)
        focus.externalInteraction(at: 11)
        #expect(!focus.externalInteractionPending)
        focus.externalInteraction(at: 13)
        let staleReentry = focus.ownedInteraction(at: 12)
        #expect(!staleReentry)
        #expect(focus.externalInteractionPending)
        #expect(focus.shouldDismiss(panelIsKey: true, ownsKeyWindow: true, dragging: false, confirming: false, hasModal: false))
    }
    /// 重复开始和无关结束不会把菜单保护计数留住或提前消掉，by AI.Coding。
    @Test func menuIdentityTracksNestedAndDuplicateNotifications() {
        _ = NSApplication.shared
        var focus = HistoryPanelFocusState()
        let root = NSMenu(), child = NSMenu(), unrelated = NSMenu()
        focus.menuBegan(ObjectIdentifier(root)); focus.menuBegan(ObjectIdentifier(root)); focus.menuBegan(ObjectIdentifier(child))
        focus.menuEnded(ObjectIdentifier(unrelated)); focus.menuEnded(ObjectIdentifier(root))
        #expect(focus.isTrackingMenu)
        #expect(!focus.shouldDismiss(panelIsKey: false, ownsKeyWindow: false, dragging: false, confirming: false, hasModal: false))
        focus.menuEnded(ObjectIdentifier(child)); focus.menuEnded(ObjectIdentifier(child))
        #expect(!focus.isTrackingMenu)
        #expect(focus.shouldDismiss(panelIsKey: false, ownsKeyWindow: false, dragging: false, confirming: false, hasModal: false))
        focus.externalInteraction(); focus.menuBegan(ObjectIdentifier(root)); focus.reset()
        #expect(!focus.externalInteractionPending && !focus.isTrackingMenu)
    }
    /// 无公开parent的筛选/分类/详情弹窗也受保护，设置和反馈始终排除，by AI.Coding。
    @Test func allHistoryPopoversShareOwnership() {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        let popover = FocusTestWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        let settings = FocusTestWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        let feedback = FocusTestWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            #expect(AppDelegate.ownsHistoryWindow(popover, panel: panel, settings: settings, feedback: feedback,
                showingDetail: flags.0, showingCategoryEditor: flags.1, showingFilters: flags.2))
            #expect(!AppDelegate.ownsHistoryWindow(settings, panel: panel, settings: settings, feedback: feedback,
                showingDetail: flags.0, showingCategoryEditor: flags.1, showingFilters: flags.2))
            #expect(!AppDelegate.ownsHistoryWindow(feedback, panel: panel, settings: settings, feedback: feedback,
                showingDetail: flags.0, showingCategoryEditor: flags.1, showingFilters: flags.2))
        }
        #expect(AppDelegate.ownsHistoryWindow(panel, panel: panel, settings: settings, feedback: feedback,
            showingDetail: false, showingCategoryEditor: false, showingFilters: false))
        #expect(!AppDelegate.ownsHistoryWindow(popover, panel: panel, settings: settings, feedback: feedback,
            showingDetail: false, showingCategoryEditor: false, showingFilters: false))
    }
    /// 详情复制/删除和确认默认按钮不能转成历史命令；普通面板导航仍可路由，by AI.Coding。
    @Test func popoverAndConfirmationKeysStayNative() {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        let popover = FocusTestWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        #expect(AppDelegate.ownsHistoryWindow(popover, panel: panel, settings: nil, feedback: nil,
            showingDetail: true, showingCategoryEditor: false, showingFilters: false))
        #expect(!AppDelegate.routesHistoryShortcuts(popover, panel: panel, confirming: false, hasModal: false))
        panel.addChildWindow(popover, ordered: .above)
        defer { panel.removeChildWindow(popover) }
        #expect(!AppDelegate.routesHistoryShortcuts(popover, panel: panel, confirming: true, hasModal: false))
        #expect(!AppDelegate.routesHistoryShortcuts(panel, panel: panel, confirming: true, hasModal: false))
        #expect(!AppDelegate.routesHistoryShortcuts(panel, panel: panel, confirming: false, hasModal: true))
        #expect(AppDelegate.routesHistoryShortcuts(panel, panel: panel, confirming: false, hasModal: false))
    }

    /// 标准关闭命令对无标题栏面板沿用收起回调，不销毁窗口或触碰历史。
    @Test func standardCloseUsesPanelDismissal() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate(), menu = delegate.makeMainMenu()
        let item = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == "w" })
        #expect(item.target == nil && item.action == #selector(NSWindow.performClose(_:)))
        let panel = ClipPanel(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        #expect(panel.validateMenuItem(item))
        var closed = 0; panel.onCancel = { closed += 1 }
        #expect(NSApp.sendAction(try #require(item.action), to: panel, from: item))
        #expect(closed == 1 && !panel.isVisible)
    }
}
