// 先验证独立开关、真实文件与高亮边界；不把fake事件当实际接收，by AI.Coding。
import Foundation
import AppKit
import Darwin
import Testing
import LocalClipCore
@testable import LocalClipMac

struct CodeFeaturesTests {
    @Test func defaultOffAndPersistence() async throws {
        var settings = SettingsSnapshot()
        #expect(!settings.smartCodeFilePaste)
        let original = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SettingsSnapshot.self, from: original).smartCodeFilePaste == false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        settings.smartCodeFilePaste = true
        _ = try await store.updateCaptureSettings(settings)
        let reopened = try HistoryStore(location: root)
        #expect(try await reopened.settings().smartCodeFilePaste)
        settings = try await reopened.settings(); settings.smartCodeFilePaste = false
        _ = try await reopened.updateCaptureSettings(settings)
        #expect(try await store.settings().smartCodeFilePaste == false)
    }
    @Test func strictFilesAndOrdering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.py"), second = root.appendingPathComponent("b.json")
        let a = "def greet():\r\n\treturn '中文'\r\n", b = "{\n  \"x\": 1\n}\n"
        try Data(a.utf8).write(to: first); try Data(b.utf8).write(to: second)
        #expect(try CodeFileReader.read([first, second]) == a + "\n" + b)
        try Data([0xff, 0x00, 0x01]).write(to: second)
        #expect(throws: (any Error).self) { try CodeFileReader.read([first, second]) }
        #expect(throws: (any Error).self) { try CodeFileReader.read([root]) }
    }
    @Test func commonSyntaxAlwaysOn() async {
        let samples = ["json": "{\"name\": \"中文\", \"count\": 42, \"ok\": true}",
            "java": "public class Example { public static void main(String[] args) { System.out.println(\"Hi\"); } }",
            "python": "def greet(name):\n    # comment\n    return f'Hello {name}'\n",
            "javascript": "function greet(name) { const n = 42; return `Hi ${name}`; }",
            "typescript": "interface User { name: string; }\nconst user: User = { name: 'Hi' };",
            "yaml": "name: localclip\nitems:\n  - enabled: true\n",
            "xml": "<?xml version=\"1.0\"?><root id=\"1\">中文</root>",
            "css": ".card { color: #fff; margin: 10px; }",
            "bash": "#!/bin/bash\nfor f in *.json; do echo \"$f\"; done\n"]
        for (language, text) in samples {
            let result = await SyntaxHighlighter.shared.highlight(text, languageHint: language)
            #expect(result != nil, "\(language)")
            #expect(result?.spans.isEmpty == false, "\(language)")
            #expect(result?.analyzedUTF16Count == text.utf16.count)
            #expect(await SyntaxHighlighter.shared.highlight(text) != nil, "auto \(language)")
        }
        #expect(await SyntaxHighlighter.shared.highlight("<!DOCTYPE html><html><body><h1 class=\"title\">Hello</h1></body></html>") != nil)
        #expect(await SyntaxHighlighter.shared.highlight("Please call me tomorrow morning.") == nil)
    }
}

