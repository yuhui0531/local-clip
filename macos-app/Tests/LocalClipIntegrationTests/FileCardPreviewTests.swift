// 文件卡片真实内容回归，仅操作临时文件和临时数据库，不打开窗口或系统剪贴板，by AI.Coding。
import Foundation
import CoreGraphics
import ImageIO
import Testing
import LocalClipCore
@testable import LocalClipMac

struct FileCardPreviewTests {
    /// 每例独立临时目录，复现微信哈希文件名及超过摘要上限的完整路径。
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 无后缀、误导后缀及长路径图片都必须按内容识别，不能落回只有文件名的卡片。
    @Test(arguments: ["0d66eb1fd32155e1c5fcd58f6306c", "photo.bin", "photo.txt", "photo.png"])
    func imageContentIgnoresExtension(name: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(String(repeating: "long-path-", count: 16))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name), original = try ImageFixtures.image(width: 1200, height: 600)
        try original.write(to: url)
        #expect(url.path.count > 180)
        guard case .image(let data) = await FileCardPreview.render(fileAt: url) else { Issue.record("图片内容必须能预览：\(name)"); return }
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 800 && image.height == 400)
        #expect(try Data(contentsOf: url) == original)
    }

    /// 文本和代码仍读有界开头，不能因新增文档缩略图丢失语法预览所需正文。
    @Test(arguments: ["main.swift", "notes.txt", "README", "view.vue"])
    func textContentIsPreserved(name: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name), text = "// 中文预览\nlet value = 42\n"
        try Data(text.utf8).write(to: url)
        guard case .text(let actual) = await FileCardPreview.render(fileAt: url) else { Issue.record("文本预览丢失"); return }
        #expect(actual == text)
    }

    /// PDF首页包含真实绘制内容，含无后缀PDF；不能当UTF-8正文显示或只显示文件图标。
    @Test(arguments: ["report.pdf", "document-without-extension"])
    func pdfPageThumbnail(name: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name), data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(bounds); context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: url)
        guard case .image(let thumbnail) = await FileCardPreview.render(fileAt: url) else { Issue.record("PDF必须生成页面预览"); return }
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 800 && image.height == 400)
        let pixels = try #require(image.dataProvider?.data) as Data
        #expect(pixels.contains(0)) // 绘制内容不应变成纯白占位页。
        #expect(try Data(contentsOf: url) == data as Data)
    }

    /// 系统Quick Look处理富文本文档，仅生成缩略图，不展示系统预览窗口。
    @Test func richTextDocumentThumbnail() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.rtf")
        let original = Data("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs36 LocalClip document preview\\par Second paragraph}".utf8)
        try original.write(to: url)
        guard case .image(let thumbnail) = await FileCardPreview.render(fileAt: url) else { Issue.record("RTF必须通过系统生成内容缩略图"); return }
        #expect(CGImageSourceCreateWithData(thumbnail as CFData, nil) != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    /// 缺失文件和目录明确回退，不生成伪缩略图，也不创建原件。
    @Test func missingAndDirectoryAreUnavailable() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for url in [root, root.appendingPathComponent("missing.png")] {
            guard case .unavailable = await FileCardPreview.render(fileAt: url) else { Issue.record("失效引用不能生成预览"); continue }
        }
    }

    /// 现有文件历史可直接恢复预览，无需重新复制、改分类、改修订或迁移数据库。
    @Test func existingHistoryReferenceRemainsUnchanged() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("wechat-image"), original = try ImageFixtures.image(width: 100, height: 80)
        try original.write(to: url)
        let store = try HistoryStore(location: root.appendingPathComponent("store")), now = SystemClock().now()
        let payload = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(url.absoluteString.utf8))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: now) else { Issue.record("历史记录fixture写入失败"); return }
        let before = try await store.detail(id: id, at: now)
        let first = try #require(before.payload.fileURLs?.first)
        guard case .image = await FileCardPreview.render(fileAt: first) else { Issue.record("已有记录未恢复预览"); return }
        let after = try await store.detail(id: id, at: now)
        #expect(after.summary.kind == .file)
        #expect(after.payload == before.payload)
        #expect(after.revision == before.revision)
        #expect(try await store.thumbnail(id: id, at: now) == nil) // 外部文件缩略图不写入持久缓存。
        #expect(try Data(contentsOf: url) == original)
    }

    /// 图形不可用时保留 SVG 源码，图形成功时优先显示，原件始终不改写。
    @Test(arguments: [false, true]) func svgKeepsTextFallback(_ succeeds: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drawing.svg")
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>"
        try Data(text.utf8).write(to: url)
        let rendered = await FileCardPreview.render(fileAt: url, document: { _ in succeeds ? .image(Data([1])) : .unavailable })
        switch rendered {
        case .image: #expect(succeeds)
        case .text(let actual): #expect(!succeeds && actual == text)
        case .unavailable: Issue.record("SVG fallback lost")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }
    /// 取消先于安装、晚于安装和成功之后都只能完成一次，迟到回调不能复活内容。
    @Test func previewCancellationCompletesExactlyOnce() async {
        for early in [true, false] {
            let completion = PreviewCompletion()
            if early { completion.cancel() }
            let result: FileCardPreview = await withCheckedContinuation { continuation in
                if completion.install(continuation) {
                    completion.cancel(); completion.finish(.image(Data([1])))
                }
            }
            guard case .unavailable = result else { Issue.record("cancelled preview published"); continue }
            #expect(completion.isCancelled)
        }
        let completion = PreviewCompletion()
        let result: FileCardPreview = await withCheckedContinuation { continuation in
            _ = completion.install(continuation); completion.finish(.image(Data([2]))); completion.cancel()
        }
        guard case .image(let data) = result else { Issue.record("completed preview lost"); return }
        #expect(data == Data([2]))
    }
}
