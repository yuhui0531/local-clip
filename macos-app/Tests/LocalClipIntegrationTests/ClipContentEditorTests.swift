// 临时数据库和假系统客户端验证草稿、保存及输出闭环，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct ClipContentEditorTests {
    /// 等待模型真正完成异步操作，超时明确失败。
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(4)
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    /// 所有系统输出都进入fake，不读取或修改用户剪贴板，也不激活任何应用。
    private func setup(_ texts: [String]) async throws -> (URL, HistoryStore, HistoryViewModel, RawBoard, FakeApplications) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root, extractor: ContentDecoder.extract)
        for text in texts { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: SystemClock().now()) }
        let raw = RawBoard(), apps = FakeApplications(), board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: apps, store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        try await wait { model.items.count == texts.count && !model.historyBusy }
        return (root, store, model, raw, apps)
    }
    /// 取消不写库；失焦隐藏、筛选变化和隐私隐藏都不丢弃草稿或改变多选。
    @Test func cancelAndHidePreserveDraftAndOriginal() async throws {
        let (root, store, model, raw, _) = try await setup(["original", "other"])
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectAllResults(); let selection = model.selectedIDs
        model.editSelectedContent()
        #expect(model.contentEditor == nil)
        let id = try #require(model.items.first { $0.preview == "original" }?.id)
        model.beginContentEdit(id)
        try await wait { model.contentEditor != nil }
        model.requestCancelContentEdit()
        #expect(model.contentEditor == nil)
        model.beginContentEdit(id); try await wait { model.contentEditor != nil }
        let editor = try #require(model.contentEditor); editor.text = "unsaved draft"
        model.requestCancelContentEdit()
        #expect(editor.confirmingDiscard && model.contentEditor === editor)
        editor.confirmingDiscard = false
        model.panelVisibilityChanged(false)
        #expect(!model.contentEditorPresented)
        model.panelVisibilityChanged(true)
        #expect(model.contentEditorPresented)
        #expect(model.contentEditor === editor && editor.text == "unsaved draft")
        #expect(model.selectedIDs == selection)
        model.query = "other"; model.searchChanged(debounce: false)
        try await wait { model.items.count == 1 && !model.historyBusy }
        #expect(model.contentEditor === editor && editor.text == "unsaved draft")
        model.updateSettings { $0.hideContents = true }
        try await wait { model.settings.hideContents }
        #expect(!model.contentEditorPresented)
        #expect(model.contentEditor === editor && editor.text == "unsaved draft")
        model.discardContentEdit()
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).plainText == "original")
        #expect(raw.count == 1 && model.contentEditor == nil)
    }

    /// 完整长文保存后就地刷新；原格式复制和直接粘贴都读取修正内容，使用假目标验证。
    @Test func saveRefreshesPreviewSearchAndOutput() async throws {
        let original = String(repeating: "long original ", count: 20) + "old-tail"
        let revised = String(repeating: "long original ", count: 20) + "修正后的尾部"
        let (root, store, model, raw, apps) = try await setup([original])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first?.id)
        model.select(id); model.editSelectedContent(); try await wait { model.contentEditor != nil }
        let editor = try #require(model.contentEditor)
        #expect(editor.text == original && editor.text.count > 180)
        #expect(!editor.canSave)
        editor.text = " \n "; model.saveContentEdit()
        #expect(!editor.canSave && !editor.saving && model.contentEditor === editor)
        editor.text = revised; model.saveContentEdit()
        try await wait { model.contentEditor == nil && !model.historyBusy && model.items.first?.contentFingerprint != editor.fingerprint }
        #expect(model.items.first?.preview == String(revised.prefix(180)))
        #expect(try await store.textCharacterCount(id: id, at: SystemClock().now()) == revised.count)
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).plainText == revised)
        model.select(id); model.perform(.original, action: .copy)
        try await wait { raw.items.first?[SupportedType.string] == Data(revised.utf8) }
        model.target = apps.remembered; model.perform(.original, action: .directPaste)
        try await wait { apps.events == 1 }
        #expect(raw.items.first?[SupportedType.string] == Data(revised.utf8))
        model.query = "修正后的尾部"; model.searchChanged(debounce: false)
        try await wait { !model.historyBusy && model.items.map(\.id) == [id] }
        model.query = "old-tail"; model.searchChanged(debounce: false)
        try await wait { !model.historyBusy && model.items.isEmpty }
    }

    /// 详情解码在途或已发布时修改同一ID，最终都展示最新正文。
    @Test func detailReloadsWhenContentChanges() async throws {
        let (root, store, model, _, _) = try await setup(["old detail"])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first?.id)
        model.select(id); model.showingDetail = true; model.detailVisibilityChanged()
        let old = try await store.loadPayload(id: id, at: SystemClock().now())
        try await store.updateText(id: id, text: "current detail", expectedFingerprint: old.fingerprint)
        try await wait { model.detail?.payload.plainText == "current detail" }
        let current = try await store.loadPayload(id: id, at: SystemClock().now())
        try await store.updateText(id: id, text: "latest detail", expectedFingerprint: current.fingerprint)
        try await wait { model.detail?.payload.plainText == "latest detail" }
        #expect(model.richPreview?.string == "latest detail")
    }

    /// 重复、内容冲突与删除导致保存失败时保留草稿；不会静默覆盖其他记录。
    @Test func failedSavesKeepDraft() async throws {
        let (root, store, model, _, _) = try await setup(["one", "two"])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first { $0.preview == "one" }?.id)
        model.beginContentEdit(id); try await wait { model.contentEditor != nil }
        let editor = try #require(model.contentEditor)
        editor.text = "two"; model.saveContentEdit()
        try await wait { !editor.saving && !editor.error.isEmpty }
        #expect(model.contentEditor === editor && editor.text == "two")
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).plainText == "one")
        try await store.updateText(id: id, text: "external correction", expectedFingerprint: editor.fingerprint)
        editor.text = "my draft"; model.saveContentEdit()
        try await wait { !editor.saving && editor.error == ContentEditError.contentChanged.message }
        #expect(model.contentEditor === editor && editor.text == "my draft")
        let deletion = try await store.preview(.delete([id])); _ = try await store.apply(deletion.token)
        model.saveContentEdit()
        try await wait { !editor.saving && editor.error.contains("记录已删除") }
        #expect(model.contentEditor === editor && editor.text == "my draft")
    }

    /// 富文本有明确转纯文本说明；嵌入图片、文件引用和混合内容整体拒绝。
    @Test func richTextWarningAndAttachmentSafety() async throws {
        let (root, store, model, _, _) = try await setup([])
        defer { try? FileManager.default.removeItem(at: root) }
        let rich = ClipboardPayload([.init([.init(SupportedType.html, Data("<b>Original bold</b>".utf8))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: rich), at: SystemClock().now()) else { Issue.record("未插入富文本"); return }
        try await wait { model.items.contains { $0.id == id } }
        model.beginContentEdit(id); try await wait { model.contentEditor != nil }
        let editor = try #require(model.contentEditor)
        #expect(editor.text == "Original bold" && editor.warning != nil)
        model.discardContentEdit()
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).canonicalData == rich.canonicalData)
        for representation in [Representation(SupportedType.html, Data("<p>text<img src='local.png'></p>".utf8)), .init(SupportedType.rtf, Data(#"{\rtf1 text {\pict image}}"#.utf8)), .init(SupportedType.png, Data([1])), .init(SupportedType.fileURL, Data("file:///tmp/file.txt".utf8))] {
            let payload = ClipboardPayload([.init([.init(SupportedType.string, Data("text".utf8)), representation], plainText: "text")])
            #expect(payload.editableText == nil)
        }
        let multiple = ClipboardPayload([.init([.init(SupportedType.string, Data("first".utf8))], plainText: "first"), .init([.init(SupportedType.string, Data("second".utf8))], plainText: "second")])
        #expect(multiple.editableText == "first\nsecond" && multiple.textEditWarning != nil)
    }

    /// 隐藏窗口内检查原生编辑控件与像素，不展示窗口，不使用真实剪贴板。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func hiddenNativeEditorRendering() async throws {
        _ = NSApplication.shared
        let (root, store, model, _, _) = try await setup(["第一行内容\nSecond line: https://example.com\n可在此修正历史记录。"])
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try await store.detail(id: model.items[0].id, at: SystemClock().now())
        let state = ClipContentEditorState(detail: detail, text: try #require(detail.payload.editableText))
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 560, height: 390), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        // 明暗外观都由生产组件实际渲染，输出证据仅用于目视检查。
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: ClipContentEditor(state: state, save: {}, cancel: {}, discard: {}).environment(\.colorScheme, scheme))
            host.sizingOptions = []; window.contentView = host; host.frame = .init(x: 0, y: 0, width: 560, height: 390)
            host.layoutSubtreeIfNeeded()
            func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
            try await wait { !editors(host).isEmpty }
            let text = try #require(editors(host).first)
            #expect(text.isEditable && text.string == state.text && !window.isVisible)
            state.text += "\n已修正的内容"
            try await wait { text.string == state.text }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            if let path = ProcessInfo.processInfo.environment["LOCALCLIP_EDIT_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("editor-\(name).png"))
            }
        }
    }
}
