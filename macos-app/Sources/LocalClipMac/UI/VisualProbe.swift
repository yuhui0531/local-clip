// Debug 专用视觉验收：合成内容写真实临时库，不进入正式应用，by AI.Coding。
#if DEBUG
import AppKit
import SwiftUI
import LocalClipCore
@MainActor public enum VisualProbe {
    /// 使用实际 SwiftUI 视图渲染像素，不以设计稿冒充运行效果。
    public static func render(at output: URL, dark: Bool, width: CGFloat = 1400) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalClip-Visual-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(location: directory, extractor: ContentDecoder.extract)
        let now = SystemClock().now()
        let inputs: [(ClipboardPayload, SourceAttribution)] = [
            (.init([.init([.init(SupportedType.string, Data("今天整理需求，明天处理代码。\n\n好的工具应该让工作流动起来。\nLocalClip · 只保存在这台 Mac".utf8))])]), .init(bundleID: "com.apple.TextEdit", name: "TextEdit")),
            (.init([.init([.init(SupportedType.url, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8)), .init(SupportedType.string, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8))])]), .init(bundleID: "com.apple.Safari", name: "Safari")),
            (.init([.init([.init(SupportedType.string, Data("func restore(_ clip: Clip) {\n  guard clip.isVisible else {\n    return\n  }\n  pasteboard.write(clip.payload)\n}\n\n// a->b · foo_bar · 50%".utf8))])]), .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")),
            (.init([.init([.init(SupportedType.html, Data("<b>让想法留在手边。</b><br><br>文字、链接与图片，<br>从复制开始，一次找回。".utf8))])]), .init(bundleID: "com.apple.iWork.Pages", name: "Pages")),
            (.init([.init([.init(SupportedType.png, try fixtureImage())])]), .unknown)
        ]
        for (index, value) in inputs.reversed().enumerated() {
            let result = try await store.ingest(.init(payload: value.0, source: value.1), at: now + Int64(index))
            if index == 2, case .inserted(let id) = result { let preview = try await store.preview(.favorite(id, true)); _ = try await store.apply(preview.token) }
        }
        let board = MacPasteboardClient(access: NativePasteboardAccess(NSPasteboard(name: .init("local.localclip.visual." + UUID().uuidString))))
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: MacApplicationClient(), store: store, capture: capture)
        let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
        try await model.start(); defer { capture.stop() }
        let host = NSHostingView(rootView: HistoryView(model: model))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 446), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: 446)
        // 给实际查询、SwiftUI布局和ImageIO可见任务时间完成。
        try await Task.sleep(for: .milliseconds(700))
        window.displayIfNeeded(); host.layoutSubtreeIfNeeded()
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw StoreError.ioFailure }
        host.cacheDisplay(in: host.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { throw StoreError.ioFailure }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output)
        print("native SwiftUI rendered \(output.path), size=\(representation.pixelsWide)x\(representation.pixelsHigh)")
    }
    /// 自有色块 fixture，未复制任何 Paste 图片或资源。
    private static func fixtureImage() throws -> Data {
        let image = NSImage(size: .init(width: 640, height: 400))
        image.lockFocus()
        NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.90, alpha: 1).setFill(); NSBezierPath(rect: .init(x: 0, y: 0, width: 640, height: 400)).fill()
        NSColor(calibratedRed: 0.40, green: 0.64, blue: 0.51, alpha: 1).setFill(); NSBezierPath(ovalIn: .init(x: 65, y: 80, width: 280, height: 280)).fill()
        NSColor(calibratedRed: 0.89, green: 0.66, blue: 0.41, alpha: 1).setFill(); NSBezierPath(roundedRect: .init(x: 300, y: 50, width: 230, height: 210), xRadius: 30, yRadius: 30).fill()
        NSColor.white.withAlphaComponent(0.8).setFill(); NSBezierPath(ovalIn: .init(x: 190, y: 160, width: 160, height: 160)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw StoreError.ioFailure }
        return png
    }
}
#endif
