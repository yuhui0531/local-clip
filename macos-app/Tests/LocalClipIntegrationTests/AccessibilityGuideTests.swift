// 授权向导的窗口布局、真实拖拽载荷与隔离权限生命周期回归，by AI.Coding。
import AppKit
import Testing
import SwiftUI
@testable import LocalClipMac

@Suite(.serialized) @MainActor struct AccessibilityGuideTests {
    /// 用隔离窗口快照替代真实系统设置，测试不修改系统窗口或权限。
    private static let settingsWindow = AccessibilitySettingsWindow(id: 42, frame: .init(x: 100, y: 100, width: 900, height: 650), isOnScreen: true, isFrontmost: true)

    /// 在系统设置右下方贴靠，副屏负坐标与屏幕边缘仍完整可见。
    @Test func bottomPlacementStaysOnScreen() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let settings = NSRect(x: 200, y: 160, width: 1000, height: 650)
        let frame = AccessibilityGuide.frame(anchor: settings, visible: screen, size: .init(width: 520, height: 190))
        #expect(frame.maxX == settings.maxX - 12)
        #expect(frame.minY == settings.minY + 16)
        #expect(screen.contains(frame))
        let secondary = NSRect(x: -1280, y: -300, width: 1280, height: 760)
        let edge = AccessibilityGuide.frame(anchor: .init(x: -1500, y: -400, width: 800, height: 600), visible: secondary, size: .init(width: 520, height: 230))
        #expect(secondary.contains(edge))
        let narrow = NSRect(x: 0, y: 0, width: 480, height: 700)
        #expect(narrow.contains(AccessibilityGuide.frame(anchor: nil, visible: narrow, size: .init(width: 520, height: 190))))
    }

    /// 参考图按2倍像素换算为715×671点；引导应覆盖右侧内容区底部的浅横条。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func referencePlacementAndResponsiveWidth() async throws {
        _ = NSApplication.shared
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let reference = NSRect(x: 0, y: 0, width: 715, height: 671)
        let width = AccessibilityGuide.guideWidth(anchor: reference, visible: screen)
        #expect(width == 458)
        let frame = AccessibilityGuide.frame(anchor: reference, visible: screen, size: .init(width: width, height: 104))
        #expect(frame.minX == 245)
        #expect(frame.minY == 16)
        #expect(frame.maxX == 703)
        var snapshot = AccessibilitySettingsWindow(id: 42, frame: reference, isOnScreen: true, isFrontmost: true)
        let guide = AccessibilityGuide(isTrusted: { false }, openSystemSettings: {}, settingsWindow: { _ in snapshot })
        defer { guide.close() }
        guide.show(skipIntro: true)
        let panel = try #require(guide.panel)
        try await eventually { panel.frame.width == 458 && panel.frame.height > 1 }
        #expect(panel.frame.height <= 110)
        snapshot.frame.size.width = 900
        try await eventually { panel.frame.width == 576 }
        #expect(panel.frame.maxX == snapshot.frame.maxX - 12)
        #expect(AccessibilityGuide.guideWidth(anchor: .init(x: 0, y: 0, width: 2000, height: 900), visible: screen) == 600)
        #expect(AccessibilityGuide.guideWidth(anchor: reference, visible: .init(x: 0, y: 0, width: 350, height: 600)) == 326)
    }

    /// 从整行拖出的必须是应用文件URL，不能是图片或文本路径；仅使用私有剪贴板。
    @Test func dragExportsApplicationFileURL() throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/Applications/LocalClip.app")
        let view = AppIconDragSource.DragView(appURL: url)
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.mouseDownCanMoveWindow)
        let board = NSPasteboard(name: .init("localclip.guide.test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        let writer = try #require(view.draggingItem().item as? any NSPasteboardWriting)
        #expect(board.writeObjects([writer]))
        #expect(board.string(forType: .fileURL) == url.absoluteString)
    }

    /// 已授权时不打开系统设置，也不创建向导窗口。
    @Test func grantedPermissionDoesNotOpenGuide() {
        _ = NSApplication.shared
        var opened = false
        let guide = AccessibilityGuide(isTrusted: { true }, openSystemSettings: { opened = true }, settingsWindow: { _ in Self.settingsWindow })
        guide.show(skipIntro: true)
        #expect(!opened)
        #expect(!guide.isVisible)
    }

    /// 真值变为已授权才显示成功并自动关闭；关闭后不再轮询。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func authorizationClosesWithoutActivatingApp() async throws {
        _ = NSApplication.shared
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var trusted = false, opened = 0, checks = 0
        let guide = AccessibilityGuide(isTrusted: { checks += 1; return trusted }, openSystemSettings: { opened += 1 }, settingsWindow: { _ in Self.settingsWindow })
        defer { guide.close() }
        guide.show(skipIntro: true)
        #expect(opened == 1)
        #expect(guide.isVisible)
        #expect(guide.panel?.styleMask.contains(.nonactivatingPanel) == true)
        #expect(guide.panel?.hidesOnDeactivate == false)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        try await Task.sleep(for: .milliseconds(700))
        #expect(guide.isVisible)
        #expect(guide.state.step == .drag)
        trusted = true
        let deadline = ContinuousClock.now + .seconds(4)
        while guide.isVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(!guide.isVisible)
        #expect(guide.state.step == .done)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        let stoppedChecks = checks
        try await Task.sleep(for: .milliseconds(700))
        #expect(checks == stoppedChecks)
    }

    /// 整行实际接收鼠标；Escape关闭并取消检查，失焦则保留浮层。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func rowHitTestingAndEscapeDismissal() async throws {
        _ = NSApplication.shared
        let guide = AccessibilityGuide(isTrusted: { false }, openSystemSettings: {}, settingsWindow: { _ in Self.settingsWindow })
        defer { guide.close() }
        guide.show(skipIntro: true)
        let panel = try #require(guide.panel)
        let host = try #require(panel.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func dragView(in view: NSView) -> AppIconDragSource.DragView? {
            if let source = view as? AppIconDragSource.DragView { return source }
            return view.subviews.lazy.compactMap { dragView(in: $0) }.first
        }
        let source = try #require(dragView(in: host))
        #expect(source.bounds.width > 300)
        let row = source.convert(source.bounds, to: host)
        #expect(host.bounds.contains(row))
        // NSView.hitTest接收父视图坐标；NSHostingView翻转Y轴后必须转换，不能误测到标题区。
        let point = host.convert(NSPoint(x: row.maxX - 12, y: row.midY), to: host.superview)
        #expect(host.hitTest(point) === source)
        panel.resignKey()
        #expect(guide.isVisible)
        panel.cancelOperation(nil)
        #expect(!guide.isVisible)
    }

    /// 说明页也监听授权；成功延迟关闭不能误关用户重新打开的向导。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func dismissAndReopenCancelsPreviousCompletion() async throws {
        _ = NSApplication.shared
        var trusted = false, opened = 0
        let guide = AccessibilityGuide(isTrusted: { trusted }, openSystemSettings: { opened += 1 }, settingsWindow: { _ in Self.settingsWindow })
        defer { guide.close() }
        guide.show(skipIntro: false)
        #expect(opened == 0)
        trusted = true
        let deadline = ContinuousClock.now + .seconds(3)
        while guide.state.step != .done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(guide.state.step == .done)
        guide.close()
        trusted = false
        guide.show(skipIntro: true)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(guide.isVisible)
        #expect(guide.state.step == .drag)
        guide.close()
        trusted = true
        try await Task.sleep(for: .milliseconds(700))
        #expect(!guide.isVisible)
        #expect(guide.state.step == .drag)
    }
    /// 设置最小化或切到其他应用时隐藏；返回同一窗口才恢复，关闭后不自动复活。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func followsSettingsVisibilityAndStopsAfterClose() async throws {
        _ = NSApplication.shared
        var snapshot: AccessibilitySettingsWindow? = Self.settingsWindow
        var checks = 0
        let guide = AccessibilityGuide(isTrusted: { checks += 1; return false }, openSystemSettings: {}, settingsWindow: { _ in snapshot })
        defer { guide.close() }
        guide.show(skipIntro: true)
        #expect(guide.isVisible)
        snapshot?.isOnScreen = false
        try await eventually { !guide.isVisible }
        #expect(guide.isGuiding)
        snapshot?.isOnScreen = true
        try await eventually { guide.isVisible }
        snapshot?.isFrontmost = false
        try await eventually { !guide.isVisible }
        snapshot?.isFrontmost = true
        try await eventually { guide.isVisible }
        snapshot = nil
        try await eventually { !guide.isGuiding }
        #expect(!guide.isVisible)
        let stoppedChecks = checks
        snapshot = Self.settingsWindow
        try await Task.sleep(for: .milliseconds(750))
        #expect(!guide.isVisible)
        #expect(checks == stoppedChecks)
    }

    /// 启动系统设置前保持隐藏；启动失败会结束会话，手动关闭也禁止后续复活。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func delayedSettingsLaunchAndFailure() async throws {
        _ = NSApplication.shared
        var snapshot: AccessibilitySettingsWindow?
        let guide = AccessibilityGuide(isTrusted: { false }, openSystemSettings: {}, settingsWindow: { _ in snapshot }, openingTimeout: .seconds(2))
        defer { guide.close() }
        guide.show(skipIntro: true)
        #expect(!guide.isVisible)
        #expect(guide.isGuiding)
        snapshot = Self.settingsWindow
        try await eventually { guide.isVisible }
        guide.close()
        try await Task.sleep(for: .milliseconds(750))
        #expect(!guide.isVisible)
        let failed = AccessibilityGuide(isTrusted: { false }, openSystemSettings: {}, settingsWindow: { _ in nil }, openingTimeout: .milliseconds(100))
        defer { failed.close() }
        failed.show(skipIntro: true)
        try await eventually { !failed.isGuiding }
        #expect(!failed.isVisible)
    }

    /// 隐藏期间授权成功直接结束，不把成功提示重新弹到其他应用上。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func authorizationWhileSettingsMinimizedStaysHidden() async throws {
        _ = NSApplication.shared
        var snapshot = Self.settingsWindow
        var trusted = false
        let guide = AccessibilityGuide(isTrusted: { trusted }, openSystemSettings: {}, settingsWindow: { _ in snapshot })
        defer { guide.close() }
        guide.show(skipIntro: true)
        snapshot.isOnScreen = false
        try await eventually { !guide.isVisible }
        trusted = true
        try await eventually { !guide.isGuiding }
        #expect(!guide.isVisible)
    }

    /// 各状态按SwiftUI自然高度贴合，帮助展开后增长、收起后回缩，不留下固定高度空白。
    // 可见浮层仅在用户明确要求桌面测试时启用，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func panelFitsMeasuredContent() async throws {
        _ = NSApplication.shared
        let guide = AccessibilityGuide(isTrusted: { false }, openSystemSettings: {}, settingsWindow: { _ in Self.settingsWindow })
        defer { guide.close() }
        guide.show(skipIntro: true)
        let panel = try #require(guide.panel)
        let host = try #require(panel.contentView)
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.frame.width == 576)
        #expect(abs(panel.frame.height - host.fittingSize.height) <= 1)
        let compact = panel.frame.height
        #expect(compact < 145)
        guide.state.waitedLong = true
        try await eventually { panel.frame.height > compact }
        #expect(abs(panel.frame.height - host.fittingSize.height) <= 1)
        guide.state.waitedLong = false
        try await eventually { panel.frame.height <= compact + 1 }
        // 说明页也贴合自然高度，不重新引入居中图标的展示空白。
        guide.show(skipIntro: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(panel.frame.height - host.fittingSize.height) <= 1)
        #expect(panel.frame.height < 150)
        #expect(panel.frame.width == 360)
    }

    /// 有界等待真实主线程任务，避免固定延迟导致并发测试抖动。
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

}