@MainActor struct SmartPasteTests {
    /// 面板抢走key焦点时未知、原编辑器焦点恢复后可识别，仍须转换整份文件，by AI.Coding。
    @Test func editorIdentifiedAfterFocusReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.smartCodeFilePaste = true
        let store = try HistoryStore(location: root.appendingPathComponent("store"), initialSettings: settings)
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications()
        let capture = CaptureCoordinator(board: board, store: store), paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        for (ext, text) in [("swift", "import Foundation\r\nlet message = \"中文\"\r\n"), ("json", "{\n  \"message\": \"中文\"\n}\n")] {
            let file = root.appendingPathComponent("fixture." + ext); try Data(text.utf8).write(to: file)
            let policy = try await store.settings()
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])]), revision: policy.revision), at: SystemClock().now()) else { Issue.record("fixture"); return }
            apps.targetKind = .unknown; apps.current = nil
            apps.onRestore = { apps.targetKind = .text }
            #expect(await paste.perform(.init(ids: [id], action: .directPaste, target: apps.remembered)) == .commandSent)
            #expect(raw.items.first?[SupportedType.string] == Data(text.utf8))
            #expect(raw.items.first?[SupportedType.fileURL] == nil)
            settings = try await store.settings(); settings.smartCodeFilePaste = false; _ = try await store.updateCaptureSettings(settings)
            apps.targetKind = .unknown; apps.current = nil
            #expect(await paste.perform(.init(ids: [id], action: .directPaste, target: apps.remembered)) == .commandSent)
            #expect(raw.items.first?[SupportedType.fileURL] == Data(file.absoluteString.utf8))
            #expect(try Data(contentsOf: file) == Data(text.utf8))
            settings = try await store.settings(); settings.smartCodeFilePaste = true; _ = try await store.updateCaptureSettings(settings)
        }
        #expect(apps.events == 4)
    }
    @Test func enabledOffAndSafeTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.py"), text = "def main():\r\n    return '中文'\r\n"
        try Data(text.utf8).write(to: file)
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications()
        apps.targetKind = .text
        let store = try HistoryStore(location: root.appendingPathComponent("store"))
        let original = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: original), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let capture = CaptureCoordinator(board: board, store: store), paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let request = PasteRequest(ids: [id], action: .directPaste, target: apps.remembered)
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] == Data(file.absoluteString.utf8))
        #expect(await paste.perform(.init(ids: [id], format: .plainText, action: .copy, target: apps.remembered)) == .copied)
        #expect(raw.items.first?[SupportedType.string] == Data(file.path.utf8))
        var settings = try await store.settings(); settings.smartCodeFilePaste = true
        _ = try await store.updateCaptureSettings(settings)
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.string] == Data(text.utf8))
        #expect(raw.items.first?[SupportedType.fileURL] == nil)
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).items.map(\.representations) == original.items.map(\.representations))
        #expect(await paste.perform(.init(ids: [id], format: .plainText, action: .copy, target: apps.remembered)) == .copied)
        #expect(raw.items.first?[SupportedType.string] == Data(text.utf8))
        apps.targetKind = .files
        #expect(await paste.perform(.init(ids: [id], format: .plainText, action: .copy, target: apps.remembered)) == .copied)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        apps.targetKind = .unknown
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        apps.targetKind = .text
        settings = try await store.settings(); settings.smartCodeFilePaste = false
        _ = try await store.updateCaptureSettings(settings)
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        #expect(try Data(contentsOf: file) == Data(text.utf8))
    }
}

struct CodeFileBoundaryTests {
    @Test func BOMsBinaryLargeAndMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("utf.ts"), text = "const x: string = '中文😀';\r\n\t// end\n"
        for (encoding, bom) in [(String.Encoding.utf8,[UInt8](arrayLiteral: 0xef,0xbb,0xbf)), (.utf16LittleEndian,[0xff,0xfe]), (.utf16BigEndian,[0xfe,0xff]), (.utf32LittleEndian,[0xff,0xfe,0,0]), (.utf32BigEndian,[0,0,0xfe,0xff])] {
            try (Data(bom) + text.data(using: encoding)!).write(to: file)
            #expect(try CodeFileReader.read([file]) == text)
        }
        try Data([0xff,0xfe,0x00,0xd8]).write(to: file)
        #expect(throws: (any Error).self) { try CodeFileReader.read([file]) }
        try Data("const x = 0;\u{0}".utf8).write(to: file)
        #expect(throws: CodeFileReadError.binaryOrEncoding) { try CodeFileReader.read([file]) }
        try Data(repeating: 65, count: CodeFileReader.perFileLimit + 1).write(to: file)
        #expect(throws: CodeFileReadError.tooLarge) { try CodeFileReader.read([file]) }
        #expect(throws: CodeFileReadError.unavailable) { try CodeFileReader.read([root.appendingPathComponent("absent.py")]) }
        let link = root.appendingPathComponent("link.ts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: CodeFileReadError.unavailable) { try CodeFileReader.read([link]) }
        let unknown = root.appendingPathComponent("data.bin"); try Data("plain".utf8).write(to: unknown)
        #expect(throws: CodeFileReadError.unsupported) { try CodeFileReader.read([unknown]) }
    }
    @Test func formatsAndNonregularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "// exact fixture\r\n\t中文😀\n"
        for ext in ["json", "java", "py", "js", "ts", "yaml", "yml", "xml", "html", "css", "sh", "JSON"] {
            let file = root.appendingPathComponent("fixture." + ext); try Data(text.utf8).write(to: file)
            #expect(try CodeFileReader.read([file]) == text)
        }
        let pipe = root.appendingPathComponent("pipe.py")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: CodeFileReadError.unavailable) { try CodeFileReader.read([pipe]) }
    }
    @Test func identitiesAndGroupQuota() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.json"); try Data("{}".utf8).write(to: file)
        let snapshot = try CodeFileReader.snapshot([file]); #expect(snapshot.isCurrent())
        try Data("{\"a\": 1}".utf8).write(to: file); #expect(!snapshot.isCurrent())
        try Data(repeating: 65, count: CodeFileReader.perFileLimit).write(to: file)
        #expect(throws: CodeFileReadError.tooLarge) { try CodeFileReader.read([file,file,file]) }
    }
    @Test func escapingUnicodeAndBounds() async {
        let text = "{\"emoji\": \"😀中文</span><script>danger()</script>&\", \"n\": 42}"
        let result = await SyntaxHighlighter.shared.highlight(text, languageHint: "json")
        #expect(result != nil)
        for span in result?.spans ?? [] { #expect(NSMaxRange(span.range) <= text.utf16.count); #expect(Range(span.range, in: text) != nil) }
        let crlf = "def hello():\r\n\treturn '中文😀'\r\n"
        #expect(await SyntaxHighlighter.shared.highlight(crlf, languageHint: "python")?.analyzedUTF16Count == crlf.utf16.count)
        let combining = "def f():\n    return 'a" + String(repeating: "\u{301}", count: 50_000) + "'"
        #expect(await SyntaxHighlighter.shared.highlight(combining, languageHint: "python")?.analyzedUTF16Count == SyntaxHighlighter.characterLimit)
        let huge = "def f():\n    return 42\n" + String(repeating: "# abc\n", count: 100_000)
        #expect(await SyntaxHighlighter.shared.highlight(huge)?.analyzedUTF16Count == SyntaxHighlighter.characterLimit)
    }
}

