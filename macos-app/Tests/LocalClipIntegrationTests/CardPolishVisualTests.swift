// 历史卡片优化（ux-history-card-polish）的合成数据托管截图：截断省略行、多图窄卡片Footer、白底缩略图描边、收藏、分类与来源色头部，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；与其他视觉专项同一双开关，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct CardPolishVisualTests {
    /// 仅渲染自有窗口，证明208/448pt下布局不截断、不重叠；不证明悬停或物理交互。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL"] == "1"))
    func cardPolishMatrix() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        func white(_ width: Int, _ height: Int) throws -> Data {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(.white); context.fill(.init(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.2, alpha: 1)); context.fill(.init(x: 20, y: height - 40, width: width / 2, height: 12))
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        func text(_ value: String) -> ClipboardPayload { .init([.init([.init(SupportedType.string, Data(value.utf8))])]) }
        let long = Array(repeating: "Synthetic sentence for truncation.", count: 9).joined(separator: " ")
        let safari = SourceAttribution(bundleID: "com.apple.Safari", name: "Safari"), messages = SourceAttribution(bundleID: "com.apple.MobileSMS", name: "Messages")
        let now = SystemClock().now()
        let records: [(ClipboardPayload, SourceAttribution?)] = [
            (text(long), safari),
            (.init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 120, height: 80))]), .init([.init(SupportedType.png, try white(90, 60))]), .init([.init(SupportedType.png, try ImageFixtures.image(width: 60, height: 60))])]), nil),
            (.init([.init([.init(SupportedType.png, try white(640, 400))])]), messages),
            (text("Favorite snippet"), nil),
        ]
        var ids: [ClipID] = []
        for (index, record) in records.enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: record.0, source: record.1 ?? .unknown), at: now + Int64(index)) else { throw StoreError.notFound }
            ids.append(id)
        }
        let favorite = try await store.preview(.favorite(ids[3], true)); _ = try await store.apply(favorite.token)
        _ = try await store.createCategory(name: "工作", colorHex: "34C759")
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(15)
        while model.items.count < records.count, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.items.count == records.count)
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 2000, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { capture.stop(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for height in [280.0, 520.0] {
                model.updateSettings { $0.panelHeight = height }
                let deadline = ContinuousClock.now + .seconds(15)
                while model.settings.panelHeight != height, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                model.actualPanelHeight = height
                model.configureHistoryViewport(width: 2000, cardWidth: HistoryView.cardSide(height: height))
                window.setContentSize(.init(width: 2000, height: height))
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("polish-\(dark ? "dark" : "light")-\(Int(height)).png"))
            }
        }
    }
}
