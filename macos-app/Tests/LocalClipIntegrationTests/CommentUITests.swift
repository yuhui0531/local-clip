// 使用模型与不显示的原生控件验证交互，不打开面板或发送桌面事件，by AI.Coding。
import Foundation
import AppKit
import Carbon
import SwiftUI
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
        // 筛选条已移除：前缀条件留在搜索词中，分类条件计入筛选按钮，几何不再随之变化，by AI.Coding。
        #expect(!model.queryConditions.isEmpty && model.filterCount == 1)
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
    /// 现状固定（dea4d44 实测）：搜索框编辑时⌘C被底栏复制按钮快捷键接管，复制所选记录。
    /// 按钮移除后窗口快捷键不再截获，键盘监听显式保留同一结果；输入法组合与无选择时仍归文字，by AI.Coding。
    @Test func searchCommandCopyOwnership() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("copy-record".utf8))])])), at: SystemClock().now())
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop(); try await wait { !model.historyBusy && model.selectedID != nil }
        let host = NSHostingView(rootView: HistoryView(model: model)), window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1440, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        host.sizingOptions = []; window.contentView = host; host.frame = .init(x: 0, y: 0, width: 1440, height: 340)
        func searchField(_ view: NSView) -> NSSearchField? { (view as? NSSearchField) ?? view.subviews.lazy.compactMap(searchField).first }
        try await wait { host.layoutSubtreeIfNeeded(); return searchField(host) != nil }
        let field = try #require(searchField(host))
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(AppDelegate.isHistorySearchEditor(editor))
        let before = raw.count
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(!window.performKeyEquivalent(with: copy)); #expect(raw.count == before)
        #expect(AppDelegate.copiesRecordFromSearch(copy, responder: editor, model: model))
        try await wait { raw.count != before && model.message == "已复制" }
        editor.setMarkedText("拼", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(!AppDelegate.copiesRecordFromSearch(copy, responder: editor, model: model))
        editor.unmarkText()
        // 结果区⌘C沿用键盘监听原有分支，不经过此搜索专用路径。
        #expect(!AppDelegate.copiesRecordFromSearch(copy, responder: window, model: model))
        model.select(nil); #expect(!AppDelegate.copiesRecordFromSearch(copy, responder: editor, model: model))
        #expect(!window.isVisible)
    }
    /// 第一响应者变化同步驱动状态槽焦点提示；搜索有词提示进入结果，结果区提示默认动作，by AI.Coding。
    @Test func focusHintFollowsFirstResponder() async throws {
        _ = NSApplication.shared
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        model.status = "正常"
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let search = NSSearchField(frame: .init(x: 0, y: 0, width: 260, height: 30)); window.contentView = search
        let observation = AppDelegate.observeHistoryFocus(of: window, model: model)
        defer { observation.invalidate() }
        try #require(window.makeFirstResponder(search))
        #expect(model.historyFocus == .search)
        #expect(model.statusEntry(queryEmpty: true) == nil)
        #expect(model.statusEntry(queryEmpty: false) == .init(level: .hint, text: "↩ 进入结果"))
        try #require(window.makeFirstResponder(window))
        #expect(model.historyFocus == .results)
        #expect(model.statusEntry(queryEmpty: true)?.text.hasPrefix(model.settings.defaultAction == .directPaste ? "↩ 粘贴到 " : "↩ 复制") == true)
        #expect(!window.isVisible)
    }
    /// 结果区键入转入搜索：仅无⌘⌃⌥的可打印字符；Space、Return、Delete、Tab、Esc、方向、功能与控制字符保留原含义，by AI.Coding。
    @Test func forwardsPrintableKeysToSearch() throws {
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        #expect(AppDelegate.forwardsToSearch(try key("a", 0), editing: false))
        #expect(AppDelegate.forwardsToSearch(try key("A", 0, .shift), editing: false))
        #expect(AppDelegate.forwardsToSearch(try key("1", 18), editing: false))
        #expect(AppDelegate.forwardsToSearch(try key("/", 44), editing: false))
        #expect(!AppDelegate.forwardsToSearch(try key("a", 0), editing: true))
        for flags in [NSEvent.ModifierFlags.command, .control, .option, [.command, .shift]] { #expect(!AppDelegate.forwardsToSearch(try key("a", 0, flags), editing: false)) }
        for (characters, code) in [(" ", UInt16(49)), ("\r", 36), ("\u{3}", 76), ("\u{7f}", 51), ("\t", 48), ("\u{1b}", 53), ("\u{F700}", 126), ("\u{F701}", 125), ("\u{F702}", 123), ("\u{F703}", 124), ("\u{F729}", 115), ("\u{F72B}", 119), ("\u{F704}", 122), ("\u{1}", 0)] {
            #expect(!AppDelegate.forwardsToSearch(try key(characters, code), editing: false))
        }
    }
    /// 同步转入后原事件按正常派发进入原生field editor，首键不丢；隐藏窗口，不激活应用，by AI.Coding。
    @Test func forwardedKeyLandsInSearchField() async throws {
        _ = NSApplication.shared
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let search = NSSearchField(frame: .init(x: 0, y: 0, width: 260, height: 30)); window.contentView = search
        #expect(!model.focusSearchSynchronously())
        model.searchField = search
        try #require(window.makeFirstResponder(window))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(AppDelegate.forwardsToSearch(event, editing: false) && model.focusSearchSynchronously())
        #expect(AppDelegate.isHistorySearchEditor(window.firstResponder))
        window.sendEvent(event) // 监听放行后AppKit按新的第一响应者派发
        #expect(search.stringValue == "a" && !window.isVisible)
    }
    /// Esc分级：分类编辑 → 筛选 → 状态 → 详情 → 清空搜索并回结果 → 关闭；三条入口共用，by AI.Coding。
    @Test func escapeLevels() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var results = 0; model.focusResults = { results += 1 }
        model.showingCategoryEditor = true; model.showingFilters = true; model.showingStatusDetail = true; model.showingDetail = true; model.query = "row"
        #expect(!model.handleEscape() && !model.showingCategoryEditor && model.showingFilters)
        #expect(!model.handleEscape() && !model.showingFilters && model.showingStatusDetail)
        #expect(!model.handleEscape() && !model.showingStatusDetail && model.showingDetail)
        #expect(!model.handleEscape() && !model.showingDetail && model.query == "row" && results == 0)
        #expect(!model.handleEscape() && model.query.isEmpty && results == 1)
        #expect(model.handleEscape())
        var closes = 0
        let field = SearchField(text: .constant(""), focus: UUID(), onChange: {}, onNavigate: { _ in }, onEnter: {}, onEscape: { if model.handleEscape() { closes += 1 } })
        model.query = "row"; field.onEscape(); #expect(closes == 0 && model.query.isEmpty)
        field.onEscape(); #expect(closes == 1)
        _ = NSApplication.shared
        let panel = ClipPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var dismissed = 0, closed = 0
        panel.onCancel = { if model.handleEscape() { dismissed += 1 } }; panel.onClose = { closed += 1 }
        model.query = "row"; panel.cancelOperation(nil); #expect(dismissed == 0 && model.query.isEmpty)
        panel.cancelOperation(nil); #expect(dismissed == 1)
        model.query = "row"; panel.performClose(nil); #expect(closed == 1 && model.query == "row")
    }
    /// 每次打开发放的focusRequest推动文件卡片重新校验；非文件卡片不因此重绘，by AI.Coding。
    @Test func focusRequestRevalidatesFileCards() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var item = try #require(model.items.first)
        func card(_ generation: UUID) -> ClipCard {
            ClipCard(item: item, index: 0, selected: false, dragging: false, editing: false, hidden: false, quickModifiers: 0, height: 268, categoryID: nil, categories: [], target: nil, selectionCount: 0, selectionHasNonText: false, queueShortcut: model.settings.queueShortcut, model: model, previewGeneration: generation)
        }
        let first = UUID(), second = UUID()
        #expect(card(first) == card(second))
        item.kind = .file
        #expect(card(first) == card(first) && !(card(first) == card(second)))
    }
    /// 详情等待反馈：快速完成不闪转圈；500ms时显示等待；换选后旧请求不再弹出，by AI.Coding。
    @Test func detailLoadingFeedback() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model.items[0].id, second = model.items[1].id
        var flashed = false
        let start = ContinuousClock.now
        model.showDetail(id: first)
        while model.detail?.summary.id != first { flashed = flashed || model.detailSlow; try await Task.sleep(for: .milliseconds(2)) }
        // 满载时真实读取可能超过阈值；只要求100ms内完成时绝不出现转圈。
        #expect(!flashed || ContinuousClock.now - start >= .milliseconds(100))
        #expect(!model.detailSlow)
        model.showingDetail = false; model.detailVisibilityChanged()
        model.detailDelayForTesting = .milliseconds(500)
        model.showDetail(id: first)
        try await wait { model.detailSlow }
        #expect(model.detail == nil && model.statusEntry(queryEmpty: true) == .init(level: .notice, text: "正在准备预览…"))
        model.showDetail(id: second)
        #expect(!model.detailSlow)
        try await wait { model.detail?.summary.id == second }
        #expect(!model.detailSlow && model.selectedID == second)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.detail?.summary.id == second)
        model.select(first)
        #expect(!model.detailSlow && !model.showingDetail)
    }
    /// Space开关预览；Space打开后方向键换选保持预览并加载新内容；点击换卡仍关闭；隐藏内容时无效，by AI.Coding。
    @Test func spaceTogglesFollowingPreview() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        model.select(model.items[0].id)
        model.toggleQuickLook()
        try await wait { model.detail?.summary.id == model.items[0].id }
        #expect(model.showingDetail && model.previewFollowsSelection)
        for step in 1...10 {
            model.navigate(1)
            let expected = model.items[min(step, model.items.count - 1)].id
            #expect(model.showingDetail && model.selectedID == expected)
            try await wait { model.detail?.summary.id == expected }
        }
        model.toggleQuickLook()
        #expect(!model.showingDetail && !model.previewFollowsSelection)
        model.showDetail(id: model.items[0].id)
        try await wait { model.detail != nil }
        model.navigate(1)
        #expect(!model.showingDetail)
        model.toggleQuickLook(); try await wait { model.showingDetail }
        model.select(model.items[3].id)
        #expect(!model.showingDetail)
        model.updateSettings { $0.hideContents = true }
        try await wait { model.settings.hideContents }
        model.toggleQuickLook(); try await Task.sleep(for: .milliseconds(150))
        #expect(!model.showingDetail)
    }
    /// 入队触发的关闭立即隐藏，不走用户关闭的淡出，by AI.Coding。
    @Test func queueClosesPanelWithoutFade() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var closes: [Bool] = []
        model.closePanel = { closes.append($0) }; model.registerQueueShortcut = { _ in true }
        model.startPasteQueue(model.items.prefix(2).map(\.id))
        #expect(closes == [false])
        model.stopPasteQueue()
    }
    /// ⌘N角标：修饰键恰好等于快速粘贴修饰键才显示，by AI.Coding。
    @Test func quickBadgeModifierMatching() {
        let command = UInt32(cmdKey), commandOption = UInt32(cmdKey | optionKey)
        #expect(AppDelegate.showsQuickBadges(.command, quickModifiers: command))
        #expect(AppDelegate.showsQuickBadges([.command, .capsLock], quickModifiers: command))
        #expect(!AppDelegate.showsQuickBadges([], quickModifiers: command))
        #expect(!AppDelegate.showsQuickBadges([.command, .shift], quickModifiers: command))
        #expect(!AppDelegate.showsQuickBadges(.option, quickModifiers: command))
        #expect(AppDelegate.showsQuickBadges([.command, .option], quickModifiers: commandOption))
        #expect(!AppDelegate.showsQuickBadges(.command, quickModifiers: commandOption))
        #expect(!AppDelegate.showsQuickBadges([], quickModifiers: 0))
    }
    /// 卡片VoiceOver命名动作：原底栏5个入口；纯文本复制按动作作用的整组在真实存储中的文本表示判定，与“更多”菜单一致，by AI.Coding。
    @Test func cardVoiceOverPlainCopyFollowsSelection() async throws {
        let (root, store, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try ImageFixtures.image(width: 4, height: 4), now = SystemClock().now() + 100
        guard case .inserted(let image) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, png)])])), at: now),
              case .inserted(let mixed) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("mixed".utf8))]), .init([.init(SupportedType.png, png)])])), at: now + 1)
        else { Issue.record("fixture"); return }
        model.refresh(); try await wait { model.contains(image) && model.contains(mixed) && !model.historyBusy }
        #expect(model.items.first { $0.id == mixed }?.kind == .mixed)
        let texts = model.items.filter { $0.kind == .text }.map(\.id)
        func actions(_ id: ClipID, hidden: Bool = false) async -> [String] {
            let allowed = await model.canCopyAsText(ClipCard.voiceOverTargets(id, selection: model.selectedIDs))
            return ClipCard.voiceOverActions(plainText: allowed, hidden: hidden, favorite: false)
        }
        model.select(texts[0])
        #expect(await actions(texts[0]) == ["详情", "收藏", "原格式复制", "纯文本复制", "直接粘贴"])
        #expect(await actions(image) == ["详情", "收藏", "原格式复制", "直接粘贴"])
        #expect(await !actions(mixed).contains("纯文本复制"))
        // 多选含无文本项：组内任一卡片都不提供；组外文本卡片只作用自身，仍提供。
        model.choose(image, modifiers: .command)
        #expect(model.selectedIDs == [texts[0], image])
        #expect(await !actions(texts[0]).contains("纯文本复制"))
        #expect(await actions(texts[1]).contains("纯文本复制"))
        model.select(texts[0]); model.choose(texts[1], modifiers: .command)
        #expect(await actions(texts[0]).contains("纯文本复制"))
        #expect(await actions(texts[0], hidden: true) == ["原格式复制"])
        #expect(ClipCard.voiceOverActions(plainText: true, hidden: false, favorite: true)[1] == "取消收藏")
    }
    /// 队列浮窗已存在时切换共享排除，窗口属性立即随设置更新，by AI.Coding。
    @Test func queuePanelSharingFollowsSetting() {
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        let queue = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        AppDelegate.applySharing(false, to: [panel, queue, nil])
        #expect(panel.sharingType == .readOnly && queue.sharingType == .readOnly)
        AppDelegate.applySharing(true, to: [panel, queue])
        #expect(panel.sharingType == .none && queue.sharingType == .none && !queue.isVisible)
        AppDelegate.applySharing(false, to: [panel, queue])
        #expect(panel.sharingType == .readOnly && queue.sharingType == .readOnly)
    }
    /// 文件图标读取：取消或记录已删除时不返回结果，卡片据此不写图标、不继续解码，by AI.Coding。
    @Test func fileIconDropsStaleRequests() async throws {
        let (root, store, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("icon.txt"); try Data("x".utf8).write(to: file)
        let id = model.items[0].id
        #expect(await ClipCard.fileIcon(file.path, id: id, model: model) != nil)
        // 任务只返回判定值，避免测试自身跨任务传递不可发送的NSImage。
        let cancelled = Task { await ClipCard.fileIcon(file.path, id: id, model: model) == nil }
        cancelled.cancel()
        #expect(await cancelled.value)
        _ = try await store.apply(store.preview(.delete([id])).token)
        model.refresh(); try await wait { !model.contains(id) && !model.historyBusy }
        #expect(await ClipCard.fileIcon(file.path, id: id, model: model) == nil)
    }
    /// 色值卡片：带空格的rgb/hsl与hex均识别，混有其他文字不识别；透明度与卡片底色合成后选字色，填充保留原透明度，by AI.Coding。
    @Test func colorCardAcceptsSpacedValuesWithReadableText() {
        func fill(_ text: String, dark: Bool = false) -> (color: Color, dark: Bool)? {
            ClipCard.colorFill(ContentInspector.inspect(text, truncated: false), darkAppearance: dark)
        }
        for value in ["#34C759", "rgb(52, 199, 89)", "hsl(135, 59%, 49%)", "rgba(0, 0, 0, 0.5)", "  #fff \n"] { #expect(fill(value) != nil, "\(value)") }
        for value in ["rgb(52, 199, 89) green", "color: #34C759", "#34C759 #000", "hsl(135, 59%, 49%);", "rgb(300, 0, 0)"] { #expect(fill(value) == nil, "\(value)") }
        // 全透明：浅色底上用黑字，深色底上用白字；不透明色两种外观一致。
        #expect(fill("#00000000")?.dark == true && fill("#00000000", dark: true)?.dark == false)
        #expect(fill("#000000")?.dark == false && fill("#000000", dark: true)?.dark == false)
        #expect(fill("#FFFFFF")?.dark == true && fill("#FFFFFF", dark: true)?.dark == true)
        // 半透明：按合成色判断。
        #expect(fill("rgba(0, 0, 0, 0.2)")?.dark == true && fill("rgba(255, 255, 255, 0.2)", dark: true)?.dark == false)
        #expect(fill("#00000000").map { NSColor($0.color).alphaComponent } == 0)
        #expect(fill("rgba(52, 199, 89, 0.5)").map { abs(NSColor($0.color).alphaComponent - 0.5) < 0.01 } == true)
    }
    /// Space预览：从按下起超过100ms即显示等待；读取中再按Space取消；换选、隐藏面板或隐藏内容后不迟到弹出，也不残留等待或失败，by AI.Coding。
    @Test func spacePreviewFeedbackAndCancel() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        func settled() -> Bool { !model.detailSlow && !model.detailFailed && model.message != "预览不可用，记录已变化" && !model.showingDetail }
        model.detailDelayForTesting = .milliseconds(300)
        model.select(model.items[0].id)
        model.toggleQuickLook()
        try await wait { model.detailSlow }
        #expect(!model.showingDetail && model.statusEntry(queryEmpty: true) == .init(level: .notice, text: "正在准备预览…"))
        model.toggleQuickLook()
        #expect(settled() && !model.previewFollowsSelection)
        try await Task.sleep(for: .milliseconds(700))
        #expect(settled() && model.detail == nil)
        // 等待反馈连续到详情发布。
        model.toggleQuickLook()
        try await wait { model.detailSlow }
        var gap = false
        while model.detail == nil { gap = gap || !model.detailSlow; try await Task.sleep(for: .milliseconds(2)) }
        #expect(!gap && model.showingDetail && !model.detailSlow && model.previewFollowsSelection)
        model.toggleQuickLook()
        #expect(!model.showingDetail)
        // 换选、隐藏面板、隐藏内容都使待弹出的预览作废。
        model.toggleQuickLook(); try await wait { model.detailSlow }
        model.select(model.items[2].id)
        #expect(settled())
        model.toggleQuickLook(); try await wait { model.detailSlow }
        model.panelVisibilityChanged(false)
        #expect(settled())
        model.panelVisibilityChanged(true)
        model.toggleQuickLook(); try await wait { model.detailSlow }
        model.updateSettings { $0.hideContents = true }
        try await wait { model.settings.hideContents }
        #expect(settled())
        try await Task.sleep(for: .milliseconds(700))
        #expect(settled() && model.detail == nil)
    }
    /// 预览跟随越过页尾：直接加载下一页与等待已有预读两种路径都保持预览并加载新卡内容，by AI.Coding。
    @Test func previewFollowsAcrossPageBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for index in 0..<110 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("page-\(index)".utf8))])])), at: SystemClock().now() + Int64(index)) }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        try await wait { !model.historyBusy && model.items.count == 50 && model.hasMore }
        model.select(model.items[49].id)
        model.toggleQuickLook(); try await wait { model.detail?.summary.id == model.items[49].id }
        model.navigate(1)
        try await wait { model.items.count > 50 && !model.historyBusy }
        let direct = model.items[50].id
        #expect(model.selectedID == direct && model.showingDetail && model.previewFollowsSelection)
        try await wait { model.detail?.summary.id == direct }
        // 已有预读在途时到达页尾：记住方向键，页面返回后继续选择并保持预览。
        let last = model.items.count - 1
        model.select(model.items[last].id, keepDetail: true)
        try await wait { model.detail?.summary.id == model.items[last].id }
        let count = model.items.count
        model.loadMore(); #expect(model.historyBusy)
        model.navigate(1)
        try await wait { model.items.count > count && !model.historyBusy }
        let queued = model.items[count].id
        #expect(model.selectedID == queued && model.showingDetail)
        try await wait { model.detail?.summary.id == queued }
        // 点击换卡仍关闭预览。
        model.select(model.items[0].id)
        #expect(!model.showingDetail)
    }
    /// 来源色头部：任何主色校正后白字对比度≥4.5:1，保持色相、饱和度≤上限；双色图标取主色桶而非RGB平均；近灰图标回退中性深灰；按键缓存只算一次，by AI.Coding。
    @Test func headerColorsKeepWhiteTextReadable() {
        let samples: [NSColor] = [.systemYellow, .yellow, NSColor(srgbRed: 0.6, green: 1, blue: 0.6, alpha: 1), .white, .cyan, .green, .orange, .red, .blue, .magenta, .systemTeal, NSColor(srgbRed: 1, green: 0.98, blue: 0.4, alpha: 1), .black]
        for sample in samples {
            let header = SourceApplicationObserver.readableHeader(sample)
            #expect(SourceApplicationObserver.whiteContrast(header) >= 4.5)
            #expect(header.saturationComponent <= SourceApplicationObserver.maxHeaderSaturation + 0.001)
        }
        let yellow = SourceApplicationObserver.readableHeader(.systemYellow).usingColorSpace(.sRGB)!
        #expect(abs(yellow.hueComponent - NSColor.systemYellow.usingColorSpace(.sRGB)!.hueComponent) < 0.02)
        func image(_ color: NSColor) -> NSImage {
            NSImage(size: .init(width: 32, height: 32), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        }
        let dominant = SourceApplicationObserver.dominantColor(image(.systemOrange))?.usingColorSpace(.sRGB)
        #expect(dominant.map { abs($0.hueComponent - NSColor.systemOrange.usingColorSpace(.sRGB)!.hueComponent) < 0.03 } == true)
        #expect(SourceApplicationObserver.dominantColor(image(.gray)) == nil)
        // 左5/8绿、右3/8紫：结果为绿色主色，不是RGB平均出的灰紫。
        let green = NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1), purple = NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        let split = NSImage(size: .init(width: 32, height: 32), flipped: false) { rect in
            green.setFill(); NSRect(x: 0, y: 0, width: 20, height: 32).fill()
            purple.setFill(); NSRect(x: 20, y: 0, width: 12, height: 32).fill(); return true
        }
        let average = NSColor(srgbRed: (0.2 * 5 + 0.69 * 3) / 8, green: (0.78 * 5 + 0.32 * 3) / 8, blue: (0.35 * 5 + 0.87 * 3) / 8, alpha: 1)
        let mixed = SourceApplicationObserver.dominantColor(split)?.usingColorSpace(.sRGB)
        #expect(mixed.map { abs($0.hueComponent - green.hueComponent) < 0.03 } == true)
        #expect(mixed.map { abs($0.hueComponent - average.hueComponent) > 0.05 } == true)
        #expect(SourceApplicationObserver.whiteContrast(SourceApplicationObserver.neutralHeader) >= 4.5)
        let first = SourceApplicationObserver.headerColor(fallback: "test-kind", base: .systemGreen)
        #expect(first === SourceApplicationObserver.headerColor(fallback: "test-kind", base: .systemGreen))
    }
    /// 队列浮窗：显示期间开始与成功不另弹提示，失败写入浮窗警告；摘要在隐藏内容时不显示正文；浮窗不属于历史窗口，by AI.Coding。
    @Test func queuePanelReplacesTransientFeedback() async throws {
        _ = NSApplication.shared
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var popups: [String] = [], changes = 0
        model.showPasteFeedback = { message, _ in popups.append(message) }
        model.registerQueueShortcut = { _ in true }; model.closePanel = { _ in }; model.pasteQueueChanged = { changes += 1 }
        model.showsQueuePanel = true
        let ids = model.items.prefix(3).map(\.id)
        model.startPasteQueue(ids)
        #expect(popups.isEmpty && model.pasteQueueWarning == nil && changes > 0)
        #expect(model.pasteQueueNextSummary == model.items[0].preview.split(whereSeparator: \.isNewline).first.map(String.init))
        model.pasteQueueNext(target: nil, modifiersHeld: { false })
        #expect(popups.isEmpty && model.pasteQueueWarning == "请先切换到要粘贴的应用")
        let host = NSHostingView(rootView: PasteQueueView(model: model))
        #expect(host.fittingSize.width <= 262 && host.fittingSize.height > 40)
        model.updateSettings { $0.hideContents = true }
        try await wait { model.settings.hideContents }
        #expect(model.pasteQueueNextSummary == "内容已隐藏")
        model.stopPasteQueue()
        #expect(model.pasteQueueWarning == nil && !model.pasteQueueActive)
        model.pasteQueueNext(target: nil, modifiersHeld: { false })
        let frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        let queue = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        #expect(!AppDelegate.ownsHistoryWindow(queue, panel: panel, settings: nil, feedback: nil, showingDetail: true, showingCategoryEditor: false, showingFilters: false, queue: queue))
    }
    /// ⌘R在结果区与搜索框中重命名所选记录，查询在途时拦截；输入法组合时归文字；右键菜单的快捷键只作展示，不在窗口中重复执行，by AI.Coding。
    @Test func renameShortcutAndMenuShortcutsRunOnce() async throws {
        _ = NSApplication.shared
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func key(_ code: UInt16, _ characters: String = "") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        let first = model.items[0].id
        model.select(first)
        #expect(AppDelegate.handleRecordCommand(try key(15), responder: window, model: model) && model.renamingID == first)
        model.cancelRename()
        let search = NSSearchField(frame: .init(x: 0, y: 0, width: 260, height: 30)); window.contentView = search
        try #require(window.makeFirstResponder(search))
        let editor = try #require(search.currentEditor() as? NSTextView)
        #expect(AppDelegate.handleRecordCommand(try key(15), responder: editor, model: model) && model.renamingID == first)
        model.cancelRename()
        editor.setMarkedText("拼", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(!AppDelegate.handleRecordCommand(try key(15), responder: editor, model: model) && model.renamingID == nil)
        editor.unmarkText()
        model.query = "row"; model.searchChanged()
        #expect(AppDelegate.handleRecordCommand(try key(15), responder: editor, model: model) && model.renamingID == nil)
        try await wait { !model.historyBusy }
        let item = try #require(model.items.first)
        let card = ClipCard(item: item, index: 0, selected: true, dragging: false, editing: false, hidden: false, quickModifiers: 0, height: 268, categoryID: nil, categories: [], target: nil, selectionCount: 1, selectionHasNonText: false, queueShortcut: model.settings.queueShortcut, model: model, previewGeneration: UUID())
        let host = NSHostingView(rootView: card); host.frame = .init(x: 0, y: 0, width: 300, height: 300); window.contentView = host
        host.layoutSubtreeIfNeeded()
        for (code, characters) in [(UInt16(17), "t"), (5, "g"), (31, "o"), (14, "e"), (15, "r"), (34, "i")] {
            #expect(!window.performKeyEquivalent(with: try key(code, characters)))
        }
        #expect(model.renamingID == nil && model.contentEditor == nil && !model.showingDetail)
    }
    /// 状态槽优先级：错误 > 监控异常 > 队列 > 通知 > 提示；旧通知计时器不能清掉同文字的新错误，by AI.Coding。
    @Test func statusSlotPriorityAndSeverity() async throws {
        let (root, _, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        model.status = "正常"; model.historyFocus = .results
        #expect(model.statusEntry(queryEmpty: true)?.level == .hint)
        model.notice("已复制")
        #expect(model.messageSeverity == .notice && model.statusEntry(queryEmpty: true) == .init(level: .notice, text: "已复制"))
        model.registerQueueShortcut = { _ in true }
        model.startPasteQueue(model.items.prefix(2).map(\.id))
        #expect(model.statusEntry(queryEmpty: true)?.level == .queue)
        model.status = "用户暂停"
        #expect(model.statusEntry(queryEmpty: true) == .init(level: .monitoring, text: "已停止监控"))
        model.message = "已复制"
        #expect(model.messageSeverity == .failure && model.statusEntry(queryEmpty: true) == .init(level: .failure, text: "已复制"))
        try await Task.sleep(for: .seconds(4.3))
        #expect(model.message == "已复制" && model.messageSeverity == .failure)
        model.showingStatusDetail = true; model.dismissMessage()
        #expect(model.message.isEmpty && !model.showingStatusDetail && model.statusEntry(queryEmpty: true)?.level == .monitoring)
        model.status = "正常"
        #expect(model.statusEntry(queryEmpty: true)?.level == .queue)
        model.stopPasteQueue()
        model.query = "app:nothing"; model.searchChanged(debounce: false)
        try await wait { !model.historyBusy && !model.queryProblems.isEmpty }
        #expect(model.statusEntry(queryEmpty: false) == .init(level: .failure, text: "未找到来源 nothing"))
    }
    /// “更多 › 所选记录”可用性逐项等于原底栏：无选择整组禁用、隐藏内容禁用收藏/分类/详情/编辑，by AI.Coding。
    @Test func selectedRecordMenuMatchesFormerFooter() async throws {
        let (root, store, model) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        func flags(_ value: SelectedRecordAvailability) -> [Bool] { [value.any, value.plainCopy, value.favorite, value.category, value.detail, value.edit] }
        let first = model.items[0].id
        model.select(first)
        try await wait { model.listState.footerState.snapshot.selectedMetadata?.summary.id == first }
        let one = model.listState.footerState.snapshot
        #expect(flags(SelectedRecordAvailability(one, canDisplay: true, canCopyText: true)) == [true, true, true, true, true, true])
        #expect(SelectedRecordAvailability(one, canDisplay: true, canCopyText: false).plainCopy == false)
        #expect(flags(SelectedRecordAvailability(one, canDisplay: false, canCopyText: true)) == [true, true, false, false, false, false])
        var pending = one; pending.selectedMetadata = nil
        #expect(!SelectedRecordAvailability(pending, canDisplay: true, canCopyText: true).category)
        var many = one; many.selectedCount = 2
        #expect(!SelectedRecordAvailability(many, canDisplay: true, canCopyText: true).edit)
        guard case .inserted(let image) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 4, height: 4))])])), at: SystemClock().now() + 100) else { Issue.record("fixture"); return }
        var picture = one; picture.selectedItem?.kind = .image; picture.selectedID = image
        #expect(!SelectedRecordAvailability(picture, canDisplay: true, canCopyText: true).edit)
        model.select(nil)
        let none = model.listState.footerState.snapshot
        #expect(flags(SelectedRecordAvailability(none, canDisplay: true, canCopyText: true)) == [false, false, false, false, false, false])
    }
    /// 卡片边长只随面板高度严格单调变化，等于 H−72，与筛选、队列、多选无关，by AI.Coding。
    @Test func cardSideIsStrictlyMonotonic() {
        var previous: CGFloat = 0
        for height in 280...520 {
            let side = HistoryView.cardSide(height: CGFloat(height))
            #expect(side == CGFloat(height - 72)); #expect(side > previous); previous = side
        }
        #expect(HistoryView.cardSide(height: 280) == 208 && HistoryView.cardSide(height: 340) == 268 && HistoryView.cardSide(height: 520) == 448)
    }
}
