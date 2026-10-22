// 原生事件只发往未显示窗口；剪贴板、目标应用和存储均为隔离边界，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

// 到期只推进测试时钟，不改系统时间，by AI.Coding。
private final class RenameClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = SystemClock().now()
    func now() -> Instant { lock.withLock { value } }
    func advance() { lock.withLock { value += 31 * dayMS } }
}
@MainActor struct ClipRenameInteractionTests {
    /// 等待实际模型完成，不以固定延时冒充保存/刷新，by AI.Coding。
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    /// 构造生产模型与假系统边界，by AI.Coding。
    private func model(_ store: HistoryStore, _ raw: RawBoard, clock: any ClipClock = SystemClock()) -> HistoryViewModel {
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store, clock: clock)
        return HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store), clock: clock)
    }
    /// 查询/删除/到期释放已消失编辑目标；旧卡片销毁不能取消新目标，by AI.Coding。
    @Test(arguments: ["query", "delete", "expire"])
    func removedOwnerAndOldCardTeardown(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = RenameClock(), store = try HistoryStore(location: root, clock: clock)
        for text in ["rename-owner", "other"] { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: clock.now()) }
        let model = model(store, RawBoard(), clock: clock); try await model.start(); model.capture.stop()
        try await wait { model.items.count == 2 && !model.historyBusy }
        let owner = model.items.first { $0.preview == "rename-owner" }!.id
        let other = model.items.first { $0.id != owner }!.id
        model.beginRename(owner); model.beginRename(other); model.cancelRename(id: owner)
        #expect(model.renamingID == other)
        model.beginRename(owner)
        switch reason {
        case "query": model.query = "other"; model.searchChanged()
        case "delete": let deletion = try await store.preview(.delete([owner])); _ = try await store.apply(deletion.token)
        default: clock.advance(); model.revalidateVisibleContent()
        }
        try await wait { !model.items.contains { $0.id == owner } && !model.historyBusy }
        #expect(model.renamingID == nil)
    }
    /// 名称变更不能清除暂停请求到持久化之间的门禁；取消不改变多选或写库，by AI.Coding。
    @Test func renamePreservesPendingPauseAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        for text in ["rename-one", "rename-two"] { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: SystemClock().now()) }
        let model = model(store, raw); try await model.start(); model.capture.stop()
        try await wait { model.items.count == 2 && !model.historyBusy }
        model.selectAllResults(); let selection = model.selectedIDs, selected = model.selectedID
        let id = model.items[0].id
        model.beginRename(id); model.cancelRename()
        #expect(model.renamingID == nil && model.selectedIDs == selection && model.selectedID == selected)
        #expect(try await store.metadata(id: id, at: SystemClock().now()).summary.title == nil)
        // 明确暂停持久化尚未执行的窗口，再让名称事件发布同版本策略，by AI.Coding。
        model.capture.requestPause()
        model.beginRename(id); model.saveRename(id: id, title: "Saved name")
        try await wait { model.items.first?.title == "Saved name" && !model.historyBusy }
        raw.user("must-not-read"); model.capture.tick()
        #expect(raw.reads.isEmpty)
        #expect(model.selectedIDs == selection && model.selectedID == selected)
        var paused = try await store.settings(); paused.captureEnabled = false
        _ = try await store.updateCaptureSettings(paused)
        try await wait { !model.settings.captureEnabled }
        model.beginRename(id); model.panelVisibilityChanged(false)
        #expect(model.renamingID == nil)
    }
    /// 标题双击只进入编辑，文字选择事件交还原生域；正文双击仍恢复原格式，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func nativeTitleAndBodyRouteSeparately() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("original-body".utf8))])])), at: SystemClock().now())
        let model = model(store, raw); try await model.start(); model.capture.stop()
        try await wait { model.items.count == 1 && !model.historyBusy }
        let host = NSHostingView(rootView: HistoryView(model: model).environment(\.colorScheme, .light)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1440, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func bridges(_ v: NSView) -> [HistoryDragBridge.DragView] { (v as? HistoryDragBridge.DragView).map { [$0] } ?? v.subviews.flatMap(bridges) }
        func nameFields(_ v: NSView) -> [ClipNameField.Field] { (v as? ClipNameField.Field).map { [$0] } ?? v.subviews.flatMap(nameFields) }
        try await wait { bridges(host).first?.headerRect.width ?? 0 > 0 }
        let view = try #require(bridges(host).first)
        // 短标题右侧空白仍属于改名行，图标与下一行时间不包含在内，by AI.Coding。
        #expect(view.headerRect.width > view.bounds.width / 2 && view.headerRect.maxX < view.bounds.width - 20)
        #expect(view.headerRect.minY < 28 && view.headerRect.maxY <= 40)
        // 可选输出是真实托管像素，仍不显示窗口或读取系统剪贴板，by AI.Coding。
        if let path = ProcessInfo.processInfo.environment["LOCALCLIP_RENAME_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func render(_ name: String) throws {
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(name))
            }
            try await store.renameClip(id: view.id, title: "示例名称")
            try await wait { model.items.first?.title == "示例名称" && !model.historyBusy }
            try render("custom-name.png")
            model.beginRename(view.id); await Task.yield(); host.layoutSubtreeIfNeeded()
            try render("inline-editor.png"); model.cancelRename()
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        }
        let count = raw.count
        let title = NSPoint(x: view.headerRect.midX, y: view.bounds.height - view.headerRect.midY)
        for local in [title, .init(x: view.headerRect.minX + 2, y: view.bounds.height - view.headerRect.midY), .init(x: view.headerRect.maxX - 2, y: view.bounds.height - view.headerRect.midY)] {
            let point = view.convert(local, to: nil)
            #expect(view.handle(event(.leftMouseDown, point)) == nil)
            #expect(view.handle(event(.leftMouseUp, point)) == nil)
            #expect(model.renamingID == view.id && raw.count == count)
            // 原生输入焦点必须真正离开搜索；仅renamingID变化不能证明能输入名称，by AI.Coding。
            try await wait { host.layoutSubtreeIfNeeded(); return nameFields(host).first?.currentEditor() != nil }
            let field = try #require(nameFields(host).first)
            let editor = try #require(field.currentEditor() as? NSTextView)
            #expect(window.firstResponder === editor)
            editor.insertText("rename-draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(model.query.isEmpty && raw.count == count)
            let editing = event(.leftMouseDown, point)
            #expect(view.handle(editing) === editing)
            model.cancelRename()
        }
        // 头部图标与时间行不再重命名，双击与正文一致走粘贴。
        let icon = view.convert(NSPoint(x: view.bounds.width - 20, y: view.bounds.height - 18), to: nil)
        _ = view.handle(event(.leftMouseDown, icon)); _ = view.handle(event(.leftMouseUp, icon))
        #expect(model.renamingID == nil)
        try await wait { raw.count > count }
        let pasted = raw.count
        #expect(view.handle(event(.leftMouseDown, view.convert(.init(x: 20, y: view.bounds.midY), to: nil))) == nil)
        #expect(view.handle(event(.leftMouseUp, view.convert(.init(x: 20, y: view.bounds.midY), to: nil))) == nil)
        try await wait { raw.count > pasted }
        #expect(raw.items.first?[SupportedType.string] == Data("original-body".utf8))
    }
}
