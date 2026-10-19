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
    /// 卡片VoiceOver命名动作：原底栏5个入口，隐藏内容与无文本时按原底栏规则收起，by AI.Coding。
    @Test func cardVoiceOverActionsMatchFooter() {
        #expect(ClipCard.voiceOverActions(kind: .text, hidden: false, favorite: false) == ["详情", "收藏", "原格式复制", "纯文本复制", "直接粘贴"])
        #expect(ClipCard.voiceOverActions(kind: .url, hidden: false, favorite: true) == ["详情", "取消收藏", "原格式复制", "纯文本复制", "直接粘贴"])
        #expect(ClipCard.voiceOverActions(kind: .image, hidden: false, favorite: false) == ["详情", "收藏", "原格式复制", "直接粘贴"])
        #expect(ClipCard.voiceOverActions(kind: .text, hidden: true, favorite: false) == ["原格式复制"])
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
