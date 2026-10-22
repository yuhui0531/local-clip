// 主界面切换的草稿保护与代次隔离；不展示窗口，不读取生产库，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct SurfaceTransitionTests {
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
