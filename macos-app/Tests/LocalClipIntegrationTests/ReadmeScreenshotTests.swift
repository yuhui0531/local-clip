// README 界面预览的合成数据托管截图：浅色/深色各一张，输出 readme-light.png / readme-dark.png，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；与其他视觉专项同一双开关，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct ReadmeScreenshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL"] == "1"))
    func readmeScreenshots() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        func artwork() throws -> Data {
            let width = 640, height = 400
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.89, green: 0.94, blue: 0.91, alpha: 1)); context.fill(.init(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.36, green: 0.64, blue: 0.50, alpha: 1)); context.fillEllipse(in: .init(x: 90, y: 70, width: 260, height: 260))
            context.setFillColor(CGColor(red: 0.91, green: 0.67, blue: 0.40, alpha: 1))
            context.addPath(CGPath(roundedRect: .init(x: 290, y: 60, width: 220, height: 200), cornerWidth: 28, cornerHeight: 28, transform: nil)); context.fillPath()
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        func text(_ value: String) -> ClipboardPayload { .init([.init([.init(SupportedType.string, Data(value.utf8))])]) }
        func source(_ id: String, _ name: String) -> SourceAttribution { .init(bundleID: id, name: name) }
        let notes = root.appendingPathComponent("发布说明.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# LocalClip 0.3.64\n\n- 打开面板首帧即最新\n- 第一屏图片即时显示\n".utf8).write(to: notes)
        let link = "https://developer.apple.com/documentation/appkit/nspasteboard"
        // 先插入的排在后面；最后一条是选中的首张卡片。
        let records: [(ClipboardPayload, SourceAttribution)] = [
            (text("#34C759"), source("com.apple.Notes", "备忘录")),
            (.init([.init([.init(SupportedType.fileURL, Data(notes.absoluteString.utf8))])]), source("com.apple.finder", "访达")),
            (.init([.init([.init(SupportedType.png, try artwork())])]), source("com.apple.Preview", "预览")),
            (text("func restore(_ clip: Clip) {\n    guard clip.isVisible else {\n        return\n    }\n    pasteboard.write(clip.payload)\n}"), source("com.microsoft.VSCode", "Visual Studio Code")),
            (.init([.init([.init(SupportedType.url, Data(link.utf8)), .init(SupportedType.string, Data(link.utf8))])]), source("com.apple.Safari", "Safari")),
            (text("今天整理需求，明天处理代码。\n\n好的工具应该让工作流动起来。\nLocalClip · 只保存在这台 Mac"), source("com.apple.TextEdit", "文本编辑")),
        ]
        let now = SystemClock().now()
        var ids: [ClipID] = []
        for (index, record) in records.enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: record.0, source: record.1), at: now + Int64(index)) else { throw StoreError.notFound }
            ids.append(id)
        }
        let favorite = try await store.preview(.favorite(ids[3], true)); _ = try await store.apply(favorite.token)
        _ = try await store.createCategory(name: "工作", colorHex: "34C759")
        _ = try await store.createCategory(name: "灵感", colorHex: "AF52DE")
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(15)
        while model.items.count < records.count, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.items.count == records.count)
        model.select(ids.last)
        // 宽度容纳全部六张卡片，不出现半张截断。
        let width = 1860.0, height = 360.0
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { capture.stop(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        model.actualPanelHeight = height
        model.configureHistoryViewport(width: width, cardWidth: HistoryView.cardSide(height: height))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // 等待缩略图、文件预览与来源色异步就绪。
            try await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("readme-\(dark ? "dark" : "light").png"))
        }
    }
}
