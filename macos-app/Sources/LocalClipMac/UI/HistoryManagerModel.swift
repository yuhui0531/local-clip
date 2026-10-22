// 历史管理窗口自有查询、页码与选择；写入复用面板的预览→确认→提交，存储事件驱动刷新，by AI.Coding。
import AppKit
import Combine
import LocalClipCore

@MainActor final class HistoryManagerModel: ObservableObject {
    enum Scope: Hashable { case all, favorites, kind(ClipKind), category(String) }
    /// 只保存约定的轻量条件，页码、多选、滚动和预览不跨窗口恢复。
    struct BrowsingState { var scope: Scope; var literal: String; var sort: HistorySortOrder }
    var browsingState: BrowsingState { .init(scope: scope, literal: literal, sort: sort) }
    /// 已删除分类退回全部，避免恢复到永远空白的失效范围。
    func restoreBrowsing(_ state: BrowsingState) {
        if case .category(let id) = state.scope, !history.categories.contains(where: { $0.id == id }) { scope = .all }
        else { scope = state.scope }
        literal = state.literal; sort = state.sort
    }
    enum TimeRange: String, CaseIterable, Identifiable {
        case all = "全部", today = "今天", week = "近 7 天", month = "近 30 天"
        var id: Self { self }
    }
    struct Toast: Equatable { var id = UUID(); var text: String; var undo = false; var failed = false }
    enum Read: Equatable { case search, memberships, sources, offset }
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
    /// 换条件/翻页/重试：清空旧结果等待；同条件后台刷新：保留内容；失败与二者分开，by AI.Coding。
    @Published private(set) var loading = false
    @Published private(set) var refreshing = false
    @Published private(set) var failed = false
    /// app:/in: 等条件无法解析时不执行查询，列出原因，by AI.Coding。
    @Published private(set) var queryProblems: [String] = []
    /// 表格选择只含本页；“选择全部”另存跨页ID，换选即失效。
    @Published var selection: Set<ClipID> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    @Published private(set) var allMatching: [ClipID]? {
        didSet { if allMatching == nil { allSummary = .init(); allMemberships = [:]; allFavorites = []; allMatchingRevision = nil; selectAllID = nil } }
    }
    /// 跨页目标的汇总与分类归属；批量分类菜单与检查器汇总按完整集合显示，by AI.Coding。
    private var allSummary = SelectionSummary()
    private var allMemberships: [ClipID: Set<String>] = [:]
    private var allFavorites: Set<ClipID> = []
    private var allMatchingRevision: Int64?
    /// 本次“选择全部”的身份；界面入口随目标一起捕获，全选作废后旧回调凭它被拒绝，by AI.Coding。
    private(set) var selectAllID: UUID?
    @Published private(set) var selectingAll = false
    @Published private(set) var detail: ClipDetailContent?
    @Published private(set) var detailFailed = false
    @Published var editor: ClipContentEditorState?
    @Published var toast: Toast?
    @Published var canUndo = false
    /// 分类草稿属于管理窗口；不得借用底栏弹层，否则隐藏面板会抢走编辑入口。
    @Published private(set) var categoryBeingEdited: ClipCategory?
    @Published var categoryEditorShown = false
    @Published var categoryName = ""
    @Published var categoryColor = ""
    @Published private(set) var categoryError = ""
    @Published private(set) var savingCategory = false
    private let categoryDraftID = UUID()
    /// 由宿主在面板中定位记录。
    var locate: ((ClipID) -> Void)?
    /// 等待首页时再选中的记录（来自“在历史管理中显示”）。
    private var pendingReveal: Set<ClipID> = []
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var subscription: Task<Void, Never>?
    private var selectAllTask: Task<Void, Never>?
    #if DEBUG
    /// 测试等待被取消的收集任务自身结束。
    var selectAllTaskForTesting: Task<Void, Never>? { selectAllTask }
    #endif
    /// 写入在途时忽略重复操作，连按⌫不会对同一批再次预览提交，by AI.Coding。
    private var changing = false
    /// 预览确认尚在途时保留所属窗口，避免出现脱离原窗口的迟到确认。
    var surfaceOperationPending: Bool { changing || editor?.saving == true || savingCategory }
    /// 来源列表只在出现未知来源后重读，不在每次采集时全库扫描；scannedFor 防止同一条件反复重读，by AI.Coding。
    private var sourcesStale = true
    private var scannedFor: String?
    #if DEBUG
    private(set) var detailLoads = 0
    /// 测试在存储读取前插入屏障或写入。
    var readHook: ((Read, SearchRequest?) async throws -> Void)?
    #endif

