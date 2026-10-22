// 主界面切换的草稿保护与代次隔离；不展示窗口，不读取生产库，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct SurfaceTransitionTests {
    /// 贴底父窗不参与确认布局；回答一次后恢复原交互状态，且不创建系统Sheet。
    @Test func cardConfirmationDoesNotMoveParent() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 280)
        let parent = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        // 隐藏测试不排序窗口；只检查控制器在父窗上的操作与continuation生命周期。
        let confirmation = SurfaceConfirmation(title: "名称修改", closing: false)
        let task = Task { await confirmation.present(for: parent, visible: false) }
        for _ in 0..<20 where !parent.ignoresMouseEvents { await Task.yield() }
        #expect(parent.frame == frame && parent.attachedSheet == nil)
        #expect(parent.ignoresMouseEvents)
        #expect(confirmation.window?.styleMask.contains(.nonactivatingPanel) == true)
        #expect((confirmation.window?.frame.height ?? 1000) < 240)
        confirmation.finish(.cancel)
        confirmation.finish(.save)
        #expect(await task.value == .cancel)
        #expect(!parent.ignoresMouseEvents && parent.frame == frame)
        #expect(confirmation.window?.contentView == nil)
        parent.close()
    }
    /// 屏幕坐标可为负数；确认始终可见且居中，不依赖系统自动搬动父窗。
    @Test func cardConfirmationPlacement() {
        let screen = NSRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let parent = NSRect(x: -1920, y: -1080, width: 1920, height: 280)
        let rect = SurfaceConfirmation.frame(size: .init(width: 420, height: 150), owner: parent, screen: screen)
        #expect(rect.midX == parent.midX && rect.midY == parent.midY)
        #expect(screen.contains(rect))
    }
    /// 气泡贴近触发元素：优先在上方并指向锚点中线；顶部放不下翻到下方，贴边时箭头夹在圆角内，by AI.Coding。
    @Test func anchoredConfirmationPlacement() {
        let screen = NSRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let size = NSSize(width: 440, height: 240)
        let tab = NSRect(x: -1500, y: -840, width: 80, height: 28)
        let above = SurfaceConfirmation.frame(size: size, anchor: tab, screen: screen)
        #expect(above.frame.minY == tab.maxY + 4 && above.frame.height == size.height + SurfaceConfirmation.Bubble.arrowHeight)
        #expect(!above.arrowUp && above.frame.minX + above.arrowX == tab.midX && screen.contains(above.frame))
        let top = NSRect(x: -1910, y: -40, width: 40, height: 28)
        let below = SurfaceConfirmation.frame(size: size, anchor: top, screen: screen)
        #expect(below.arrowUp && below.frame.maxY == top.minY - 4 && screen.contains(below.frame))
        #expect(below.frame.minX == screen.minX + 12 && below.arrowX == 24)
        // 卡片边长超过面板一半仍是有效锚点，箭头指向其上沿；整块面板大小的视图回退居中。
        let panel = NSRect(x: 0, y: 0, width: 1440, height: 340), card = NSRect(x: 100, y: 20, width: 268, height: 268)
        #expect(SurfaceConfirmation.anchorEdge(card, owner: panel) == NSRect(x: 100, y: 286, width: 268, height: 2))
        #expect(SurfaceConfirmation.anchorEdge(panel, owner: panel) == nil)
    }
    /// 使用真实宿主路由和隐藏窗口，证明退出会释放模型而只恢复轻量查询条件。
    @Test func hiddenWindowSwitchingAndRelease() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let history = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await history.start(); capture.stop(); history.panelVisibilityChanged(false)
        let app = AppDelegate(); app.configureSurfacesForTesting(history)
        func settle() async throws { try await Task.sleep(for: .milliseconds(650)) }
        app.switchSurfaceForTesting(.manager); try await settle()
        weak var firstWindow = app.surfaceWindowsForTesting.2
        weak var firstModel = app.surfaceManagerForTesting
        #expect(firstWindow != nil && firstWindow?.isVisible == false)
        #expect(firstWindow?.styleMask.contains(.nonactivatingPanel) == true)
        #expect(firstWindow?.collectionBehavior.contains(.moveToActiveSpace) == true)
        // 重复入口在静默宿主中也不能意外排序窗口到真实桌面。
        app.switchSurfaceForTesting(.manager); try await settle()
        #expect(firstWindow?.isVisible == false)
        firstModel?.literal = "saved-query"; firstModel?.sort = .recentAsc; firstModel?.scope = .favorites
        app.switchSurfaceForTesting(.settings); try await settle()
        #expect(firstWindow == nil && firstModel == nil)
        #expect(app.surfaceWindowsForTesting.1?.isVisible == false)
        app.switchSurfaceForTesting(.manager); try await settle()
        #expect(app.surfaceManagerForTesting?.literal == "saved-query")
        #expect(app.surfaceManagerForTesting?.scope == .favorites)
        #expect(app.surfaceManagerForTesting?.sort == .recentAsc)
        #expect(app.surfaceManagerForTesting?.selection.isEmpty == true && app.surfaceManagerForTesting?.page == 0)
        // 连续改变目标时旧淡出不得释放最后选择的界面。
        app.switchSurfaceForTesting(.settings)
        try await Task.sleep(for: .milliseconds(50))
        app.switchSurfaceForTesting(.manager); try await settle()
        #expect(app.surfaceWindowsForTesting.1 == nil && app.surfaceWindowsForTesting.2 != nil)
        let draftID = UUID()
        history.surfaceEdits.register(draftID, surface: .manager, draft: .init(title: "测试名称", dirty: { true }, save: { false }, discard: {}))
        app.surfaceChoiceForTesting = { _ in .save }
        app.switchSurfaceForTesting(.settings); try await settle()
        #expect(app.surfaceWindowsForTesting.2 != nil && app.surfaceWindowsForTesting.1 == nil)
        app.surfaceChoiceForTesting = { _ in .discard }
        app.switchSurfaceForTesting(nil); try await settle()
        #expect(app.surfaceWindowsForTesting.1 == nil && app.surfaceWindowsForTesting.2 == nil)
        // 卡片显式关闭也必须走草稿保护；粘贴后的非动画收起保持原语义。
        app.switchSurfaceForTesting(.cards); try await settle()
        #expect(history.panelVisible && app.surfaceWindowsForTesting.0?.isVisible == false)
        let cardDraft = UUID()
        history.surfaceEdits.register(cardDraft, surface: .cards, draft: .init(title: "卡片名称", dirty: { true }, save: { false }, discard: {}))
        app.surfaceChoiceForTesting = { _ in .cancel }
        history.closePanel?(true); try await settle()
        #expect(history.panelVisible)
        #expect(app.surfaceWindowsForTesting.0?.ignoresMouseEvents == false)
        var choices = 0
        app.surfaceChoiceForTesting = { _ in choices += 1; return .discard }
        // 同一事件周期的旧请求在 Task 开始前已取消，不能抢先弹出旧目标确认。
        app.switchSurfaceForTesting(.settings)
        app.switchSurfaceForTesting(.manager)
        try await settle()
        #expect(choices == 1 && app.surfaceWindowsForTesting.2 != nil && app.surfaceWindowsForTesting.1 == nil)
        #expect(!history.panelVisible)
        app.switchSurfaceForTesting(nil); try await settle()
    }
    /// 确认期间拒绝新请求；取消/保存失败均不得执行原切换。
    @Test func draftResolution() async {
        let edits = SurfaceEdits()
        let id = UUID()
        var dirty = true, saved = false, discarded = false
        edits.register(id, surface: .manager, draft: .init(title: "名称", dirty: { dirty }, save: { saved }, discard: { discarded = true; dirty = false }))
        #expect(edits.hasChanges(.manager))
        #expect(!(await edits.resolve(.manager, choose: { _ in .cancel })))
        #expect(!(await edits.resolve(.manager, choose: { _ in .save })))
        #expect(!discarded)
        saved = true
        #expect(await edits.resolve(.manager, choose: { _ in .save }))
        #expect(await edits.resolve(.manager, choose: { _ in .discard }))
        #expect(discarded)
        edits.remove(id)
        #expect(!edits.hasChanges(.manager))
    }
    /// 新请求不会替换草稿确认所保护的原目标。
    @Test func pendingConfirmationRejectsReentry() async {
        let edits = SurfaceEdits()
        edits.register(UUID(), surface: .cards, draft: .init(title: "名称", dirty: { true }, save: { true }, discard: {}))
        let allowed = await edits.resolve(.cards) { _ in
            #expect(edits.resolving)
            #expect(!(await edits.resolve(.cards, choose: { _ in Issue.record("不得叠加确认"); return .discard })))
            return .cancel
        }
        #expect(!allowed); #expect(!edits.resolving)
    }
    /// 插值无反弹；从中途值继续时首帧与前一帧连续。
    @Test func restrainedMotion() {
        let values = (0...100).map { SurfaceMotion.value(from: 0, to: 1, progress: Double($0) / 100) }
        #expect(values.first == 0); #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(SurfaceMotion.value(from: 0.37, to: 0, progress: 0) == 0.37)
        #expect(SurfaceMotion.duration(reduceMotion: true) < SurfaceMotion.duration(reduceMotion: false))
    }
}
