// 隐藏期间新增后重开的首帧：真实非激活面板渲染，临时库与假剪贴板隔离，by AI.Coding。
import AppKit
import SwiftUI
import Vision
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；专项开关与其他桌面测试一致，by AI.Coding。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct FirstFrameDesktopTests {
    private func text(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    /// 与presentHistory相同：布局并同步绘制后立即取像，即用户看到的第一帧。
    private func frame(_ host: NSView, _ window: NSWindow) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    /// fixture的蓝/橙色块已绘制，说明缩略图首帧即显示而非加载占位。
    private func imagePixels(_ bitmap: NSBitmapImageRep) -> (blue: Int, orange: Int) {
        var blue = 0, orange = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent - color.redComponent > 0.25, color.greenComponent - color.redComponent > 0.2 { blue += 1 }
                if color.redComponent - color.greenComponent > 0.2, color.greenComponent - color.blueComponent > 0.12 { orange += 1 }
            }
        }
        return (blue, orange)
    }

    /// 后台已备好（静默后打开）与刚复制立即打开（80ms等待）两条路径，首帧都须是最新首卡且图片不转圈。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_FIRST_FRAME"] == "1"), arguments: [false, true])
    func reopenFirstFrameShowsNewestCards(immediate: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        for index in 0..<30 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("OLD ITEM \(index)".utf8))])])), at: now + Int64(index)) }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        if immediate { model.hiddenRefreshDelay = .seconds(60) }
        model.configureHistoryViewport(width: 1000, cardWidth: HistoryView.cardSide(height: 340))
        try await model.start(); capture.stop()
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1000, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        model.panelVisibilityChanged(true); window.orderFront(nil)
        let loaded = ContinuousClock.now + .seconds(15)
        while (model.historyBusy || model.items.first?.preview != "OLD ITEM 29"), ContinuousClock.now < loaded { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try text(frame(host, window)).contains("OLD ITEM 29"))

        window.orderOut(nil); model.panelVisibilityChanged(false)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 320, height: 240))])])), at: now + 1000)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("FIRSTFRAME NEW".utf8))])])), at: now + 1001)
        // 静默路径给后台准备留足时间；立即路径只等事件送达，随后由打开前的80ms等待接手。
        let delivered = ContinuousClock.now + .seconds(15)
        while !model.hiddenChanges && model.items.first?.preview != "FIRSTFRAME NEW", ContinuousClock.now < delivered { try await Task.sleep(for: .milliseconds(2)) }
        // 两次提交的事件都需送达；立即路径只多等20ms，仍在60秒静默等待之内。
        try await Task.sleep(for: immediate ? .milliseconds(20) : .seconds(1))

        // 与prepareSurface/presentHistory一致的打开顺序。
        let began = ContinuousClock.now
        await model.awaitHiddenFirstScreen(timeout: .milliseconds(80))
        let waited = began.duration(to: .now)
        try await Task.sleep(for: .milliseconds(32))
        model.showFirstCard(); model.panelVisibilityChanged(true); window.orderFront(nil)
        let first = try frame(host, window)
        let firstText = try text(first), pixels = imagePixels(first)
        if let output = ProcessInfo.processInfo.environment["LOCALCLIP_FIRST_FRAME_OUTPUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(first.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(immediate ? "first-frame-immediate.png" : "first-frame-prepared.png"))
        }
        print("FIRST_FRAME immediate=\(immediate) waited=\(waited) firstCard=\(model.items.first?.preview ?? "-") blue=\(pixels.blue) orange=\(pixels.orange)")
        #expect(waited < .milliseconds(100))
        #expect(firstText.contains("FIRSTFRAME"), "\(firstText)")
        #expect(!firstText.contains("正在加载预览"), "\(firstText)")
        #expect(pixels.blue > 600 && pixels.orange > 100)
        #expect(model.selectedID == model.items.first?.id)
    }
}
