// Debug 专用视觉验收：合成内容写真实临时库，不进入正式应用，by AI.Coding。
#if DEBUG
import AppKit
import SwiftUI
import LocalClipCore
@MainActor public enum VisualProbe {
    /// 使用实际 SwiftUI 视图渲染像素，不以设计稿冒充运行效果。
    private static var session: (NSWindow, HistoryViewModel, URL)?
    private static var pointerMonitor: Any?
    public static func render(at output: URL, dark: Bool, width: CGFloat = 1400, height: CGFloat = 400, keepOpen: Bool = false, codeDetail: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalClip-Visual-" + UUID().uuidString)
        defer { if !keepOpen { try? FileManager.default.removeItem(at: directory) } }
        var settings = SettingsSnapshot(); settings.panelHeight = min(height, 520)
        settings.smartCodeFilePaste = ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_SMART_PASTE"] == "1"
        let store = try HistoryStore(location: directory, initialSettings: settings, extractor: ContentDecoder.extract)
        // 长文件名fixture用于检查卡片正文与辅助图标的空间分配。
        let file = directory.appendingPathComponent("LocalClip-source-example.txt")
        try Data("LocalClip synthetic file fixture".utf8).write(to: file)
        // 图片文件引用应显示图片预览而非文件图标。
        let imageFile = directory.appendingPathComponent("LocalClip-photo.png")
        try fixtureImage().write(to: imageFile)
        let secondImage = directory.appendingPathComponent("LocalClip-photo-2.png")
        try fixtureImage().write(to: secondImage)
        let now = SystemClock().now()
        var inputs: [(ClipboardPayload, SourceAttribution)] = [
            (.init([.init([.init(SupportedType.string, Data("今天整理需求，明天处理代码。\n\n好的工具应该让工作流动起来。\nLocalClip · 只保存在这台 Mac".utf8))])]), .init(bundleID: "com.apple.TextEdit", name: "TextEdit")),
            (.init([.init([.init(SupportedType.url, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8)), .init(SupportedType.string, Data("https://developer.apple.com/documentation/appkit/nspasteboard".utf8))])]), .init(bundleID: "com.apple.Safari", name: "Safari")),
            (.init([.init([.init(SupportedType.string, Data("func restore(_ clip: Clip) {\n  guard clip.isVisible else {\n    return\n  }\n  pasteboard.write(clip.payload)\n}\n\n// a->b · foo_bar · 50%".utf8))])]), .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")),
            (.init([.init([.init(SupportedType.html, Data("<b>让想法留在手边。</b><br><br>文字、链接与图片，<br>从复制开始，一次找回。".utf8))])]), .init(bundleID: "com.apple.iWork.Pages", name: "Pages")),
            (.init([.init([.init(SupportedType.png, try fixtureImage())])]), .init(bundleID: "com.apple.Preview", name: "预览")),
            (.init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])]), .init(bundleID: "com.apple.finder", name: "Finder")),
            (.init([imageFile, secondImage].map { .init([.init(SupportedType.fileURL, Data($0.absoluteString.utf8))]) }), .init(bundleID: "com.apple.finder", name: "Finder"))
        ]
        let codeFixtures = [
            "{\n  \"name\": \"LocalClip 中文\",\n  \"count\": 42,\n  \"enabled\": true\n}",
            "def greet(name):\n    # Preserve indentation\n    count = 42\n    return f'Hello {name}'\n",
            "interface User {\n  name: string;\n}\nconst user: User = { name: 'LocalClip' };\n"
        ]
        if ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_CODES"] == "1" || codeDetail {
            inputs = codeFixtures.map { (.init([.init([.init(SupportedType.string, Data($0.utf8))])]), .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")) }
        }
        // F17识别徽标：时间戳、JWT、颜色、UUID、Base64与代码语言标题，仅合成数据，by AI.Coding。
        // 取值为序号时把该fixture排到首位，供LOCALCLIP_VISUAL_POPOVER=detail渲染对应详情。
        if let first = ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_DETECTIONS"].flatMap(Int.init) {
            inputs = ["1760313600", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImV4cCI6MTcwMDAwMDAwMH0.c2lnbmF0dXJl", "#34C759",
                      "f47ac10b-58cc-4372-a567-0e02b2c3d479", "aGVsbG8gd29ybGQgZnJvbSBMb2NhbENsaXA=", codeFixtures[0]]
                .map { (.init([.init([.init(SupportedType.string, Data($0.utf8))])]), .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")) }
            inputs = Array(inputs[(first % inputs.count)...] + inputs[..<(first % inputs.count)])
        }
        for (index, value) in inputs.reversed().enumerated() {
            let result = try await store.ingest(.init(payload: value.0, source: value.1), at: now + Int64(index))
            guard case .inserted = result else { throw StoreError.ioFailure }
            if index == 2, case .inserted(let id) = result { let preview = try await store.preview(.favorite(id, true)); _ = try await store.apply(preview.token) }
        }
        // 保持“正在记录”外观；采集只监听下方私有命名剪贴板，不读取通用剪贴板，by AI.Coding。
        for (name, color) in [("自定义", "34C759"), ("提示词", "8E8E93"), ("物理知识", "FFCC00")] {
            _ = try await store.createCategory(name: name, colorHex: color)
        }
        if ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_STATE"] == "categories" {
            for index in 1...18 { _ = try await store.createCategory(name: "测试分类 \(index)", colorHex: "007AFF") }
        }
        let board = MacPasteboardClient(access: NativePasteboardAccess(NSPasteboard(name: .init("local.localclip.visual." + UUID().uuidString))))
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: MacApplicationClient(), store: store, capture: capture)
        let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
        try await model.start(); defer { if !keepOpen { capture.stop() } }
        model.actualPanelHeight = height
        // 所有视觉状态仅作用于合成临时库，用于检查空状态、隐藏和溢出，by AI.Coding。
        switch ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_STATE"] {
        case "empty": model.query = "no-matching-synthetic-record"; model.searchChanged()
        case "favorites": model.favorites = true; model.kind = .file; model.searchChanged()
        case "hidden": model.updateSettings { $0.hideContents = true }
        case "paused": model.updateSettings { $0.pauseUntil = SystemClock().now() + 60_000 }
        default: break
        }
        // 弹出框离屏无法截取，单独渲染筛选与详情内容供视觉检查，by AI.Coding。
        let popover = ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_POPOVER"]
        if popover == "detail" { while model.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }; model.select(model.items.first(where: { HistoryView.kindName($0.kind) == ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_KIND"] })?.id ?? model.items.first?.id); model.showingDetail = true; model.detailVisibilityChanged() }
        var settingsHeight: CGFloat?
        let guide = AccessibilityGuideState()
        // 引导宽度来自宿主设置窗口；离屏验收用调用方指定宽度复现同一布局，by AI.Coding。
        if ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_GUIDE"] != nil { guide.panelWidth = width }
        // 分别渲染正常等待与延迟帮助，避免只验证展开态而漏掉紧凑布局，by AI.Coding。
        switch ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_GUIDE"] { case "drag": guide.step = .drag; case "drag-waiting": guide.step = .drag; guide.waitedLong = true; case "done": guide.step = .done; default: break }
        let view: AnyView = ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_TOAST"] != nil
            ? AnyView(VStack(spacing: 16) { PasteFeedbackView(message: "已复制，请确认目标位置后手动粘贴", failed: false); PasteFeedbackView(message: "剪贴板已变化或复制失败，请重新选择", failed: true) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor)))
            : ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_GUIDE"] != nil
            ? AnyView(AccessibilityGuideView(state: guide, openSettings: {}, close: {}, fitContent: { settingsHeight = $0 }).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
            : popover == "filter" ? AnyView(FilterEditor(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
            : popover == "detail" ? AnyView(ClipInspector(model: model).frame(width: 520).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
            : ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_SETTINGS"] == "1"
            ? AnyView(SettingsView(model: model, login: LoginItemService(), section: SettingsSection(rawValue: ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_SECTION"] ?? "") ?? .general, fitWindow: { settingsHeight = $0 }))
            : codeDetail
            ? AnyView(VStack(alignment: .leading, spacing: 12) { Text("代码详情 · JSON").font(.headline); SyntaxDetailPreview(content: NSAttributedString(string: codeFixtures[0])) }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
            : AnyView(HistoryView(model: model))
        // 离屏窗口不会可靠传播外观变化；显式传递指定主题才能验证同主题的SwiftUI颜色。
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)); host.sizingOptions = []
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
                    if let handle = try? FileHandle(forWritingTo: log) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8)); try? handle.close() }
                    else { try? Data(text.utf8).write(to: log) }
                }
                return event
            }
        }
        // 给实际查询、SwiftUI布局和ImageIO可见任务时间完成。
        try await Task.sleep(for: .milliseconds(700))
        // 设置窗口按内容定高，验证图同样使用贴合尺寸，暴露留白或截断。
        if let settingsHeight { window.setContentSize(.init(width: width, height: settingsHeight)); host.frame.size = .init(width: width, height: settingsHeight); try await Task.sleep(for: .milliseconds(200)) }
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
        guard board.writeObjects(writers), let imageWriter = writers.first(where: { ContentExportProvider.promiseProvider(for: $0)?.fileType == SupportedType.png }),
              let image = ContentExportProvider.promiseProvider(for: imageWriter),
              image.fileType == SupportedType.png, image.delegate != nil,
              let data = imageWriter.pasteboardPropertyList(forType: .init(SupportedType.png)) as? Data,
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
