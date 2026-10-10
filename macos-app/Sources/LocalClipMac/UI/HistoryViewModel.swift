// 主线程 UI 状态，查询/详情版本防止旧结果复活，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
@MainActor public final class HistoryViewModel: ObservableObject {
    public let store: HistoryStore
    public let capture: CaptureCoordinator
    public let paste: PasteCoordinator
    public let derived: DerivedContentService
    @Published public var query = ""
    @Published public var favorites = false
    @Published public var categoryID: String?
    @Published public private(set) var categories: [ClipCategory] = []
    @Published public var categoryFilters: Set<String> = []
    @Published public var sourceFilter: String?
    @Published public var dateFilterEnabled = false
    @Published public var dateFrom = Date()
    @Published public var dateUntil = Date()
    @Published public var showingFilters = false
    @Published public private(set) var sourceSuggestions: [SourceAttribution] = []
    @Published public private(set) var selectedIDs: Set<ClipID> = []
    @Published public var categoryColor = "34C759"
    @Published public var actualPanelHeight = 340.0
    @Published public var dragActive = false
    @Published public var richPreview: NSAttributedString?
    private var anchorID: ClipID?
    private let filePreview = FilePreview()
    public var focusResults: (() -> Void)?
    public var settingsChanged: (() -> Void)?
    public var resizePanel: ((Double, Bool) -> Void)?
    @Published public var kind: ClipKind?
    @Published public private(set) var items: [ClipSummary] = []
    @Published public private(set) var selectedID: ClipID?
    @Published public private(set) var selectedMetadata: ClipMetadata?
    @Published public private(set) var detailLoading = false
    @Published public private(set) var detail: ClipDetail?
    @Published public private(set) var image: NSImage?
    @Published public private(set) var previewMessage = ""
    @Published public var status = "准备中"
    @Published public var message = ""
    @Published public private(set) var loading = false
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
    private var detailID = UUID()
    private var cursor: SearchCursor?
    private var pageRevision: Int64 = 0
    private var searching: Task<Void, Never>?
    private var detailing: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var pendingDeletion: Set<ClipID> = []
    private var changingHistory = false
    private var subscription: Task<Void, Never>?
    private var visibilityDeadline: Task<Void, Never>?
    private let clock: any ClipClock
    private var savingSettings = false
    public nonisolated static let categoryDragType = "local.localclip.history-item"
    private var dragAccesses: [ClipExportAccess] = []
    private var categoryDrag: (token: String, ids: [ClipID], expiresAt: Instant)?
    public var closePanel: (() -> Void)?
    public var openSettings: (() -> Void)?
    public var registerShortcut: ((Shortcut) -> Bool)?
    public var showPasteFeedback: ((String) -> Void)?
    public var panelInteractionChanged: (() -> Void)?
    public init(store: HistoryStore, capture: CaptureCoordinator, paste: PasteCoordinator, derived: DerivedContentService, clock: any ClipClock = SystemClock()) {
        self.store = store; self.capture = capture; self.paste = paste; self.derived = derived; self.clock = clock
    }
    /// 订阅仅作为刷新信号，事实仍从 HistoryStore 读取。
    public func start() async throws {
        settings = try await store.settings(); usage = try await store.usage()
        categories = try await store.categories(); sourceSuggestions = try await store.sources()
        capture.onState = { [weak self] state in self?.status = state }
        // 持久变更流已负责刷新，避免同一次采集同时触发两轮查询和布局。
        try await capture.start(); status = capture.state
        let stream = await store.events()
        subscription = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                if case .derived = event {
                    do { self.usage = try await self.store.usage() } catch { self.message = "空间计量失败" }
                    continue
                }
                if case .unavailable = event { self.message = "提交后存储不可用，请重启。已提交操作不会重放。" }
                self.invalidateSelection(); self.refresh()
                do { self.categories = try await self.store.categories(); self.pruneCategoryFilters(); self.sourceSuggestions = try await self.store.sources(); self.settings = try await self.store.settings(); self.usage = try await self.store.usage(); self.revalidateVisibleContent(); self.reconcileSelection() }
                catch { self.message = "存储状态读取失败" }
            }
        }
        refresh()
    }
    /// 更新输入立即作废旧queryID，防抖60ms包含在用户延迟中。
    public func searchChanged() { selectedIDs.removeAll(); anchorID = nil; search(debounce: true) }
    /// 捕获/删除/到期刷新不额外防抖。
    public func refresh() { search(debounce: false) }
    /// 查询乱序保护与清晰加载/失败状态。
    private func search(debounce: Bool) {
        searching?.cancel(); queryID = UUID(); let id = queryID
        let request = SearchRequest(query, favorites: favorites, kind: kind, queryID: id, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1)
        loading = true; cursor = nil
        searching = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(60)) }
                let started = ContinuousClock.now
                let page = try await store.search(request)
                if settings.timingEnabled { StageTiming.record("history_query", since: started, count: page.items.count) }
                guard !Task.isCancelled, queryID == page.queryID else { return }
                items = page.items.filter(isVisible); cursor = page.next; pageRevision = page.revision; loading = false
                if let selectedID, items.contains(where: { $0.id == selectedID }) { select(selectedID, preserveSelection: true) }
                else { select(items.first?.id) }
                scheduleVisibilityDeadline()
            } catch is CancellationError { /* 旧输入取消无需报错。 */ }
            catch {
                guard id == queryID else { return }
                loading = false; items = []; select(nil); message = "历史查询失败，请重试"
            }
        }
    }
    public var hasMore: Bool { cursor != nil }
    /// 分页携带同输入和storeRevision；失效时重新查询。
    public func loadMore() { loadMore(advanceSelection:false) }
    /// 键盘到达页尾时延续选择，不能把第50条当成历史终点。
    private func loadMore(advanceSelection:Bool, extend: Bool = false) {
        guard let cursor, !loading else { return }
        let id = queryID; loading = true
        let previousCount = items.count, previousSelection = selectedID
        let request = SearchRequest(query, favorites: favorites, kind: kind, cursor: cursor, queryID: id, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1)
        Task {
            do {
                let started = ContinuousClock.now
                let page = try await store.search(request)
                if settings.timingEnabled { StageTiming.record("history_query", since: started, count: page.items.count) }
                guard id == queryID else { return }
                items += page.items.filter(isVisible); self.cursor = page.next; loading = false
                if advanceSelection, selectedID == previousSelection, items.count > previousCount { if extend { choose(items[previousCount].id, modifiers: .shift) } else { select(items[previousCount].id) } }
                scheduleVisibilityDeadline()
            } catch { if id == queryID { loading = false; refresh() } }
        }
    }
    /// 高亮立即更新；快速连续选择取消旧元数据请求，完整正文仅在详情打开时读取。
    public func select(_ id: ClipID?, preserveSelection: Bool = false) {
        if !preserveSelection { selectedIDs = Set(id.map { [$0] } ?? []); anchorID = id }
        if selectedID == id, let metadata = selectedMetadata,
           metadata.summary == items.first(where: { $0.id == id }) { return }
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
                guard generation == detailID, selectedID == id, latest.revision == detail.revision, isVisible(latest.summary) else { return }
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
        detailing?.cancel(); detailing = nil; detailID = UUID(); detail = nil; image = nil; richPreview = nil; previewMessage = ""; detailLoading = false
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
        if let selectedID, !items.contains(where: { $0.id == selectedID }) { select(items.first?.id) }
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
            message = result.message
            notifyPasteResult(result)
        }
    }
    /// 双击恢复原格式后向原应用焦点粘贴；Finder文件对象仍复制到其当前实际目录。
    public func doubleClick(_ id: ClipID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if !selectedIDs.contains(id) { select(id) }
        focusResults?()
        let ids = orderedSelection
        let rememberedTarget = target
        let copyFiles = ids.allSatisfy { id in items.first(where: { $0.id == id })?.kind == .file } && rememberedTarget?.bundleID == "com.apple.finder"
        Task {
            message = copyFiles ? "正在复制文件到Finder…" : "正在复制并粘贴…"
            let result = await paste.perform(.init(ids: ids, format: settings.defaultFormat, action: copyFiles ? .copy : .directPaste, target: rememberedTarget), copyFilesToFinder: copyFiles)
            message = result.message
            notifyPasteResult(result)
        }
    }
    /// 仅在失败或回退时提示；发出粘贴指令后不弹窗打断使用。
    private func notifyPasteResult(_ result: PasteResult) {
        switch result {
        case .fallback, .failed: showPasteFeedback?(result.message)
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
                    let alert = NSAlert(); alert.messageText = preview.message
                    alert.informativeText = "涉及普通历史或选中条目：\(preview.affectedCount) 条。实际释放空间将在完成后按磁盘文件统计。"
                    alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
                    alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                searching?.cancel(); queryID = UUID(); cursor = nil; loading = false
                invalidateSelection()
                if case .delete(let ids) = change {
                    // 确认后仅撤销被删记录，保留相邻卡片；在途旧查询也受删除集合过滤。
                    let previous = items.firstIndex(where: { $0.id == selectedID }) ?? 0
                    selectedIDs.subtract(ids); pendingDeletion.formUnion(ids); items.removeAll { pendingDeletion.contains($0.id) }
                    select(items.isEmpty ? nil : items[min(previous, items.count - 1)].id)
                } else { selectedMetadata = nil }
                let result = try await store.apply(preview.token)
                // 提交点之后再次作废期间查询，清除删除集合也不能让提交前快照复活。
                searching?.cancel(); queryID = UUID()
                pendingDeletion.removeAll()
                settings = try await store.settings(); capture.updatePolicy(settings)
                await capture.refreshCapacity(); usage = try await store.usage()
                let undo = await store.undoAvailable()
                let deleted = { if case .delete = change { return true }; return false }()
                message = (undo ? "可按⌘Z撤销（30秒） · " : deleted ? "本次删除不可撤销（超过内存预算或无可恢复内容） · " : "") + "已保存变更，删除\(result.removed)条，实际释放\(Self.bytes(result.reclaimedBytes))"
                refresh()
            } catch StoreError.stalePreview { pendingDeletion.removeAll(); message = "历史已变化，请重新预览并确认"; refresh() }
            catch { pendingDeletion.removeAll(); message = "变更未完成，旧内容保持或存储不可用，请检查状态"; refresh() }
        }
    }
    /// 键盘删除沿用同一预览/确认/事务流程，不另造直接删库入口。
    public func deleteSelected() {
        guard let id = selectedID, items.contains(where: { $0.id == id }), !changingHistory else { return }
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
                    categories = try await store.categories(); message = "分类已重命名"
                } else {
                    let created = try await store.createCategory(name: name, colorHex: categoryColor)
                    categories = try await store.categories(); categoryFilters = [created.id]; categoryID = created.id
                    message = "分类已创建；把历史卡片拖到分类标签即可加入"
                }
                showingCategoryEditor = false
                refresh()
            } catch let error as CategoryError { categoryError = error.message }
            catch { categoryError = "分类保存失败，请检查容量或存储状态" }
        }
    }
    /// 开始拖动只生成短期ID令牌，正文由公开提供者按需读取。
    public func registerDragAccess(_ access: ClipExportAccess) { dragAccesses.append(access) }
    public func finishDrag(cancelled: Bool) {
        if cancelled { for access in dragAccesses { access.cancel() }; categoryDrag = nil }
        dragAccesses.removeAll(); dragActive = false; panelInteractionChanged?()
    }
    public func prepareDrag(_ clipID: ClipID) -> String {
        if !selectedIDs.contains(clipID) { select(clipID) }
        let token = UUID().uuidString
        categoryDrag = (token, orderedSelection, clock.now() + 60_000)
        dragActive = true; panelInteractionChanged?(); return token
    }
    /// 接受拖放不代表持久化成功；加载令牌后再次校验记录与目标，复用分类提交。
    public func dropIntoCategory(_ providers: [NSItemProvider], categoryID: String) -> Bool {
        guard !providers.isEmpty, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(Self.categoryDragType),
              categories.contains(where: { $0.id == categoryID }), let drag = categoryDrag,
              clock.now() <= drag.expiresAt, !showingCategoryEditor else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.categoryDragType) { [weak self] data, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let data, data.count == 36, String(data: data, encoding: .utf8) == drag.token,
                      categoryDrag?.token == drag.token, clock.now() <= drag.expiresAt,
                      drag.ids.allSatisfy({ id in items.contains(where: { $0.id == id }) && !pendingDeletion.contains(id) }),
                      categories.contains(where: { $0.id == categoryID }) else {
                    message = "拖入未完成，请重新拖动仍在历史中的记录"; return
                }
                categoryDrag = nil
                change(.category(drag.ids, categoryID, true))
            }
        }
        return true
    }
    /// 分类变更只影响归属，成功后刷新查询版本，旧分页结果不能混入新分类。
    public func setCategory(_ clipID: ClipID, categoryID: String, included: Bool) {
        let ids = selectedIDs.contains(clipID) ? orderedSelection : [clipID]
        change(.category(ids, categoryID, included))
    }
    /// 设置持久化成功后才更新开关与采集策略。
    public func updateSettings(_ edit: (inout SettingsSnapshot) -> Void) {
        guard !savingSettings else { message = "正在保存设置，请稍候"; return }
        var next = settings; edit(&next)
        if !next.showMenuIcon, registerShortcut?(next.shortcut) != true { message = "快捷键注册失败，不能隐藏菜单栏入口"; return }
        savingSettings = true
        if settings.captureEnabled && !next.captureEnabled { capture.requestPause() }
        Task {
            defer { savingSettings = false }
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
        do { _ = try await store.expire(at: clock.now()); await capture.refreshCapacity(); usage = try await store.usage(); refresh() }
        catch { message = "清理失败，未报告已释放" }
    }
    /// 二进制容量单位与真实计量一致。
    public static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    public var ignoreDescription: String {
        guard let (reason, time) = capture.lastIgnored else { return "" }
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
        selectedIDs.formUnion(items.map(\.id)); select(items.first?.id, preserveSelection: true)
        guard let cursor else { return }
        searching?.cancel(); queryID = UUID(); let generation = queryID; loading = true
        Task {
            defer { if generation == queryID { loading = false } }
            var next: SearchCursor? = cursor
            do {
                while let pageCursor = next {
                    let page = try await store.search(SearchRequest(query, favorites: favorites, kind: kind, cursor: pageCursor, queryID: generation, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1))
                    guard generation == queryID else { return }
                    let values = page.items.filter(isVisible); items += values; selectedIDs.formUnion(values.map(\.id)); next = page.next; self.cursor = next
                }
            } catch { message = "结果已变化，请重新全选"; refresh() }
        }
    }
    public func edgeSelection(_ last: Bool, extend: Bool) {
        if last && hasMore {
            let generation = queryID, anchor = anchorID
            loading = true
            Task {
                defer { if generation == queryID { loading = false } }
                do {
                    while let next = cursor {
                        let page = try await store.search(SearchRequest(query, favorites: favorites, kind: kind, cursor: next, queryID: generation, categoryIDs: activeCategories, sourceBundleID: sourceFilter, from: dateBounds?.0, until: dateBounds?.1))
                        guard generation == queryID else { return }; items += page.items.filter(isVisible); cursor = page.next
                    }
                    if let id = items.last?.id { anchorID = anchor; choose(id, modifiers: extend ? .shift : []) }
                } catch { message = "结果已变化，请重试"; refresh() }
            }; return
        }
        if let id = (last ? items.last : items.first)?.id { choose(id, modifiers: extend ? .shift : []) }
    }
    public func toggleCategory(_ id: String) {
        var next = activeCategories
        if next.contains(id) { next.remove(id) } else if NSEvent.modifierFlags.contains(.command) { next.insert(id) } else { next = [id] }
        categoryFilters = next; categoryID = next.count == 1 ? next.first : nil
    }
    public func switchBoard(_ delta: Int) {
        let boards: [String?] = [nil] + categories.map { Optional($0.id) }
        let index = boards.firstIndex(of: categoryID) ?? 0
        categoryID = boards[(index + delta + boards.count) % boards.count]; categoryFilters = Set(categoryID.map { [$0] } ?? [])
    }
    public func moveCategory(_ category: ClipCategory, delta: Int) {
        Task { do { try await store.moveCategory(id: category.id, delta: delta); categories = try await store.categories() } catch { message = "分类排序未保存" } }
    }
    public func moveSelected(_ delta: Int) {
        guard let categoryID, let selectedID else { return }
        Task { do { try await store.moveItem(id: selectedID, categoryID: categoryID, delta: delta); refresh() } catch { message = "记录排序未保存" } }
    }
    public func undoDeletion() {
        Task { do { try await store.undoDelete(); pendingDeletion.removeAll(); refresh(); message = "已撤销删除" } catch { message = "不能撤销：期限、容量、策略或内容已变化" } }
    }
    /// 依据当前记录ID逐页定位，不使用旧偏移。
    public func jumpToHistory(category: String? = nil) {
        guard let wanted = selectedID else { return }
        Task {
            do {
                _ = try await store.metadata(id: wanted, at: clock.now())
                query = ""; favorites = false; kind = nil; sourceFilter = nil; dateFilterEnabled = false; categoryID = category; categoryFilters = Set(category.map { [$0] } ?? [])
                searching?.cancel(); queryID = UUID(); let generation = queryID
                var next: SearchCursor?; var found: [ClipSummary] = []
                repeat {
                    let page = try await store.search(SearchRequest(cursor: next, queryID: generation, categoryIDs: activeCategories))
                    guard generation == queryID else { return }; found += page.items; next = page.next; pageRevision = page.revision
                } while !found.contains(where: { $0.id == wanted }) && next != nil
                guard found.contains(where: { $0.id == wanted }) else { message = "记录已删除、到期或离开分类"; return }
                items = found.filter(isVisible); cursor = next; loading = false; select(wanted); focusResults?()
            } catch { message = "无法定位：记录已变化" }
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
