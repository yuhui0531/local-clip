// 历史管理窗口自有查询、页码与选择；写入复用面板的预览→确认→提交，存储事件驱动刷新，by AI.Coding。
import AppKit
import LocalClipCore

@MainActor final class HistoryManagerModel: ObservableObject {
    enum Scope: Hashable { case all, favorites, kind(ClipKind), category(String) }
    enum TimeRange: String, CaseIterable, Identifiable {
        case all = "全部", today = "今天", week = "近 7 天", month = "近 30 天"
        var id: Self { self }
    }
    struct Toast: Equatable { var id = UUID(); var text: String; var undo = false; var failed = false }
    static let pageSizes = [25, 50, 100]

    let history: HistoryViewModel
    private var store: HistoryStore { history.store }
    private var clock: any ClipClock { history.previewClock }

    @Published var scope = Scope.all { didSet { if scope != oldValue { filtersChanged() } } }
    @Published var literal = "" { didSet { if literal != oldValue { filtersChanged(debounce: true) } } }
    @Published var time = TimeRange.all { didSet { if time != oldValue { filtersChanged() } } }
    /// 来源 bundle ID；空字符串表示未知来源，nil 不限。
    @Published var source: String? { didSet { if source != oldValue { filtersChanged() } } }
    @Published var sort = HistorySortOrder.recentDesc { didSet { if sort != oldValue { filtersChanged() } } }
    @Published var pageSize = 50 { didSet { if pageSize != oldValue { filtersChanged() } } }
    @Published private(set) var page = 0
    @Published private(set) var rows: [ClipSummary] = []
    @Published private(set) var total = 0
    @Published private(set) var memberships: [ClipID: Set<String>] = [:]
    @Published private(set) var sources: [SourceAttribution] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    /// 表格选择只含本页；“选择全部”另存跨页ID，换选即失效。
    @Published var selection: Set<ClipID> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    @Published private(set) var allMatching: [ClipID]?
    @Published private(set) var selectingAll = false
    @Published private(set) var detail: ClipDetailContent?
    @Published private(set) var detailFailed = false
    @Published var editor: ClipContentEditorState?
    @Published var toast: Toast?
    @Published var canUndo = false
    /// 由宿主在面板中定位记录。
    var locate: ((ClipID) -> Void)?
    /// 等待首页时再选中的记录（来自“在历史管理中显示”）。
    private var pendingReveal: Set<ClipID> = []
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var subscription: Task<Void, Never>?
    private var selectAllTask: Task<Void, Never>?
    /// 写入在途时忽略重复操作，连按⌫不会对同一批再次预览提交，by AI.Coding。
    private var changing = false
    #if DEBUG
    private(set) var detailLoads = 0
    #endif

    init(history: HistoryViewModel) { self.history = history }

