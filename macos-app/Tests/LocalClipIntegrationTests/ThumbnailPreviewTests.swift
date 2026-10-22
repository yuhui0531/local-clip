// 真实编码图片与隔离缩略图回归；仅使用临时库和RawBoard，不访问系统剪贴板或生产库，by AI.Coding。
import AppKit
import ImageIO
import SwiftUI
import Vision
import Testing
import LocalClipCore
@testable import LocalClipMac

struct ThumbnailPreviewTests {
    /// 文本文件引用只读开头；截断处的多字节字符、二进制与缺失文件都有确定结果。
    @Test func textFileReferencePreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["a.txt", "b.go", "c.tsx", "d.sql", "Makefile", "e.vue"] { #expect(TextFilePreview.isCandidate(path), "\(path)") }
        for path in ["a.rtf", "b.png", "c.JPG"] { #expect(!TextFilePreview.isCandidate(path), "\(path)") }
        let code = directory.appendingPathComponent("main.go"), pdf = directory.appendingPathComponent("doc.pdf")
        try Data("package main\n\nfunc main() {}\n".utf8).write(to: code)
        try Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, 0xE2, 0xE3, 0xCF, 0xD3]).write(to: pdf)
        #expect(TextFilePreview.read(code) == "package main\n\nfunc main() {}\n")
        #expect(TextFilePreview.read(pdf) == nil)
        let chinese = directory.appendingPathComponent("中文.txt"), binary = directory.appendingPathComponent("bin.txt")
        try Data(String(repeating: "汉", count: 10).utf8).write(to: chinese)
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        #expect(TextFilePreview.read(chinese) == String(repeating: "汉", count: 10))
        #expect(TextFilePreview.read(chinese, limit: 7) == "汉汉")
        #expect(TextFilePreview.read(binary) == nil)
        #expect(TextFilePreview.read(directory.appendingPathComponent("missing.txt")) == nil)
    }
    /// 图片文件引用从磁盘生成预览；文件缺失或内容不是图片时返回不可用，卡片退回普通文件样式。
    @Test func imageFileReferenceThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("photo.png"), fake = directory.appendingPathComponent("fake.png")
        try ImageFixtures.image(width: 120, height: 60).write(to: image)
        try Data("not an image".utf8).write(to: fake)
        guard case .image(let data) = ThumbnailRenderer.render(fileAt: image) else { Issue.record("图片文件应生成预览"); return }
        #expect(NSImage(data: data)?.size.width ?? 0 > 0)
        guard case .unavailable = ThumbnailRenderer.render(fileAt: fake) else { Issue.record("非图片内容不应生成预览"); return }
        guard case .unavailable = ThumbnailRenderer.render(fileAt: directory.appendingPathComponent("missing.png")) else { Issue.record("缺失文件不应生成预览"); return }
    }
    /// 两页不同尺寸的真实TIFF，用于确认只派生首页预览而保留所有原始页。
    private func multipageTIFF() throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, SupportedType.tiff as CFString, 2, nil))
        for width in [80, 120] {
            let png = try ImageFixtures.image(width: width, height: 60)
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            CGImageDestinationAddImage(destination, image, nil)
        }
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 首个表示损坏时尝试后续真实PNG/TIFF/JPEG，既不丢弃坏数据也不改写好数据。
    @Test(arguments: [SupportedType.png, SupportedType.tiff, SupportedType.jpeg])
    func invalidFirstRepresentationFallsBack(type: String) throws {
        let data = try ImageFixtures.image(width: 1200, height: 600, type: type)
        let payload = ClipboardPayload([.init([.init("public.png", Data("invalid PNG fixture".utf8))]), .init([.init(type, data)])])
        let before = payload
        guard case .image(let thumbnail) = ThumbnailRenderer.render(payload) else { Issue.record("有效后续图片未生成预览"); return }
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 800 && image.height == 400)
        #expect(payload == before)
    }

    /// 同一项损坏PNG与多页TIFF共存时，存储、派生缓存及重开均保留原始表示和设置。
    @Test func multipageFallbackCachesWithoutChangingOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tiff = try multipageTIFF()
        let payload = ClipboardPayload([.init([.init(SupportedType.png, Data("invalid PNG fixture".utf8)), .init(SupportedType.tiff, tiff)])])
        let store = try HistoryStore(location: root), now = SystemClock().now()
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: now) else { Issue.record("缺fixture"); return }
        let original = try await store.detail(id: id, at: now), settings = try await store.settings()
        let derived = DerivedContentService(store: store)
        guard case .image(let first) = await derived.thumbnail(id: id) else { Issue.record("TIFF备用预览失败"); return }
        let source = try #require(CGImageSourceCreateWithData(first as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 80 && image.height == 60)
        guard case .image(let cached) = await derived.thumbnail(id: id) else { Issue.record("缓存读取失败"); return }
        #expect(first == cached)
        let reopened = try HistoryStore(location: root), after = try await reopened.detail(id: id, at: now)
        #expect(after.payload == payload && after.revision == original.revision)
        #expect(try await reopened.settings() == settings)
        #expect(try await reopened.thumbnail(id: id, at: now) == first)
        let retained = try #require(after.payload.items[0].representations.first { $0.type == SupportedType.tiff })
        let originalSource = try #require(CGImageSourceCreateWithData(retained.data as CFData, nil))
        #expect(CGImageSourceGetCount(originalSource) == 2)
        // 删除后的缓存不可再显示或重新生成历史。
        let deletion = try await store.preview(.delete([id])); _ = try await store.apply(deletion.token)
        if case .unavailable = await derived.thumbnail(id: id) {} else { Issue.record("已删预览仍可见") }
    }

    /// 无有效表示时返回失败，首个有效表示仍保持原顺序；空载荷不伪装成可预览图片。
    @Test func invalidAndEmptyPayloadsFail() {
        for payload in [ClipboardPayload([]), .init([.init([.init(SupportedType.png, Data("invalid PNG fixture".utf8))])])] {
            if case .unavailable = ThumbnailRenderer.render(payload) {} else { Issue.record("无效图片应明确失败") }
        }
    }

    /// UI状态覆盖损坏缓存与像素限制，失败状态不会保留加载指示或虚构缩略图。
    @MainActor @Test func previewStatesAreDistinct() throws {
        let valid = try ImageFixtures.image(width: 32, height: 24)
        let ready = ThumbnailPreviewState(.image(valid))
        #expect(ready.image != nil)
        #expect(ThumbnailPreviewState(.image(Data("broken cache".utf8))).image == nil)
        if case .failed = ThumbnailPreviewState(.image(Data("broken cache".utf8))) {} else { Issue.record("坏缓存不应显示加载中") }
        if case .failed = ThumbnailPreviewState(.unavailable) {} else { Issue.record("失败状态不明确") }
        if case .tooLarge = ThumbnailPreviewState(.tooManyPixels) {} else { Issue.record("尺寸限制不明确") }
        #expect(Set([ThumbnailPreviewState.loading.label, ready.label,
                     ThumbnailPreviewState.failed.label, ThumbnailPreviewState.tooLarge.label]).count == 4)
    }
}

