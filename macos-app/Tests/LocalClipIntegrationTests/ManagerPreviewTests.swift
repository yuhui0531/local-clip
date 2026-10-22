// 仅使用合成链接及隐藏窗口，验证管理检查器的实际文字排版，by AI.Coding。
import AppKit
import SwiftUI
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

// 替身不展示任何窗口，仍核对真实异步加载、原始图片次序及隐私策略。
@MainActor private final class ManagerPreviewRecorder: ClipPreviewPresenting {
    var isVisible = false
    var presentations = 0
    var values: [QuickPreview.Item] = []
    var excluded = false
    func show(_ values: [QuickPreview.Item], parent: NSWindow?, excludeFromSharing: Bool) {
        self.values = values; presentations += 1; isVisible = true; excluded = excludeFromSharing
    }
    func close() { isVisible = false; values = [] }
    func setSharing(excluded: Bool) { self.excluded = excluded }
}

@MainActor struct ManagerPreviewTests {
    /// 短链接和长链接都必须在检查器可见范围内排出字形，不能只有可聚焦的空白文字框。
    @Test func linkBodyLaysOutVisibleGlyphs() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for type in [SupportedType.string, SupportedType.url] {
            let url = "https://example.invalid/compatible-mode/" + String(repeating: "long-path-", count: 12)
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(type, Data(url.utf8))])])), at: SystemClock().now()) else { throw StoreError.ioFailure }
            let content = try await ClipDetailContent.load(try await store.detail(id: id, at: SystemClock().now()), inspect: false)
            #expect(content.richPreview?.string == url)
            let host = NSHostingView(rootView: ClipDetailPreview(detail: content.detail, image: content.image, text: content.richPreview, highlight: content.highlight, interactive: true, fills: true).frame(width: 360, height: 620))
            host.sizingOptions = []
            let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 360, height: 620), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
            func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
            let text = try #require(textViews(host).first)
            #expect(text.string == url)
            #expect(text.bounds.width > 100 && text.bounds.height > 0)
            let layout = try #require(text.layoutManager), container = try #require(text.textContainer)
            layout.ensureLayout(for: container)
            let glyph = layout.boundingRect(forGlyphRange: layout.glyphRange(for: container), in: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            #expect(!glyph.isEmpty && glyph.intersects(text.visibleRect))
        }
    }
    /// Chrome等来源同时给出有效纯文本和空白富文本时，后者不能遮住真实链接正文。
    @Test func emptyRichRepresentationFallsBackToStoredURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let url = "https://example.invalid/compatible-mode"
        for extra in [Representation(SupportedType.rtf, Data("{\\rtf1\\ansi \\par}".utf8)), Representation(SupportedType.html, Data("<html><head><title>ignored</title></head><body><br></body></html>".utf8)), Representation(SupportedType.html, Data("<meta charset=\"utf-8\"><input value=\"https://example.invalid/compatible-mode\">".utf8))] {
            let payload = ClipboardPayload([.init([.init(SupportedType.string, Data(url.utf8)), extra])])
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else { throw StoreError.ioFailure }
            let content = try await ClipDetailContent.load(try await store.detail(id: id, at: SystemClock().now()), inspect: false)
            #expect(content.richPreview?.string.trimmingCharacters(in: .whitespacesAndNewlines) == url)
        }
    }

    /// 使用完整管理视图层级复现检查器，不用单独固定尺寸的预览代替生产布局。
    @Test func managerInspectorRetainsReadableLinkBody() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let url = "https://example.invalid/compatible-mode"
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(url.utf8))])])), at: SystemClock().now()) else { throw StoreError.ioFailure }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let history = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await history.start(); capture.stop()
        let model = HistoryManagerModel(history: history); model.start()
        defer { model.stop() }
        let until = ContinuousClock.now + .seconds(15)
        while model.rows.isEmpty, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        model.selection = [id]
        while model.detail == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.detail?.richPreview?.string == url)
        let host = NSHostingView(rootView: HistoryManagerView(model: model, history: history)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        let text = try #require(textViews(host).first { $0.string == url })
        let layout = try #require(text.layoutManager), container = try #require(text.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.boundingRect(forGlyphRange: layout.glyphRange(for: container), in: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        #expect(text.bounds.width > 100 && !glyph.isEmpty && glyph.intersects(text.visibleRect))
    }

    /// Space开关、Esc、重复键、文字编辑、换选跟随以及隐藏/关闭取消，共用卡片真实预览条目。
    @Test func managerSpacePreviewFollowsSelectionAndPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        var ids: [ClipID] = []
        for width in [16, 24] {
            let payload = ClipboardPayload([.init([.init(SupportedType.png, try ImageFixtures.image(width: width, height: 12))])])
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else { throw StoreError.ioFailure }
            ids.append(id)
        }
        let file = root.appendingPathComponent("preview.txt"); try Data("synthetic file".utf8).write(to: file)
        guard case .inserted(let fileID) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])), at: SystemClock().now()) else { throw StoreError.ioFailure }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let history = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await history.start(); capture.stop()
        let recorder = ManagerPreviewRecorder(), model = HistoryManagerModel(history: history, preview: recorder)
        model.start(); history.panelVisibilityChanged(false); defer { model.stop() }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(predicate())
        }
        try await wait { model.rows.count == 3 }
        model.selection = [ids[0]]
        #expect(!history.panelVisible) // 管理窗口不依赖底部面板可见。
        #expect(!model.handleKey(code: 49, flags: [], editing: true))
        #expect(!model.handleKey(code: 49, flags: .command, editing: false))
        #expect(!model.handleKey(code: 49, flags: [], editing: false, isRepeat: true))
        #expect(model.handleKey(code: 49, flags: [], editing: false))
        try await wait { recorder.isVisible }
        #expect(model.previewFollowsSelection && recorder.presentations == 1)
        #expect(model.handleKey(code: 49, flags: [], editing: false, isRepeat: true))
        #expect(recorder.isVisible && recorder.presentations == 1)
        model.selection = [ids[1]]
        try await wait { recorder.presentations == 2 }
        guard case .image(let image, _)? = recorder.values.first else { Issue.record("Expected full image preview"); return }
        #expect(image.representations.first?.pixelsWide == 24)
        model.selection = [fileID]
        try await wait { recorder.presentations == 3 }
        guard case .file(let shown)? = recorder.values.first else { Issue.record("Expected shared file preview"); return }
        #expect(shown == file)
        #expect(model.handleKey(code: 53, flags: [], editing: false))
        #expect(!recorder.isVisible && model.selection == [fileID])
        // 再按Space在读取尚未呈现时取消，不能稍后补弹窗口。
        let previous = recorder.presentations
        #expect(model.handleKey(code: 49, flags: [], editing: false))
        #expect(model.handleKey(code: 49, flags: [], editing: false))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!recorder.isVisible && recorder.presentations == previous)
        model.selection = [ids[0]]; #expect(model.toggleQuickLook())
        try await wait { recorder.isVisible }
        history.updateSettings { $0.excludeFromSharing = true }
        try await wait { recorder.excluded }
        history.updateSettings { $0.hideContents = true }
        try await wait { !recorder.isVisible && history.settings.hideContents }
        #expect(!model.toggleQuickLook())
        history.updateSettings { $0.hideContents = false }
        try await wait { !history.settings.hideContents }
        #expect(model.toggleQuickLook()); model.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!recorder.isVisible)
    }

}