@MainActor struct SmartPasteBoundaryTests {
    @Test func mixedFilesAndFailuresPreserveOriginalSet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.js"), second = root.appendingPathComponent("second.json")
        try Data("const first = 1;\n".utf8).write(to: first); try Data("{\"second\": 2}".utf8).write(to: second)
        var settings = SettingsSnapshot(); settings.smartCodeFilePaste = true
        let store = try HistoryStore(location: root.appendingPathComponent("store"), initialSettings: settings)
        let payload = ClipboardPayload([first,second].map { .init([.init(SupportedType.fileURL, Data($0.absoluteString.utf8))]) })
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications(); apps.targetKind = .text
        let capture = CaptureCoordinator(board: board, store: store), paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let request = PasteRequest(ids: [id], action: .copy, target: apps.remembered)
        #expect(await paste.perform(request) == .copied)
        #expect(raw.items.first?[SupportedType.string] == Data("const first = 1;\n\n{\"second\": 2}".utf8))
        try Data([0x00,0x01]).write(to: second)
        #expect(await paste.perform(request) == .copied)
        #expect(raw.items.count == 2); #expect(raw.items[0][SupportedType.fileURL] == Data(first.absoluteString.utf8)); #expect(raw.items[1][SupportedType.fileURL] == Data(second.absoluteString.utf8))
        try FileManager.default.removeItem(at: second)
        #expect(await paste.perform(request) == .copied); #expect(raw.items.count == 2)
        apps.permitted = false
        #expect(await paste.perform(request) == .copied); #expect(raw.items[0][SupportedType.fileURL] != nil)
        #expect(await paste.perform(.init(ids: [id], action: .copy)) == .copied)
        #expect(raw.items.count == 2)
    }
    @Test func changesWhileRestoringFocusNeverPasteStaleText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.ts"); try Data("const x: number = 1;\n".utf8).write(to: file)
        var settings = SettingsSnapshot(); settings.smartCodeFilePaste = true
        let store = try HistoryStore(location: root.appendingPathComponent("store"), initialSettings: settings)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications(); apps.targetKind = .text
        let capture = CaptureCoordinator(board: board, store: store), paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let request = PasteRequest(ids: [id], action: .directPaste, target: apps.remembered)
        apps.onActivate = { Task { var value = try await store.settings(); value.smartCodeFilePaste = false; _ = try await store.updateCaptureSettings(value) } }
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        settings = try await store.settings(); settings.smartCodeFilePaste = true; _ = try await store.updateCaptureSettings(settings)
        apps.current = nil
        apps.onActivate = { apps.targetKind = .unknown }
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        apps.current = nil; apps.targetKind = .text
        apps.onActivate = { try? Data("const replaced = true;".utf8).write(to: file) }
        #expect(await paste.perform(request) == .commandSent)
        #expect(raw.items.first?[SupportedType.fileURL] != nil)
        apps.current = nil; apps.onActivate = { raw.user("USER-NEW-COPY") }
        #expect(await paste.perform(request) == .failed("剪贴板已变化，请重新选择"))
        #expect(apps.events == 3); #expect(raw.items.first?[SupportedType.string] == Data("USER-NEW-COPY".utf8))
    }
}

