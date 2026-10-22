// 历史管理窗口模型：页码、总数、筛选、删除撤销与按键路由，不创建窗口，by AI.Coding。
import AppKit
import Combine
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac
@MainActor struct HistoryManagerTests {
    /// 超时记为失败，等待之后没有断言的步骤也不会静默通过。
    private func until(timeout: Duration = .seconds(5), _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { Issue.record("等待条件超时", sourceLocation: sourceLocation) }
    }
    private func make(_ count: Int, raw: RawBoard = RawBoard()) async throws -> (HistoryManagerModel, HistoryStore, ManagerClock, [ClipID], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = ManagerClock(), store = try HistoryStore(location: root, clock: clock)
        var ids: [ClipID] = []
        for index in 0..<count {
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("row-\(index)".utf8))])])), at: clock.now()) else { throw StoreError.ioFailure }
            ids.append(id); clock.advance(1)
        }
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store, clock: clock)
        let history = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture, clock: clock), derived: DerivedContentService(store: store), clock: clock)
        try await history.start(); capture.stop()
        let model = HistoryManagerModel(history: history)
        model.pageSize = 25; model.start()
        try await until { model.rows.count == min(25, count) && model.total == count }
        return (model, store, clock, ids.reversed(), root)
    }
    /// 写入发出的存储事件异步送达；负载下可能晚于随后的“选择全部”，被当成历史变化作废全选。
    /// 等模型处理完事件（事件触发后台刷新，读到刷新查询即已处理）再继续，不按固定时长等待。
    private func afterChange<T: Sendable>(_ model: HistoryManagerModel, _ write: () async throws -> T) async throws -> T {
        var searched = false
        let hook = model.readHook
        model.readHook = { kind, request in if kind == .search { searched = true }; try await hook?(kind, request) }
        defer { model.readHook = hook }
        let value = try await write()
        try await until { searched && !model.refreshing }
        return value
    }
    @Test func pagesTotalsAndPageSizes() async throws {
        let (model, _, _, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(model.rows.map(\.id) == Array(newest[0..<25]) && model.pageCount == 3 && model.rangeText == "1–25，共 60 条")
        model.go(toPage: 2)
        try await until { model.rows.count == 10 }
        #expect(model.rows.map(\.id) == Array(newest[50...]) && model.rangeText == "51–60，共 60 条")
        // 每页100需两次取页；改每页回到首页。
        model.pageSize = 100
        try await until { model.rows.count == 60 }
        #expect(model.page == 0 && model.pageCount == 1)
        model.literal = "row-5"
        try await until { model.total == 11 }
        #expect(model.rows.count == 11)
    }
    @Test func scopeAndCategoryMemberships() async throws {
        let (model, store, _, newest, root) = try await make(5)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let category = try await store.createCategory(name: "工作", colorHex: "007AFF")
        _ = try await store.apply(try await store.preview(.category([newest[1]], category.id, true)).token)
        try await until { model.memberships[newest[1]] == [category.id] }
        model.scope = .category(category.id)
        try await until { model.rows.map(\.id) == [newest[1]] }
        #expect(model.total == 1)
        model.scope = .kind(.image)
        try await until { model.total == 0 }
        model.scope = .all; model.time = .today
        try await until { model.total == 5 }
        #expect(model.total == 5 && model.rows.count == 5)
    }
    @Test func deleteClampsPageAndUndoRestores() async throws {
        let (model, _, _, newest, root) = try await make(26)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.go(toPage: 1)
        try await until { model.rows.map(\.id) == [newest[25]] }
        model.selection = [newest[25]]
        // 文字编辑中⌫交给文本框；结果区才删除。
        #expect(!model.handleKey(code: 51, flags: [], editing: true))
        #expect(model.handleKey(code: 51, flags: [], editing: false))
        try await until { model.page == 0 && model.total == 25 }
        #expect(model.rows.count == 25 && model.canUndo && model.toast?.undo == true)
        #expect(model.handleKey(code: 6, flags: .command, editing: false))
        try await until { model.total == 26 }
        #expect(model.total == 26 && !model.canUndo && model.toast?.text == "已撤销删除")
    }
    @Test func escapeClearsOnlyMultiSelection() async throws {
        let (model, _, _, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[0]]
        #expect(!model.handleKey(code: 53, flags: [], editing: false))
        model.selection = [newest[0], newest[1]]
        #expect(model.targetIDs == [newest[0], newest[1]])
        #expect(model.handleKey(code: 53, flags: [], editing: false) && model.selection.isEmpty)
        model.selectAllMatching()
        try await until { model.allMatching?.count == 3 }
        #expect(model.targetIDs == newest)
    }
    @Test func revealJumpsToRecordPage() async throws {
        let (model, _, _, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.literal = "row-1"; try await until { model.total == 11 }
        model.reveal([newest[55], newest[56]])
        try await until { model.selection == [newest[55], newest[56]] }
        #expect(model.page == 2 && model.literal.isEmpty && model.total == 60)
    }
    @Test func hiddenContentsBlocksWrites() async throws {
        let (model, _, _, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[0]]
        model.history.updateSettings { $0.hideContents = true }
        try await until { !model.history.canDisplayContents }
        #expect(!model.handleKey(code: 51, flags: [], editing: false))
        #expect(!model.handleKey(code: 2, flags: .command, editing: false))
        model.delete([newest[0]]); model.selectAllMatching()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.total == 3 && model.allMatching == nil && !model.selectingAll)
    }
    @Test func repeatedDeleteKeepsUndo() async throws {
        let (model, store, _, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[0]]
        #expect(model.handleKey(code: 51, flags: [], editing: false) && model.handleKey(code: 51, flags: [], editing: false))
        try await until { model.total == 2 && model.toast?.undo == true }
        // 提交前已移出选择；之后再按⌫没有目标。
        #expect(model.selection.isEmpty)
        _ = model.handleKey(code: 51, flags: [], editing: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await store.undoAvailable() && model.toast?.undo == true)
    }
    @Test func selectAllCancelledByFilterChange() async throws {
        let (model, _, _, _, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selectAllMatching()
        #expect(model.selectingAll)
        model.scope = .favorites
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.allMatching == nil && !model.selectingAll)
    }
    @Test func hundredPerPageUsesTwoReads() async throws {
        let (model, _, _, newest, root) = try await make(160)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.pageSize = 100
        try await until { model.rows.count == 100 }
        #expect(model.rows.map(\.id) == Array(newest[0..<100]))
        model.go(toPage: 1)
        try await until { model.rows.count == 60 }
        #expect(model.rows.map(\.id) == Array(newest[100...]))
    }
    @Test func unrelatedCaptureDoesNotReloadDetail() async throws {
        let (model, store, clock, newest, root) = try await make(3)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selection = [newest[1]]
        try await until { model.detail?.detail.summary.id == newest[1] }
        let loads = model.detailLoads
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("new".utf8))])])), at: clock.now())
        try await until { model.total == 4 }
        #expect(model.detailLoads == loads && model.selection == [newest[1]])
    }
    @Test func copyKeysYieldWithoutSelectionOrToTextSelection() async throws {
        let (model, _, _, _, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(!model.handleKey(code: 8, flags: .command, editing: false))
        let text = NSTextView(); text.isEditable = false; text.string = "abc"
        #expect(!AppDelegate.managerTextOwnsKeys(text) && !AppDelegate.managerTextOwnsKeys(nil))
        text.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(AppDelegate.managerTextOwnsKeys(text))
    }
    private func ingest(_ store: HistoryStore, _ clock: ManagerClock, _ text: String) async throws -> ClipID {
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: clock.now()) else { throw StoreError.ioFailure }
        clock.advance(1); return id
    }
    // #1 隐藏内容：编辑附页收起但草稿保留，确认期间被隐藏视为取消由写入守卫覆盖。
    @Test func hiddenContentsKeepsEditorDraft() async throws {
        let (model, _, _, newest, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.beginEdit(newest[0]); try await until { model.editor != nil }
        model.editor?.text = "草稿"
        model.history.updateSettings { $0.hideContents = true }
        try await until { !model.history.canDisplayContents }
        #expect(!model.editorPresented && model.editor?.text == "草稿")
        model.history.updateSettings { $0.hideContents = false }
        try await until { model.history.canDisplayContents }
        #expect(model.editorPresented && model.editor?.text == "草稿")
    }
    // #2 跨页目标：分类与名单覆盖完整集合；时钟走动不改冻结的条件；历史变化后作废。
    @Test func selectAllCarriesFullMetadataAndExpires() async throws {
        let (model, store, clock, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let category = try await store.createCategory(name: "C", colorHex: "007AFF")
        _ = try await store.apply(try await store.preview(.category(newest, category.id, true)).token)
        try await until { model.memberships[newest[0]] == [category.id] }
        model.time = .week; try await until { model.total == 60 }
        clock.autoAdvance = true
        model.selection = [newest[0], newest[1]]
        model.selectAllMatching()
        try await until { model.allMatching?.count == 60 }
        #expect(model.targetIDs.allSatisfy { model.categoryIDs(of: $0).contains(category.id) })
        #expect(model.selectionSummary.count == 60 && model.selectionSummary.categories[category.id] == 60)
        clock.autoAdvance = false
        _ = try await ingest(store, clock, "late")
        try await until { model.allMatching == nil }
        #expect(model.allMatching == nil && model.selectionSummary.count == 0)
    }
    @Test func selectAllCancelledByCloseAndPaging() async throws {
        let (model, _, _, _, root) = try await make(120)
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectAllMatching(); model.go(toPage: 1)
        #expect(!model.selectingAll)
        model.selectAllMatching(); model.stop()
        #expect(!model.selectingAll)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.allMatching == nil)
    }
    // #3 面板隐藏时新建分类立即进入共享列表，默认颜色随之轮换，重名被拒绝。
    @Test func createCategoryRefreshesWhilePanelHidden() async throws {
        let (model, _, _, _, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.history.panelVisibilityChanged(false)
        let color = model.history.nextCategoryColor
        #expect(await model.createCategory("新分类") == nil)
        #expect(model.history.categories.map(\.name) == ["新分类"] && model.history.nextCategoryColor != color)
        // 重名原因交给分类编辑弹窗显示；弹窗选的颜色照用。
        #expect(await model.createCategory(" 新分类 ") != nil && model.history.categories.count == 1)
        #expect(await model.createCategory("  ") == "请输入分类名称")
        #expect(await model.createCategory("红", color: "FF3B30") == nil && model.history.categories.first { $0.name == "红" }?.colorHex.uppercased() == "FF3B30")
    }
    /// 分类改名使用临时库与模型，不打开浮层；验证共享刷新、失败保留和离开保护。
    @Test func categoryRenamePreservesIdentityAndDraftProtection() async throws {
        let (model, store, _, ids, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(await model.createCategory("备忘", color: "007AFF") == nil)
        #expect(await model.createCategory("工作") == nil)
        let category = try #require(model.history.categories.first { $0.name == "备忘" })
        let other = try #require(model.history.categories.first { $0.name == "工作" })
        _ = try await store.apply(try await store.preview(.category(ids, category.id, true)).token)
        model.beginCategoryRename(category)
        #expect(model.scope == .category(category.id) && !model.history.surfaceEdits.hasChanges(.manager))
        model.categoryEditorShown = false; model.beginCategoryRename(other)
        #expect(model.categoryBeingEdited?.id == other.id && model.scope == .category(other.id))
        model.beginCategoryRename(category)
        model.categoryName = "临时草稿"; model.categoryEditorShown = false
        model.beginCategoryRename(other)
        #expect(model.categoryBeingEdited?.id == category.id && model.categoryName == "临时草稿" && model.categoryEditorShown)
        #expect(model.history.surfaceEdits.hasChanges(.manager) && !model.history.surfaceEdits.hasChanges(.cards))
        #expect(await model.history.surfaceEdits.resolve(.manager, choose: { _ in .cancel }) == false)
        #expect(model.categoryName == "临时草稿")
        model.categoryName = "工作"
        #expect(await model.saveCategoryRename() == false)
        #expect(!model.categoryError.isEmpty && model.categoryEditorShown)
        model.categoryName = "新备忘"
        #expect(await model.history.surfaceEdits.resolve(.manager, choose: { _ in .save }))
        #expect(model.categoryBeingEdited == nil && !model.history.surfaceEdits.hasChanges(.manager))
        let saved = try #require(model.history.categories.first { $0.id == category.id })
        #expect(saved.name == "新备忘" && saved.colorHex == category.colorHex)
        #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == ids)
        model.beginCategoryRename(saved); model.categoryName = "不保存"
        #expect(await model.history.surfaceEdits.resolve(.manager, choose: { _ in .discard }))
        #expect(try await store.categories().first { $0.id == category.id }?.name == "新备忘")
    }
    // #4 定位失败给出准确提示；途中换条件即放弃定位。
    @Test func revealMissingAndInterrupted() async throws {
        let (model, _, _, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.reveal(["missing"])
        try await until { model.toast != nil }
        #expect(model.toast?.text == "记录已删除或已过期" && model.selection.isEmpty)
        model.toast = nil
        model.reveal([newest[55]]); model.scope = .favorites
        try await until { model.total == 0 && model.rows.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.selection.isEmpty && model.toast == nil && model.page == 0)
    }
    // #5 附页、子窗口按归属认领；无关窗口与空值不认领。
    @Test func managerOwnershipCoversOnlyItsWindows() {
        let manager = NSWindow(), other = NSWindow()
        #expect(AppDelegate.ownedBy(manager, manager) && !AppDelegate.ownedBy(other, manager))
        #expect(!AppDelegate.ownedBy(nil, manager) && !AppDelegate.ownedBy(manager, nil))
        #expect(!AppDelegate.ownsHistoryWindow(manager, panel: other, settings: nil, feedback: nil, showingDetail: true, showingCategoryEditor: false, showingFilters: false, manager: manager))
    }
    // #6 每页100：首页精确100个唯一ID，末页25个，两页无重叠。
    @Test func hundredPerPageStaticPages() async throws {
        let (model, _, _, newest, root) = try await make(125)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.pageSize = 100
        try await until { model.rows.count == 100 }
        let first = model.rows.map(\.id)
        model.go(toPage: 1)
        try await until { model.rows.count == 25 }
        #expect(first == Array(newest[0..<100]) && Set(first).count == 100)
        #expect(model.rows.map(\.id) == Array(newest[100...]) && Set(first).isDisjoint(with: model.rows.map(\.id)))
    }
    // #7 保存同步锁定并冻结正文：保存中不能放弃或重复提交，提交内容是发起时的草稿。
    @Test func saveLocksDraftSynchronously() async throws {
        let (model, store, clock, newest, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.beginEdit(newest[0]); try await until { model.editor != nil }
        let editor = try #require(model.editor)
        editor.text = "发起时"
        model.saveEdit()
        #expect(editor.saving && editor.save(to: store) == nil)
        model.discardEdit()
        #expect(model.editor === editor)
        editor.text = "之后改动"
        try await until { model.editor == nil }
        #expect(try await store.detail(id: newest[0], at: clock.now()).payload.plainText == "发起时")
    }
    // #8 重开窗口读取真实撤销状态；管理窗口删除使面板旧的搜索撤销资格失效。
    @Test func undoStateOnStartAndSearchUndoOwnership() async throws {
        let (model, _, _, newest, root) = try await make(3)
        defer { try? FileManager.default.removeItem(at: root) }
        model.history.change(.delete([newest[0]]))
        try await until { model.history.recordUndoQuery != nil }
        model.delete([newest[1]])
        try await until { model.total == 1 }
        #expect(model.history.recordUndoQuery == nil && model.history.canUndoDeletion)
        model.stop()
        let reopened = HistoryManagerModel(history: model.history); reopened.start()
        defer { reopened.stop() }
        try await until { reopened.canUndo }
        #expect(reopened.canUndo)
    }
    // #9/R5 旧名称回写不覆盖更新的提交或草稿；失败保留草稿；规范化后显示；交错提交。
    @Test func renameEchoKeepsNewDraft() {
        typealias Draft = HistoryManagerModel.NameDraft
        // 先后提交 A、AB，A 的回写到达时不能把输入框改回 A。
        var draft = Draft(nil)
        draft.text = "A"; #expect(draft.submit(current: nil) == "A")
        draft.text = "AB"; #expect(draft.submit(current: nil) == "AB")
        draft.titleChanged(from: nil, to: "A"); #expect(draft.text == "AB")
        draft.finished("A"); draft.titleChanged(from: "A", to: "AB"); draft.finished("AB")
        #expect(draft.text == "AB" && draft.pending.isEmpty)
        // 只提交 AB 时外部或旧回写 A 不覆盖；写入结束前后到达的旧读取同样不覆盖。
        draft = Draft("X"); draft.text = "AB"; _ = draft.submit(current: "X")
        draft.titleChanged(from: "X", to: "A"); #expect(draft.text == "AB")
        draft.finished("AB"); draft.titleChanged(from: "A", to: "A2"); #expect(draft.text == "AB")
        // 失败：草稿保留，可再次提交。
        draft = Draft("旧"); draft.text = "新"; _ = draft.submit(current: "旧")
        draft.finished("新"); draft.titleChanged(from: "旧", to: "旧")
        #expect(draft.text == "新" && draft.submit(current: "旧") == "新")
        // 规范化：去首尾空白并组合字符；与当前名称相同不写入。
        draft = Draft("A"); draft.text = "  e\u{301} "
        #expect(draft.submit(current: "A") == "\u{e9}" && draft.text == "\u{e9}")
        draft = Draft("A"); draft.text = " A "; #expect(draft.submit(current: "A") == nil && draft.text == "A")
        // 空闲时外部改名跟随；继续输入的草稿不被覆盖。
        draft = Draft(nil); draft.titleChanged(from: nil, to: "外部"); #expect(draft.text == "外部")
        draft.text = "改了"; draft.titleChanged(from: "外部", to: "外部2"); #expect(draft.text == "改了")
    }
    // R5 交错提交经真实存储与发布的回写：输入框始终为最后一次提交；失败返回 false 并提示。
    @Test func interleavedRenamesKeepLatest() async throws {
        let (model, store, clock, newest, root) = try await make(1)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        final class Box { var draft = HistoryManagerModel.NameDraft(nil); var last: String?; var seen: [String?] = [] }
        let box = Box()
        let watch = model.$rows.map { $0.first?.title }.removeDuplicates().dropFirst().sink { title in
            box.draft.titleChanged(from: box.last, to: title); box.last = title; box.seen.append(title)
        }
        defer { watch.cancel() }
        box.draft.text = "A"; let a = box.draft.submit(current: nil)
        box.draft.text = "AB"; let ab = box.draft.submit(current: nil)
        #expect(a == "A" && ab == "AB")
        let first = Task { await model.rename(newest[0], "A") }, second = Task { await model.rename(newest[0], "AB") }
        let ok = await (first.value, second.value)
        box.draft.finished("A"); box.draft.finished("AB")
        try await until { box.last == "AB" }
        #expect(ok == (true, true) && box.draft.text == "AB" && box.draft.pending.isEmpty)
        #expect(!(await model.rename(newest[0], String(repeating: "x", count: 2000))) && model.toast?.failed == true)
        #expect(try await store.detail(id: newest[0], at: clock.now()).summary.title == "AB")
    }
    /// 已在途的旧任务完成：存储串行，之后的读取返回时旧读取已结束。
    private func settle(_ store: HistoryStore) async throws {
        _ = try await store.search(SearchRequest()); await Task.yield(); await Task.yield()
    }
    private func favoriteCount(_ store: HistoryStore) async throws -> Int {
        var request = SearchRequest(favorites: true, pageSize: 1); request.countTotal = true
        return try await store.search(request).total ?? -1
    }

    // R1 换条件立即清空旧结果进入加载，查询未返回前不显示空态。
    @Test func conditionChangeShowsLoadingNotStaleRows() async throws {
        let (model, _, _, _, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        model.readHook = { kind, _ in if kind == .search { await gate.wait() } }
        model.literal = "row-1"
        #expect(model.rows.isEmpty && model.loading && !model.failed && model.rangeText == "正在加载…")
        try await until { gate.arrivals == 1 }
        #expect(model.rows.isEmpty && model.loading)
        gate.open()
        try await until { !model.loading }
        #expect(model.total == 11 && model.rows.allSatisfy { $0.preview.hasPrefix("row-1") } && !model.failed)
    }
    // R1 同条件后台刷新失败保留内容并标记失败；重试立即进入等待；无内容时重试进入加载。
    @Test func refreshFailureKeepsRowsAndRetryWaits() async throws {
        let (model, store, clock, _, root) = try await make(5)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        var fail = true
        let gate = Gate()
        model.readHook = { kind, _ in
            guard kind == .search else { return }
            if fail { throw StoreError.ioFailure }
            await gate.wait()
        }
        _ = try await ingest(store, clock, "new")
        try await until { model.failed }
        #expect(model.rows.count == 5 && !model.loading && !model.refreshing)
        fail = false
        model.retry()
        #expect(!model.failed && model.refreshing && model.rows.count == 5)
        try await until { gate.arrivals == 1 }
        gate.open()
        try await until { model.total == 6 }
        #expect(!model.refreshing && !model.failed && model.rows.count == 6)
        // 换条件失败：无内容可留，重试同步进入加载。
        fail = true; model.literal = "row-2"
        try await until { model.failed }
        #expect(model.rows.isEmpty && !model.loading)
        fail = false; model.retry()
        #expect(model.loading && !model.failed)
        try await until { !model.loading }
        #expect(model.total == 1 && !model.failed)
    }
    // R1 被取代的旧查询晚到的成功或失败都不覆盖新条件的结果与状态。
    @Test(arguments: [true, false])
    func staleQueryCannotOverwriteNewer(_ oldFails: Bool) async throws {
        let (model, store, _, _, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        model.readHook = { kind, request in
            guard kind == .search, request?.literal == "row-1" else { return }
            await gate.wait()
            if oldFails { throw StoreError.ioFailure }
        }
        model.literal = "row-1"
        try await until { gate.arrivals == 1 }
        model.literal = "row-2"
        try await until { !model.loading }
        #expect(model.total == 11)
        gate.open()
        try await until { gate.passed == 1 }
        try await settle(store)
        #expect(model.total == 11 && model.rows.allSatisfy { $0.preview.hasPrefix("row-2") } && !model.failed && !model.loading)
    }
    // R2 收集全部期间批量写入在模型层被拒绝，不落到原有两条；取消可用，晚到结果不恢复全选。
    @Test func selectingAllRefusesWrites() async throws {
        let (model, store, _, newest, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let category = try await afterChange(model) { try await store.createCategory(name: "C", colorHex: "007AFF") }
        await model.history.reloadCategories()
        let gate = Gate()
        model.readHook = { kind, _ in if kind == .memberships, model.selectingAll { await gate.wait() } }
        model.selection = [newest[0], newest[1]]
        model.selectAllMatching()
        try await until { gate.arrivals == 1 }
        #expect(model.selectingAll && model.targetIDs.count == 2)
        #expect(model.handleKey(code: 2, flags: .command, editing: false))
        #expect(model.handleKey(code: 51, flags: [], editing: false))
        model.setCategory(model.targetIDs, category.id, true); model.setFavorite(model.targetIDs, true); model.delete(model.targetIDs)
        model.copy(model.targetIDs)
        #expect(model.toast?.text == "正在选择全部…")
        try await settle(store)
        #expect(try await favoriteCount(store) == 0 && model.total == 120)
        #expect(try await store.categoryMemberships([newest[0], newest[1]]).isEmpty)
        model.clearSelection()
        #expect(!model.selectingAll)
        gate.open()
        try await until { gate.passed == 1 }
        try await settle(store)
        #expect(model.allMatching == nil && !model.selectingAll && model.targetIDs.isEmpty)
    }
    // R3 收集中途历史变化：立即取消全选，不依赖刷新查询完成。
    @Test func storeChangeExpiresSelectAllDuringCollection() async throws {
        let (model, store, clock, _, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let collect = Gate(), refresh = Gate()
        model.readHook = { kind, _ in
            if kind == .memberships, model.selectingAll { await collect.wait() }
            if kind == .search, !model.selectingAll { await refresh.wait() }
        }
        model.selectAllMatching()
        try await until { collect.arrivals == 1 }
        _ = try await ingest(store, clock, "late")
        try await until { !model.selectingAll }
        #expect(refresh.passed == 0 && model.allMatching == nil && model.selection.isEmpty && model.toast?.text == "历史已变化，已取消全选，请重新选择")
        collect.open(); refresh.open()
        try await until { model.total == 121 }
        #expect(model.allMatching == nil)
    }
    // R3 收集完成后、或最后一批读取之后历史变化：全选立即作废。
    @Test(arguments: [false, true])
    func storeChangeExpiresSelectAllAfterCollection(_ afterLastRead: Bool) async throws {
        let (model, store, clock, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        var memberships = 0
        let refresh = Gate()
        model.readHook = { kind, _ in
            if kind == .search, !model.selectingAll { await refresh.wait() }
            guard kind == .memberships, model.selectingAll else { return }
            memberships += 1
            // 60条分两批，第二批的搜索已返回，此时写入。
            if afterLastRead, memberships == 2 { _ = try await store.apply(try await store.preview(.favorites([newest[59]], true)).token) }
        }
        model.selectAllMatching()
        if !afterLastRead {
            try await until { model.allMatching?.count == 60 }
            _ = try await ingest(store, clock, "late")
        }
        try await until { model.toast?.text == "历史已变化，已取消全选，请重新选择" }
        #expect(refresh.passed == 0 && model.allMatching == nil && !model.selectingAll && model.selection.isEmpty)
        refresh.open()
    }
    // R3 提交前版本复核：全选收集后变化而事件尚未处理时，提交中止并提示重选，不降级为本页操作。
    @Test func staleSelectAllAbortsCommit() async throws {
        let (model, store, _, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selectAllMatching()
        try await until { model.allMatching?.count == 60 }
        let ids = model.targetIDs, other = newest[0]
        blocking { _ = try await store.apply(try await store.preview(.favorites([other], true)).token) }
        model.setFavorite(ids, true)
        try await until { model.toast?.text == "全选结果已过期，请重新选择" }
        #expect(try await favoriteCount(store) == 1 && model.allMatching == nil && model.selection.isEmpty)
    }
    // R4 窗口打开期间出现的新来源进入列表；来源筛选与 app: 结果一致；未知来源不退化为全库查询，已知来源采集不重读来源。
    @Test func newSourceAppearsAndUnknownAppBlocks() async throws {
        let raw = RawBoard()
        let (model, _, _, _, root) = try await make(3, raw: raw)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        var sourceReads = 0
        model.readHook = { kind, _ in if kind == .sources { sourceReads += 1 } }
        func copy(_ text: String, from bundleID: String) {
            raw.count += 1; raw.items = [[SupportedType.string: Data(text.utf8), "org.nspasteboard.source": Data(bundleID.utf8)]]
            model.history.capture.tick()
        }
        copy("from-b", from: "test.localclip.beta")
        try await until { model.sources.contains { $0.bundleID == "test.localclip.beta" } && model.total == 4 }
        let reads = sourceReads
        copy("from-b-2", from: "test.localclip.beta")
        try await until { model.total == 5 }
        #expect(sourceReads == reads)
        model.source = "test.localclip.beta"
        try await until { !model.loading }
        let filtered = model.rows.map(\.id)
        model.source = nil; model.literal = "app:test.localclip.beta"
        try await until { !model.loading }
        #expect(filtered.count == 2 && model.rows.map(\.id) == filtered && model.queryProblems.isEmpty)
        model.literal = "app:nothing"
        try await until { !model.loading }
        #expect(model.rows.isEmpty && model.total == 0 && model.queryProblems == ["未找到来源 nothing"])
        model.selectAllMatching()
        #expect(!model.selectingAll && model.allMatching == nil)
        copy("from-b2", from: "test.localclip.betb")
        try await until { model.sources.contains { $0.bundleID == "test.localclip.betb" } }
        model.literal = "app:test.localclip.bet"
        try await until { !model.loading }
        #expect(model.rows.isEmpty && model.queryProblems.first?.hasPrefix("来源“test.localclip.bet”匹配多个") == true)
    }
    // R6 跨页全选时 ⌘D 依据完整目标集合的收藏状态，不读正文、不额外查询。
    @Test func favoriteToggleUsesFullSelectAll() async throws {
        let (model, store, _, newest, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        // 本页25条全部已收藏，其余未收藏。
        _ = try await store.apply(try await store.preview(.favorites(Array(newest[0..<25]), true)).token)
        try await until { model.rows.allSatisfy(\.isFavorite) }
        for expected in [120, 0] {
            model.selectAllMatching()
            try await until { model.allMatching?.count == 120 }
            var reads = 0
            let detailLoads = model.detailLoads
            model.readHook = { _, _ in reads += 1 }
            #expect(model.handleKey(code: 2, flags: .command, editing: false))
            #expect(reads == 0 && model.detailLoads == detailLoads)
            model.readHook = nil
            try await until { model.allMatching == nil && model.toast != nil }
            #expect(try await favoriteCount(store) == expected)
            try await until { model.rows.allSatisfy { $0.isFavorite == (expected == 120) } }
        }
    }
    private func picture(_ store: HistoryStore, _ clock: ManagerClock, _ byte: UInt8) async throws -> (ClipID, String) {
        let png = Data(repeating: byte, count: 64)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, png)])])), at: clock.now()) else { throw StoreError.ioFailure }
        clock.advance(1); return (id, ContentFingerprint.hash(png))
    }
    /// 图片入库并开启图片文字搜索后等后台刷新结束，之后的读取计数只属于测试步骤。
    private func enableImageText(_ model: HistoryManagerModel, _ store: HistoryStore, count: Int) async throws {
        var searches = 0
        model.readHook = { kind, _ in if kind == .search { searches += 1 } }
        var settings = try await store.settings(); settings.imageTextSearchSince = 1
        _ = try await store.updateCaptureSettings(settings)
        try await until { searches >= 1 && !model.refreshing && model.total == count }
        model.readHook = nil
    }
    // R7 无关图片文字更新：浏览两段取页不失败、不重读；依赖图片文字的字面检索重取整页、只发布一次。
    @Test func imageTextUpdateAffectsOnlyLiteralPages() async throws {
        let (model, store, clock, _, root) = try await make(130)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.pageSize = 100
        try await until { model.rows.count == 100 }
        let (first, firstDigest) = try await picture(store, clock, 7), (second, secondDigest) = try await picture(store, clock, 8)
        try await enableImageText(model, store, count: 132)
        var searches = 0, held = false
        let gate = Gate()
        model.readHook = { kind, request in
            guard kind == .search else { return }
            searches += 1
            if request?.cursor != nil, !held { held = true; await gate.wait() }
        }
        model.reload()
        try await until { gate.arrivals == 1 }
        #expect(try await store.saveImageText(.init(clipID: first, itemIndex: 0), digest: firstDigest, text: "unrelated"))
        gate.open()
        try await until { !model.loading }
        #expect(searches == 2 && model.rows.count == 100 && !model.failed && model.toast == nil)
        // 字面检索：第二段期间图片文字变为匹配，丢弃首段重取，不发布混合结果。
        var published = 0
        let watch = model.$rows.dropFirst().sink { if !$0.isEmpty { published += 1 } }
        defer { watch.cancel() }
        searches = 0; held = false
        let literal = Gate()
        model.readHook = { kind, request in
            guard kind == .search else { return }
            searches += 1
            if request?.cursor != nil, !held { held = true; await literal.wait() }
        }
        model.literal = "row-"
        try await until { literal.arrivals == 1 }
        #expect(try await store.saveImageText(.init(clipID: second, itemIndex: 0), digest: secondDigest, text: "row-ocr"))
        literal.open()
        try await until { !model.loading }
        #expect(searches == 4 && published == 1 && model.total == 131 && model.rows.count == 100 && !model.failed)
    }
    // R7 全选：浏览收集不受图片文字更新影响；字面收集遇到代次变化失败提示，不发布混合集合。
    @Test func imageTextUpdateDuringSelectAll() async throws {
        let (model, store, clock, _, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let (first, firstDigest) = try await picture(store, clock, 7), (second, secondDigest) = try await picture(store, clock, 8)
        try await enableImageText(model, store, count: 122)
        for (literal, id, digest) in [("", first, firstDigest), ("row-", second, secondDigest)] {
            // 第一张图的文字已匹配“row-”。
            if !literal.isEmpty { model.literal = literal; try await until { !model.loading && model.total == 121 } }
            let gate = Gate()
            model.readHook = { kind, _ in if kind == .memberships, model.selectingAll, gate.arrivals == 0 { await gate.wait() } }
            model.selectAllMatching()
            try await until { gate.arrivals == 1 }
            #expect(try await store.saveImageText(.init(clipID: id, itemIndex: 0), digest: digest, text: "row-ocr"))
            gate.open()
            try await until { !model.selectingAll }
            model.readHook = nil
            if literal.isEmpty { #expect(model.allMatching?.count == 122 && Set(model.allMatching ?? []).count == 122) }
            else { #expect(model.allMatching == nil && model.toast?.text == "选择全部失败：记录已变化，请重新选择") }
        }
    }
    /// 约1000条经模型完整链路“选择全部”（浏览与字面）：重复采样完整收集耗时、数量、唯一性与读取次数；
    /// 第5批读取处用屏障取消，等待被取消任务自身结束后再报告退出时延与取消后的读取；只打印测量值，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_MANAGER_PERF"] == "1"))
    func thousandSelectAll() async throws {
        let (model, _, _, _, root) = try await make(1_000)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        for literal in ["", "row-"] {
            if !literal.isEmpty { model.literal = literal; try await until(timeout: .seconds(30)) { !model.loading && model.total == 1_000 } }
            for sample in 1...3 {
                var searches = 0, memberships = 0
                model.readHook = { kind, _ in if kind == .search { searches += 1 } else if kind == .memberships { memberships += 1 } }
                let started = ContinuousClock.now
                model.selectAllMatching()
                try await until(timeout: .seconds(60)) { !model.selectingAll }
                let elapsed = ms(ContinuousClock.now - started)
                let ids = model.allMatching ?? []
                print("manager-perf select-all literal=\"\(literal)\" sample=\(sample) ms=\(String(format: "%.1f", elapsed)) count=\(ids.count) unique=\(Set(ids).count) summary=\(model.selectionSummary.count) searches=\(searches) memberships=\(memberships)")
                #expect(ids.count == 1_000 && Set(ids).count == 1_000 && model.selectionSummary.count == 1_000)
                model.clearSelection()
            }
            // 第5批搜索前挂起，取消后放行；等待任务本身结束。
            let gate = Gate()
            var searches = 0, memberships = 0
            model.readHook = { kind, _ in
                if kind == .search { searches += 1; if searches == 5 { await gate.wait() } } else if kind == .memberships { memberships += 1 }
            }
            model.selectAllMatching()
            try await until { gate.arrivals == 1 }
            let task = try #require(model.selectAllTaskForTesting)
            let atCancel = (searches, memberships)
            model.clearSelection()
            let cancelled = ContinuousClock.now
            gate.open()
            await task.value
            let exit = ms(ContinuousClock.now - cancelled)
            print("manager-perf select-all-cancel literal=\"\(literal)\" exit_ms=\(String(format: "%.1f", exit)) at_cancel=\(atCancel) after_exit=\((searches, memberships))")
            #expect(!model.selectingAll && model.allMatching == nil && model.targetIDs.isEmpty)
            model.readHook = nil
        }
    }
    // R3 全选失败（图片文字代次变化或读取失败）：跨页集合与原页内选择一并清除，原2条不能再被批量操作，存储不变；可重新选择全部。
    @Test(arguments: [true, false])
    func selectAllFailureClearsLocalSelection(_ imageText: Bool) async throws {
        let (model, store, clock, _, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let category = try await afterChange(model) { try await store.createCategory(name: "C", colorHex: "007AFF") }
        await model.history.reloadCategories()
        let (picture, digest) = try await picture(store, clock, 7)
        try await enableImageText(model, store, count: 121)
        model.literal = "row-"
        try await until { !model.loading && model.total == 120 }
        let picked = [model.rows[0].id, model.rows[1].id]
        model.selection = Set(picked)
        let gate = Gate()
        var failNext = !imageText
        model.readHook = { kind, _ in
            guard kind == .memberships, model.selectingAll, gate.arrivals == 0 else { return }
            await gate.wait()
            if failNext { failNext = false; throw StoreError.ioFailure }
        }
        model.selectAllMatching()
        try await until { gate.arrivals == 1 }
        if imageText { #expect(try await store.saveImageText(.init(clipID: picture, itemIndex: 0), digest: digest, text: "row-ocr")) }
        gate.open()
        try await until { !model.selectingAll }
        #expect(model.toast?.text == "选择全部失败：记录已变化，请重新选择" && model.toast?.failed == true)
        #expect(model.allMatching == nil && model.selection.isEmpty && model.targetIDs.isEmpty)
        _ = model.handleKey(code: 2, flags: .command, editing: false)
        _ = model.handleKey(code: 51, flags: [], editing: false)
        model.setCategory(model.targetIDs, category.id, true)
        try await settle(store)
        var all = SearchRequest(pageSize: 1); all.countTotal = true
        let stored = try await store.search(all).total
        #expect(try await favoriteCount(store) == 0 && stored == 121)
        let undo = await store.undoAvailable()
        #expect(try await store.categoryMemberships(picked).isEmpty && !undo)
        model.readHook = nil
        model.selectAllMatching()
        try await until { !model.selectingAll }
        #expect(model.allMatching?.count == (imageText ? 121 : 120))
    }
    // UX 另一实例写入不产生本窗口事件：后台刷新发现版本变化时作废全选也要提示，不静默清除。
    @Test func refreshNoticesExternalChangeDuringSelectAll() async throws {
        let (model, _, clock, _, root) = try await make(30)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.selectAllMatching()
        try await until { model.allMatching?.count == 30 }
        let other = try HistoryStore(location: root, clock: clock)
        _ = try await ingest(other, clock, "external")
        model.reload(background: true)
        try await until { model.allMatching == nil }
        #expect(model.selection.isEmpty && model.toast?.text == "历史已变化，已取消全选，请重新选择")
    }
    // UX2 多选汇总：本页按当前行统计；跨页全选在收集循环里同步统计；作废后清空。
    @Test func selectionSummaryCoversPageAndSelectAll() async throws {
        let (model, store, _, newest, root) = try await make(30)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        _ = try await store.apply(try await store.preview(.favorites([newest[0], newest[29]], true)).token)
        try await until { model.rows.first?.isFavorite == true }
        let times = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.lastCopiedAt) })
        model.selection = [newest[0], newest[1]]
        var summary = model.selectionSummary
        #expect(summary.count == 2 && summary.kinds[.text] == 2 && summary.favorites == 1)
        #expect(summary.earliest == times[newest[1]] && summary.latest == times[newest[0]])
        model.selectAllMatching()
        try await until { model.allMatching?.count == 30 }
        summary = model.selectionSummary
        #expect(summary.count == 30 && summary.kinds == [.text: 30] && summary.favorites == 2 && summary.latest == times[newest[0]])
        #expect(summary.earliest.map { $0 < times[newest[24]]! } == true)
        model.clearSelection()
        #expect(model.selectionSummary == .init())
    }
    // UX2 来源未知只显示“来源未知”，不拼成“未知 · 来源未知”。
    @Test func unknownSourceIsNotRepeated() {
        #expect(HistoryView.sourceDescription(.unknown) == "来源未知" && HistoryView.sourceName(.unknown) == "来源未知")
        let app = SourceAttribution(bundleID: "com.tencent.xinWeChat", name: "微信", basis: "frontmost")
        #expect(HistoryView.sourceDescription(app) == "微信 · 复制时前台应用推断" && HistoryView.sourceName(app) == "微信")
    }
    // UX 本页全选不是跨页全选：新采集只刷新列表，不清除也不提示，已选记录仍在。
    @Test func captureKeepsPageSelection() async throws {
        let (model, store, clock, newest, root) = try await make(10)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.setPageChecked(true)
        let added = try await ingest(store, clock, "new capture")
        try await until { model.rows.first?.id == added }
        #expect(model.selection == Set(newest) && model.toast == nil && model.allMatching == nil)
    }
    // UX 跨页全选时可见行都显示勾选；取消一行退回本页其余记录；“选择本页全部”切换本页。
    @Test func checkboxesReflectSelectAllAndPage() async throws {
        let (model, _, _, newest, root) = try await make(30)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(!model.pageChecked)
        model.setPageChecked(true)
        #expect(model.selection == Set(newest[0..<25]) && model.pageChecked)
        model.selectAllMatching()
        try await until { model.allMatching?.count == 30 }
        #expect(model.rows.allSatisfy { model.isChecked($0.id) } && model.pageChecked)
        model.setChecked(newest[0], false)
        #expect(model.allMatching == nil && model.selection == Set(newest[1..<25]) && !model.isChecked(newest[0]))
        model.setChecked(newest[0], true)
        #expect(model.pageChecked)
        model.setPageChecked(false)
        #expect(model.selection.isEmpty && model.allMatching == nil)
    }
    // UX 勾选列连击被表格当作行点击：按勾选切换，保留其余勾选；普通行点击照常改选。
    @Test func checkboxDoubleClickTogglesInsteadOfReplacing() async throws {
        let (model, _, _, newest, root) = try await make(5)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.setChecked(newest[0], true)
        model.tableSelected([newest[1]], checkboxClick: true)
        #expect(model.selection == [newest[0], newest[1]])
        model.tableSelected([newest[0]], checkboxClick: true)
        #expect(model.selection == [newest[1]])
        model.tableSelected([newest[2]], checkboxClick: false)
        #expect(model.selection == [newest[2]])
    }
    // 窗口不显示：挂上内容时不先缩小，首次布局即按默认尺寸，检查器取理想宽度。
    @Test func defaultWindowSizeMatchesPrototype() {
        #expect(HistoryManagerWindow.defaultSize == NSSize(width: 1180, height: 820))
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(HistoryManagerWindow.autosaveName)")
        let content = NSViewController(); content.view = NSView()
        let window = HistoryManagerWindow(content: content)
        defer { window.close(); UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(HistoryManagerWindow.autosaveName)") }
        #expect(content.view.frame.size == HistoryManagerWindow.defaultSize && !window.isVisible)
    }
    // B3 SwiftUI 检查器首次出现落在最小宽度；窗口把它放到理想宽度，之后仍可拖到最小值。隐藏窗口，不上屏。
    @Test func inspectorOpensAtIdealWidth() async throws {
        let (model, _, _, _, root) = try await make(5)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(HistoryManagerWindow.autosaveName)")
        let host = NSHostingController(rootView: HistoryManagerView(model: model, history: model.history))
        host.sceneBridgingOptions = [.toolbars, .title]; host.sizingOptions = []
        let window = HistoryManagerWindow(content: host)
        defer { window.close(); UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(HistoryManagerWindow.autosaveName)") }
        window.applyInspectorIdealWidth()
        func width() -> CGFloat? { window.contentView?.layoutSubtreeIfNeeded(); return HistoryManagerWindow.inspectorSplit(in: window.contentView)?.arrangedSubviews.last?.frame.width }
        try await until { width() == HistoryManagerWindow.inspectorIdealWidth }
        #expect(!window.isVisible)
        let split = try #require(HistoryManagerWindow.inspectorSplit(in: window.contentView))
        split.setPosition(split.bounds.width - 200, ofDividerAt: 0)
        try await until { width() == 300 }
    }
    // 文件说明纵向固定，曾把检查器最小高度撑过窗口，选中文件行整页被居中上移、侧栏钻到标题栏下。隐藏窗口，不上屏。
    @Test func selectingFileKeepsWindowLayout() async throws {
        let (model, store, clock, _, root) = try await make(2)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("说明.txt")
        try Data("line".utf8).write(to: file)
        guard case .inserted(let id) = try await afterChange(model, {
            try await store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])), at: clock.now())
        }) else { throw StoreError.ioFailure }
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(HistoryManagerWindow.autosaveName)")
        let host = NSHostingController(rootView: HistoryManagerView(model: model, history: model.history))
        host.sceneBridgingOptions = [.toolbars, .title]; host.sizingOptions = []
        let window = HistoryManagerWindow(content: host)
        defer { window.close(); UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(HistoryManagerWindow.autosaveName)") }
        model.selection = [id]
        try await until { model.detail?.detail.summary.id == id }
        func frame() -> NSRect? {
            window.contentView?.layoutSubtreeIfNeeded()
            var queue = [window.contentView].compactMap { $0 }
            while !queue.isEmpty { let view = queue.removeFirst(); if view is NSSplitView { return view.convert(view.bounds, to: nil) }; queue += view.subviews }
            return nil
        }
        // 详情出现后还会再布局几轮，持续核对一段时间而不是只看一次。
        for _ in 0..<20 {
            #expect(frame() == NSRect(origin: .zero, size: HistoryManagerWindow.defaultSize))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!window.isVisible)
    }
    // 定位只来自“在历史管理中显示”：未完成的定位随关闭作废，之后无目标打开不选中任何行。
    @Test func revealDoesNotSurviveReopen() async throws {
        let (model, _, _, newest, root) = try await make(30)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.reveal([newest[3]]); model.stop()
        model.start()
        try await until { !model.loading && model.rows.count == 25 }
        #expect(model.selection.isEmpty && model.page == 0)
    }
    // R3 被取代的旧收集晚到的失败不清除用户之后建立的选择，也不影响新的收集任务。
    @Test func lateSelectAllFailureKeepsNewerSelection() async throws {
        let (model, store, _, newest, root) = try await make(120)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        model.readHook = { kind, _ in
            guard kind == .memberships, model.selectingAll, gate.arrivals == 0 else { return }
            await gate.wait(); throw StoreError.ioFailure
        }
        // 用户改了选择：旧任务被取消，晚到的失败不清除新选择。
        model.selection = [newest[0], newest[1]]
        model.selectAllMatching()
        try await until { gate.arrivals == 1 }
        let old = try #require(model.selectAllTaskForTesting)
        model.selection = [newest[2]]
        gate.open(); await old.value
        #expect(model.selection == [newest[2]] && model.toast == nil && model.allMatching == nil)
        // 新收集开始后，旧任务晚到的失败不影响新任务完成。
        let second = Gate()
        model.readHook = { kind, _ in
            guard kind == .memberships, model.selectingAll, second.arrivals == 0 else { return }
            await second.wait(); throw StoreError.ioFailure
        }
        model.selectAllMatching()
        try await until { second.arrivals == 1 }
        let stale = try #require(model.selectAllTaskForTesting)
        model.selectAllMatching()
        second.open(); await stale.value
        try await until { !model.selectingAll }
        #expect(model.allMatching?.count == 120 && model.toast == nil)
        try await settle(store)
    }
    // R4 来源歧义形成→删除其一后无需改输入即解除→撤销删除后重新判断为歧义，不沿用旧唯一匹配。
    @Test func sourceDeletionAndUndoRecheckAppCondition() async throws {
        let raw = RawBoard()
        let (model, store, _, _, root) = try await make(1, raw: raw)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        func copy(_ text: String, from bundleID: String) {
            raw.count += 1; raw.items = [[SupportedType.string: Data(text.utf8), "org.nspasteboard.source": Data(bundleID.utf8)]]
            model.history.capture.tick()
        }
        copy("from-beta", from: "test.localclip.beta")
        try await until { model.total == 2 }
        copy("from-betb", from: "test.localclip.betb")
        try await until { model.total == 3 && model.sources.count == 3 }
        model.literal = "app:test.localclip.bet"
        try await until { !model.loading }
        #expect(model.rows.isEmpty && model.queryProblems.first?.hasPrefix("来源“test.localclip.bet”匹配多个") == true)
        let betb = try await store.search(SearchRequest(sourceBundleID: "test.localclip.betb")).items.map(\.id)
        #expect(betb.count == 1)
        _ = try await store.apply(try await store.preview(.delete(betb)).token)
        try await until { model.queryProblems.isEmpty && model.rows.count == 1 }
        #expect(model.rows.first?.source.bundleID == "test.localclip.beta" && !model.sources.contains { $0.bundleID == "test.localclip.betb" })
        try await store.undoDelete()
        try await until { !model.queryProblems.isEmpty && model.rows.isEmpty }
        #expect(model.queryProblems.first?.hasPrefix("来源“test.localclip.bet”匹配多个") == true && model.total == 0)
    }
    // 旧回调：入口捕获的全选身份在全选作废（历史变化、换条件、取消）后被拒绝，存储不变；当前全选、单条与局部选择照常。
    @Test func staleSelectAllCallbackIsRejected() async throws {
        let (model, store, clock, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let category = try await afterChange(model) { try await store.createCategory(name: "C", colorHex: "007AFF") }
        await model.history.reloadCategories()
        func capture() async throws -> ([ClipID], UUID?) {
            model.selectAllMatching()
            try await until { model.allMatching?.count == model.total && !model.selectingAll }
            return (model.targetIDs, model.selectAllID)
        }
        // 历史变化：失效事件已处理后旧回调继续执行。
        var (ids, token) = try await capture()
        #expect(token != nil)
        _ = try await ingest(store, clock, "late")
        try await until { model.allMatching == nil && !model.loading && model.total == 61 }
        model.setCategory(ids, category.id, true, selectAll: token)
        #expect(model.toast?.text == "全选结果已过期，请重新选择")
        model.setFavorite(ids, true, selectAll: token); model.delete(ids, selectAll: token)
        // 换条件与取消：没有存储变化，同样拒绝。
        (ids, token) = try await capture()
        model.time = .week
        try await until { !model.loading }
        model.setFavorite(ids, true, selectAll: token)
        (ids, token) = try await capture()
        model.clearSelection()
        model.delete(ids, selectAll: token)
        try await settle(store)
        let stored = try await store.search({ var r = SearchRequest(pageSize: 1); r.countTotal = true; return r }()).total
        let members = try await store.categoryMemberships(ids)
        #expect(try await favoriteCount(store) == 0 && stored == 61 && members.isEmpty)
        // 当前全选携带身份正常提交。
        (ids, token) = try await capture()
        model.setFavorite(ids, true, selectAll: token)
        try await until { model.toast?.text == "已收藏" }
        #expect(try await favoriteCount(store) == 61)
        // 单条与局部选择不携带身份，照常提交。
        model.setCategory([newest[0]], category.id, true)
        try await until { model.toast?.text == "已加入“C”" }
        model.toast = nil
        model.selection = [newest[1], newest[2]]
        model.setCategory(model.targetIDs, category.id, true)
        try await until { model.toast?.text == "已加入“C”" }
        #expect(try await store.categoryMemberships([newest[0], newest[1], newest[2]]).count == 3)
    }
    // 拖入分类：已选行拖完整选择、未选行只拖自己；令牌单次有效；全部已在其中只提示；内容隐藏拒绝。
    @Test func dragIntoCategoryFollowsSelection() async throws {
        let (model, store, _, newest, root) = try await make(30)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(try await afterChange(model) { await model.createCategory("拖入") } == nil)
        let category = try #require(model.history.categories.first)
        model.selection = [newest[0], newest[1]]
        let pair = model.dragToken(for: newest[0])
        #expect(model.dragToken(for: newest[1]) == pair)
        let single = model.dragToken(for: newest[5])
        // 新的拖动取代旧令牌；未知分类不接收。
        #expect(single != pair && !model.drop([pair], into: category.id) && !model.drop([single], into: "missing"))
        #expect(model.drop([single, single], into: category.id))
        try await until { model.memberships[newest[5]] == [category.id] }
        #expect(try await store.categoryMemberships([newest[0], newest[1], newest[5]]).keys.sorted() == [newest[5]])
        #expect(model.selection == [newest[0], newest[1]] && !model.drop([single], into: category.id))
        model.toast = nil
        #expect(model.drop([model.dragToken(for: newest[5])], into: category.id))
        #expect(model.toast?.text == "已在“拖入”中")
        // 部分已在其中：整批加入，已在的不受影响。
        model.selection = [newest[0], newest[5]]
        #expect(model.drop([model.dragToken(for: newest[0])], into: category.id))
        try await until { model.memberships[newest[0]] == [category.id] }
        #expect(model.memberships[newest[5]] == [category.id])
        model.history.updateSettings { $0.hideContents = true }
        try await until { !model.history.canDisplayContents }
        #expect(!model.drop([model.dragToken(for: newest[2])], into: category.id))
    }
    // 跨页全选拖动携带全选身份：过期后拒绝写入，当前全选整批加入。
    @Test func dragCarriesSelectAllAndRejectsExpired() async throws {
        let (model, store, clock, newest, root) = try await make(60)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(try await afterChange(model) { await model.createCategory("全选") } == nil)
        let category = try #require(model.history.categories.first)
        model.selectAllMatching()
        try await until { model.allMatching?.count == 60 }
        let stale = model.dragToken(for: newest[0])
        _ = try await ingest(store, clock, "late")
        try await until { model.allMatching == nil }
        #expect(model.drop([stale], into: category.id))
        try await until { model.toast?.text == "全选结果已过期，请重新选择" }
        #expect(try await store.categoryMemberships(newest).isEmpty)
        model.selectAllMatching()
        try await until { model.allMatching?.count == 61 }
        let all = try #require(model.allMatching)
        #expect(model.drop([model.dragToken(for: model.rows[3].id)], into: category.id))
        try await until { model.toast?.text == "已加入“全选”" }
        #expect(try await store.categoryMemberships(all).count == 61)
    }
}
/// 读取屏障：到达计数，打开前挂起；测试按到达次数推进，不用固定时长制造竞态。
@MainActor private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0, passed = 0
    private var isOpen = false
    func wait() async {
        arrivals += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        passed += 1
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
/// 阻塞当前线程完成存储写入，期间主线程上的事件订阅无法先行处理。
private func blocking(_ work: @escaping @Sendable () async throws -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached { try? await work(); done.signal() }
    done.wait()
}
private final class ManagerClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = SystemClock().now()
    /// 每次读取前进1ms，模拟两次取页之间时钟走动。
    var autoAdvance = false
    func now() -> Instant { lock.withLock { if autoAdvance { value += 1 }; return value } }
    func advance(_ delta: Instant) { lock.withLock { value += delta } }
}