    private let quickPreview: any ClipPreviewPresenting
    private var previewTask: Task<Void, Never>?
    private var previewID = UUID()
    private(set) var previewFollowsSelection = false
    private var previewSettings: AnyCancellable?
    var previewParent: (() -> NSWindow?)?
    /// 每个窗口独立持有预览状态，不能借用底部卡片的选择或要求底部面板保持可见。
    init(history: HistoryViewModel, preview: any ClipPreviewPresenting = QuickPreview()) {
        self.history = history; self.quickPreview = preview
    }
    /// 空格只对可独立预览的图片/文件生效，重复按键不会反复开关；正文继续在检查器显示。
    @discardableResult func toggleQuickLook() -> Bool {
        if previewTask != nil || quickPreview.isVisible { closeQuickLook(); return true }
        guard let row = selectedRow, row.kind == .image || row.kind == .file, history.canDisplayContents else { return false }
        previewFollowsSelection = true; loadQuickLook(row.id); return true
    }
    /// 右键菜单与检查器按钮沿用卡片的显式预览语义：先选中目标再打开，不误关已有预览。
    func preview(_ id: ClipID) {
        guard history.canDisplayContents, let row = rows.first(where: { $0.id == id }), row.kind == .image || row.kind == .file else { return }
        closeQuickLook(); selection = [id]
        previewFollowsSelection = true; loadQuickLook(id)
    }
    /// 取消在途请求并收回预览，不影响检查器选择。
    func closeQuickLook() {
        previewTask?.cancel(); previewTask = nil; previewID = UUID()
        previewFollowsSelection = false; quickPreview.close()
    }
    /// 与卡片一致：按需读原件，呈现前复查选择、内容指纹及隐藏策略，过期请求绝不弹窗。
    private func loadQuickLook(_ id: ClipID) {
        previewTask?.cancel(); previewID = UUID()
        let generation = previewID
        previewTask = Task {
            do {
                let value = try await store.detail(id: id, at: clock.now())
                let items = await QuickPreview.loadItems(value)
                let latest = try await store.metadata(id: id, at: clock.now())
                let settings = try await store.settings()
                guard !Task.isCancelled, generation == previewID else { return }
                previewTask = nil
                guard history.canDisplayContents, !settings.hideContents, selectedRow?.id == id,
                      latest.summary.contentFingerprint == value.summary.contentFingerprint else { closeQuickLook(); return }
                guard !items.isEmpty else { closeQuickLook(); show("图片预览不可用：数据无法解码或超过40MP，原始数据已保留", failed: true); return }
                // 等待数据库期间共享策略可能已经收紧，不能用旧快照覆盖刚生效的隐藏共享状态。
                quickPreview.show(items, parent: previewParent?(), excludeFromSharing: history.settings.excludeFromSharing || settings.excludeFromSharing)
            } catch {
                guard !Task.isCancelled, generation == previewID else { return }
                closeQuickLook(); show("预览不可用，记录已变化", failed: true)
            }
        }
    }

