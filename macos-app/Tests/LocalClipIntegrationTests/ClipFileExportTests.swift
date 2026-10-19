// F15全类型拖出为文件：文件承诺的类型、文件名、字节与不覆盖规则，真实临时SQLite，不访问通用剪贴板，by AI.Coding。
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct ClipFileExportTests {
    private func store(_ root: URL) throws -> HistoryStore { try HistoryStore(location: root.appendingPathComponent("Store")) }
    private func ingest(_ store: HistoryStore, _ representations: [Representation], at: Instant = SystemClock().now()) async throws -> ClipID {
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init(representations)])), at: at) else { throw StoreError.notFound }
        return id
    }
    private func promise(_ writer: any NSPasteboardWriting) throws -> (NSFilePromiseProvider, any NSFilePromiseProviderDelegate) {
        let provider = try #require(ContentExportProvider.promiseProvider(for: writer))
        return (provider, try #require(provider.delegate))
    }
    private func write(_ promise: (NSFilePromiseProvider, any NSFilePromiseProviderDelegate), to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in promise.1.filePromiseProvider(promise.0, writePromiseTo: url) { @Sendable in continuation.resume(returning: $0) } }
    }
    private static func rtf(_ text: String, font: NSFont) -> Data {
        let value = NSAttributedString(string: text, attributes: [.font: font])
        return value.rtf(from: NSRange(location: 0, length: value.length), documentAttributes: [:])!
    }

    /// PRD 6.2格式表：每种文字内容的文件类型、扩展名和写出字节，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"), arguments: ["json", "swift-html", "rtf-prose", "html-only", "markdown", "prose",
                                                                                                  "user-prose", "css", "ambiguous-js", "mono-rtf-prose", "inline-code-html", "partial-pre-html",
                                                                                                  "vscode-html", "fenced-markdown", "mixed-prose-code", "empty-mono-span-html",
                                                                                                  "unrelated-pre-html", "oversized-html", "json-prose-pre", "php-explanation", "template-sql",
                                                                                                  "log-sql", "invalid-json", "go-crlf", "unicode-sql-pre"])
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
        case "user-prose":
            // 用户原始复现样本：此前被识别为CSS。
            let text = "Do we need a review agent to double confirm your changes? if yes, please generate a review prompt to let other coding agent to review your changes."
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "txt"; expected = Data(text.utf8)
        case "css":
            let text = ".card { color: #fff; margin: 10px; }\r\n"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "css"; expected = Data(text.utf8)
        case "ambiguous-js":
            let text = "const value = 1;"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "txt"; expected = Data(text.utf8)
        case "mono-rtf-prose":
            let prose = "Please review the export function and send the report by Friday."
            let data = Self.rtf(prose, font: NSFont(name: "Menlo", size: 12)!)
            representations = [.init(SupportedType.string, Data(prose.utf8)), .init(SupportedType.rtf, data)]; expectedExtension = "rtf"; expected = data
        case "inline-code-html":
            let data = Data("<p>Please review the <code>export</code> function and send the report.</p>".utf8)
            representations = [.init(SupportedType.string, Data("Please review the export function and send the report.".utf8)), .init(SupportedType.html, data)]
            expectedExtension = "html"; expected = data
        case "partial-pre-html":
            let html = "<p>The fix is below; please check it before the release.</p><pre>x = compute()</pre><p>Thanks for reviewing this today.</p>"
            let data = Data(html.utf8)
            representations = [.init(SupportedType.string, Data("The fix is below; please check it before the release.\nx = compute()\nThanks for reviewing this today.".utf8)), .init(SupportedType.html, data)]
            expectedExtension = "html"; expected = data
        case "vscode-html":
            let html = "<meta charset='utf-8'><div style=\"color: #d4d4d4;font-family: Menlo, Monaco, 'Courier New', monospace;white-space: pre;\"><div>\(swift)</div></div>"
            representations = [.init(SupportedType.string, Data(swift.utf8)), .init(SupportedType.html, Data(html.utf8))]
            expectedExtension = "swift"; expected = Data(swift.utf8)
        case "fenced-markdown":
            let text = "Here is the fix:\r\n\r\n```swift\r\nlet a = 1\r\n```\r\n\r\nIt removes the crash.\r\n"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "md"; expected = Data(text.utf8)
        case "mixed-prose-code":
            let text = swift + "\n" + String(repeating: "This paragraph explains why the function above needs another careful review.\n", count: 8)
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "txt"; expected = Data(text.utf8)
        case "empty-mono-span-html", "unrelated-pre-html", "oversized-html":
            // 审查R1/R2：空等宽元素、与正文无关的<pre>、超出64 KiB验证预算都不能授权转成.sql。
            let sql = "SELECT id FROM users WHERE active = 1;"
            let html = switch kind {
            case "empty-mono-span-html": "<span style=\"font-family: Menlo\"></span><p>\(sql)</p>"
            case "unrelated-pre-html": "<pre>This report explains the quarter forecast in full detail.</pre>"
            default: "<span style=\"font-family: Menlo\"></span>" + String(repeating: " ", count: 65_536) + "<p style=\"font-family: Arial\">\(sql)</p>"
            }
            representations = [.init(SupportedType.string, Data(sql.utf8)), .init(SupportedType.html, Data(html.utf8))]; expectedExtension = "html"; expected = Data(html.utf8)
        case "json-prose-pre":
            let text = "{\"name\": \"Alice\"}\nPlease review the report and send it back tomorrow."
            let data = Data("<pre>\(text)</pre>".utf8)
            representations = [.init(SupportedType.string, Data(text.utf8)), .init(SupportedType.html, data)]; expectedExtension = "html"; expected = data
        case "php-explanation", "template-sql", "log-sql", "invalid-json":
            let text = switch kind {
            case "php-explanation": "<?php is the opening tag used by PHP. This paragraph explains the syntax."
            case "template-sql": "let query = `\r\nSELECT id FROM users;\r\n`;"
            case "log-sql": "2026-10-19 INFO SELECT id FROM users;"
            default: "{\"name\": \"Alice\" \"tags\": [1, 2]}"
            }
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "txt"; expected = Data(text.utf8)
        case "go-crlf":
            let text = "func greet(name string) {\r\n    print(name)\r\n}\r\n"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "go"; expected = Data(text.utf8)
        case "unicode-sql-pre":
            let text = "SELECT 名称, emoji\r\nFROM users;\r\n"
            representations = [.init(SupportedType.string, Data(text.utf8)), .init(SupportedType.html, Data("<pre>SELECT 名称, emoji<br>FROM users;</pre>".utf8))]
            expectedExtension = "sql"; expected = Data(text.utf8)
        default:
            let text = "明天下午三点开会，记得带上电脑。"
            representations = [.init(SupportedType.string, Data(text.utf8))]; expectedExtension = "txt"; expected = Data(text.utf8)
        }
        let id = try await ingest(store, representations)
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "test", register: { _ in })
        let promise = try promise(try #require(writers.first))
        let name = promise.1.filePromiseProvider(promise.0, fileNameForType: promise.0.fileType)
        #expect(name.hasSuffix("." + expectedExtension), "\(kind): \(name)")
        // 原样导出声明原表示类型，纯文本导出声明扩展名对应的UTType。
        let expectedType = representations.first { $0.type != SupportedType.string && $0.data == expected }?.type ?? UTType(filenameExtension: expectedExtension)?.identifier
        #expect(promise.0.fileType == expectedType, "\(kind): \(promise.0.fileType)")
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func titlesAndMultiDragNumbering() async throws {
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func existingFileIsNeverOverwritten() async throws {
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
        for _ in 0..<30 { let begin = ContinuousClock.now; _ = await SyntaxHighlighter.shared.guess(of: json); let value = ContinuousClock.now - begin; languages.append(Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15) }
        func p(_ values: [Double], _ q: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1)] }
        let report: [String: Any] = ["bytes": json.utf8.count, "dragStartMs": starts, "writeMs": writes,
                                     "dragStartP50": p(starts, 0.5), "dragStartP95": p(starts, 0.95), "writeP50": p(writes, 0.5), "writeP95": p(writes, 0.95), "languageMs": languages, "languageP50": p(languages, 0.5), "languageP95": p(languages, 0.95)]
        if let output = ProcessInfo.processInfo.environment["LOCALCLIP_EXPORT_PERF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        #expect(p(writes, 0.95) < 100)
    }
}
