// README 界面预览的合成数据托管截图：底部面板浅色/深色 readme-light/dark.png，历史管理浅色 readme-manager.png，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；与其他视觉专项同一双开关，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct ReadmeScreenshotTests {
    struct Seeded {
        let model: HistoryViewModel, capture: CaptureCoordinator, ids: [ClipID], output: URL
    }

    /// 十条规整的合成记录（ids[0] 最新），带名称、收藏与“工作/设计”分类。
    private func seed(_ root: URL) async throws -> Seeded {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
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
        func link(_ value: String) -> ClipboardPayload { .init([.init([.init(SupportedType.url, Data(value.utf8)), .init(SupportedType.string, Data(value.utf8))])]) }
        func source(_ id: String, _ name: String) -> SourceAttribution { .init(bundleID: id, name: name) }
        let notes = root.appendingPathComponent("发布说明.md")
        try Data("# LocalClip 0.3.64\n\n- 打开面板首帧即最新\n- 第一屏图片即时显示\n- 修复多选偶尔被清空\n".utf8).write(to: notes)
        let code = source("com.microsoft.VSCode", "Visual Studio Code"), safari = source("com.apple.Safari", "Safari")
        // 一位开发者一天里的复制，按时间从新到旧；分钟数决定“x分钟前/x小时前/昨天”。
        let records: [(payload: ClipboardPayload, source: SourceAttribution, minutesAgo: Int64, title: String?)] = [
            (text("登录改版本周完成，下周一进入灰度测试；回归问题统一记在发布清单里。"), source("com.apple.Notes", "备忘录"), 3, "周会纪要"),
            (link("https://developer.apple.com/documentation/appkit/nspasteboard"), safari, 12, "NSPasteboard 文档"),
            (text("func restore(_ clip: Clip) {\n  board.clearContents()\n  board.write(clip.payload)\n}"), code, 26, "恢复剪贴板"),
            (.init([.init([.init(SupportedType.png, try artwork())])]), source("com.apple.Preview", "预览"), 48, "首页配色草图"),
            (.init([.init([.init(SupportedType.fileURL, Data(notes.absoluteString.utf8))])]), source("com.apple.finder", "访达"), 95, "发布说明"),
            (text("#0A84FF"), source("com.apple.Notes", "备忘录"), 140, "品牌主色"),
            (text("git log --oneline -5"), source("com.apple.Terminal", "终端"), 210, "查看最近提交"),
            (text("{\n  \"version\": \"0.3.64\",\n  \"build\": 86,\n  \"channel\": \"stable\"\n}"), code, 320, "版本配置"),
            (text("您好，附件是 10 月版本的验收清单，请在周五前确认。"), source("com.apple.mail", "邮件"), 26 * 60, "验收清单邮件"),
            (link("https://www.swift.org/documentation/"), safari, 30 * 60, "Swift 文档"),
        ]
        let now = SystemClock().now()
        var ids: [ClipID] = []
        // 先插入最旧的，列表按最近复制排在前面；ids 与 records 同序。
        for record in records.reversed() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: record.payload, source: record.source), at: now - record.minutesAgo * 60_000) else { throw StoreError.notFound }
            if let title = record.title { try await store.renameClip(id: id, title: title) }
            ids.insert(id, at: 0)
        }
        for index in [2, 7] { let favorite = try await store.preview(.favorite(ids[index], true)); _ = try await store.apply(favorite.token) }
        let work = try await store.createCategory(name: "工作", colorHex: "34C759")
        let design = try await store.createCategory(name: "设计", colorHex: "AF52DE")
        for (members, category) in [([ids[0], ids[2], ids[7], ids[8]], work), ([ids[3], ids[5]], design)] {
            let change = try await store.preview(.category(members, category.id, true)); _ = try await store.apply(change.token)
        }
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(15)
        while model.items.count < records.count, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.items.count == records.count)
        return .init(model: model, capture: capture, ids: ids, output: output)
    }

    private func snapshot(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded(); host.window?.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL"] == "1"))
    func readmeScreenshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try await seed(root), model = seeded.model
        model.select(seeded.ids.first)
        // 宽度恰好放下六张卡片，右侧不露出半张。
        let width = 1840.0, height = 360.0
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { seeded.capture.stop(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        model.actualPanelHeight = height
        model.configureHistoryViewport(width: width, cardWidth: HistoryView.cardSide(height: height))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // 等待缩略图、文件预览与来源色异步就绪。
            try await Task.sleep(for: .seconds(2))
            try snapshot(host, to: seeded.output.appendingPathComponent("readme-\(dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_VISUAL"] == "1"))
    func readmeManagerScreenshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try await seed(root)
        let manager = HistoryManagerModel(history: seeded.model); manager.start()
        defer { manager.stop(); seeded.capture.stop() }
        let until = ContinuousClock.now + .seconds(15)
        while manager.rows.count < seeded.ids.count, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        manager.selection = [seeded.ids[2]]
        while manager.detail == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        // 默认宽度；高度收到十行数据刚好铺满，避免大片空行。
        let size = NSSize(width: HistoryManagerWindow.defaultSize.width, height: 680)
        let host = NSHostingView(rootView: HistoryManagerView(model: manager, history: seeded.model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .seconds(2))
        try snapshot(host, to: seeded.output.appendingPathComponent("readme-manager.png"))
    }
}