    var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }
    var hasFilters: Bool { time != .all || source != nil }
    /// 批量操作作用于“选择全部”或本页选择，按表格顺序。
    var targetIDs: [ClipID] { allMatching ?? rows.map(\.id).filter(selection.contains) }
    var selectedRow: ClipSummary? { selection.count == 1 && allMatching == nil ? rows.first { selection.contains($0.id) } : nil }
    /// 多选检查器汇总：本页选择按当前行统计，跨页全选用收集时同步统计的结果，不另行查询，by AI.Coding。
    var selectionSummary: SelectionSummary {
        if allMatching != nil { return allSummary }
        var summary = SelectionSummary()
        for row in rows where selection.contains(row.id) { summary.add(row, categories: memberships[row.id] ?? []) }
        return summary
    }
    func categoryIDs(of id: ClipID) -> Set<String> { allMemberships[id] ?? memberships[id] ?? [] }
    /// 内容隐藏时收起编辑附页但保留草稿，重新显示后继续编辑，by AI.Coding。
    var editorPresented: Bool { editor != nil && history.canDisplayContents }
    var rangeText: String { loading ? "正在加载…" : rows.isEmpty ? "共 \(total) 条" : "\(page * pageSize + 1)–\(page * pageSize + rows.count)，共 \(total) 条" }

    /// 窗口打开时开始订阅；关闭时停止，不在后台持续查询。
    func start() {
        guard subscription == nil else { return }
        // 使用通知携带的新设置，不在Published的willSet阶段回读旧值；隐藏立即取消待弹出的预览。
        previewSettings = history.$settings.sink { [weak self] settings in
            guard let self else { return }
            self.quickPreview.setSharing(excluded: settings.excludeFromSharing)
            if settings.hideContents { self.closeQuickLook() }
        }
        history.onCaptureSource = { [weak self] source in
            guard let self, !self.sources.contains(where: { $0.bundleID == source.bundleID }) else { return }
            self.sourcesStale = true
        }
        reload()
        subscription = Task { [weak self] in
            guard let store = self?.store else { return }
            let stream = await store.events()
            // 启动即读取真实撤销状态，重开窗口仍可撤销有效期内的删除，by AI.Coding。
            let undo = await store.undoAvailable()
            self?.canUndo = undo
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                // 连续采集合并为一次刷新，by AI.Coding。
                case .changed:
                    // 跨页全选立即作废，不等防抖刷新，by AI.Coding。
                    self.expireSelectAll("历史已变化，已取消全选，请重新选择")
                    // app: 按来源列表解析；删除或撤销可使来源消失或恢复，变更后重读，不沿用旧歧义或旧唯一匹配。
                    // ponytail: 使用 app: 时每次变更都全库扫描来源，规模变大时改为按版本或删除事件失效。
                    if self.usesSourceCondition { self.sourcesStale = true }
                    self.reload(debounce: true, background: true); self.canUndo = await self.store.undoAvailable()
                case .settings: self.reload(debounce: true, background: true); self.canUndo = await self.store.undoAvailable()
                default: break
                }
            }
        }
    }
    func stop() {
        closeQuickLook(); previewSettings?.cancel(); previewSettings = nil
        subscription?.cancel(); subscription = nil; history.onCaptureSource = nil
        loadTask?.cancel(); loadTask = nil; detailTask?.cancel(); detailTask = nil; toastTask?.cancel(); toastTask = nil; cancelSelectAll(); pendingReveal = []
        rows = []; detail = nil; memberships = [:]; editor = nil
    }
    /// 显示指定记录：清除筛选回到全部历史，跳到记录所在页后选中。
    func reveal(_ ids: [ClipID]) {
        literal = ""; time = .all; source = nil; scope = .all; sort = .recentDesc
        // 条件复位会清除旧的待显示记录，之后再登记本次目标；用户随后换条件或翻页即放弃定位。
        pendingReveal = Set(ids)
        page = 0; clearSelection(); reload()
    }
    func go(toPage value: Int) {
        let target = min(max(0, value), pageCount - 1)
        guard target != page else { return }
        page = target; pendingReveal = []; clearSelection(); reload()
    }
    func clearFilters() { time = .all; source = nil }
    private func filtersChanged(debounce: Bool = false) {
        page = 0; pendingReveal = []; clearSelection(); reload(debounce: debounce)
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
    /// background 为同条件的事件刷新：保留现有内容；其余加载先清空旧结果，旧行不冒充新条件的结果，by AI.Coding。
    func reload(debounce: Bool = false, attempt: Int = 0, background: Bool = false) {
        loadTask?.cancel()
        if background { refreshing = !loading }
        else { rows = []; memberships = [:]; loading = true; refreshing = false; failed = false }
        loadTask = Task { [weak self] in
            guard let self else { return }
            if debounce { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
            let size = self.pageSize
            do {
                let problems = await self.conditionProblems()
                try Task.checkCancellation()
                self.queryProblems = problems
                guard problems.isEmpty else { self.publish([], total: 0, memberships: [:], revision: nil); return }
                // 待显示记录不在首页时先跳到它所在页，by AI.Coding。
                if !self.pendingReveal.isEmpty {
                    let probe = self.request(offset: 0, pageSize: 1), reveal = self.pendingReveal
                    if let offset = try await self.read(.offset, probe, { try await self.store.firstOffset(of: reveal, in: probe) }) {
                        try Task.checkCancellation()
                        self.page = offset / size
                    }
                }
                var first = self.request(offset: self.page * size, pageSize: min(50, size)); first.countTotal = true
                let head = try await self.search(first)
                var items = head.items
                // 第二段沿用首段游标；期间有写入（revision）或图片文字索引更新（派生代次）则有界重取整页，不发布混合结果，by AI.Coding。
                if size > 50, let next = head.next {
                    var rest = first; rest.countTotal = false; rest.cursor = next; rest.pageSize = size - 50
                    do {
                        let tail = try await self.search(rest)
                        guard tail.derivedGeneration == head.derivedGeneration else { throw StoreError.invalidCursor }
                        items += tail.items
                    } catch StoreError.invalidCursor {
                        guard !Task.isCancelled else { return }
                        if attempt < 3 { self.reload(attempt: attempt + 1, background: background) }
                        else { self.loadFailed(); self.show("记录持续变化，请稍后重试", failed: true) }
                        return
                    }
                }
                let total = head.total ?? items.count
                try Task.checkCancellation()
                if items.isEmpty, self.page > 0 { self.page = max(0, (total - 1) / size); self.reload(background: background); return }
                let ids = items.map(\.id)
                let memberships = (try? await self.read(.memberships, nil, { try await self.store.categoryMemberships(ids) })) ?? [:]
                try Task.checkCancellation()
                self.publish(items, total: total, memberships: memberships, revision: head.revision)
            } catch is CancellationError {
            } catch StoreError.invalidCursor where self.page > 0 {
                // 浏览路径越界会报错；先取总数再落到最后一页。
                var probe = self.request(offset: 0, pageSize: 1); probe.countTotal = true
                let total = (try? await self.search(probe).total) ?? 0
                guard !Task.isCancelled else { return }
                self.page = max(0, (total - 1) / size); self.reload(background: background)
            } catch {
                // 已被新查询取代的任务不能把失败状态写到新状态上，by AI.Coding。
                guard !Task.isCancelled else { return }
                self.loadFailed()
            }
        }
    }
    /// 读取失败后重试：无内容时进入加载，有同条件旧内容时保留并显示刷新中，by AI.Coding。
    func retry() { failed = false; reload(background: !rows.isEmpty) }
    private func loadFailed() { failed = true; loading = false; refreshing = false }
    private func read<T: Sendable>(_ kind: Read, _ request: SearchRequest?, _ body: () async throws -> T) async throws -> T {
        #if DEBUG
        try await readHook?(kind, request)
        #endif
        return try await body()
    }
    private func search(_ request: SearchRequest) async throws -> SearchPage {
        try await read(.search, request) { try await store.search(request) }
    }
    /// 出现新来源后重读来源；条件仍无法解析时按当前输入重读一次来源与分类，仍不行则返回原因，不退化为全库查询，by AI.Coding。
    private func conditionProblems() async -> [String] {
        var scanned = false
        if sourcesStale, let value = try? await read(.sources, nil, { try await store.sources() }) { sources = value; sourcesStale = false; scanned = true }
        var problems = blockingProblems()
        if !problems.isEmpty, !scanned, scannedFor != literal {
            scannedFor = literal
            if let value = try? await read(.sources, nil, { try await store.sources() }) { sources = value; sourcesStale = false }
            await history.reloadCategories()
            problems = blockingProblems()
        }
        return problems
    }
    private var usesSourceCondition: Bool {
        let parsed = SearchQueryParser.parse(literal, sources: sources, categories: history.categories, now: clock.now())
        return parsed.sourceBundleID != nil || parsed.problems.contains { $0.contains("来源") }
    }
    /// 引号未闭合只是按字面检索的提示；来源、分类无法解析才阻止查询。
    func blockingProblems() -> [String] {
        SearchQueryParser.parse(literal, sources: sources, categories: history.categories, now: clock.now()).problems.filter { !$0.contains("引号未闭合") }
    }
    private func publish(_ items: [ClipSummary], total: Int, memberships: [ClipID: Set<String>], revision: Int64?) {
        rows = items; self.total = total; self.memberships = memberships; failed = false; loading = false; refreshing = false
        // 跨页目标收集后历史有变化即作废，批量操作不作用于过期集合，by AI.Coding。
        if let revision, let collected = allMatchingRevision, collected != revision { expireSelectAll("历史已变化，已取消全选，请重新选择") }
        let visible = Set(items.map(\.id))
        if !pendingReveal.isEmpty {
            let found = pendingReveal.intersection(visible)
            pendingReveal = []
            selection = found
            if found.isEmpty { show("记录已删除或已过期", failed: true) }
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
        guard blockingProblems().isEmpty else { show("条件未生效，无法选择全部", failed: true); return }
        let base = request(offset: 0, pageSize: 50)
        selectingAll = true
        selectAllTask = Task {
            var ids: [ClipID] = [], summary = SelectionSummary(), memberships: [ClipID: Set<String>] = [:], favorites: Set<ClipID> = []
            var cursor: SearchCursor?, first: SearchPage?
            do {
                // 冻结一份查询，只推进游标；revision或派生代次变化即失败，不混合收集结果。
                repeat {
                    var request = base; request.cursor = cursor
                    let page = try await search(request)
                    guard page.derivedGeneration == (first ?? page).derivedGeneration else { throw StoreError.invalidCursor }
                    let pageIDs = page.items.map(\.id)
                    let pageMemberships = try await read(.memberships, nil) { try await store.categoryMemberships(pageIDs) }
                    try Task.checkCancellation()
                    first = first ?? page
                    ids += page.items.map(\.id)
                    for item in page.items { summary.add(item, categories: pageMemberships[item.id] ?? []) }
                    memberships.merge(pageMemberships) { $1 }
                    favorites.formUnion(page.items.filter(\.isFavorite).map(\.id))
                    cursor = page.next
                } while cursor != nil
                allMatching = ids; allSummary = summary; allMemberships = memberships; allFavorites = favorites; allMatchingRevision = first?.revision; selectAllID = UUID()
            } catch {
                // 已被取消或取代的旧任务不动新的选择；本任务失败则连同页内选择一起清除，不退回原局部选择，by AI.Coding。
                if Task.isCancelled { return }
                selectingAll = false; selectAllTask = nil; selection = []
                show("选择全部失败：记录已变化，请重新选择", failed: true)
                return
            }
            selectingAll = false; selectAllTask = nil
        }
    }
    func clearSelection() { selection = []; allMatching = nil; cancelSelectAll() }
    /// 勾选框：跨页全选时可见行都显示为选中；此时取消任一行退回本页其余记录，by AI.Coding。
    func isChecked(_ id: ClipID) -> Bool { allMatching != nil || selection.contains(id) }
    func setChecked(_ id: ClipID, _ on: Bool) {
        if allMatching != nil { if !on { selection = Set(rows.map(\.id)).subtracting([id]) }; return }
        if on { selection.insert(id) } else { selection.remove(id) }
    }
    /// “选择本页全部”：本页全选或已跨页全选时为选中。
    var pageChecked: Bool { allMatching != nil || (!rows.isEmpty && Set(rows.map(\.id)).isSubset(of: selection)) }
    /// 表格改选：系统双击间隔内点勾选列时，表格会把这次点击当成行点击并改为只选该行；按勾选切换处理，保留其余勾选，by AI.Coding。
    func tableSelected(_ value: Set<ClipID>, checkboxClick: Bool) {
        if checkboxClick, value.count == 1, let id = value.first { setChecked(id, !isChecked(id)) } else { selection = value }
    }
    func setPageChecked(_ on: Bool) { if on { selection = Set(rows.map(\.id)) } else { clearSelection() } }
    private func cancelSelectAll() { selectAllTask?.cancel(); selectAllTask = nil; selectingAll = false }
    /// 全选在途或已完成时作废，连同页内选择一起清除，不静默降级为本页操作，by AI.Coding。
    private func expireSelectAll(_ message: String) {
        guard selectingAll || allMatching != nil else { return }
        cancelSelectAll(); allMatching = nil; selection = []
        show(message, failed: true)
    }
    /// 跨页目标按收集时的收藏状态判断，不读正文，by AI.Coding。
    func allFavorite(_ ids: [ClipID]) -> Bool {
        let favorites = allMatching != nil ? allFavorites : Set(rows.filter(\.isFavorite).map(\.id))
        return !ids.isEmpty && ids.allSatisfy(favorites.contains)
    }

    private func selectionChanged() {
        cancelSelectAll()
        if allMatching != nil, !selection.isSuperset(of: rows.map(\.id)) { allMatching = nil }
        // 持续预览随本页单选更新；多选、取消选择、切页或换筛选都关闭旧内容。
        if previewFollowsSelection, previewTask != nil || quickPreview.isVisible {
            if let row = selectedRow, row.kind == .image || row.kind == .file { loadQuickLook(row.id) }
            else { closeQuickLook() }
        }
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
                let contentChanged = detail?.detail.summary.id == id && detail?.detail.summary.contentFingerprint != value.detail.summary.contentFingerprint
                detail = value
                if contentChanged, previewFollowsSelection, quickPreview.isVisible { loadQuickLook(id) }
            } catch is CancellationError {
            } catch { if selectedRow?.id == id { detailFailed = true } }
        }
    }

    // MARK: 操作
    func show(_ text: String, undo: Bool = false, failed: Bool = false) {
        let value = Toast(text: text, undo: undo, failed: failed)
        toast = value; toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(undo || failed ? 6 : 3)); if toast == value { toast = nil } }
    }
    /// 管理窗口只复制，从不直接粘贴到其他应用。
    func copy(_ ids: [ClipID], plain: Bool = false) {
        guard !ids.isEmpty, history.canDisplayContents else { return }
        guard !selectingAll else { show("正在选择全部…"); return }
        Task {
            let result = await history.output(.init(ids: ids, format: plain ? .plainText : history.settings.defaultFormat, action: .copy))
            switch result {
            case .copied: show(ids.count > 1 ? "已复制 \(ids.count) 条" : "已复制")
            case .failed: show(result.message, failed: true)
            default: show(result.message)
            }
        }
    }
    /// selectAll 为入口生成时捕获的全选身份；单条与局部选择不传。
    func setFavorite(_ ids: [ClipID], _ value: Bool, selectAll: UUID? = nil) { apply(.favorites(ids, value), ids, selectAll) }
    func setCategory(_ ids: [ClipID], _ categoryID: String, _ included: Bool, selectAll: UUID? = nil) { apply(.category(ids, categoryID, included), ids, selectAll) }
    func delete(_ ids: [ClipID], selectAll: UUID? = nil) { apply(.delete(ids), ids, selectAll) }
    /// 确认附页挂在管理窗口上；它以非激活方式前置，右键时不一定是key窗口，by AI.Coding。
    static var window: NSWindow? { NSApp.windows.first { $0 is HistoryManagerWindow && $0.isVisible } }
    /// 删除分类沿用预览→管理窗口附页确认→提交；与记录内容无关，内容隐藏时也可删除，进行中的写入给出提示，by AI.Coding。
    func deleteCategory(_ id: String) {
        guard !changing else { show("正在处理上一个操作"); return }
        changing = true
        Task {
            defer { changing = false }
            do {
                guard let result = try await history.commit(.deleteCategory(id), confirm: { await ChangeConfirmation.confirm($0, parent: Self.window) }, willApply: {
                    // 确认后才作废全选：删除会改变记录归属，避免随后的存储事件以“全选已过期”覆盖成功提示；取消则保留全选。
                    if allMatching != nil || selectingAll { cancelSelectAll(); allMatching = nil; selection = [] }
                }) else { return }
                show(history.changeMessage(.deleteCategory(id), result: result))
            } catch { show("操作未完成：分类已变化，请重试", failed: true) }
        }
    }
    /// 拖动剪贴板只放随机令牌，目标与全选身份留在模型里：其他应用拿不到记录，跨页全选也不把整批ID写入剪贴板，by AI.Coding。
    private var drag: (token: String, ids: [ClipID], selectAll: UUID?)?
    /// 从已选行开始拖作用于完整目标（含跨页全选），与右键一致；否则只拖该行。多选时各行取到同一令牌。
    func dragToken(for id: ClipID) -> String {
        let selected = isChecked(id)
        let ids = selected ? targetIDs : [id], selectAll = selected ? selectAllID : nil
        if let drag, drag.ids == ids, drag.selectAll == selectAll { return drag.token }
        let token = UUID().uuidString
        drag = (token, ids, selectAll)
        return token
    }
    /// 放下只加入分类，不移出其他分类；全部已在其中只提示。全选过期、收集中由 apply 拒绝，by AI.Coding。
    @discardableResult func drop(_ tokens: [String], into categoryID: String) -> Bool {
        guard history.canDisplayContents, let drag, tokens.contains(drag.token),
              let category = history.categories.first(where: { $0.id == categoryID }) else { return false }
        self.drag = nil
        if drag.ids.allSatisfy({ categoryIDs(of: $0).contains(categoryID) }) { show("已在“\(category.name)”中"); return true }
        setCategory(drag.ids, categoryID, true, selectAll: drag.selectAll)
        return true
    }
    /// 内容隐藏时不允许盲改；提交前移出待删记录，by AI.Coding。
    /// 全选收集中拒绝批量写入；作用于全选时预览版本须与收集版本一致，过期则中止并提示重选，by AI.Coding。
    private func apply(_ change: HistoryChange, _ ids: [ClipID], _ selectAll: UUID? = nil) {
        guard !changing, history.canDisplayContents else { return }
        guard !selectingAll else { show("正在选择全部…"); return }
        // 携带的全选已作废（历史变化、换条件、取消或关闭）则拒绝，不当作局部操作提交。
        if let selectAll, selectAll != selectAllID || allMatching != ids { show("全选结果已过期，请重新选择", failed: true); return }
        let collected = allMatching == ids ? allMatchingRevision : nil
        changing = true
        Task {
            defer { changing = false }
            do {
                // 确认期间内容被隐藏则视为取消，by AI.Coding。
                guard let result = try await history.commit(change, isCurrent: { collected == nil || $0.storeRevision == collected },
                                                            confirm: { await ChangeConfirmation.confirm($0, parent: Self.window) && history.canDisplayContents }, willApply: {
                    // 自身写入引起的变更事件不再提示全选过期。
                    if collected != nil { allMatching = nil; selection = [] }
                    if case .delete(let ids) = change { allMatching = nil; selection.subtract(ids) }
                }) else { return }
                if case .delete = change {
                    canUndo = history.canUndoDeletion
                    show(result.removed == 1 ? "已删除 1 条" : "已删除 \(result.removed) 条", undo: canUndo)
                } else { show(history.changeMessage(change, result: result)) }
            } catch StoreError.stalePreview where collected != nil {
                cancelSelectAll(); allMatching = nil; selection = []
                show("全选结果已过期，请重新选择", failed: true)
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
    @discardableResult func rename(_ id: ClipID, _ title: String) async -> Bool {
        do { try await store.renameClip(id: id, title: title); return true }
        catch { show(HistoryViewModel.renameFailure, failed: true); return false }
    }
    /// 新建分类：名称去空白，重复由存储拒绝；返回失败原因，由分类编辑弹窗就地显示，by AI.Coding。
    func createCategory(_ name: String, color: String? = nil) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "请输入分类名称" }
        // 面板隐藏时不会走可见刷新，创建后立即更新共享分类，侧栏、in:解析与下一个默认颜色随之生效，by AI.Coding。
        do { _ = try await store.createCategory(name: name, colorHex: color ?? history.nextCategoryColor); await history.reloadCategories(); return nil }
        catch { return HistoryViewModel.categoryFailure(error) }
    }
    /// 只有仍存在的自定义分类可以编辑；浮层失焦后的重复入口保留未保存草稿。
    func beginCategoryRename(_ category: ClipCategory) {
        guard !savingCategory, !history.surfaceEdits.resolving,
              history.categories.contains(where: { $0.id == category.id }) else { return }
        if let previous = categoryBeingEdited,
           categoryName != previous.name || categoryColor != previous.colorHex {
            categoryEditorShown = true; return
        }
        scope = .category(category.id)
        categoryBeingEdited = category; categoryName = category.name; categoryColor = category.colorHex
        categoryError = ""; categoryEditorShown = true
        history.surfaceEdits.register(categoryDraftID, surface: .manager, draft: .init(title: "分类修改", dirty: { [weak self] in
            guard let self else { return false }
            return self.savingCategory || self.categoryName != category.name || self.categoryColor != category.colorHex
        }, save: { [weak self] in await self?.saveCategoryRename() ?? false }, discard: { [weak self] in self?.cancelCategoryRename() }))
    }
    /// 取消只释放草稿，名称、颜色与分类归属均不写入。
    func cancelCategoryRename() {
        guard !savingCategory else { return }
        categoryEditorShown = false; categoryBeingEdited = nil
        history.surfaceEdits.remove(categoryDraftID)
    }
    /// 使用同一存储校验并立即刷新共享分类，底栏隐藏时也能同步新名称。
    @discardableResult func saveCategoryRename() async -> Bool {
        guard let category = categoryBeingEdited, !savingCategory else { return false }
        savingCategory = true; categoryError = ""
        defer { savingCategory = false }
        do {
            try await store.renameCategory(id: category.id, name: categoryName, colorHex: categoryColor)
            await history.reloadCategories()
            categoryEditorShown = false; categoryBeingEdited = nil
            history.surfaceEdits.remove(categoryDraftID)
            return true
        } catch { categoryError = HistoryViewModel.categoryFailure(error); categoryEditorShown = true; return false }
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
        guard let editor, let saving = editor.save(to: store) else { return }
        Task {
            guard await saving.value else { return }
            if self.editor === editor { self.editor = nil }
            show("内容已保存")
        }
    }
    func discardEdit() { if editor?.saving != true { editor = nil } }
    /// 名称草稿：提交按存储规则规范化后显示；有提交在途时任何回写都不覆盖输入框，写入结束（成功或失败）才移出；
    /// 失败保留草稿。空闲时只有输入框仍是旧标题才跟随外部改名，by AI.Coding。
    struct NameDraft {
        var text: String
        private(set) var pending: [String] = []
        init(_ title: String?) { text = title ?? "" }
        /// 返回需写入的名称；与当前（或最后一次提交的）名称相同时不写。
        mutating func submit(current: String?) -> String? {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard text != (pending.last ?? current ?? "") else { return nil }
            pending.append(text); return text
        }
        mutating func finished(_ name: String) { if let index = pending.firstIndex(of: name) { pending.remove(at: index) } }
        mutating func titleChanged(from old: String?, to new: String?) {
            if pending.isEmpty, text == (old ?? "") { text = new ?? "" }
        }
    }
    /// 多选汇总：类型分布、收藏数、分类条数与复制时间范围，by AI.Coding。
    struct SelectionSummary: Equatable {
        var kinds: [ClipKind: Int] = [:]
        var favorites = 0
        var categories: [String: Int] = [:]
        var earliest: Instant?
        var latest: Instant?
        var count: Int { kinds.values.reduce(0, +) }
        mutating func add(_ row: ClipSummary, categories ids: Set<String>) {
            kinds[row.kind, default: 0] += 1
            if row.isFavorite { favorites += 1 }
            for id in ids { categories[id, default: 0] += 1 }
            earliest = min(earliest ?? row.lastCopiedAt, row.lastCopiedAt)
            latest = max(latest ?? row.lastCopiedAt, row.lastCopiedAt)
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
        case ([], 49): return isRepeat ? (previewTask != nil || quickPreview.isVisible) : toggleQuickLook()
        case ([], 36), ([], 76), ([.command], 8): copy(ids); return !ids.isEmpty
        case ([.command], 14): if let id = selectedRow?.id { beginEdit(id) }; return true
        case ([.command], 2):
            if !ids.isEmpty { setFavorite(ids, !allFavorite(ids)) }
            return true
        case ([.command], 5): if let id = selectedRow?.id { locate?(id) }; return true
        case ([.command], 6): undoDelete(); return true
        case ([], 51), ([], 117), ([.command], 51):
            if !isRepeat, !ids.isEmpty { delete(ids) }
            return true
        case ([], 116): go(toPage: page - 1); return true
        case ([], 121): go(toPage: page + 1); return true
        case ([], 53):
            if previewTask != nil || quickPreview.isVisible { closeQuickLook(); return true }
            guard selection.count > 1 || allMatching != nil else { return false }
            clearSelection(); return true
        default: return false
        }
    }
}
