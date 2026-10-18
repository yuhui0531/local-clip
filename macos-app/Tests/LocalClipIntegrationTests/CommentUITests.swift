// 使用模型与不显示的原生控件验证交互，不打开面板或发送桌面事件，by AI.Coding。
import Foundation
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct CommentUITests {
    /// 等待真实异步条件，失败时明确记录。
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    /// 临时库配合假剪贴板，初始化后停止自动轮询。
    private func setup() async throws -> (URL, HistoryStore, HistoryViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root)
        for index in 0..<12 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("row-\(index)".utf8))])])), at: SystemClock().now() + Int64(index)) }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await wait { !model.historyBusy && model.items.count > 1 }
        return (root, store, model)
    }
    /// 搜索方向键交接结果焦点，等待新查询和空结果时不跳离搜索，by AI.Coding。
    @Test func searchNavigationEntersResultsOnlyWhenReady() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var entries = 0
        model.focusResults = { entries += 1 }
        let second = model.items[1].id
        model.navigateFromSearch(1)
        #expect(model.selectedID == second && entries == 1)
        model.query = "no-such-fixture"; model.searchChanged()
        model.navigateFromSearch(-1)
        #expect(entries == 1 && model.selectedID == second)
        try await wait { !model.historyBusy && model.items.isEmpty }
        model.navigateFromSearch(1)
        #expect(entries == 1)
        model.query = "row"; model.searchChanged(debounce: false)
        try await wait { !model.historyBusy && model.items.count > 1 }
        let first = model.items[0].id
        model.navigateFromSearch(-1)
        #expect(entries == 2 && model.selectedID == first)
    }
    /// 使用真实但不显示的原生field editor，验证快捷键作用对象、IME与查询等待保护，by AI.Coding。
    @Test func searchRecordCommandsKeepTextAndIMEOwnership() async throws {
        _ = NSApplication.shared
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let search = NSSearchField(frame: .init(x: 0, y: 0, width: 260, height: 30))
        window.contentView = search
        try #require(window.makeFirstResponder(search))
        let editor = try #require(search.currentEditor() as? NSTextView)
        #expect(AppDelegate.isHistorySearchEditor(editor) && !window.isVisible)
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        #expect(AppDelegate.handleRecordCommand(try key(34), responder: editor, model: model))
        #expect(model.showingDetail)
        #expect(AppDelegate.handleRecordCommand(try key(34), responder: editor, model: model))
        #expect(!model.showingDetail)
        // 全选/复制/撤销和非Command组合仍交给文本控件，不写剪贴板或触发记录操作。
        for code: UInt16 in [0, 8, 6, 36] { #expect(!AppDelegate.handleRecordCommand(try key(code), responder: editor, model: model)) }
        #expect(!AppDelegate.handleRecordCommand(try key(34, flags: [.command, .shift]), responder: editor, model: model))
        editor.setMarkedText("拼", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        for code: UInt16 in [5, 31, 14, 34, 17] { #expect(!AppDelegate.handleRecordCommand(try key(code), responder: editor, model: model)) }
        #expect(!model.showingDetail && model.contentEditor == nil)
        editor.unmarkText()
        model.query = "row"; model.searchChanged()
        #expect(AppDelegate.handleRecordCommand(try key(34), responder: editor, model: model))
        #expect(!model.showingDetail)
        try await wait { !model.historyBusy }
        model.panelVisibilityChanged(true)
        let selected = model.selectedID
        #expect(AppDelegate.handleRecordCommand(try key(14), responder: editor, model: model))
        try await wait { model.contentEditor?.id == selected }
        model.discardContentEdit()
        let name = NSTextField(frame: search.frame); window.contentView = name
        try #require(window.makeFirstResponder(name))
        let nameEditor = try #require(name.currentEditor() as? NSTextView)
        #expect(!AppDelegate.isHistorySearchEditor(nameEditor))
        for code: UInt16 in [5, 31, 14, 34, 17] { #expect(!AppDelegate.handleRecordCommand(try key(code), responder: nameEditor, model: model)) }
        #expect(!model.showingDetail && model.contentEditor == nil && !window.isVisible)
    }
    /// 定位相同ID也必须发出滚动请求；失败保持原查询和列表。
    @Test func locationPublishesRevealAndFailureKeepsFilters() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.last?.id)
        model.select(id)
        let oldScroll = model.scrollRestoration
        model.jumpToHistory(); try await wait { !model.historyBusy }
        #expect(model.selectedID == id && model.scrollRestoration != oldScroll)
        #expect((model.scrollRestoration?.offset ?? 0) > 0)
        let restored = model.scrollRestoration
        model.searchChanged(debounce: false)
        #expect(!model.historyBusy && model.scrollRestoration == restored)
        model.query = "row"; model.searchChanged(debounce: false); try await wait { !model.historyBusy }
        let items = model.items, selected = model.selectedID
        model.jumpToHistory(category: "missing"); try await wait { !model.historyBusy }
        #expect(model.query == "row" && model.activeCategories.isEmpty)
        #expect(model.items == items && model.selectedID == selected)
    }
    /// 保存失败继续编辑同一份本地草稿；取消/重试仍沿用原语义。
    @Test func failedRenameKeepsEditorUntilSuccessfulRetry() async throws {
        let (root, store, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first?.id)
        model.beginRename(id); model.saveRename(id: id, title: String(repeating: "x", count: 1025))
        try await wait { model.message.contains("重命名失败") }
        #expect(model.renamingID == id)
        #expect(try await store.metadata(id: id, at: SystemClock().now()).summary.title == nil)
        model.saveRename(id: id, title: "retry draft")
        try await wait { model.renamingID == nil && model.items.first?.title == "retry draft" }
    }
    /// 全部文本才允许转换；主卡片顺序不能改变混合选择的能力。
    @Test func plainCopyChecksWholeSelection() async throws {
        let (root, store, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let textIDs = Set(model.items.prefix(2).map(\.id))
        #expect(await model.canCopyAsText(textIDs))
        guard case .inserted(let image) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 4, height: 4))])])), at: SystemClock().now() + 100) else { Issue.record("fixture"); return }
        #expect(await !model.canCopyAsText(textIDs.union([image])))
        #expect(await !model.canCopyAsText([]))
    }

    /// 后一次失败不能被较早成功关闭，仍可修正当前草稿重试。
    @Test func overlappingRenameKeepsNewestFailedDraft() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first?.id)
        model.beginRename(id)
        model.saveRename(id: id, title: "first submission")
        model.saveRename(id: id, title: String(repeating: "x", count: 1025))
        try await wait { model.message.contains("重命名失败") }
        #expect(model.renamingID == id)
        model.saveRename(id: id, title: "corrected latest draft")
        try await wait { model.renamingID == nil && model.items.first?.title == "corrected latest draft" }
    }

    /// 提交后继续输入但尚未再次保存，早先成功也不能收起新的本地草稿。
    @Test func editingWhileRenameSavesKeepsDraftOpen() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first?.id)
        model.beginRename(id); model.saveRename(id: id, title: "submitted name")
        model.renameDraftChanged(id: id)
        try await wait { model.items.first?.title == "submitted name" }
        #expect(model.renamingID == id)
        model.saveRename(id: id, title: "continued draft")
        try await wait { model.renamingID == nil && model.items.first?.title == "continued draft" }
    }

    /// 连续有效提交的持久结果按用户顺序，取消及新编辑会话不接收旧错误。
    @Test func renameSubmissionsStayOrderedAndErrorsStayScoped() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(model.items.first?.id)
        model.beginRename(id)
        model.saveRename(id: id, title: String(repeating: "x", count: 1025))
        model.cancelRename(); model.beginRename(id)
        model.message = "new session"
        for index in 0..<5 { model.saveRename(id: id, title: "ordered-\(index)") }
        try await wait { model.renamingID == nil && model.items.first?.title == "ordered-4" }
        #expect(!model.message.contains("重命名失败"))
    }


    /// 明确详情入口不被延迟选中回调关闭，普通选卡仍关闭旧详情。
    @Test func explicitDetailSurvivesSelectionAndNormalSelectionClosesIt() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model.items[0].id, second = model.items[1].id
        model.showDetail(id: first)
        try await wait { model.detail?.summary.id == first }
        #expect(model.showingDetail && model.detailEditable)
        model.showDetail(id: second)
        try await wait { model.detail?.summary.id == second }
        #expect(model.showingDetail && model.selectedID == second && model.detailEditable)
        model.select(first)
        #expect(!model.showingDetail && model.detail == nil && !model.detailEditable)
        model.categoryFilters = ["category"]
        #expect(model.hasFilterSelection)
        model.query = "type:text"; model.searchChanged(debounce: false)
        try await wait { !model.historyBusy }
        #expect(model.hasFilterStrip)
    }

    /// 首次编辑外点只关闭或请求确认，下一次独立点击仍可选卡，不发送粘贴。
    @Test func footerCapabilityIgnoresMetadataAndPagination() async throws {
        let (root, store, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model.items[0].id, second = model.items[1].id
        model.select(first)
        let key = model.listState.footerState.snapshot.textCapability
        model.listState.selectedMetadata = try await store.metadata(id: first, at: SystemClock().now())
        model.listState[\.loading] = true
        #expect(model.listState.footerState.snapshot.textCapability == key)
        model.listState[\.loading] = false; model.select(second)
        #expect(model.listState.footerState.snapshot.textCapability != key)
    }
    /// 关闭浮层的整个双击序列不选择、不粘贴；下一次独立点击仍可正常选卡。
    @Test(arguments: ["detail", "filter", "category"])
    func popoverOutsideDoubleClickIsConsumed(_ kind: String) async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model.items[0].id, second = model.items[1].id
        model.select(first)
        if kind == "detail" { model.showingDetail = true }
        if kind == "filter" { model.showingFilters = true }
        if kind == "category" { model.showingCategoryEditor = true }
        let bridge = HistoryDragBridge.DragView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        bridge.model = model; bridge.id = second
        var timestamp: TimeInterval = 0
        func click(_ count: Int) throws {
            timestamp += 1
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: .init(x: 20, y: 100), modifierFlags: [], timestamp: timestamp, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
                _ = bridge.handle(event)
            }
        }
        try click(1); try click(2)
        #expect(model.selectedID == first)
        #expect(!model.showingDetail && !model.showingFilters && !model.showingCategoryEditor)
        try click(1)
        #expect(model.selectedID == second)
    }

    @Test(arguments: [false, true]) func editorOutsideClickDoesNotSelectOrPaste(_ changed: Bool) async throws {
        _ = NSApplication.shared
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model.items[0].id, second = model.items[1].id
        model.select(first); model.panelVisibilityChanged(true); model.beginContentEdit(first)
        try await wait { model.contentEditor != nil }
        if changed { model.contentEditor?.text = "unsaved" }
        let bridge = HistoryDragBridge.DragView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        bridge.model = model; bridge.id = second
        var eventTime: TimeInterval = 0
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            eventTime += 1
            return try #require(NSEvent.mouseEvent(with: type, location: .init(x: 20, y: 100), modifierFlags: [], timestamp: eventTime, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        _ = bridge.handle(try event(.leftMouseDown)); _ = bridge.handle(try event(.leftMouseUp))
        #expect(model.selectedID == first)
        if changed { #expect(model.contentEditor?.confirmingDiscard == true && model.contentEditor?.text == "unsaved"); model.discardContentEdit() }
        else { #expect(model.contentEditor == nil) }
        _ = bridge.handle(try event(.leftMouseDown)); _ = bridge.handle(try event(.leftMouseUp))
        #expect(model.selectedID == second)
    }
}
