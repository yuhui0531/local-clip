// 主线程 UI 状态，查询/详情版本防止旧结果复活，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
@MainActor public final class HistoryViewModel: ObservableObject {
    public let store: HistoryStore
    public let capture: CaptureCoordinator
    public let paste: PasteCoordinator
    public let derived: DerivedContentService
    let queryState = HistoryQueryState()
    let listState = HistoryListState()
    public var query: String { get { queryState.literal } set { queryState.literal = newValue } }
    @Published public var favorites = false
    @Published public var categoryID: String?
    @Published public private(set) var categories: [ClipCategory] = []
    @Published public var categoryFilters: Set<String> = []
    @Published public var sourceFilter: String?
    @Published public var dateFilterEnabled = false
    @Published public var dateFrom = Date()
    @Published public var dateUntil = Date()
    @Published public var showingFilters = false {
        didSet { if showingFilters && !oldValue { requestSourceSuggestions() } }
    }
    @Published public private(set) var sourceSuggestions: [SourceAttribution] = []
    public private(set) var selectedIDs: Set<ClipID> { get { listState[\.selectedIDs] } set { listState[\.selectedIDs] = newValue } }
    @Published public var categoryColor = "34C759"
    @Published public var actualPanelHeight = 340.0
    @Published public var dragActive = false
    @Published public private(set) var draggedIDs: Set<ClipID> = []
    @Published public var richPreview: NSAttributedString?
    private var anchorID: ClipID?
    private var dragSelection: (ids: [ClipID], index: Int)?
    private let filePreview = FilePreview()
    public var focusResults: (() -> Void)?
    public var settingsChanged: (() -> Void)?
    public var resizePanel: ((Double, Bool) -> Void)?
    @Published public var kind: ClipKind?
    // 查询、删除与到期共用发布入口，编辑目标消失时同步释放按键归属，by AI.Coding。
    public private(set) var items: [ClipSummary] {
        get { listState[\.items] }
        set {
            listState[\.items] = newValue
            itemIDs = Set(newValue.map(\.id))
            if let renamingID, !itemIDs.contains(renamingID) { cancelRename(id: renamingID) }
        }
    }
    /// 与items同步的ID集合；卡片任务与选择检查O(1)，全选大量历史时不逐项线性扫描，by AI.Coding。
    private var itemIDs: Set<ClipID> = []
    public func contains(_ id: ClipID) -> Bool { itemIDs.contains(id) }
    public private(set) var selectedID: ClipID? { get { listState[\.selectedID] } set { listState[\.selectedID] = newValue } }
    public private(set) var selectedMetadata: ClipMetadata? { get { listState.selectedMetadata } set { listState.selectedMetadata = newValue } }
    @Published public private(set) var detailLoading = false
    @Published public private(set) var detail: ClipDetail?
    @Published public private(set) var image: NSImage?
    @Published public private(set) var previewMessage = ""
    @Published public var status = "准备中"
    @Published public var message = ""
    public private(set) var loading: Bool { get { listState[\.loading] } set { listState[\.loading] = newValue } }
    @Published public private(set) var confirmingChange = false
    struct ScrollRestoration: Equatable { var generation = UUID(); var offset: CGFloat }
    private(set) var scrollRestoration: ScrollRestoration? { get { listState[\.scrollRestoration] } set { listState[\.scrollRestoration] = newValue } }
    private var viewportPageSize = 50
    private var historyViewport: CGFloat = 0
    private var historyStride: CGFloat = 195
    private var scrollAnchor: (id: ClipID, relative: CGFloat)?
    private var historyOffset: CGFloat = 0
    private var started = false
    private var paging: Task<Void, Never>?
    private var pendingPageNavigation: (selection: ClipID?, extend: Bool)?
    @Published public private(set) var settings = SettingsSnapshot()
    @Published public private(set) var usage: StorageUsage?
    @Published public var target: TargetToken?
    @Published public var focusRequest = UUID()
    @Published public var showingDetail = false
    @Published public var showingCategoryEditor = false
    @Published public private(set) var categoryBeingEdited: ClipCategory?
    @Published public var categoryDraft = ""
    @Published public private(set) var categoryError = ""
    @Published public private(set) var savingCategory = false
    private var queryID = UUID()
    #if DEBUG
    var guiQueryGeneration: UUID { queryID }
    private(set) var historyWindowQueryCount = 0
    private(set) var historyWindowRefreshCount = 0
    /// 验收包只通过生产持久化设置更新采集策略，by AI.Coding。
    func guiApplySettings(_ value: SettingsSnapshot) { settings = value; capture.updatePolicy(value) }
    #endif
    private var detailID = UUID()
    private var cursor: SearchCursor? { get { listState[\.cursor] } set { listState[\.cursor] = newValue } }
    private var pageRevision: Int64 = 0
    private var searching: Task<Void, Never>?
    private var queryPending = false
    private var activeSearchSignature: String?
    private var delayedLoading: Task<Void, Never>?
    var historyBusy: Bool { queryPending || paging != nil || loading }
    private var detailing: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var pendingDeletion: Set<ClipID> = []
    private var changingHistory = false
    private var subscription: Task<Void, Never>?
    private var indexRepair: Task<Void, Never>?
    private var visibilityDeadline: Task<Void, Never>?
    private let clock: any ClipClock
    private var savingSettings = false
    @Published public private(set) var recordUndoQuery: String?
    /// 最近一次变更后存储是否仍有可撤销删除，供菜单禁用状态使用，by AI.Coding。
    @Published public private(set) var canUndoDeletion = false
    public var canUndoFromSearch: Bool { recordUndoQuery != nil && recordUndoQuery == query }
    private var pendingSettingsEdits: [(inout SettingsSnapshot) -> Void] = []
    public private(set) var panelVisible = true
    private var hiddenChanges = false
    private var settingsVisible = false
    private var sourcesNeeded = false
    private var sourcesTask: Task<Void, Never>?
    private var cheapMetadataTask: Task<Void, Error>?
    private var cheapMetadataGeneration = UUID()
    private var metadataNeedsRetry = false
    private struct CaptureNotice: Equatable { var reason: SkipReason; var at: Instant }
    @Published private var captureNotice: CaptureNotice?
    public nonisolated static let categoryDragType = "local.localclip.history-item"
    private var dragAccesses: [ClipExportAccess] = []
    private var categoryDrag: (token: String, ids: [ClipID], expiresAt: Instant)?
    public var closePanel: (() -> Void)?
    public var openSettings: (() -> Void)?
    public var quitApplication: (() -> Void)?
    public var registerShortcut: ((Shortcut) -> Bool)?
    public var showPasteFeedback: ((String) -> Void)?
    public var panelInteractionChanged: (() -> Void)?
    public init(store: HistoryStore, capture: CaptureCoordinator, paste: PasteCoordinator, derived: DerivedContentService, clock: any ClipClock = SystemClock()) {
        self.store = store; self.capture = capture; self.paste = paste; self.derived = derived; self.clock = clock
    }
    /// 列表先刷新；来源和空间仅在相关入口读取，事实仍来自存储，by AI.Coding。
    public func start(resumeCapture: Bool = false) async throws {
        settings = try await store.settings()
        configureHistoryViewport(width: historyViewport, cardWidth: HistoryView.cardSide(height: settings.panelHeight, filtered: sourceFilter != nil || dateFilterEnabled))
        categories = try await store.categories()
        capture.onState = { [weak self] state in self?.acceptCaptureState(state) }
        capture.onSourcePending = { [weak self] source in
            guard let self, !self.sourceSuggestions.contains(where: { $0.bundleID == source.bundleID }) else { return }
            self.sourcesNeeded = true
        }
        // 持久变更流已负责刷新，避免同一次采集同时触发两轮查询和布局。
        try await capture.start(resumeCapture: resumeCapture); settings = capture.policy; status = capture.state
        let stream = await store.events()
        subscription = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                if case .derived = event {
                    if self.settingsVisible { await self.refreshUsage() }
                    continue
                }
                if case .unavailable = event { self.message = "提交后存储不可用，请重启。已提交操作不会重放。" }
                if !self.panelVisible {
                    self.hiddenChanges = true
                    do { self.acceptSettings(try await self.store.settings()) }
                    catch { self.message = "存储状态读取失败" }
                    if self.settingsVisible { await self.refreshUsage() }
                    continue
                }
                // 不让全表元数据扫描挡住新卡片；保留原窗口与详情，by AI.Coding。
                self.refresh()
                let metadata = self.prepareEventMetadata()
                do {
                    try await metadata.value; self.reconcileSelection()
                    if self.showingFilters { self.requestSourceSuggestions() }
                    if self.settingsVisible { await self.searching?.value; await self.refreshUsage() }
                }
                catch { self.message = "存储状态读取失败" }
            }
        }
        started = true
        // 启动期间的设置只在新策略和事件订阅就绪后保存，避免与自动恢复争用版本，by AI.Coding。
        if !pendingSettingsEdits.isEmpty {
            let edits = pendingSettingsEdits; pendingSettingsEdits.removeAll()
            updateSettings { value in for edit in edits { edit(&value) } }
        }
        refresh()
        if showingFilters { requestSourceSuggestions() }
        // 旧版缺索引只在后台有界修复；空间不足仍从原格式检索，不删除历史。
        indexRepair = Task { [weak self] in
            while let self, !Task.isCancelled {
                do { if try await self.store.rebuildSearchIndex() == 0 { return } }
                catch { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    /// 隐藏期间只记失效；重新打开先展示列表再读廉价元数据，by AI.Coding。
    public func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        if !visible { cancelRename() }
        guard visible, hiddenChanges else { return }
        hiddenChanges = false
        refresh()
        let metadata = prepareEventMetadata()
        Task {
            do {
                try await metadata.value
                if showingFilters || sourcesNeeded { requestSourceSuggestions() }
            }
            catch { message = "存储状态读取失败" }
        }
    }
    /// 同值不发送Published通知，减少无关界面的重新计算，by AI.Coding。
    private func assignIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HistoryViewModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
    /// 状态文字相同时仍发布新的忽略原因/时间，供非Observable采集器更新提示，by AI.Coding。
    private func acceptCaptureState(_ value: String) {
        assignIfChanged(\.status, value)
        assignIfChanged(\.captureNotice, capture.lastIgnored.map { CaptureNotice(reason: $0.0, at: $0.1) })
    }
    /// 仅廉价事实在SQL前完成，分类裁剪与查询签名一致；来源/空间不进入此屏障，by AI.Coding。
    private func prepareEventMetadata() -> Task<Void, Error> {
        let generation = UUID(); cheapMetadataGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            // 完成的屏障不保留失败；旧任务不能清除更新任务，重试仍先校正廉价事实，by AI.Coding。
            defer { if self.cheapMetadataGeneration == generation { self.cheapMetadataTask = nil } }
            do {
                self.assignIfChanged(\.categories, try await self.store.categories()); self.pruneCategoryFilters()
                self.acceptSettings(try await self.store.settings())
                if self.cheapMetadataGeneration == generation { self.metadataNeedsRetry = false }
            } catch {
                if self.cheapMetadataGeneration == generation { self.metadataNeedsRetry = true }
                throw error
            }
        }
        cheapMetadataTask = task
        return task
    }
    /// 策略改变才通知采集器，保留既有暂停与队列规则，by AI.Coding。
    private func acceptSettings(_ value: SettingsSnapshot) {
        guard value != settings else { return }
        // 名称元数据不递增策略版本，不能清除正在持久化的即时暂停，by AI.Coding。
        let policyChanged = value.revision != settings.revision
        assignIfChanged(\.settings, value)
        if policyChanged { capture.updatePolicy(value) }
    }
    /// 合并来源读取并等列表发布；隐藏时保留失效标记到下一次打开，by AI.Coding。
    private func requestSourceSuggestions() {
        sourcesNeeded = true
        guard started, panelVisible || showingFilters, sourcesTask == nil else { return }
        sourcesTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sourcesTask = nil }
            while self.sourcesNeeded, !Task.isCancelled, self.panelVisible || self.showingFilters {
                self.sourcesNeeded = false
                await self.searching?.value
                do { self.assignIfChanged(\.sourceSuggestions, try await self.store.sources()) }
                catch { self.message = "来源读取失败" }
            }
        }
    }
    /// 设置窗口显示时读取真实占用，不让后台捕获重复全量计量，by AI.Coding。
    public func settingsVisibilityChanged(_ visible: Bool) {
        settingsVisible = visible
        if visible { Task { await refreshUsage() } }
    }
    /// 所有空间发布复用同值检查；失败不伪造释放结果，by AI.Coding。
    private func refreshUsage() async {
        do { assignIfChanged(\.usage, try await store.usage()) }
        catch { message = "空间计量失败" }
    }
    /// 更新输入立即作废旧queryID，防抖20ms给检索和绘制保留延迟预算。
    public func searchChanged() {
        // 同一在途请求合并分类行的多个属性观察，不打断定位或重复查询，by AI.Coding。
        if queryPending, activeSearchSignature == currentSearchSignature { return }
        if let recordUndoQuery, recordUndoQuery != query { self.recordUndoQuery = nil }
        search(debounce: true)
    }
    /// 捕获/删除/到期刷新不额外防抖。
    public func refresh() { search(debounce: false, preserveWindow: true) }
    private var currentSearchSignature: String {
        SearchRequest(query, favorites: favorites, kind: kind, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1).signature
    }
    /// 每个查询所有者独立计时；旧加载任务不能向新查询发布，by AI.Coding。
    private func beginQueryLoading(_ generation: UUID) {
        queryPending = true; delayedLoading?.cancel()
        delayedLoading = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, generation == self.queryID, self.queryPending else { return }
            self.loading = true
        }
    }
    /// 查询乱序保护与清晰加载/失败状态。
    private func search(debounce: Bool, preserveWindow: Bool = false) {
        #if DEBUG
        if preserveWindow { historyWindowRefreshCount += 1 }
        #endif
        let windowSize = preserveWindow ? max(viewportPageSize, items.count) : viewportPageSize
        let previousSelection = selectedID
        let previousIndex = items.firstIndex { $0.id == previousSelection } ?? 0
        let tailCandidates = preserveWindow ? items.suffix(50).map(\.id) : []
        let previousSelections = preserveWindow ? selectedIDs.union(Set(previousSelection.map { [$0] } ?? [])) : []
        searching?.cancel(); paging?.cancel(); paging = nil; pendingPageNavigation = nil; queryID = UUID(); let id = queryID
        if !preserveWindow { scrollAnchor = nil; historyOffset = 0 }
        activeSearchSignature = currentSearchSignature; beginQueryLoading(id)
        searching = Task { [weak self] in
            guard let self else { return }
            defer {
                if id == queryID { queryPending = false; delayedLoading?.cancel(); delayedLoading = nil }
            }
            do {
                // 服务P95约57ms；输入防抖缩至20ms，避免单防抖就耗尽100ms预算。
                if debounce { try await Task.sleep(for: .milliseconds(20)) }
                let metadata = cheapMetadataTask ?? (metadataNeedsRetry ? prepareEventMetadata() : nil)
                try await metadata?.value
                try Task.checkCancellation()
                guard id == queryID else { return }
                // 廉价元数据裁剪完成后才固定请求，避免已删分类发布旧空结果，by AI.Coding。
                let request = SearchRequest(query, favorites: favorites, kind: kind, queryID: id, pageSize: preserveWindow ? min(50, max(viewportPageSize, windowSize)) : viewportPageSize, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1)
                activeSearchSignature = request.signature
                let started = ContinuousClock.now
                let matching = preserveWindow ? try await store.matchingIDs(Set(tailCandidates).union(previousSelections), in: request) : nil
                var anchors = previousSelections.intersection(matching?.ids ?? [])
                let tail = tailCandidates.last(where: { matching?.ids.contains($0) == true })
                if let tail { anchors.insert(tail) }
                #if DEBUG
                historyWindowQueryCount += 1
                #endif
                var page = try await store.search(request)
                if let matching, matching.revision != page.revision { throw StoreError.invalidCursor }
                var values = page.items
                var pages = [page]
                var loadedIDs = Set(values.map(\.id))
                // 读到仍可见的原窗口尾部和选择；新增项推过50/100边界也不能替换详情。
                while values.count < max(windowSize, viewportPageSize) || !anchors.isSubset(of: loadedIDs), let next = page.next {
                    var following = request; following.cursor = next
                    // 查询期间窗口放大时只补当前缺口，不用旧视口留下半空首屏，by AI.Coding。
                    if anchors.isSubset(of: loadedIDs) { following.pageSize = min(50, max(1, max(windowSize, viewportPageSize) - values.count)) }
                    page = try await store.search(following); pages.append(page); values += page.items
                    loadedIDs.formUnion(page.items.map(\.id))
                    try Task.checkCancellation()
                }
                if settings.timingEnabled { StageTiming.record("history_query", since: started, count: page.items.count) }
                guard !Task.isCancelled, queryID == page.queryID else { return }
                // 只发布原窗口及锚点需要的精确范围；下一页从截断位置续读，不跳过超取行。
                let window = planHistoryWindow(pages: pages, windowSize: max(windowSize, viewportPageSize), anchors: anchors)
                let visible = window.items.filter(isVisible)
                // 新记录插入头部时保留正在浏览的卡片与卡内偏移，不用旧像素位置显示别的记录，by AI.Coding。
                if preserveWindow, historyOffset > 0,
                   let anchor = scrollAnchor, let index = visible.firstIndex(where: { $0.id == anchor.id }) {
                    let offset = max(0, 24 + CGFloat(index) * historyStride + anchor.relative)
                    if abs(offset - historyOffset) > 0.5 { scrollRestoration = .init(offset: offset) }
                }
                listState.update {
                    if !preserveWindow {
                        selectedIDs.removeAll()
                        anchorID = nil
                        scrollRestoration = .init(offset: 0)
                    }
                    items = visible; cursor = window.cursor; pageRevision = page.revision; loading = false
                    if preserveWindow {
                        selectedIDs.formIntersection(Set(items.map(\.id)))
                        if let selectedID, contains(selectedID) { select(selectedID, preserveSelection: true) }
                        else { select(items.isEmpty ? nil : items[min(previousIndex, items.count - 1)].id) }
                    } else {
                        select(items.first?.id)
                    }
                }
                queryPending = false
                scheduleVisibilityDeadline()
                fillHistoryViewport()
                if sourcesNeeded { requestSourceSuggestions() }
            } catch StoreError.invalidCursor { if id == queryID { refresh() } }
            catch is CancellationError { /* 旧输入取消无需报错。 */ }
            catch {
                guard id == queryID else { return }
                listState.update { loading = false; items = []; cursor = nil; select(nil) }; message = "历史查询失败，请重试"
            }
        }
    }
    public var hasMore: Bool { cursor != nil }
    /// 首屏只读足够填满可见区域的摘要；尺寸变化只补不足，不截断浏览窗口或选择，by AI.Coding。
    func configureHistoryViewport(width: CGFloat, cardWidth: CGFloat) {
        guard width.isFinite, cardWidth.isFinite, width > 48, cardWidth > 0 else { return }
        historyViewport = width; historyStride = cardWidth + 16
        viewportPageSize = min(50, max(1, Int(ceil((width - 48 + 16) / historyStride))))
        fillHistoryViewport()
    }
    /// 发布后复核最新视口；补屏查询只取缺少的行，零偏移也不会一直留空，by AI.Coding。
    private func fillHistoryViewport() {
        if started, !historyBusy, hasMore, items.count < viewportPageSize { loadMore(advanceSelection: false, pageSize: viewportPageSize - items.count) }
    }
    /// 只在实际滚动后预读一屏距离内的下一批；首屏布局/卡片appear不能级联加载，by AI.Coding。
    func historyScrolled(offset: CGFloat) {
        guard historyViewport > 0, offset.isFinite else { return }
        historyOffset = max(0, offset)
        if !items.isEmpty {
            let index = min(items.count - 1, max(0, Int(floor((historyOffset - 24) / historyStride))))
            scrollAnchor = (items[index].id, historyOffset - (24 + CGFloat(index) * historyStride))
        }
        guard historyOffset > 1, !dragActive, !historyBusy, hasMore else { return }
        let end = 48 + CGFloat(items.count) * historyStride - 16
        if end - (historyOffset + historyViewport) < historyViewport { loadMore() }
    }
    /// 分页携带同输入和storeRevision；失效时重新查询。
    public func loadMore() { loadMore(advanceSelection:false) }
    /// 键盘到达页尾时延续选择，不能把第50条当成历史终点。
    private func loadMore(advanceSelection:Bool, extend: Bool = false, pageSize: Int? = nil) {
        guard let cursor else { return }
        if historyBusy {
            // 预读正在进行时记住页尾方向键，页面返回后继续选择，不要求用户再按一次，by AI.Coding。
            if advanceSelection, paging != nil { pendingPageNavigation = (selectedID, extend) }
            return
        }
        let id = queryID; loading = true
        let previousCount = items.count, previousSelection = selectedID
        let request = pageRequest(cursor: cursor, queryID: id, pageSize: pageSize ?? min(50, max(8, viewportPageSize * 2)))
        // 一个在途分页任务合并连续滚动；查询切换立即取消，旧页不能混入新筛选，by AI.Coding。
        paging = Task {
            do {
                let started = ContinuousClock.now
                let page = try await store.search(request)
                if settings.timingEnabled { StageTiming.record("history_query", since: started, count: page.items.count) }
                guard !Task.isCancelled, id == queryID else { return }
                items += page.items.filter(isVisible); self.cursor = page.next; loading = false
                let queued = pendingPageNavigation; pendingPageNavigation = nil; paging = nil
                let advance = (advanceSelection && selectedID == previousSelection) || (queued != nil && queued?.selection == selectedID)
                if advance, items.count > previousCount { if queued?.extend ?? extend { choose(items[previousCount].id, modifiers: .shift) } else { select(items[previousCount].id) } }
                scheduleVisibilityDeadline()
                fillHistoryViewport()
            } catch is CancellationError { }
            catch { if id == queryID { loading = false; refresh() } }
        }
    }
    /// 高亮立即更新；快速连续选择取消旧元数据请求，完整正文仅在详情打开时读取。
    public func select(_ id: ClipID?, preserveSelection: Bool = false) {
        guard !dragActive else { return }
        if !preserveSelection { selectedIDs = Set(id.map { [$0] } ?? []); anchorID = id }
        if selectedID == id {
            guard let id else { return }
            // 同一ID的原始内容不可变；只更新元数据，不释放正在浏览的正文。
            metadataTask?.cancel()
            let generation = selectionGeneration
            metadataTask = Task {
                guard let latest = try? await store.metadata(id: id, at: clock.now()),
                      !Task.isCancelled, selectedID == id, generation == selectionGeneration else { return }
                selectedMetadata = latest
                if var detail, detail.summary.id == id { detail.summary = latest.summary; detail.categoryIDs = latest.categoryIDs; detail.revision = latest.revision; self.detail = detail }
            }
            return
        }
        invalidateSelection(); selectedID = id
        guard let id else { return }
        let generation = selectionGeneration
        metadataTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(25))
                let metadata = try await store.metadata(id: id, at: clock.now())
                guard !Task.isCancelled, generation == selectionGeneration, selectedID == id,
                      isVisible(metadata.summary) else { return }
                selectedMetadata = metadata
            } catch is CancellationError { }
            catch { if generation == selectionGeneration { selectedMetadata = nil } }
        }
        if showingDetail { loadDetail() }
    }
    /// 详情显示才加载完整格式；关闭时释放大内容，保留轻量选择状态。
    public func detailVisibilityChanged() {
        panelInteractionChanged?()
        if showingDetail { loadDetail() } else { invalidateDetail() }
    }
    private func loadDetail() {
        guard let id = selectedID, !pendingDeletion.contains(id) else { return }
        if detail?.summary.id == id { return }
        invalidateDetail(); detailLoading = true
        let generation = detailID
        detailing = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await store.detail(id: id, at: clock.now())
                guard !Task.isCancelled, generation == detailID, selectedID == id, showingDetail else { return }
                guard isVisible(detail.summary) else { revalidateVisibleContent(); return }
                let rich = await Task.detached { () -> AttributedString in
                    let result = NSMutableAttributedString(string: "")
                    for (index, item) in detail.payload.items.enumerated() { if index > 0 { result.append(NSAttributedString(string: "\n")) }; result.append(RichContent.attributed(item)) }
                    return AttributedString(result)
                }.value
                guard !Task.isCancelled, generation == detailID, selectedID == id else { return }
                let latest = try await store.metadata(id: id, at: clock.now())
                guard generation == detailID, selectedID == id, isVisible(latest.summary), !pendingDeletion.contains(id) else { return }
                self.detail = detail; detailLoading = false; richPreview = NSAttributedString(rich)
                if detail.summary.kind == .image || detail.summary.kind == .mixed {
                    let bytes = await Task.detached { RichContent.fullImage(detail.payload) }.value
                    let metadata = try await store.metadata(id: id, at: clock.now())
                    guard !Task.isCancelled, generation == detailID, selectedID == id, isVisible(metadata.summary) else { return }
                    image = bytes.flatMap(NSImage.init(data:))
                    if image == nil { previewMessage = "原图预览不可用或超过40MP；原始格式仍保留" }

                }
            } catch { if generation == detailID { invalidateDetail() } }
        }
    }
    /// 存储变更/删除作废两个请求世代，不让旧详情或旧元数据重新覆盖当前选择。
    private func invalidateSelection() {
        metadataTask?.cancel(); metadataTask = nil; selectionGeneration = UUID(); selectedMetadata = nil
        invalidateDetail()
    }
    /// 数据变更先使已展示派生内容失效。
    private func invalidateDetail() {
        detailing?.cancel(); detailing = nil; detailID = UUID()
        if detail != nil { detail = nil }; if image != nil { image = nil }; if richPreview != nil { richPreview = nil }
        if !previewMessage.isEmpty { previewMessage = "" }; if detailLoading { detailLoading = false }
    }
    /// 已发布卡片与详情也必须在到期边界消失，不能等待每分钟物理清理。
    private func isVisible(_ item: ClipSummary) -> Bool {
        !pendingDeletion.contains(item.id) && (settings.retentionDays == 0 || item.isProtected || item.lastCopiedAt > clock.now() - Int64(settings.retentionDays) * dayMS)
    }
    /// 唤醒和精确截止任务复查内存状态；所有异步发布同时调用相同规则。
    func revalidateVisibleContent() {
        let previousCount = items.count
        items.removeAll { !isVisible($0) }; selectedIDs.subtract(pendingDeletion)
        if let detail, !isVisible(detail.summary) { invalidateDetail() }
        if let selectedID, !contains(selectedID) { select(items.first?.id) }
        // 本页到期后重新取第一页，让更旧但仍有效的收藏不会困在不可见的下一页。
        if previousCount != items.count { refresh() }
        scheduleVisibilityDeadline()
    }
    /// 只安排当前可见普通内容的最近期限，避免持续轮询全库。
    private func scheduleVisibilityDeadline() {
        visibilityDeadline?.cancel(); visibilityDeadline = nil
        guard settings.retentionDays > 0 else { return }
        let ordinary = items.filter { !$0.isProtected }
        guard let deadline = ordinary.map({ $0.lastCopiedAt + Int64(settings.retentionDays) * dayMS }).min() else { return }
        let delay = deadline - clock.now()
        if delay <= 0 { revalidateVisibleContent(); return }
        visibilityDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.revalidateVisibleContent()
        }
    }
    /// 搜索焦点中的方向键导航与默认Enter操作。
    public func navigate(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        if delta > 0, current == items.count - 1, hasMore { loadMore(advanceSelection:true); return }
        select(items[min(items.count - 1, max(0, current + delta))].id)
    }
    /// 按配置动作执行；输出状态不会写成目标已接收。
    public func perform(_ format: OutputFormat? = nil, action: PasteAction? = nil) {
        let ids = orderedSelection
        guard !ids.isEmpty else { return }
        Task {
            let result = await paste.perform(.init(ids: ids, format: format ?? settings.defaultFormat, action: action ?? settings.defaultAction, target: target))
            message = result.message + (paste.smartPasteNotice.map { "；" + $0 } ?? "")
            notifyPasteResult(result)
            await recordUse(ids, result)
        }
    }
    @Published public private(set) var renamingID: ClipID?
    /// 只编辑指定卡片的名称，不改变单选/多选与当前滚动窗口，by AI.Coding。
    public func beginRename(_ id: ClipID) {
        guard !dragActive, contains(id) else { return }
        renamingID = id
    }
    /// 取消仅移除编辑状态，不写库，by AI.Coding。
    public func cancelRename(id: ClipID? = nil) {
        if let id, id != renamingID { return }
        renamingID = nil
    }
    /// 提交捕获的名称；持久事件负责刷新，不重复发起列表查询，by AI.Coding。
    public func saveRename(id: ClipID, title: String) {
        guard renamingID == id else { return }
        renamingID = nil
        Task {
            do { try await store.renameClip(id: id, title: title); message = "名称已保存" }
            catch { message = "重命名失败：名称需为单行且不超过1024字节，记录和容量仍须有效" }
        }
    }
    /// 双击恢复原格式后向原应用焦点粘贴；Finder文件对象仍复制到其当前实际目录。
    public func doubleClick(_ id: ClipID) {
        guard contains(id) else { return }
        if !selectedIDs.contains(id) { select(id) }
        focusResults?()
        let ids = orderedSelection
        let rememberedTarget = target
        let copyFiles = ids.allSatisfy { id in items.first(where: { $0.id == id })?.kind == .file } && rememberedTarget?.bundleID == "com.apple.finder"
        Task {
            message = copyFiles ? "正在复制文件到Finder…" : "正在复制并粘贴…"
            let result = await paste.perform(.init(ids: ids, format: settings.defaultFormat, action: copyFiles ? .copy : .directPaste, target: rememberedTarget), copyFilesToFinder: copyFiles)
            message = result.message + (paste.smartPasteNotice.map { "；" + $0 } ?? "")
            notifyPasteResult(result)
            await recordUse(ids, result)
        }
    }
    /// 内容已写入剪贴板的结果视为一次使用；按设置置前，失败不影响已完成的复制，by AI.Coding。
    private func recordUse(_ ids: [ClipID], _ result: PasteResult) async {
        guard settings.moveUsedToFront else { return }
        switch result {
        case .copied, .commandSent, .filesCopied, .fallback: try? await store.touch(ids: ids, at: clock.now())
        case .failed: break
        }
    }
    /// 仅在失败或回退时提示；发出粘贴指令后不弹窗打断使用。
    private func notifyPasteResult(_ result: PasteResult) {
        switch result {
        case .fallback, .failed: showPasteFeedback?(message)
        case .commandSent where paste.smartPasteNotice != nil: showPasteFeedback?(message)
        default: break
        }
    }
    /// 破坏性操作只能经预览和用户确认；过期token要求再次预览。
    public func change(_ change: HistoryChange) {
        guard !changingHistory else { return }
        changingHistory = true
        Task {
            defer { changingHistory = false }
            do {
                let preview = try await store.preview(change)
                if preview.requiresConfirmation {
                    confirmingChange = true; panelInteractionChanged?()
                    let accepted = await ChangeConfirmation.confirm(preview)
                    confirmingChange = false; panelInteractionChanged?()
                    guard accepted else { return }
                }
                searching?.cancel(); delayedLoading?.cancel(); queryPending = false; queryID = UUID(); cursor = nil; loading = false
                invalidateSelection()
                if case .delete(let ids) = change {
                    // 确认后仅撤销被删记录，保留相邻卡片；在途旧查询也受删除集合过滤。
                    let previous = items.firstIndex(where: { $0.id == selectedID }) ?? 0
                    selectedIDs.subtract(ids); pendingDeletion.formUnion(ids); items.removeAll { pendingDeletion.contains($0.id) }
                    select(items.isEmpty ? nil : items[min(previous, items.count - 1)].id)
                } else { selectedMetadata = nil }
                let result = try await store.apply(preview.token)
                // 提交前查询已作废；提交事件拥有刷新，不能在返回时取消新版本查询，by AI.Coding。
                pendingDeletion.removeAll()
                await capture.refreshCapacity()
                // 删除和容量/期限操作后更新计量，其他变更只在设置窗口可见时读取，by AI.Coding。
                switch change {
                case .delete, .clearOrdinary, .quota, .retention, .deleteCategory: await refreshUsage()
                default: if settingsVisible { await refreshUsage() }
                }
                let undo = await store.undoAvailable(); canUndoDeletion = undo
                let deleted = { if case .delete = change { return true }; return false }()
                if deleted { recordUndoQuery = undo ? query : nil }
                // 分类归属成功后明确目标名称；只有提交完成才报告加入成功。
                if case .category(let ids, let categoryID, true) = change {
                    let name = categories.first(where: { $0.id == categoryID })?.name ?? "分类"
                    message = "已将\(ids.count)条记录加入“\(name)”"
                } else {
                    message = (undo ? "可按⌘Z撤销（30秒） · " : deleted ? "本次删除不可撤销（超过内存预算或无可恢复内容） · " : "") + "已保存变更，删除\(result.removed)条，实际释放\(Self.bytes(result.reclaimedBytes))"
                }
            } catch StoreError.stalePreview { pendingDeletion.removeAll(); message = "历史已变化，请重新预览并确认"; refresh() }
            catch { pendingDeletion.removeAll(); message = "变更未完成，旧内容保持或存储不可用，请检查状态"; refresh() }
        }
    }
    /// 键盘删除沿用同一预览/确认/事务流程，不另造直接删库入口。
    public func deleteSelected() {
        guard let id = selectedID, contains(id), !changingHistory else { return }
        change(.delete(orderedSelection))
    }
    /// 分类在面板内编辑，只有持久化成功后才更新标签和归属入口。
    public func editCategory(_ category: ClipCategory? = nil) {
        guard !savingCategory else { return }
        categoryBeingEdited = category; categoryDraft = category?.name ?? ""; categoryColor = category?.colorHex ?? "34C759"; categoryError = ""
        showingDetail = false; showingCategoryEditor = true
    }
    public func saveCategory() {
        guard !savingCategory else { return }
        let category = categoryBeingEdited, name = categoryDraft
        savingCategory = true; categoryError = ""
        Task {
            defer { savingCategory = false }
            do {
                if let category {
                    try await store.renameCategory(id: category.id, name: name, colorHex: categoryColor)
                    message = "分类已重命名"
                } else {
                    let created = try await store.createCategory(name: name, colorHex: categoryColor)
                    selectCategories([created.id])
                    message = "分类已创建；把历史卡片拖到分类标签即可加入"
                }
                showingCategoryEditor = false
            } catch let error as CategoryError { categoryError = error.message }
            catch { categoryError = "分类保存失败，请检查容量或存储状态" }
        }
    }
    /// 开始拖动只生成短期ID令牌，正文由公开提供者按需读取。
    public func registerDragAccess(_ access: ClipExportAccess) { dragAccesses.append(access) }
    public func finishDrag(cancelled: Bool) {
        if cancelled { for access in dragAccesses { access.cancel() }; categoryDrag = nil }
        let wasDragging = dragActive
        dragAccesses.removeAll(); draggedIDs = []; dragActive = false
        // 手势内冻结来源；释放后按原顺序选择最近存活记录，不能保留已删除的ID/详情，by AI.Coding。
        if wasDragging {
            let visible = Set(items.map(\.id))
            if let selectedID, visible.contains(selectedID) {
                selectedIDs.formIntersection(visible); selectedIDs.insert(selectedID)
                select(selectedID, preserveSelection: true)
            } else {
                var nearest: ClipID?, distance = Int.max
                if let snapshot = dragSelection {
                    for (index, id) in snapshot.ids.enumerated() where visible.contains(id) {
                        let offset = abs(index - snapshot.index)
                        if offset <= distance { nearest = id; distance = offset }
                    }
                }
                select(nearest ?? items.first?.id)
            }
        }
        dragSelection = nil; panelInteractionChanged?()
        #if DEBUG
        GUIAcceptanceProbe.event(cancelled ? "drag-cancelled" : "drag-completed", self)
        #endif
    }
    public func prepareDrag(_ clipID: ClipID) -> String {
        if !selectedIDs.contains(clipID) { select(clipID) }
        dragSelection = (items.map(\.id), items.firstIndex { $0.id == selectedID } ?? 0)
        let token = UUID().uuidString
        categoryDrag = (token, orderedSelection, clock.now() + 60_000)
        draggedIDs = Set(orderedSelection)
        dragActive = true; panelInteractionChanged?()
        #if DEBUG
        GUIAcceptanceProbe.event("drag-started", self)
        #endif
        return token
    }
    /// 原生拖放目标同步校验令牌，不读取正文，不接受其他应用伪造的归属ID。
    public func canDropIntoCategory(_ token: String, categoryID: String) -> Bool {
        guard dragActive, !changingHistory, let drag = categoryDrag, token == drag.token,
              clock.now() <= drag.expiresAt, !showingCategoryEditor,
              categories.contains(where: { $0.id == categoryID }) else { return false }
        return !drag.ids.isEmpty && drag.ids.allSatisfy { id in
            contains(id) && !pendingDeletion.contains(id)
        }
    }
    /// 放下时先认领令牌，再结束拖动；提交失败仍由统一变更入口报告，不把接收当保存成功。
    public func dropIntoCategory(_ token: String, categoryID: String) -> Bool {
        guard canDropIntoCategory(token, categoryID: categoryID), let drag = categoryDrag else { return false }
        categoryDrag = nil
        change(.category(drag.ids, categoryID, true))
        return true
    }
    /// 分类变更只影响归属，成功后刷新查询版本，旧分页结果不能混入新分类。
    public func setCategory(_ clipID: ClipID, categoryID: String, included: Bool) {
        let ids = selectedIDs.contains(clipID) ? orderedSelection : [clipID]
        change(.category(ids, categoryID, included))
    }
    /// 暂停/恢复保存绝对用户意图，启动后的配置变化不能把按钮动作反转，by AI.Coding。
    public func setCaptureEnabled(_ enabled: Bool) {
        if !enabled { capture.requestPause() }
        updateSettings { $0.captureEnabled = enabled }
    }
    /// 设置持久化成功后才更新开关与采集策略，启动期间先排队，by AI.Coding。
    public func updateSettings(_ edit: @escaping (inout SettingsSnapshot) -> Void) {
        // 启动尚未完成时不持有旧revision写库；无关编辑不会被当作暂停意图，by AI.Coding。
        if !started {
            var next = settings; edit(&next)
            if settings.captureEnabled && !next.captureEnabled { capture.requestPause() }
            pendingSettingsEdits.append(edit); return
        }
        // 保存期间累计编辑，下一次合并到最新事实，最终滑块值不会被丢弃。
        guard !savingSettings else { pendingSettingsEdits.append(edit); return }
        var next = settings; edit(&next)
        if !next.showMenuIcon, registerShortcut?(next.shortcut) != true { message = "快捷键注册失败，不能隐藏菜单栏入口"; return }
        savingSettings = true
        if settings.captureEnabled && !next.captureEnabled { capture.requestPause() }
        Task {
            defer {
                savingSettings = false
                if !pendingSettingsEdits.isEmpty {
                    let edits = pendingSettingsEdits; pendingSettingsEdits.removeAll()
                    updateSettings { value in for edit in edits { edit(&value) } }
                }
            }
            let previous = settings
            if next.shortcut != previous.shortcut, registerShortcut?(next.shortcut) != true { capture.updatePolicy(previous); message = "快捷键注册冲突，菜单栏仍可使用"; return }
            do {
                settings = try await store.updateCaptureSettings(next); capture.updatePolicy(settings); settingsChanged?()
                if settings.hideContents { showingDetail = false; invalidateDetail(); filePreview.close() }
                message = "设置已保存"
            } catch {
                if next.shortcut != previous.shortcut { _ = registerShortcut?(previous.shortcut) }
                do {
                    let persisted = try await store.settings()
                    settings = persisted; capture.updatePolicy(persisted)
                    message = "设置保存失败，未显示为已生效"
                } catch {
                    capture.requestPause()
                    message = "存储状态不可用，采集已暂停，请重启"
                }
            }
        }
    }
    /// 清理在启动、每分钟和唤醒调用，所有读取入口仍自行检查到期。
    public func maintenance() async {
        do { try await store.cleanExports() } catch { message = "导出临时文件回收未完成，仍计入容量" }
        revalidateVisibleContent()
        do {
            let expired = try await store.expire(at: clock.now()); await capture.refreshCapacity()
            if settingsVisible || expired.removed > 0 { await refreshUsage() }
            if expired.removed > 0 { refresh() }
        }
        catch { message = "清理失败，未报告已释放" }
        // 启动只做快速检查；完整页级校验在面板隐藏时每天后台执行一次，不阻塞采集与界面，by AI.Coding。
        if !panelVisible, lastIntegrityCheck.map({ ContinuousClock.now - $0 > .seconds(86_400) }) ?? true {
            lastIntegrityCheck = ContinuousClock.now
            // 读取失败（如磁盘忙）不当作损坏，次日再查；确认损坏才暂停采集。
            if (try? await store.integrityCheck()) == false {
                capture.requestPause(); message = "数据库完整性检查失败，已暂停采集，请备份后重启"
            }
        }
    }
    private var lastIntegrityCheck: ContinuousClock.Instant?
    /// 二进制容量单位与真实计量一致；零值显示数字而非“Zero KB”，by AI.Coding。
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter(); formatter.countStyle = .binary; formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }
    public var ignoreDescription: String {
        guard let captureNotice else { return "" }
        let reason = captureNotice.reason, time = captureNotice.at
        let names: [SkipReason: String] = [.sensitive:"敏感/临时标记", .unsupported:"无支持格式、无效文件引用或文件promise", .tooLarge:"超过32项或50MiB", .paused:"采集暂停或配置变化", .excluded:"声明来源被排除", .changedDuringRead:"读取期间内容持续变化", .accessUnavailable:"剪贴板访问或表示读取失败", .busy:"处理繁忙，未记录", .selfWrite:"自身恢复，未新增历史"]
        return "最近忽略：\(names[reason] ?? reason.rawValue) · \(Date(timeIntervalSince1970: Double(time)/1000).formatted(date: .omitted, time: .shortened))"
    }
    /// 变更事件按ID复查跨分页选择，不保留已删除或到期的幽灵选择。
    private func reconcileSelection() {
        let generation = queryID, ids = selectedIDs
        Task {
            var valid = Set<ClipID>()
            for id in ids { if (try? await store.metadata(id: id, at: clock.now())) != nil { valid.insert(id) } }
            guard generation == queryID else { return }
            selectedIDs.formIntersection(valid)
        }
    }
    /// 分类被删除后清理筛选身份，不能困在已经不存在的空分类中。
    private func pruneCategoryFilters() {
        let valid = Set(categories.map(\.id)), current = activeCategories
        let remaining = current.intersection(valid)
        guard remaining != current else { return }
        categoryFilters = remaining; categoryID = remaining.count == 1 ? remaining.first : nil
    }
    public var activeCategories: Set<String> { categoryFilters.isEmpty ? Set(categoryID.map { [$0] } ?? []) : categoryFilters }
    public var dateBounds: (Instant, Instant)? {
        guard dateFilterEnabled else { return nil }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: min(dateFrom, dateUntil))
        let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(dateFrom, dateUntil)))!
        return (Int64(from.timeIntervalSince1970 * 1000), Int64(until.timeIntervalSince1970 * 1000))
    }
    public var orderedSelection: [ClipID] { items.filter { selectedIDs.contains($0.id) }.map(\.id) }
    /// Command切换单条，Shift基于稳定ID锚点扩选；原生文字编辑不进入此路径。
    public func choose(_ id: ClipID, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard !dragActive else { return }
        focusResults?()
        if modifiers.contains(.shift), let anchorID, let start = items.firstIndex(where: { $0.id == anchorID }), let end = items.firstIndex(where: { $0.id == id }) {
            selectedIDs.formUnion(items[min(start,end)...max(start,end)].map(\.id)); select(id, preserveSelection: true)
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            anchorID = id; select(selectedIDs.contains(id) ? id : orderedSelection.first, preserveSelection: true)
        } else { select(id) }
    }
    public func extendNavigation(_ delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), !items.isEmpty else { return }
        if index + delta >= items.count, hasMore { loadMore(advanceSelection: true, extend: true); return }
        choose(items[max(0,min(items.count-1,index+delta))].id, modifiers: .shift)
    }
    public func selectAllResults() {
        guard !queryPending else { return }
        selectedIDs.formUnion(items.map(\.id)); select(items.first?.id, preserveSelection: true)
        guard cursor != nil else { return }
        loadRemainingPages(failure: "结果已变化，请重新全选", onPage: { [weak self] in self?.selectedIDs.formUnion($0.map(\.id)) })
    }
    public func edgeSelection(_ last: Bool, extend: Bool) {
        guard !queryPending else { return }
        if last && hasMore {
            let anchor = anchorID
            loadRemainingPages(failure: "结果已变化，请重试", completion: { [weak self] in
                guard let self, let id = self.items.last?.id else { return }
                self.anchorID = anchor; self.choose(id, modifiers: extend ? .shift : [])
            }); return
        }
        if let id = (last ? items.last : items.first)?.id { choose(id, modifiers: extend ? .shift : []) }
    }
    /// 当前筛选条件下的分页请求；所有续页入口共用，避免各处重复拼装条件，by AI.Coding。
    private func pageRequest(cursor: SearchCursor?, queryID: UUID, pageSize: Int = 50) -> SearchRequest {
        SearchRequest(query, favorites: favorites, kind: kind, cursor: cursor, queryID: queryID, pageSize: pageSize, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1)
    }
    /// 全选与End共用的读完剩余分页：接管在途查询与预读，新代次使旧页只能被取消、不能重复追加，by AI.Coding。
    private func loadRemainingPages(failure: String, onPage: @escaping ([ClipSummary]) -> Void = { _ in }, completion: @escaping () -> Void = {}) {
        searching?.cancel(); paging?.cancel(); pendingPageNavigation = nil; queryID = UUID(); let generation = queryID; loading = true
        paging = Task {
            defer { if generation == queryID { loading = false; paging = nil } }
            do {
                while let next = cursor {
                    let page = try await store.search(pageRequest(cursor: next, queryID: generation))
                    guard !Task.isCancelled, generation == queryID else { return }
                    let values = page.items.filter(isVisible); items += values; cursor = page.next; onPage(values)
                }
                completion()
            } catch is CancellationError { }
            catch { if generation == queryID { message = failure; refresh() } }
        }
    }
    /// 类型入口切换到整个历史，清除自定义分类及收藏范围，保留字面搜索和显式来源／日期条件。
    public func selectKind(_ value: ClipKind?) {
        categoryID = nil; categoryFilters = []; favorites = false; kind = value
    }
    /// 自定义分类是独立浏览范围，任何入口都不能携带先前的内容类型。
    public func selectCategories(_ values: Set<String>) {
        kind = nil; favorites = false; categoryFilters = values
        categoryID = values.count == 1 ? values.first : nil
    }
    /// 普通点击切换单分类，Command允许分类并集；两种方式都退出类型筛选。
    public func toggleCategory(_ id: String) {
        var next = activeCategories
        if next.contains(id) { next.remove(id) } else if NSEvent.modifierFlags.contains(.command) { next.insert(id) } else { next = [id] }
        selectCategories(next)
    }
    /// 快捷键切换与分类点击使用同一范围契约。
    public func switchBoard(_ delta: Int) {
        let boards: [String?] = [nil] + categories.map { Optional($0.id) }
        let index = boards.firstIndex(of: categoryID) ?? 0
        let board = boards[(index + delta + boards.count) % boards.count]
        selectCategories(Set(board.map { [$0] } ?? []))
    }
    public func moveCategory(_ category: ClipCategory, delta: Int) {
        Task { do { try await store.moveCategory(id: category.id, delta: delta); categories = try await store.categories() } catch { message = "分类排序未保存" } }
    }
    public func moveSelected(_ delta: Int) {
        guard let categoryID, let selectedID else { return }
        Task { do { try await store.moveItem(id: selectedID, categoryID: categoryID, delta: delta) } catch { message = "记录排序未保存" } }
    }
    public func undoDeletion() {
        Task { do { try await store.undoDelete(); recordUndoQuery = nil; canUndoDeletion = false; pendingDeletion.removeAll(); message = "已撤销删除" } catch { canUndoDeletion = false; message = "不能撤销：期限、容量、策略或内容已变化" } }
    }
    /// 依据当前记录ID逐页定位，不使用旧偏移。
    public func jumpToHistory(category: String? = nil) {
        guard let wanted = selectedID else { return }
        searching?.cancel(); paging?.cancel(); paging = nil; pendingPageNavigation = nil
        queryID = UUID(); let generation = queryID
        query = ""; favorites = false; kind = nil; sourceFilter = nil; dateFilterEnabled = false; categoryID = category; categoryFilters = Set(category.map { [$0] } ?? [])
        activeSearchSignature = currentSearchSignature; beginQueryLoading(generation)
        // 定位也拥有完整查询生命周期；取消、失败和空结果都释放逻辑忙碌状态，by AI.Coding。
        searching = Task {
            defer {
                if generation == queryID { queryPending = false; delayedLoading?.cancel(); delayedLoading = nil; loading = false }
            }
            do {
                _ = try await store.metadata(id: wanted, at: clock.now())
                try Task.checkCancellation(); guard generation == queryID else { return }
                var next: SearchCursor?; var found: [ClipSummary] = []
                repeat {
                    let page = try await store.search(SearchRequest(cursor: next, queryID: generation, categoryIDs: activeCategories))
                    guard !Task.isCancelled, generation == queryID else { return }; found += page.items; next = page.next; pageRevision = page.revision
                } while !found.contains(where: { $0.id == wanted }) && next != nil
                guard found.contains(where: { $0.id == wanted }) else { message = "记录已删除、到期或离开分类"; return }
                listState.update { items = found.filter(isVisible); cursor = next; loading = false; select(wanted) }
                focusResults?()
            } catch is CancellationError { }
            catch { if generation == queryID { message = "无法定位：记录已变化" } }
        }
    }
    /// Space按需预览文件；其他格式使用详情，不提前读取正文。
    public func quickLook() {
        guard let selectedID else { return }
        Task { do { let detail = try await store.detail(id: selectedID, at: clock.now()); if let urls = detail.payload.fileURLs { filePreview.show(urls, excludeFromSharing: settings.excludeFromSharing) } else { showingDetail = true; detailVisibilityChanged() } } catch { message = "预览不可用，记录已变化" } }
    }
    /// 用户明确选择单个对象再打开，混合记录不会自动打开所有资源。
    public func openSelected(reveal: Bool = false, withApplication: Bool = false) {
        guard let selectedID else { return }
        Task {
            do {
                let value = try await store.detail(id: selectedID, at: clock.now())
                let urls = value.payload.fileURLs ?? value.payload.items.flatMap { $0.representations }.filter { $0.type == SupportedType.url }.compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }.filter { ["http","https","mailto"].contains($0.scheme?.lowercased() ?? "") }
                guard !urls.isEmpty else { message = "没有可打开的链接或文件"; return }
                var url = urls[0]
                if urls.count > 1 { let picker = NSAlert(); picker.messageText = "选择要打开的对象"; let popup = NSPopUpButton(frame: NSRect(x:0,y:0,width:400,height:26)); popup.addItems(withTitles: urls.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }); picker.accessoryView = popup; picker.addButton(withTitle:"打开"); picker.addButton(withTitle:"取消"); guard picker.runModal() == .alertFirstButtonReturn else { return }; url = urls[popup.indexOfSelectedItem] }
                _ = try await store.metadata(id: selectedID, at: clock.now())
                if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { message = "原文件已移动或删除；历史保存的是引用"; return }
                if reveal && url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else if withApplication && url.isFileURL {
                    let picker = NSOpenPanel(); picker.allowedContentTypes = [.application]; picker.directoryURL = URL(fileURLWithPath: "/Applications"); guard picker.runModal() == .OK, let app = picker.url else { return }
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in let failed = error != nil; Task { @MainActor in if failed { self?.message = "指定应用未能打开对象" } } }
                } else if !NSWorkspace.shared.open(url) { message = "系统未能打开对象，请检查关联应用" }
            } catch { message = "打开失败，记录已变化" }
        }
    }

}
