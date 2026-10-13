// F15全类型拖出为文件：文件承诺的类型、文件名、字节与不覆盖规则，真实临时SQLite，不访问通用剪贴板，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct ClipFileExportTests {
    private func store(_ root: URL) throws -> HistoryStore { try HistoryStore(location: root.appendingPathComponent("Store")) }
    private func ingest(_ store: HistoryStore, _ representations: [Representation], at: Instant = SystemClock().now()) async throws -> ClipID {
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init(representations)])), at: at) else { throw StoreError.notFound }
        return id
    }
    private func promise(_ writer: any NSPasteboardWriting) throws -> (NSFilePromiseProvider, any NSFilePromiseProviderDelegate) {
        let provider = try #require(writer as? NSFilePromiseProvider)
        return (provider, try #require(provider.delegate))
    }
    private func write(_ promise: (NSFilePromiseProvider, any NSFilePromiseProviderDelegate), to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in promise.1.filePromiseProvider(promise.0, writePromiseTo: url) { continuation.resume(returning: $0) } }
    }
    private static func rtf(_ text: String, font: NSFont) -> Data {
        let value = NSAttributedString(string: text, attributes: [.font: font])
        return value.rtf(from: NSRange(location: 0, length: value.length), documentAttributes: [:])!
    }

    /// PRD 6.2格式表：每种文字内容的文件类型、扩展名和写出字节，by AI.Coding。
    @Test(arguments: ["json", "swift-html", "rtf-prose", "html-only", "markdown", "prose"])
    func textItemsBecomeTypedFiles(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let swift = "import Foundation\nstruct Point { let x: Int; let y: Int }\nfunc distance(_ a: Point, _ b: Point) -> Double {\n    let dx = Double(a.x - b.x), dy = Double(a.y - b.y)\n    return (dx * dx + dy * dy).squareRoot()\n}\n"
        let json = "{\n  \"name\": \"LocalClip\",\n  \"tags\": [\"clipboard\", \"macOS\"],\n  \"build\": 42\n}\n"
        let representations: [Representation], expectedExtension: String, expected: Data
        switch kind {
        case "json": representations = [.init(SupportedType.string, Data(json.utf8))]; expectedExtension = "json"; expected = Data(json.utf8)
        case "swift-html":
            representations = [.init(SupportedType.string, Data(swift.utf8)), .init(SupportedType.html, Data("<pre><code class=\"language-swift\">\(swift)</code></pre>".utf8))]
            expectedExtension = "swift"; expected = Data(swift.utf8)
        case "rtf-prose":
            let prose = "Hello team, the release notes are attached. See you tomorrow."
            let data = Self.rtf(prose, font: NSFont(name: "Helvetica", size: 13)!)
            representations = [.init(SupportedType.string, Data(prose.utf8)), .init(SupportedType.rtf, data)]; expectedExtension = "rtf"; expected = data
        case "html-only":
            let data = Data("<p>Hello <b>there</b>, see you tomorrow.</p>".utf8)
            representations = [.init(SupportedType.html, data)]; expectedExtension = "html"; expected = data
        case "markdown":
            let text = "# 发布说明\n\n- 新增拖出为文件\n- 修复若干问题\n\n详见 [PRD](https://example.com/prd)\n"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "md"; expected = Data(text.utf8)
        default:
            let text = "明天下午三点开会，记得带上电脑。"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "txt"; expected = Data(text.utf8)
        }
        let id = try await ingest(store, representations)
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "test", register: { _ in })
        let promise = try promise(try #require(writers.first))
        let name = promise.1.filePromiseProvider(promise.0, fileNameForType: promise.0.fileType)
        #expect(name.hasSuffix("." + expectedExtension), "\(kind): \(name)")
        #expect(name.range(of: "^LocalClip-\\d{8}-\\d{6}\\.", options: .regularExpression) != nil, "\(kind): \(name)")
        let destination = root.appendingPathComponent(name)
        #expect(await write(promise, to: destination) == nil)
        #expect(try Data(contentsOf: destination) == expected, "\(kind)")
        // 导出不改历史，租约已释放。
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).canonicalData == ClipboardPayload([.init(representations)]).canonicalData)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Store/Exports").path)) ?? []).isEmpty)
    }

    /// 链接与文件引用保持原有拖放写入者，由Finder生成.webloc或复制原件，by AI.Coding。
    @Test func linksAndFileReferencesKeepNativeDrag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let link = try await ingest(store, [.init(SupportedType.url, Data("https://example.com/a".utf8)), .init(SupportedType.string, Data("https://example.com/a".utf8))])
        // 文件引用附带图标图片时仍按原件处理，不生成图标PNG（PRD 6.2规则1先于规则2）。
        let file = try await ingest(store, [.init(SupportedType.fileURL, Data(URL(fileURLWithPath: "/tmp/a.txt").absoluteString.utf8)), .init(SupportedType.tiff, try ImageFixtures.image(width: 4, height: 4, type: SupportedType.tiff))], at: SystemClock().now() + 1)
        let writers = try await ContentExportProvider.writers(ids: [link, file], store: store, token: "test", register: { _ in })
        #expect(writers.count == 2)
        #expect(writers.allSatisfy { !($0 is NSFilePromiseProvider) })
    }

    /// 自定义名称作为文件名；多项一起拖出按顺序加序号，图片不再使用UUID，by AI.Coding。
    @Test func titlesAndMultiDragNumbering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root), now = SystemClock().now()
        let text = try await ingest(store, [.init(SupportedType.string, Data("{\"a\": 1, \"b\": [true, null]}".utf8))], at: now)
        let image = try await ingest(store, [.init(SupportedType.png, try ImageFixtures.image(width: 8, height: 8))], at: now + 1)
        try await store.renameClip(id: text, title: "API 响应/v2")
        let single = try promise(try #require(try await ContentExportProvider.writers(ids: [text], store: store, token: "test", register: { _ in }).first))
        #expect(single.1.filePromiseProvider(single.0, fileNameForType: single.0.fileType) == "API 响应-v2.json")
        let writers = try await ContentExportProvider.writers(ids: [text, image], store: store, token: "test", register: { _ in })
        let names = try writers.map { writer in let value = try promise(writer); return value.1.filePromiseProvider(value.0, fileNameForType: value.0.fileType) }
        #expect(names[0] == "API 响应-v2-1.json")
        #expect(names[1].range(of: "^LocalClip-\\d{8}-\\d{6}-2\\.png$", options: .regularExpression) != nil, "\(names[1])")
    }

    /// 目标已有同名文件时写为"名称 2.ext"，原文件逐字节不变，by AI.Coding。
    @Test func existingFileIsNeverOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let json = Data("{\"ok\": true}".utf8)
        let id = try await ingest(store, [.init(SupportedType.string, json)])
        let promise = try promise(try #require(try await ContentExportProvider.writers(ids: [id], store: store, token: "test", register: { _ in }).first))
        let destination = root.appendingPathComponent("result.json"), existing = Data("keep me".utf8)
        try existing.write(to: destination)
        #expect(await write(promise, to: destination) == nil)
        #expect(try Data(contentsOf: destination) == existing)
        #expect(try Data(contentsOf: root.appendingPathComponent("result 2.json")) == json)
    }

    /// 同一拖动项同时提供文件承诺、原有文字类型与立即可读的分类令牌；只有HTML时仍合成纯文字，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func textPromiseStillOffersTextAndCategoryToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let id = try await ingest(store, [.init(SupportedType.html, Data("<p>Hello <b>there</b></p>".utf8))])
        let writer = try #require(try await ContentExportProvider.writers(ids: [id], store: store, token: "drag-token", register: { _ in }).first as? NSFilePromiseProvider)
        let board = NSPasteboard(name: .init("local.localclip.file-export." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let category = NSPasteboard.PasteboardType(HistoryViewModel.categoryDragType)
        let types = writer.writableTypes(for: board).map(\.rawValue)
        #expect(types.contains(SupportedType.html) && types.contains(SupportedType.string) && types.contains(HistoryViewModel.categoryDragType))
        #expect(writer.writingOptions(forType: category, pasteboard: board) == [])
        #expect(board.writeObjects([writer]))
        #expect(board.data(forType: category) == Data("drag-token".utf8))
        // 与原有文字拖放相同的本地HTML提取结果。
        #expect(board.string(forType: .string) == ContentDecoder.extract(.init(SupportedType.html, Data("<p>Hello <b>there</b></p>".utf8))))
        #expect(board.data(forType: .html) == Data("<p>Hello <b>there</b></p>".utf8))
    }

    /// PRD 5.5：1 MiB文字记录的拖动开始（声明类型、预读）与写出文件耗时；可选执行，原始样本写入输出文件，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_EXPORT_PERF"] == "1"))
    func oneMiBTextExportTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let line = "  {\"id\": 123456, \"name\": \"LocalClip export benchmark\", \"tags\": [\"a\", \"b\"]},\n"
        let json = "[\n" + String(repeating: line, count: (1 << 20) / line.utf8.count) + "  {}\n]\n"
        let id = try await ingest(store, [.init(SupportedType.string, Data(json.utf8))])
        var starts: [Double] = [], writes: [Double] = []
        for sample in 0..<30 {
            let begin = ContinuousClock.now
            let writer = try #require(try await ContentExportProvider.writers(ids: [id], store: store, token: "perf", register: { _ in }).first)
            let ready = ContinuousClock.now
            let promise = try promise(writer)
            #expect(await write(promise, to: root.appendingPathComponent("out-\(sample).json")) == nil)
            let done = ContinuousClock.now
            func ms(_ value: Duration) -> Double { Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15 }
            starts.append(ms(ready - begin)); writes.append(ms(done - ready))
        }
        // 拆出语言识别耗时，便于判断拖动开始的主要成本。
        var languages: [Double] = []
        for _ in 0..<30 { let begin = ContinuousClock.now; _ = await SyntaxHighlighter.shared.language(of: json, sample: 512); let value = ContinuousClock.now - begin; languages.append(Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15) }
        func p(_ values: [Double], _ q: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1)] }
        let report: [String: Any] = ["bytes": json.utf8.count, "dragStartMs": starts, "writeMs": writes,
                                     "dragStartP50": p(starts, 0.5), "dragStartP95": p(starts, 0.95), "writeP50": p(writes, 0.5), "writeP95": p(writes, 0.95), "languageMs": languages, "languageP50": p(languages, 0.5), "languageP95": p(languages, 0.95)]
        if let output = ProcessInfo.processInfo.environment["LOCALCLIP_EXPORT_PERF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        #expect(p(writes, 0.95) < 100)
    }
}