@MainActor struct CodeNamedPasteboardTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func actualFileAndTextTypesBothStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("named.json"), text = "{\r\n  \"中文\": true\r\n}\r\n"
        try Data(text.utf8).write(to: file)
        let native = NSPasteboard(name: .init("local.localclip.code-test." + UUID().uuidString)); defer { native.releaseGlobally() }
        let input = NSPasteboardItem(); input.setString(file.absoluteString, forType: .fileURL)
        native.clearContents(); #expect(native.writeObjects([input]))
        let board = MacPasteboardClient(access: NativePasteboardAccess(native))
        guard case .snapshot(let snapshot) = board.capture(after: -1, policy: .init()) else { Issue.record("named capture"); return }
        let store = try HistoryStore(location: root.appendingPathComponent("store"))
        guard case .inserted(let id) = try await store.ingest(ContentDecoder.decode(snapshot), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let apps = FakeApplications(); apps.targetKind = .text
        let capture = CaptureCoordinator(board: board, store: store), paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        let request = PasteRequest(ids: [id], action: .copy, target: apps.remembered)
        #expect(await paste.perform(request) == .copied)
        #expect(native.pasteboardItems?.first?.string(forType: .fileURL) == file.absoluteString)
        var settings = try await store.settings(); settings.smartCodeFilePaste = true; _ = try await store.updateCaptureSettings(settings)
        #expect(await paste.perform(request) == .copied)
        #expect(native.string(forType: .string) == text); #expect(native.pasteboardItems?.first?.data(forType: .fileURL) == nil)
        apps.targetKind = .files
        #expect(await paste.perform(request) == .copied)
        #expect(native.pasteboardItems?.first?.string(forType: .fileURL) == file.absoluteString)
        settings = try await store.settings(); settings.smartCodeFilePaste = false; _ = try await store.updateCaptureSettings(settings)
        apps.targetKind = .text
        #expect(await paste.perform(request) == .copied)
        #expect(native.pasteboardItems?.first?.string(forType: .fileURL) == file.absoluteString)
    }
}

struct CodePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_CODE_PERF"] == "1"))
    func boundedHighlightAndFileRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var samples: [[String: Any]] = []
        func ms(_ start: ContinuousClock.Instant) -> Double { let d = ContinuousClock.now - start; return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let engine = SyntaxHighlighter(), cold = ContinuousClock.now
        #expect(await engine.highlight("{\"name\": \"LocalClip\", \"count\": 42}") != nil)
        samples.append(["stage": "engine_cold", "ms": ms(cold)])
        for index in 0..<30 {
            let text = "def f_\(index)(x):\n    # fixture\n    return x + 42\n" + String(repeating: "# comment\n", count: 60)
            var start = ContinuousClock.now; #expect(await engine.highlight(text) != nil)
            samples.append(["stage": "highlight_uncached_700chars", "sample": index, "ms": ms(start)])
            start = ContinuousClock.now; #expect(await engine.highlight(text) != nil)
            samples.append(["stage": "highlight_cached", "sample": index, "ms": ms(start)])
        }
        let file = root.appendingPathComponent("four-mib.js")
        try Data(repeating: 65, count: CodeFileReader.perFileLimit).write(to: file)
        for index in 0..<10 {
            let start = ContinuousClock.now
            let value = try await Task.detached { try CodeFileReader.read([file]) }.value
            #expect(value.utf8.count == CodeFileReader.perFileLimit)
            samples.append(["stage": "read_4MiB_utf8", "sample": index, "ms": ms(start)])
        }
        if let path = ProcessInfo.processInfo.environment["LOCALCLIP_CODE_PERF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}

@MainActor struct CodeTargetTests {
    @Test func textRolesEditorsAndUnknownTargets() {
        for role in ["AXTextArea", "AXTextField", "AXSearchField"] {
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: nil, selectedRangeSettable: false) == .text)
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: false, selectedRangeSettable: true) == .unknown)
        }
        #expect(MacApplicationClient.classifyTextMetadata(role: "AXTextField", subrole: "AXSecureTextField", editable: true, selectedRangeSettable: true) == .unknown)
        for role in ["AXGroup", "AXDocument", "AXWebArea"] {
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: true, selectedRangeSettable: false) == .text)
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: nil, selectedRangeSettable: true) == .text)
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: nil, selectedRangeSettable: false) == .unknown)
        }
        for role in ["AXMenuItem", "AXOutline", "AXImage", "AXButton", ""] {
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: true, selectedRangeSettable: true) == .unknown)
            #expect(MacApplicationClient.classifyTextMetadata(role: role, subrole: "", editable: nil, selectedRangeSettable: false, bundleID: "dev.zed.Zed") == .unknown)
        }
        #expect(MacApplicationClient.classifyTextMetadata(role: "AXWindow", subrole: "AXStandardWindow", editable: nil, selectedRangeSettable: false, bundleID: "dev.zed.Zed") == .text)
        #expect(MacApplicationClient.classifyTextMetadata(role: "AXWindow", subrole: "", editable: nil, selectedRangeSettable: false, bundleID: "com.apple.finder") == .unknown)
        #expect(MacApplicationClient.classifyTextMetadata(role: "AXWindow", subrole: "", editable: nil, selectedRangeSettable: false, bundleID: "local.unknown") == .unknown)
    }
}
