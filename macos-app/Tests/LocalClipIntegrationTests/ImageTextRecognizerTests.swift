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

    /// LC-F03：正文图片文件优先于同项图标，保留混合文本条目下的相同语义，by AI.Coding。
    @Test(arguments: [false, true])
    func fileContentsTakePrecedenceOverIcon(mixed: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.png(lines: ["DOCUMENT 4242"]).write(to: url)
        let icon = try #require(NSBitmapImageRep(data: Self.png(lines: ["ICON 9999"]))?.representation(using: .tiff, properties: [:]))
        let file = PasteboardItemValue([.init(SupportedType.fileURL, Data(url.absoluteString.utf8)), .init(SupportedType.tiff, icon)])
        let text = PasteboardItemValue([.init(SupportedType.string, Data("caption".utf8))])
        let value = ClipboardPayload(mixed ? [text, file] : [file])
        let recognized = try await ImageTextRecognizer.recognize(value).joined(separator: " ")
        #expect(recognized.contains("4242"), "\(recognized)")
        #expect(!recognized.contains("9999"), "\(recognized)")
    }

    /// LC-F04：逐项枚举混合记录的文件，跳过非图片/损坏文件，保持全文件聚合契约，by AI.Coding。
    @Test(arguments: [false, true])
    func mixedFileReferencesRemainOCRCandidates(textFirst: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.png")
        try Self.png(lines: ["MIXED 5678"]).write(to: url)
        let bad = root.appendingPathComponent("broken.png"), other = root.appendingPathComponent("note.txt")
        try Data("not an image".utf8).write(to: bad)
        try Data("plain file".utf8).write(to: other)
        let files = [other, bad, url].map { PasteboardItemValue([.init(SupportedType.fileURL, Data($0.absoluteString.utf8))]) }
        let text = PasteboardItemValue([.init(SupportedType.string, Data("caption".utf8))])
        let mixed = ClipboardPayload(textFirst ? [text] + files : files + [text])
        #expect(mixed.fileURLs == nil)
        #expect(ClipboardPayload(files).fileURLs == [other, bad, url])
        #expect(try await ImageTextRecognizer.recognize(mixed).joined().contains("5678"))
    }

    /// 文件不可用时仍可识别后续有效表示；内嵌图片加独立文本保持可用，by AI.Coding。
    @Test func unavailableFileFallsBackToInlineImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let bytes = try Self.png(lines: ["FALLBACK 6789"])
        let file = PasteboardItemValue([.init(SupportedType.fileURL, Data(url.absoluteString.utf8)), .init(SupportedType.png, Data("broken".utf8)), .init(SupportedType.tiff, bytes)])
        let text = PasteboardItemValue([.init(SupportedType.string, Data("caption".utf8))])
        for value in [ClipboardPayload([file, text]), ClipboardPayload([.init([.init(SupportedType.png, bytes)]), text])] {
            #expect(try await ImageTextRecognizer.recognize(value).joined().contains("6789"))
        }
    }

    /// 超过4000万像素的文件不解码，并可回退到下一项的有效图片，by AI.Coding。
    @Test func oversizedFileIsRejectedWithoutHidingLaterImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageFixtures.image(width: 6500, height: 6200).write(to: url)
        let file = PasteboardItemValue([.init(SupportedType.fileURL, Data(url.absoluteString.utf8))])
        do { _ = try await ImageTextRecognizer.recognize(.init([file])); Issue.record("Oversized image accepted") }
        catch let error as ImageTextRecognizer.Failure { #expect(error.message == "图片超过 4000 万像素，无法识别") }
        let next = PasteboardItemValue([.init(SupportedType.png, try Self.png(lines: ["NEXT 7890"]))])
        #expect(try await ImageTextRecognizer.recognize(.init([file, next])).joined().contains("7890"))
    }

    /// LC-R10：损坏首表示应尝试后续原图；Finder图片引用沿用同一识别链，by AI.Coding。
    @Test func fallsBackToTIFFAndRecognizesFileReference() async throws {
        let data = try Self.png(lines: ["LocalClip fallback 2026"])
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        let mixed = ClipboardPayload([.init([.init(SupportedType.png, Data("invalid".utf8)), .init(SupportedType.tiff, tiff), .init(SupportedType.string, Data("caption".utf8))])])
        #expect(try await ImageTextRecognizer.recognize(mixed).joined().contains("2026"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(url.absoluteString.utf8))])])
        #expect(try await ImageTextRecognizer.recognize(file).joined().contains("2026"))
    }

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
