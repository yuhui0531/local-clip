// 指定报告的合成数据原生托管截图；不读取日常历史或系统剪贴板，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；原有专项开关仍保留，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct SpecifiedReviewVisualTests {
    /// 仅渲染自有窗口；这不证明真实目标接收或辅助功能键盘导航。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL"] == "1"))
    func reviewVisualMatrix() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        let now = SystemClock().now()
        for (index, text) in ["Synthetic review fixture — 中文与 English", "A long title and multiline text\nLine two\nLine three", "https://example.invalid/localclip-review"].enumerated() {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: now + Int64(index))
        }
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 300, height: 480))])])), at: now + 4)
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(5)
        while model.items.count < 4, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.items.count == 4)
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1200, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { capture.stop(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for compact in [false, true] {
                for height in [280.0, 340.0, 520.0] {
                    for hidden in [false, true] {
                        model.updateSettings { $0.compactLayout = compact; $0.hideContents = hidden; $0.panelHeight = height }
                        let deadline = ContinuousClock.now + .seconds(3)
                        while (model.settings.compactLayout != compact || model.settings.hideContents != hidden || model.settings.panelHeight != height), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                        try #require(model.settings.compactLayout == compact && model.settings.hideContents == hidden && model.settings.panelHeight == height)
                        model.actualPanelHeight = height
                        model.configureHistoryViewport(width: 1200, cardWidth: HistoryView.cardSide(height: height, filtered: false))
                        window.setContentSize(.init(width: 1200, height: height))
                        try await Task.sleep(for: .milliseconds(250))
                        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        let name = "\(dark ? "dark" : "light")-\(compact ? "compact" : "standard")-\(Int(height))-\(hidden ? "hidden" : "visible").png"
                        try data.write(to: output.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
