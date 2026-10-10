// Debug 专用视觉验收：合成内容写真实临时库，不进入正式应用，by AI.Coding。
#if DEBUG
import AppKit
import SwiftUI
import LocalClipCore
@MainActor public enum VisualProbe {
    /// 使用实际 SwiftUI 视图渲染像素，不以设计稿冒充运行效果。
    private static var session: (NSWindow, HistoryViewModel, URL)?
    private static var pointerMonitor: Any?
    public static func render(at output: URL, dark: Bool, width: CGFloat = 1400, height: CGFloat = 400, keepOpen: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalClip-Visual-" + UUID().uuidString)
        defer { if !keepOpen { try? FileManager.default.removeItem(at: directory) } }
        var settings = SettingsSnapshot(); settings.panelHeight = height
        let store = try HistoryStore(location: directory, initialSettings: settings, extractor: ContentDecoder.extract)
        // 长文件名fixture用于检查卡片正文与辅助图标的空间分配。
        let file = directory.appendingPathComponent("LocalClip-source-example.txt")
        try Data("LocalClip synthetic file fixture".utf8).write(to: file)
        let now = SystemClock().now()
        let inputs: [(ClipboardPayload, SourceAttribution)] = [
            (.init([.init([.init(SupportedType.string, Data("今天整理需求，明天处理代码。\n\n好的工具应该让工作流动起来。\nLocalClip · 只保存在这台 Mac".utf8))])]), .init(bundleID: "com.apple.TextEdit", name: "TextEdit")),
            (.init([.init([.init(SupportedType.url, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8)), .init(SupportedType.string, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8))])]), .init(bundleID: "com.apple.Safari", name: "Safari")),
            (.init([.init([.init(SupportedType.string, Data("func restore(_ clip: Clip) {\n  guard clip.isVisible else {\n    return\n  }\n  pasteboard.write(clip.payload)\n}\n\n// a->b · foo_bar · 50%".utf8))])]), .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")),
            (.init([.init([.init(SupportedType.html, Data("<b>让想法留在手边。</b><br><br>文字、链接与图片，<br>从复制开始，一次找回。".utf8))])]), .init(bundleID: "com.apple.iWork.Pages", name: "Pages")),
            (.init([.init([.init(SupportedType.png, try fixtureImage())])]), .init(bundleID: "com.apple.Preview", name: "预览")),
            (.init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])]), .init(bundleID: "com.apple.finder", name: "Finder"))
        ]
        for (index, value) in inputs.reversed().enumerated() {
            let result = try await store.ingest(.init(payload: value.0, source: value.1), at: now + Int64(index))
            guard case .inserted = result else { throw StoreError.ioFailure }
            if index == 2, case .inserted(let id) = result { let preview = try await store.preview(.favorite(id, true)); _ = try await store.apply(preview.token) }
        }
        // 合成记录写入后才暂停，暂停策略同样会阻止测试fixture入库。
        settings = try await store.settings(); settings.captureEnabled = false
        _ = try await store.updateCaptureSettings(settings)
        for (name, color) in [("自定义", "34C759"), ("提示词", "8E8E93"), ("物理知识", "FFCC00")] {
            _ = try await store.createCategory(name: name, colorHex: color)
        }
        let board = MacPasteboardClient(access: NativePasteboardAccess(NSPasteboard(name: .init("local.localclip.visual." + UUID().uuidString))))
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: MacApplicationClient(), store: store, capture: capture)
        let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
        try await model.start(); defer { if !keepOpen { capture.stop() } }
        model.actualPanelHeight = height
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: height)
        window.title = "LocalClip 隔离验证"; window.backgroundColor = .windowBackgroundColor
        if keepOpen {
            session = (window, model, directory); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let geometry: [String: Any] = ["frame": NSStringFromRect(window.frame), "screen": NSStringFromRect(window.screen?.frame ?? .zero), "scale": window.backingScaleFactor]
            try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted,.sortedKeys]).write(to: output.deletingLastPathComponent().appendingPathComponent("window-geometry.json"))
            // 只记录隔离验证窗口内的鼠标几何，不采集正文或系统剪贴板。
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { event in
                if event.window === window {
                    let text = "type=\(event.type.rawValue) point=\(NSStringFromPoint(event.locationInWindow)) buttons=\(NSEvent.pressedMouseButtons)\n"
                    let log = output.deletingLastPathComponent().appendingPathComponent("pointer-events.log")
                    if let handle = try? FileHandle(forWritingTo: log) { try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8)); try? handle.close() }
                    else { try? Data(text.utf8).write(to: log) }
                }
                return event
            }
        }
        // 给实际查询、SwiftUI布局和ImageIO可见任务时间完成。
        try await Task.sleep(for: .milliseconds(700))
        window.displayIfNeeded(); host.layoutSubtreeIfNeeded()
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw StoreError.ioFailure }
        host.cacheDisplay(in: host.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { throw StoreError.ioFailure }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output)
        if keepOpen { try await checkExport(model: model, output: output.deletingLastPathComponent()) }
        print("native SwiftUI rendered \(output.path), size=\(representation.pixelsWide)x\(representation.pixelsHigh)")
    }
    /// 真实AppKit提供者和文件promise接收器，限定私有剪贴板及合成文件，绝不操作通用剪贴板。
    private static func checkExport(model: HistoryViewModel, output: URL) async throws {
        let token = UUID().uuidString
        var accesses: [ClipExportAccess] = []
        defer { for access in accesses { access.cancel() } }
        let writers = try await ContentExportProvider.writers(ids: model.items.map(\.id), store: model.store, token: token, register: { accesses.append($0) })
        let board = NSPasteboard(name: .init("local.localclip.export-check." + UUID().uuidString))
        defer { board.releaseGlobally() }
        guard board.writeObjects(writers), let image = writers.first(where: { $0 is NSFilePromiseProvider }) as? NSFilePromiseProvider,
              image.fileType == SupportedType.png, image.delegate != nil,
              let data = image.pasteboardPropertyList(forType: .init(SupportedType.png)) as? Data,
              NSImage(data: data) != nil else { throw StoreError.ioFailure }
        let destination = output.appendingPathComponent("promise-received", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // 本机私有剪贴板receiver尝试未回调；这里直接验证真实delegate兑现，不声称receiver验收通过。
        let received = destination.appendingPathComponent(image.delegate!.filePromiseProvider(image, fileNameForType: image.fileType))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            image.delegate!.filePromiseProvider(image, writePromiseTo: received) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        guard try Data(contentsOf: received) == data else { throw StoreError.corruptPayload }
        let report: [String: Any] = ["scope": "真实AppKit writer及delegate，私有剪贴板及合成fixtures；不等同鼠标拖放或receiver验收", "writerCount": writers.count, "imageProviderInitialized": true, "originalPNGRead": true, "promiseDelegateWroteExactPNG": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("native-drag-api.json"))
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