    var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }
    var hasFilters: Bool { time != .all || source != nil }
    /// 批量操作作用于“选择全部”或本页选择，按表格顺序。
    var targetIDs: [ClipID] { allMatching ?? rows.map(\.id).filter(selection.contains) }
    var selectedRow: ClipSummary? { selection.count == 1 && allMatching == nil ? rows.first { selection.contains($0.id) } : nil }
    var rangeText: String { rows.isEmpty ? "共 \(total) 条" : "\(page * pageSize + 1)–\(page * pageSize + rows.count)，共 \(total) 条" }

    /// 窗口打开时开始订阅；关闭时停止，不在后台持续查询。
    func start() {
        guard subscription == nil else { return }
        reload()
        subscription = Task { [weak self] in
            guard let stream = await self?.store.events() else { return }
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                // 连续采集合并为一次刷新，by AI.Coding。
                case .changed, .settings: self.reload(debounce: true); self.canUndo = await self.store.undoAvailable()
                default: break
                }
            }
        }
    }
    func stop() {
        subscription?.cancel(); subscription = nil
        loadTask?.cancel(); detailTask?.cancel(); toastTask?.cancel(); cancelSelectAll()
    }
    /// 显示指定记录：清除筛选回到全部历史，跳到记录所在页后选中。
    func reveal(_ ids: [ClipID]) {
        pendingReveal = Set(ids)
        literal = ""; time = .all; source = nil; scope = .all; sort = .recentDesc
        page = 0; reload()
    }
    func go(toPage value: Int) {
        let target = min(max(0, value), pageCount - 1)
        guard target != page else { return }
        page = target; clearSelection(); reload()
    }
    func clearFilters() { time = .all; source = nil }
    private func filtersChanged(debounce: Bool = false) {
        page = 0; clearSelection(); reload(debounce: debounce)
    }

    func request(offset: Int, pageSize: Int) -> SearchRequest {
        let now = clock.now()
        let parsed = SearchQueryParser.parse(literal, sources: sources, categories: history.categories, now: now)
        var request = SearchRequest(parsed.literal, favorites: parsed.favorites || scope == .favorites, pageSize: pageSize, sourceBundleID: parsed.sourceBundleID ?? source, sort: sort)
        if case .kind(let kind) = scope { request.kind = kind }
        if let kind = parsed.kind { request.kind = kind }
        if case .category(let id) = scope { request.categoryIDs = [id] }
        if !parsed.categoryIDs.isEmpty { request.categoryIDs = parsed.categoryIDs }
        request.from = parsed.from ?? Self.start(of: time, now: now)
        request.until = parsed.until
        request.offset = offset
        return request
    }
    static func start(of range: TimeRange, now: Instant) -> Instant? {
        let day: Int64 = 86_400_000
        switch range {
        case .all: return nil
        case .today: return Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000)).timeIntervalSince1970 * 1000)
        case .week: return now - 7 * day
        case .month: return now - 30 * day
        }
    }

    /// 存储单页上限50；每页100时取两次。页码越界（删除末页后）回到最后一页。
    func reload(debounce: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            if debounce { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
            if self.sources.isEmpty { self.sources = (try? await self.store.sources()) ?? [] }
            let size = self.pageSize
            do {
                // 待显示记录不在首页时先跳到它所在页，by AI.Coding。
                if !self.pendingReveal.isEmpty, let offset = try await self.store.firstOffset(of: self.pendingReveal, in: self.request(offset: 0, pageSize: 1)) {
                    try Task.checkCancellation()
                    self.page = offset / size
                }
                var first = self.request(offset: self.page * size, pageSize: min(50, size)); first.countTotal = true
                let head = try await self.store.search(first)
                var items = head.items
                // 第二段沿用首段游标；期间有写入则重取整页，不重复也不遗漏，by AI.Coding。
                if size > 50, let next = head.next {
                    var rest = first; rest.countTotal = false; rest.cursor = next; rest.pageSize = size - 50
                    do { items += try await self.store.search(rest).items }
                    catch StoreError.invalidCursor { if !Task.isCancelled { self.reload() }; return }
                }
                let total = head.total ?? items.count
                try Task.checkCancellation()
                if items.isEmpty, self.page > 0 { self.page = max(0, (total - 1) / size); self.reload(); return }
                let memberships = (try? await self.store.categoryMemberships(items.map(\.id))) ?? [:]
                try Task.checkCancellation()
                self.publish(items, total: total, memberships: memberships)
            } catch is CancellationError {
            } catch StoreError.invalidCursor where self.page > 0 {
                // 浏览路径越界会报错；先取总数再落到最后一页。
                var probe = self.request(offset: 0, pageSize: 1); probe.countTotal = true
                let total = (try? await self.store.search(probe).total) ?? 0
                guard !Task.isCancelled else { return }
                self.page = max(0, (total - 1) / size); self.reload()
            } catch {
                self.failed = true; self.loading = false
            }
        }
    }
    private func publish(_ items: [ClipSummary], total: Int, memberships: [ClipID: Set<String>]) {
        rows = items; self.total = total; self.memberships = memberships; failed = false; loading = false
        let visible = Set(items.map(\.id))
        if !pendingReveal.isEmpty {
            let found = pendingReveal.intersection(visible)
            pendingReveal = []
            selection = found
            if found.isEmpty { show("记录已删除、到期或不在首页", failed: true) }
            return
        }
        if allMatching == nil, !selection.isSubset(of: visible) { selection.formIntersection(visible) }
        else if selection.count == 1, !detailIsCurrent { loadDetail() }
    }
    /// 只在详情所示字段变化时重读完整内容，频繁采集不反复解析正文与原图，by AI.Coding。
    private var detailIsCurrent: Bool {
        guard let row = selectedRow, let current = detail?.detail else { return false }
        return current.summary.id == row.id && current.summary.contentFingerprint == row.contentFingerprint
            && current.summary.copyCount == row.copyCount && current.summary.lastCopiedAt == row.lastCopiedAt
            && current.categoryIDs == memberships[row.id] ?? []
    }

    /// 跨页收集当前条件下所有记录ID；条件、页码或选择变化即取消，过期结果不会套到新查询上，by AI.Coding。
    func selectAllMatching() {
        guard history.canDisplayContents else { return }
        cancelSelectAll()
        let base = request(offset: 0, pageSize: 50)
        selectingAll = true
        selectAllTask = Task {
            var ids: [ClipID] = []; var cursor: SearchCursor?
            do {
                repeat {
                    var request = base; request.cursor = cursor
                    let page = try await store.search(request)
                    try Task.checkCancellation()
                    ids += page.items.map(\.id); cursor = page.next
                } while cursor != nil
                allMatching = ids
            } catch {
                if Task.isCancelled { return }
                show("记录已变化，请重试", failed: true)
            }
            selectingAll = false; selectAllTask = nil
        }
    }
    func clearSelection() { selection = []; allMatching = nil; cancelSelectAll() }
    private func cancelSelectAll() { selectAllTask?.cancel(); selectAllTask = nil; selectingAll = false }

    private func selectionChanged() {
        cancelSelectAll()
        if allMatching != nil, !selection.isSuperset(of: rows.map(\.id)) { allMatching = nil }
        loadDetail()
    }
    func loadDetail() {
        detailTask?.cancel()
        guard let row = selectedRow else { detail = nil; detailFailed = false; return }
        if detail?.detail.summary.id != row.id { detail = nil }
        detailFailed = false
        let id = row.id, fingerprint = row.contentFingerprint
        #if DEBUG
        detailLoads += 1
        #endif
        detailTask = Task {
            do {
                // 检查器不显示“识别结果”，跳过整份内容判定，by AI.Coding。
                let value = try await ClipDetailContent.load(try await store.detail(id: id, at: clock.now()), inspect: false)
                guard !Task.isCancelled, selectedRow?.id == id else { return }
                if detail?.detail.summary == value.detail.summary, detail?.detail.categoryIDs == value.detail.categoryIDs, fingerprint == value.detail.summary.contentFingerprint { return }
                detail = value
            } catch is CancellationError {
            } catch { if selectedRow?.id == id { detailFailed = true } }
        }
    }

    // MARK: 操作
    func show(_ text: String, undo: Bool = false, failed: Bool = false) {
        let value = Toast(text: text, undo: undo, failed: failed)
        toast = value; toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(undo ? 6 : 3)); if toast == value { toast = nil } }
    }
    /// 管理窗口只复制，从不直接粘贴到其他应用。
    func copy(_ ids: [ClipID], plain: Bool = false) {
        guard !ids.isEmpty, history.canDisplayContents else { return }
        Task {
            let result = await history.output(.init(ids: ids, format: plain ? .plainText : history.settings.defaultFormat, action: .copy))
            switch result {
            case .copied: show(ids.count > 1 ? "已复制 \(ids.count) 条" : "已复制")
            case .failed: show(result.message, failed: true)
            default: show(result.message)
            }
        }
    }
    func setFavorite(_ ids: [ClipID], _ value: Bool) { apply(.favorites(ids, value)) }
    func setCategory(_ ids: [ClipID], _ categoryID: String, _ included: Bool) { apply(.category(ids, categoryID, included)) }
    func delete(_ ids: [ClipID]) { apply(.delete(ids)) }
    /// 内容隐藏时不允许盲改；提交前移出待删记录，by AI.Coding。
    private func apply(_ change: HistoryChange) {
        guard !changing, history.canDisplayContents else { return }
        changing = true
        Task {
            defer { changing = false }
            do {
                guard let result = try await history.commit(change, confirm: { await ChangeConfirmation.confirm($0) }, willApply: {
                    if case .delete(let ids) = change { allMatching = nil; selection.subtract(ids) }
                }) else { return }
                if case .delete = change {
                    canUndo = history.canUndoDeletion
                    show(result.removed == 1 ? "已删除 1 条" : "已删除 \(result.removed) 条", undo: canUndo)
                } else { show(history.changeMessage(change, result: result)) }
            } catch { show("操作未完成：记录已变化，请重试", failed: true) }
        }
    }
    func undoDelete() {
        guard canUndo else { return }
        Task {
            canUndo = false
            if await history.restoreDeleted() { show("已撤销删除") } else { show(HistoryViewModel.undoFailure, failed: true) }
        }
    }
    func rename(_ id: ClipID, _ title: String) {
        Task {
            do { try await store.renameClip(id: id, title: title) }
            catch { show(HistoryViewModel.renameFailure, failed: true) }
        }
    }
    /// 新建分类：名称去空白，重复由存储拒绝。
    func createCategory(_ name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        do { _ = try await store.createCategory(name: name, colorHex: history.nextCategoryColor); return true }
        catch { show(HistoryViewModel.categoryFailure(error), failed: true) }
        return false
    }
    func beginEdit(_ id: ClipID) {
        guard history.canDisplayContents, editor == nil else { return }
        Task {
            do {
                guard let editor = ClipContentEditorState(detail: try await store.detail(id: id, at: clock.now())) else { show(ContentEditError.unsupportedContent.message, failed: true); return }
                self.editor = editor
                await editor.detectLanguage()
            } catch { show(ClipContentEditorState.loadFailure, failed: true) }
        }
    }
    func saveEdit() {
        guard let editor else { return }
        Task {
            guard await editor.save(to: store) else { return }
            if self.editor === editor { self.editor = nil }
            show("内容已保存")
        }
    }
    func cancelEdit() {
        guard let editor, !editor.saving else { return }
        if editor.hasChanges { editor.confirmingDiscard = true } else { self.editor = nil }
    }

    /// 窗口本地按键；文字编辑与输入法组字交还文本框。返回 true 表示已处理。
    func handleKey(code: UInt16, flags: NSEvent.ModifierFlags, editing: Bool, isRepeat: Bool = false) -> Bool {
        let flags = flags.intersection([.command, .option, .control, .shift])
        if editor != nil || !history.canDisplayContents { return false }
        if flags == [.command], code == 3 { return false } // ⌘F 由搜索框处理
        if editing { return false }
        let ids = targetIDs
        switch (flags, code) {
        // 没有选择时交还系统，⌘C 仍可复制其他控件里的文字。
        case ([], 36), ([], 76), ([.command], 8): copy(ids); return !ids.isEmpty
        case ([.command], 14): if let id = selectedRow?.id { beginEdit(id) }; return true
        case ([.command], 2):
            if !ids.isEmpty { setFavorite(ids, !(rows.filter { ids.contains($0.id) }.allSatisfy(\.isFavorite))) }
            return true
        case ([.command], 5): if let id = selectedRow?.id { locate?(id) }; return true
        case ([.command], 6): undoDelete(); return true
        case ([], 51), ([], 117), ([.command], 51):
            if !isRepeat, !ids.isEmpty { delete(ids) }
            return true
        case ([], 116): go(toPage: page - 1); return true
        case ([], 121): go(toPage: page + 1); return true
        case ([], 53):
            guard selection.count > 1 || allMatching != nil else { return false }
            clearSelection(); return true
        default: return false
        }
    }
}
