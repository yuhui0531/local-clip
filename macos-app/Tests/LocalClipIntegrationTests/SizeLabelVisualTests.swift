// N-01 大小标签的合成数据托管截图：窄卡片、长文件名、多文件含目录与隐藏内容，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；原有专项开关仍保留，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct SizeLabelVisualTests {
    /// 仅渲染自有窗口，证明布局不遮挡；不证明真实辅助功能朗读或物理交互。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL"] == "1"))
    func sizeLabelLayoutMatrix() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files.appendingPathComponent("A folder"), withIntermediateDirectories: true)
        let long = files.appendingPathComponent("A very long synthetic report file name that must truncate inside the card 2026-10-15 final.pdf")
        try Data(repeating: 1, count: 2_400_000).write(to: long)
        let small = files.appendingPathComponent("notes.txt"); try Data(repeating: 2, count: 128_000).write(to: small)
        let store = try HistoryStore(location: root.appendingPathComponent("data")), board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        let now = SystemClock().now()
        func fileItem(_ url: URL) -> PasteboardItemValue { .init([.init(SupportedType.fileURL, Data(url.absoluteString.utf8))]) }
        let payloads: [ClipboardPayload] = [
            .init([.init([.init(SupportedType.string, Data("Plain text stays unchanged /tmp/looks/like/a/path.png".utf8))])]),
            .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 600, height: 400))])]),
            .init([fileItem(long)]),
            .init([fileItem(small), fileItem(long), fileItem(files.appendingPathComponent("A folder"))]),
            .init([fileItem(files.appendingPathComponent("missing.bin"))]),
        ]
        for (index, payload) in payloads.enumerated() { _ = try await store.ingest(.init(payload: payload), at: now + Int64(index)) }
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(5)
        while model.items.count < payloads.count, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.items.count == payloads.count)
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1200, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { capture.stop(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        for height in [200.0, 280.0, 520.0] {
            for hidden in [false, true] {
                model.updateSettings { $0.hideContents = hidden; $0.panelHeight = height }
                let deadline = ContinuousClock.now + .seconds(3)
                while (model.settings.hideContents != hidden || model.settings.panelHeight != height), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                model.actualPanelHeight = height
                model.configureHistoryViewport(width: 1200, cardWidth: HistoryView.cardSide(height: height, filtered: false))
                window.setContentSize(.init(width: 1200, height: height))
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("size-\(Int(height))-\(hidden ? "hidden" : "visible").png"))
            }
        }
    }
}
