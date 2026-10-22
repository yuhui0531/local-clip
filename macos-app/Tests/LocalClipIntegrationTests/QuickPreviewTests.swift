// 统一预览：文件内容分类、扩展名语言、编辑/预览着色范围与缩略图取消竞态；窗口类用例需显式交互授权，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct QuickPreviewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    /// 程序文件直接显示正文并带语言；图片/二进制交给系统预览；缺失与无权限给出明确原因，不静默失败。
    @Test func classifiesFileContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("locked.py").path); try? FileManager.default.removeItem(at: directory) }
        let samples = ["a.json": ("{\"a\": 1}\n", "json"), "b.xml": ("<a/>\n", "xml"), "c.yaml": ("a: 1\n", "yaml"), "d.py": ("print(1)\n", "python"),
                       "E.java": ("class E {}\n", "java"), "f.js": ("let a = 1\n", "javascript"), "g.ts": ("const a: number = 1\n", "typescript"),
                       "h.sql": ("select 1;\n", "sql"), "i.sh": ("echo hi\n", "bash")]
        for (name, (body, language)) in samples {
            let url = directory.appendingPathComponent(name); try Data(body.utf8).write(to: url)
            #expect(FilePreviewContent.classify(url) == .text(body, language: language, truncated: false), "\(name)")
        }
        let unknown = directory.appendingPathComponent("notes.custom"); try Data("plain".utf8).write(to: unknown)
        #expect(FilePreviewContent.classify(unknown) == .text("plain", language: nil, truncated: false))
        let image = directory.appendingPathComponent("photo.png"); try ImageFixtures.image(width: 8, height: 8).write(to: image)
        #expect(FilePreviewContent.classify(image) == .quickLook)
        let binary = directory.appendingPathComponent("data.bin"); try Data([0, 1, 2, 0]).write(to: binary)
        #expect(FilePreviewContent.classify(binary) == .quickLook)
        #expect(FilePreviewContent.classify(directory) == .quickLook)
        // SVG显示图形、PDF显示页面（即使内容全为ASCII、无扩展名），不当成源码。
        let svg = directory.appendingPathComponent("logo.svg"); try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: svg)
        #expect(FilePreviewContent.classify(svg) == .quickLook)
        let pdf = directory.appendingPathComponent("report")
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, [kCGPDFContextCreator: "LocalClip"] as CFDictionary))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        #expect(FilePreviewContent.classify(pdf) == .quickLook)
        guard case .failure(let missing) = FilePreviewContent.classify(directory.appendingPathComponent("gone.py")) else { Issue.record("缺失文件应给出原因"); return }
        #expect(missing.contains("不存在"))
        let locked = directory.appendingPathComponent("locked.py"); try Data("x = 1".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        guard case .failure(let denied) = FilePreviewContent.classify(locked) else { Issue.record("无权限文件应给出原因"); return }
        #expect(denied.contains("权限"))
        let large = directory.appendingPathComponent("big.ts")
        try Data(String(repeating: "let a = 1\n", count: FilePreviewContent.textLimit / 10 + 10).utf8).write(to: large)
        guard case .text(let text, "typescript", true) = FilePreviewContent.classify(large) else { Issue.record("大文件应截断显示正文"); return }
        #expect(text.utf8.count <= FilePreviewContent.textLimit)
    }

    /// 扩展名提示覆盖需求中的常见语言，未知扩展名交给内容判定。
    @Test func fileLanguageHints() {
        let pairs = ["a.json": "json", "a.xml": "xml", "a.yml": "yaml", "a.yaml": "yaml", "a.py": "python", "A.Java": "java", "a.mjs": "javascript",
                     "a.tsx": "typescript", "a.sql": "sql", "a.zsh": "bash", "Makefile": "makefile", "Dockerfile": "bash"]
        for (name, language) in pairs { #expect(SyntaxHighlighter.language(forFile: URL(fileURLWithPath: "/tmp/" + name)) == language, "\(name)") }
        #expect(SyntaxHighlighter.language(forFile: URL(fileURLWithPath: "/tmp/a.unknownext")) == nil)
    }

    /// 文件预览与编辑器的着色范围超过卡片默认上限，后段代码同样上色；默认调用保持原上限。
    @Test func extendedHighlightLimit() async throws {
        let line = "const value = \"text\"; // note\n"
        let text = String(repeating: line, count: SyntaxHighlighter.characterLimit / line.utf16.count * 3)
        let engine = SyntaxHighlighter()
        let bounded = try #require(await engine.highlight(text, languageHint: "javascript"))
        let extended = try #require(await engine.highlight(text, languageHint: "javascript", limit: QuickPreview.highlightLimit))
        #expect(bounded.analyzedUTF16Count <= SyntaxHighlighter.characterLimit)
        #expect(extended.analyzedUTF16Count == text.utf16.count)
        #expect(extended.spans.contains { $0.range.location > SyntaxHighlighter.characterLimit && $0.style.contains("string") })
    }

    /// 编辑器着色只改颜色：文字、撤销栈与纯文本复制不受影响。
    @Test func editorHighlightKeepsTextAndUndo() async throws {
        let scroll = CodeTextView.make(text: "", editable: true)
        let view = try #require(scroll.documentView as? NSTextView)
        let undo = UndoManager(); undo.groupsByEvent = false
        let window = UndoWindow(undo); window.contentView = scroll
        undo.beginUndoGrouping(); view.insertText("let a = \"x\"", replacementRange: NSRange(location: 0, length: 0)); undo.endUndoGrouping()
        let highlight = try #require(await SyntaxHighlighter().highlight(view.string, languageHint: "javascript"))
        CodeTextView.apply(highlight, to: view)
        #expect(view.string == "let a = \"x\"")
        #expect(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != NSColor.labelColor)
        #expect(undo.canUndo)
        // 委托方法签名必须与AppKit选择器一致，否则新输入会静默继承关键字颜色。
        let coordinator = HighlightingTextEditor.Coordinator(HighlightingTextEditor(text: .constant(""), monospaced: true, editable: true, focused: false))
        #expect(coordinator.responds(to: #selector(NSTextViewDelegate.textView(_:shouldChangeTypingAttributes:toAttributes:))))
        undo.undo()
        #expect(view.string.isEmpty)
        window.contentView = nil
    }
    private final class UndoWindow: NSWindow {
        let manager: UndoManager
        init(_ manager: UndoManager) { self.manager = manager; super.init(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true) }
        override var undoManager: UndoManager? { manager }
    }

    /// 离屏取消晚于重新可见的新请求时，仍在等待的调用方得到缩略图而不是“无法生成预览”。
    @Test func staleCancelDoesNotFailWaitingThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let png = try ImageFixtures.image(width: 1600, height: 1200)
        for round in 0..<8 {
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, png + Data([UInt8(round)]))])])), at: SystemClock().now()) else { Issue.record("插入失败"); return }
            let derived = DerivedContentService(store: store)
            async let result = derived.thumbnail(id: id)
            await Task.yield()
            await derived.cancel(id: id)
            guard case .image = await result else { Issue.record("第\(round)轮被过期取消判为失败"); return }
        }
    }

    /// 需显式交互授权：图片与文件经Space打开独立预览窗口（不弹详情），再按Space关闭；缺失文件显示原因而非静默。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction")) func spaceOpensPreviewWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let code = root.appendingPathComponent("main.py"); try Data("print('hi')\n".utf8).write(to: code)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 40, height: 30))])])), at: SystemClock().now())
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(code.absoluteString.utf8))])])), at: SystemClock().now() + 1)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await wait { !model.historyBusy && model.items.count == 2 }
        // “预览”菜单与Space同一入口。
        model.preview(id: model.items[0].id); try await wait { model.previewWindowVisible }
        #expect(model.previewFollowsSelection); model.toggleQuickLook(); #expect(!model.previewWindowVisible)
        for item in model.items {
            model.select(item.id); model.toggleQuickLook()
            try await wait { model.previewWindowVisible }
            #expect(!model.showingDetail && model.message.isEmpty)
            model.toggleQuickLook()
            #expect(!model.previewWindowVisible)
        }
        model.select(model.items[0].id); model.toggleQuickLook(); try await wait { model.previewWindowVisible }
        #expect(!model.handleEscape() && !model.previewWindowVisible)
        model.toggleQuickLook(); try await wait { model.previewWindowVisible }
        model.panelVisibilityChanged(false)
        #expect(!model.previewWindowVisible)
    }
}
