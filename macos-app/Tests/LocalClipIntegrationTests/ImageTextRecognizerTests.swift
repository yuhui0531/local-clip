// F21图片文字识别：用测试内绘制的合成截图验证中英文、行序与无文字提示；不读取用户图片或剪贴板，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct ImageTextRecognizerTests {
    private static func png(lines: [String], width: Int = 900, height: Int = 260) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: 30, y: height - 80 - index * 70))
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    private func payload(_ data: Data) -> ClipboardPayload { .init([.init([.init(SupportedType.png, data)])]) }

    /// AC1：中英混排按阅读顺序逐行返回，by AI.Coding。
    @Test func recognizesChineseAndEnglishInOrder() async throws {
        let lines = try await ImageTextRecognizer.recognize(payload(try Self.png(lines: ["Error: file not found 404", "你好，世界", "LocalClip 2026"])))
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.first?.contains("404") == true, "\(lines)")
        #expect(lines.contains { $0.contains("你好") }, "\(lines)")
        #expect(lines.last?.contains("LocalClip") == true, "\(lines)")
    }

    /// AC4与非图片：纯色图提示未识别到文字，文字记录提示不含图片，by AI.Coding。
    @Test func reportsBlankImagesAndNonImages() async throws {
        do { _ = try await ImageTextRecognizer.recognize(payload(try Self.png(lines: []))); Issue.record("Blank image produced text") }
        catch let error as ImageTextRecognizer.Failure { #expect(error.message == "未识别到文字") }
        do { _ = try await ImageTextRecognizer.recognize(.init([.init([.init(SupportedType.string, Data("text".utf8))])])); Issue.record("Text accepted") }
        catch let error as ImageTextRecognizer.Failure { #expect(error.message == "所选内容不含图片") }
    }

    /// 识别结果只写纯文本并带自写收据，采集不会把它记入历史，by AI.Coding。
    @Test func copiedTextDoesNotEnterHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard(), board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture)
        try await capture.start()
        #expect(paste.copyText("识别结果\nline 2") == .copied)
        #expect(raw.items[0][SupportedType.string] == Data("识别结果\nline 2".utf8))
        capture.tick(); try await Task.sleep(for: .milliseconds(150)); capture.stop()
        #expect(try await store.search(.init()).items.isEmpty)
    }
}