/// 显式启用的原生托管回归仅创建本测试的窗口、临时库与假剪贴板，by AI.Coding。
// 桌面展示另需明确授权；原有专项开关仍保留，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct ThumbnailPreviewHostingTests {
    /// 识别本测试渲染的合成像素，不依赖SwiftUI内部AX树，也不截取系统屏幕。
    private func visibleText(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 无点击、无选择也自动加载真实卡片；损坏图片明确失败，并保存隔离截图供视觉检查。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_PREVIEW_TEST"] == "1"))
    func visibleCardsLoadAutomatically() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let valid = try ImageFixtures.image(width: 320, height: 240)
        for (index, data) in [valid, Data("invalid PNG fixture".utf8)].enumerated() {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, data)])])), at: now + Int64(index))
        }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1000, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        let deadline = ContinuousClock.now + .seconds(15)
        var text = "", rendered: NSBitmapImageRep?
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap); rendered = bitmap
            text = try visibleText(bitmap)
            // 坏图可能先完成；同时等待有效图渲染结束，不能把异步加载中的另一张图判成回归，by AI.Coding。
            if text.contains("无法生成预览"), !text.contains("正在加载预览"),
               model.items.contains(where: { model.thumbnails.object(forKey: $0.id as NSString) != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        #expect(text.contains("无法生成预览") && text.contains("原始数据已保留"), "\(text)")
        #expect(!text.contains("按需预览") && !text.contains("正在加载预览"))
        #expect(!model.showingDetail)
        let bitmap = try #require(rendered)
        // 确认fixture的两块大面积色块确已绘制；使用色差以兼容显示器色彩管理。
        var bluePixels = 0, orangePixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    if color.blueComponent - color.redComponent > 0.25,
                       color.greenComponent - color.redComponent > 0.2 { bluePixels += 1 }
                    if color.redComponent - color.greenComponent > 0.2,
                       color.greenComponent - color.blueComponent > 0.12 { orangePixels += 1 }
                }
            }
        }
        #expect(bluePixels > 600 && orangePixels > 100)
        // 仅在显式指定工作区证据目录时保存截图，不导出用户历史。
        if let output = ProcessInfo.processInfo.environment["LOCALCLIP_PREVIEW_OUTPUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("preview-cards.png"))
        }
    }

    /// 浅深色与紧凑布局均渲染实际组件，加载和两种失败文案不得混淆或消失。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_PREVIEW_TEST"] == "1"))
    func loadingAndFailureStatesRender() async throws {
        _ = NSApplication.shared
        let states: [ThumbnailPreviewState] = [.loading, .failed, .tooLarge]
        for dark in [false, true] {
            let view = VStack(spacing: 16) {
                HStack(spacing: 16) {
                    ForEach(states.indices, id: \.self) { index in
                        ThumbnailPreview(state: states[index], tint: .teal, compact: false).frame(width: 210, height: 160)
                    }
                }
                HStack(spacing: 16) {
                    ForEach(states.indices, id: \.self) { index in
                        ThumbnailPreview(state: states[index], tint: .teal, compact: true).frame(width: 210, height: 48)
                    }
                }
            }.padding(16).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view); host.sizingOptions = []
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 694, height: 256), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let text = try visibleText(bitmap)
            for state in states { #expect(text.contains(state.label), "\(text)") }
            if let output = ProcessInfo.processInfo.environment["LOCALCLIP_PREVIEW_OUTPUT"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(dark ? "states-dark.png" : "states-light.png"))
            }
        }
    }
}

/// 共享缓存淘汰仍可见卡片的缩略图后，卡片不能退回加载态；窗口从不显示，无桌面副作用，by AI.Coding。
@MainActor struct ThumbnailCacheEvictionTests {
    @Test func visibleCardKeepsCachedThumbnailAfterEviction() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), data = try ImageFixtures.image(width: 320, height: 240)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, data)])])), at: SystemClock().now()) else { throw StoreError.notFound }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        // 预置缓存命中：卡片走复用路径而非自行生成。
        model.thumbnails.setObject(try #require(NSImage(data: data)), forKey: id as NSString)
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func text() throws -> String {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans"]
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(!(try text()).contains("正在加载"))
        // 淘汰后任意重绘都不能露出无人重载的加载占位；切换隐藏内容只为触发卡片重绘。
        model.thumbnails.removeObject(forKey: id as NSString)
        model.updateSettings { $0.hideContents = true }
        try await Task.sleep(for: .milliseconds(300))
        model.updateSettings { $0.hideContents = false }
        try await Task.sleep(for: .milliseconds(800))
        let after = try text()
        #expect(!after.contains("正在加载"), "\(after)")
    }
}
