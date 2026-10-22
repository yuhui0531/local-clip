// 主线程 UI 状态，查询/详情版本防止旧结果复活，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
@MainActor public final class HistoryViewModel: ObservableObject {
    /// 主界面的未提交输入统一参与关闭与切换保护。
    let surfaceEdits = SurfaceEdits()
    public let store: HistoryStore
    public let capture: CaptureCoordinator
    public let paste: PasteCoordinator
    public let derived: DerivedContentService
    /// 卡片字符数按记录与内容指纹缓存，修改后不会复用旧值，by AI.Coding。
    let characterCounts = NSCache<NSString, NSNumber>()
    /// 图片文件引用的文件数；预览文本截断时据此显示准确张数。
    let fileCounts = NSCache<NSString, NSNumber>()
    /// 文本文件引用的开头内容。
    let fileTexts: NSCache<NSString, NSString> = { let value = NSCache<NSString, NSString>(); value.countLimit = 200; return value }()
    let thumbnails = ThumbnailMemoryCache()
    private var filePreviewVersions: [ClipID: FileReferencePreviewVersion] = [:]
    /// 已由后台取回文件版本后才允许缓存命中；未知/变更身份清除旧正文，by AI.Coding。
    func validateFilePreview(id: ClipID, version: FileReferencePreviewVersion?) -> Bool {
        let unchanged = version != nil && filePreviewVersions[id] == version
        if !unchanged {
            fileTexts.removeObject(forKey: id as NSString); fileCounts.removeObject(forKey: id as NSString)
            thumbnails.removeObject(forKey: id as NSString)
        }
        if filePreviewVersions.count >= 200 { filePreviewVersions.removeAll() }
        filePreviewVersions[id] = version
        return unchanged
    }
    private var visibleThumbnailIDs: Set<ClipID> = []
    private var thumbnailCleanup: Task<Void, Never>?
    var thumbnailCleanupDelay: Duration = .seconds(30)
    let queryState = HistoryQueryState()
    let listState = HistoryListState()
    public var query: String { get { queryState.literal } set { queryState.literal = newValue } }
    @Published public var favorites = false
    /// 置顶时失焦不自动隐藏；粘贴、Esc、关闭仍照常收起，仅本次运行有效。
    @Published public var pinned = false
    /// 置顶期间用户可能已切换应用；由宿主在粘贴前重取当前前台应用与焦点。
    public var refreshPinnedTarget: (() -> Void)?
    /// 采集到来源时通知历史管理窗口，未知来源才重读来源列表，by AI.Coding。
    var onCaptureSource: ((SourceAttribution) -> Void)?
    /// 未置顶沿用打开面板时记住的目标；置顶时以粘贴这一刻的前台应用为准。
    private func pasteTarget() -> TargetToken? {
        if pinned { refreshPinnedTarget?() }
        return target
    }
    @Published public var categoryID: String?
    @Published public private(set) var categories: [ClipCategory] = []
    @Published public var categoryFilters: Set<String> = []
    @Published public var sourceFilter: String?
    @Published public var dateFilterEnabled = false
    /// 同一筛选状态用于图标与预布局预算，分类条件也属于筛选，by AI.Coding。
    var hasFilterSelection: Bool { sourceFilter != nil || dateFilterEnabled || !categoryFilters.isEmpty }
    /// 筛选按钮显示的生效条件数：来源、日期、多分类各计一项。
    var filterCount: Int { (sourceFilter != nil ? 1 : 0) + (dateFilterEnabled ? 1 : 0) + (categoryFilters.isEmpty ? 0 : 1) }
    @Published public var dateFrom = Date()
    @Published public var dateUntil = Date()
    @Published public var showingFilters = false {
        didSet {
            if showingFilters && !oldValue { requestSourceSuggestions() }
            if oldValue && !showingFilters { rememberNativePopoverDismissal() }
        }
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
    private let quickPreview = QuickPreview()
    /// 预览窗口挂在历史面板下作为子窗口，由宿主提供面板，by AI.Coding。
    public var previewParent: (() -> NSWindow?)?
    var previewWindowVisible: Bool { quickPreview.isVisible }
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
    /// 详情读取超过100ms才显示等待；更快完成不闪转圈，by AI.Coding。
    @Published private(set) var detailSlow = false
    /// 详情读取失败，状态槽提供重试，by AI.Coding。
    @Published private(set) var detailFailed = false
    private var detailSlowTask: Task<Void, Never>?
    /// Space打开的预览随方向键换选跟随；点击卡片与显式详情入口沿用换卡关闭，by AI.Coding。
    var previewFollowsSelection = false
    #if DEBUG
    /// 测试注入详情读取延迟，验证等待反馈与请求代次，by AI.Coding。
    var detailDelayForTesting: Duration = .zero
    #endif
    @Published public private(set) var detail: ClipDetail?
    @Published public private(set) var image: NSImage?
    /// 识别结果与正文高亮随详情同批发布，弹窗首帧即最终内容与尺寸，by AI.Coding。
    @Published private(set) var detailInspection: ContentInspector.Inspection?
    @Published private(set) var detailHighlight: SyntaxHighlight?
    @Published private(set) var detailEditable = false
    @Published public private(set) var previewMessage = ""
    @Published public var status = "准备中"
    /// 错误与警告直接赋值message，默认按失败级别显示；只有notice()降为短暂通知，by AI.Coding。
    @Published public var message = "" {
        didSet {
            if messageSeverity != .failure { messageSeverity = .failure }
            // 新操作或手动关闭接管状态槽，旧授权检查不能清掉后来的消息，by AI.Coding。
            waitingForPastePermission = false
            permissionNoticeTask?.cancel(); permissionNoticeTask = nil
        }
    }
    private var waitingForPastePermission = false
    private var permissionNoticeTask: Task<Void, Never>?
    enum MessageSeverity { case notice, failure }
    @Published private(set) var messageSeverity = MessageSeverity.failure
    private var noticeClear: Task<Void, Never>?
    /// 成功提示只在状态槽短暂显示后恢复状态；错误与警告保留到下一次操作或点按关闭，by AI.Coding。
    func notice(_ text: String) {
        message = text; messageSeverity = .notice; noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            // 同文字的新错误不能被旧通知计时器清掉。
            guard let self, !Task.isCancelled, self.message == text, self.messageSeverity == .notice else { return }
            self.message = ""
        }
    }
    /// 状态槽弹窗内关闭错误全文；通知和状态不受影响。
    func dismissMessage() { if messageSeverity == .failure { message = "" }; showingStatusDetail = false }
    /// 焦点提示所需的第一响应者归类，由宿主随窗口第一响应者变化同步更新，by AI.Coding。
    enum HistoryFocus { case search, results, other }
    @Published var historyFocus = HistoryFocus.other
    /// 状态槽全文弹窗；与筛选同样属于自有浮层，Esc和点击归属一致，by AI.Coding。
    @Published var showingStatusDetail = false {
        didSet { if oldValue && !showingStatusDetail { rememberNativePopoverDismissal() } }
    }
    /// 工具栏状态槽单条内容；按优先级取最高一条，低优先级动作另有入口，by AI.Coding。
    struct StatusEntry: Equatable {
        enum Level: Int, Comparable { case failure = 1, monitoring, queue, notice, hint
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue } }
        var level: Level
        var text: String
    }
    /// 错误 → 监控异常 → 队列 → 通知 → 焦点提示；隐藏内容时文案均不含正文，by AI.Coding。
    func statusEntry(queryEmpty: Bool) -> StatusEntry? {
        if !message.isEmpty, messageSeverity == .failure { return .init(level: .failure, text: message) }
        if capture.capacityBlocked { return .init(level: .failure, text: HistoryView.statusLabel("容量已满")) }
        if let problem = queryProblems.first { return .init(level: .failure, text: queryProblems.count > 1 ? queryProblems.joined(separator: "；") : problem) }
        if detailFailed { return .init(level: .failure, text: "预览未能读取 · 重试") }
        if recordingPaused || status != "正常" {
            return .init(level: .monitoring, text: HistoryView.statusLabel(recordingPaused && status == "正常" ? "用户暂停" : status))
        }
        if let queue = pasteQueueStatus { return .init(level: .queue, text: queue) }
        if !message.isEmpty { return .init(level: .notice, text: message) }
        if detailSlow { return .init(level: .notice, text: "正在准备预览…") }
        switch historyFocus {
        case .search where !queryEmpty: return .init(level: .hint, text: "↩ 进入结果")
        case .results where selectedID != nil:
            return .init(level: .hint, text: settings.defaultAction == .directPaste ? "↩ 粘贴到 \(MacApplicationClient.targetName(target))" : "↩ 复制")
        default: return nil
        }
    }
    /// 成功结果静默或短提示；回退、失败与智能粘贴降级保留原因，by AI.Coding。
    private func showPasteResult(_ result: PasteResult) {
        if result == .fallback(PasteCoordinator.permissionFallbackReason) {
            message = result.message
            waitingForPastePermission = true
            refreshPastePermissionNotice()
            return
        }
        if let notice = paste.smartPasteNotice { message = result.message + "；" + notice; return }
        switch result {
        case .copied: notice("已复制")
        case .commandSent: notice(result.message)
        case .filesCopied(let text): notice(text)
        case .fallback, .failed: message = result.message
        }
    }
    /// 仅可见且仍有授权警告时检查权限；隐藏后停止，重开立即复核，by AI.Coding。
    private func refreshPastePermissionNotice() {
        permissionNoticeTask?.cancel(); permissionNoticeTask = nil
        guard waitingForPastePermission, panelVisible else { return }
        if paste.pastePermissionGranted { message = ""; return }
        permissionNoticeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard let self, self.panelVisible, self.waitingForPastePermission else { return }
                // 授权成功只撤销已过时的警告，不能向旧目标自动补发粘贴。
                if self.paste.pastePermissionGranted { self.message = ""; return }
            }
        }
    }
    public private(set) var loading: Bool { get { listState[\.loading] } set { listState[\.loading] = newValue } }
    @Published public private(set) var confirmingChange = false
    /// 非nil时历史面板显示确认浮层；回答只经answerPanelConfirmation一次，by AI.Coding。
    @Published private(set) var panelConfirmation: ChangeConfirmationCopy?
    private var panelConfirmationAnswer: CheckedContinuation<Bool, Never>?
    struct ScrollRestoration: Equatable { var generation = UUID(); var offset: CGFloat }
    private(set) var scrollRestoration: ScrollRestoration? { get { listState[\.scrollRestoration] } set { listState[\.scrollRestoration] = newValue } }
    private var viewportPageSize = 50
    private var historyViewport: CGFloat = 0
    private var historyStride: CGFloat = HistoryView.cardSide(height: 340) + HistoryView.cardSpacing
    private var scrollAnchor: (id: ClipID, relative: CGFloat)?
    private var historyOffset: CGFloat = 0
    private var started = false
    private var paging: Task<Void, Never>?
    private var pendingPageNavigation: (selection: ClipID?, extend: Bool)?
    @Published public private(set) var settings = SettingsSnapshot() {
        didSet {
            // 所有设置来源共用隐藏撤销边界，不能只覆盖设置窗口入口，by AI.Coding。
            if settings.excludeFromSharing != oldValue.excludeFromSharing { quickPreview.setSharing(excluded: settings.excludeFromSharing) }
            if settings.hideContents && !oldValue.hideContents {
                showingDetail = false; invalidateDetail(); imageTextTask?.cancel(); imageTextGeneration = UUID()
                if message == "正在识别图中文字…" { message = "" }
            }
            if settings.imageTextSearchSince != oldValue.imageTextSearchSince || settings.hideContents != oldValue.hideContents { syncImageTextIndex() }
        }
    }
    @Published public private(set) var usage: StorageUsage?
    /// 拖出图片文件占用；不计入历史容量，单独展示与清理，by AI.Coding。
    @Published public private(set) var dragFilesBytes: Int64?
    @Published public var target: TargetToken?
    /// 面板显示周期标识，供文件预览重新校验与GUI探针；不再驱动搜索框焦点，by AI.Coding。
    @Published public var focusRequest = UUID()
    /// 仅此令牌把搜索框设为第一响应者（打开面板、⌘F），by AI.Coding。
    @Published public var searchFocusRequest = UUID()
    /// 搜索框创建时登记，结果区键入可同步转入，by AI.Coding。
    weak var searchField: NSSearchField?
    /// 同步设为第一响应者，调用方随后放行原事件，首键经field editor与输入法处理，by AI.Coding。
    @discardableResult func focusSearchSynchronously() -> Bool {
        guard let field = searchField, let window = field.window else { return false }
        return window.makeFirstResponder(field)
    }
    /// Esc分级：面板内确认 → 自有弹窗 → 清空搜索词（焦点回结果）→ 返回true表示应关闭面板；输入法候选由调用方先放行，by AI.Coding。
    func handleEscape() -> Bool {
        if panelConfirmation != nil { answerPanelConfirmation(false) }
        else if quickPreview.isVisible { quickPreview.close(); previewFollowsSelection = false }
        else if showingCategoryEditor { showingCategoryEditor = false }
        else if showingFilters { showingFilters = false }
        else if showingStatusDetail { showingStatusDetail = false }
        else if showingDetail { showingDetail = false }
        else if !queryState.literal.isEmpty { queryState.literal = ""; searchChanged(); focusResults?() }
        else { return true }
        return false
    }
    /// 所有详情入口共享隐藏条件；隐藏是视觉策略，不禁止普通复制，by AI.Coding。
    public var canDisplayContents: Bool { !settings.hideContents }
    /// 卡片预览读取统一由ViewModel传递时间，不让视图直接选择真实时钟，by AI.Coding。
    func previewDetail(id: ClipID) async throws -> ClipDetail { try await store.detail(id: id, at: clock.now()) }
    /// 预览发布前仍复查持久可见性。
    func previewMetadata(id: ClipID) async throws -> ClipMetadata { try await store.metadata(id: id, at: clock.now()) }
    /// 只读取轻量字符数，不向视图暴露存储调用细节。
    func previewCharacterCount(id: ClipID) async throws -> Int? { try await store.textCharacterCount(id: id, at: clock.now()) }
    /// 图片主表示的已保存字节数；只读计数列，不加载正文。单张图片顺带读≤256KB前缀解析像素，失败只缺像素，by AI.Coding。
    func previewImageSize(id: ClipID) async throws -> (bytes: Int64, items: Int, pixels: PixelSize?)? {
        guard let size = try await store.imageByteCount(id: id, at: clock.now()) else { return nil }
        // 卡片离屏取消后不再排队读前缀，避免快速滚动时作废读取拖慢可见卡片。
        guard size.items == 1, !Task.isCancelled, let header = try? await store.imageHeaderPrefix(id: id, at: clock.now()), !Task.isCancelled else { return (size.bytes, size.items, nil) }
        let pixels = await Task.detached(priority: .utility) { ThumbnailRenderer.pixelSize(header: header) }.value
        return (size.bytes, size.items, pixels)
    }
    @Published public var showingDetail = false {
        didSet {
            if oldValue && !showingDetail { rememberNativePopoverDismissal(); previewFollowsSelection = false }
            if showingDetail && !canDisplayContents { showingDetail = false; return }
            if showingDetail, let editor = contentEditor {
                if !editor.hasChanges && !editor.saving { discardContentEdit() }
                else { showingDetail = false; requestCancelContentEdit() }
            }
        }
    }
    private var contentGeneration = UUID()
    private var transformMenuRequest = UUID()
    private var transformMenu: TransformMenuController?
    #if DEBUG
    /// 测试替换最后的窗口展示步骤，真实请求与取消流程仍执行，不弹窗、不激活应用，by AI.Coding。
    var presentTransformMenuForTesting: ((TransformMenuController, NSWindow, NSPoint) -> Void)?
    #endif
    private var dismissedPopoverClickSequence = false
    private var dismissedPopoverEventTime: TimeInterval?
    /// AppKit可能先关闭transient浮层再派发原点击；记住该事件，防止同一次按下穿透。
    private func rememberNativePopoverDismissal() {
        guard let event = NSApp?.currentEvent, event.type == .leftMouseDown, event.window is ClipPanel else { return }
        dismissedPopoverClickSequence = true; dismissedPopoverEventTime = event.timestamp
    }
    /// 浮层外的左键只关闭浮层；同一双击序列的后续按下也消费，避免误粘贴。
    func dismissPopoverForBackdropClick(count: Int, timestamp: TimeInterval? = nil) -> Bool {
        if count <= 1, timestamp == nil || timestamp != dismissedPopoverEventTime { dismissedPopoverClickSequence = false }
        if dismissedPopoverClickSequence { return true }
        guard contentEditorPresented || showingDetail || showingFilters || showingStatusDetail || showingCategoryEditor || transformMenu != nil else { return false }
        dismissedPopoverClickSequence = true
        dismissedPopoverEventTime = timestamp
        if contentEditorPresented { requestCancelContentEdit(); return true }
        if showingCategoryEditor && savingCategory { return true }
        if showingDetail { showingDetail = false }
        if showingFilters { showingFilters = false }
        if showingStatusDetail { showingStatusDetail = false }
        if showingCategoryEditor { showingCategoryEditor = false }
        transformMenu?.close()
        return true
    }
    private var quickLookTask: Task<Void, Never>?
    @Published public var showingCategoryEditor = false {
        didSet { if oldValue && !showingCategoryEditor { rememberNativePopoverDismissal() } }
    }
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
    /// 在途破坏性操作可能稍后显示确认，主界面此时不得提前释放。
    var surfaceOperationPending: Bool { changingHistory || savingCategory }
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
    // 编辑sheet跟随父面板显示，隐藏期间仅保留草稿，不留下独立可见窗口，by AI.Coding。
    @Published public private(set) var panelVisible = true
    private(set) var hiddenChanges = false
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
    private var dragFileSessions: [ImageDragSession] = []
    private var internalCategoryDrop = false
    private var dragCleanup: Task<Void, Never>?
    /// 导出元数据与预览共用注入时钟，by AI.Coding。
    var previewClock: any ClipClock { clock }
    private var categoryDrag: (token: String, ids: [ClipID], expiresAt: Instant)?
    /// 参数为是否淡出：用户关闭淡出，粘贴与入队立即隐藏，by AI.Coding。
    public var closePanel: ((Bool) -> Void)?
    /// 入场位移（pt），由面板显示驱动；减弱动态效果时保持0，by AI.Coding。
    @Published var panelEntrance: CGFloat = 0
    /// 修饰键恰好等于快速粘贴修饰键时显示⌘N角标，by AI.Coding。
    @Published var quickBadgesVisible = false
    /// 追加页读取失败时“更多历史”显示重试；下一次读取开始即清除，by AI.Coding。
    @Published private(set) var loadMoreFailed = false
    public var openSettings: (() -> Void)?
    /// 打开历史管理窗口并选中给定记录；空数组只打开窗口，by AI.Coding。
    public var openHistoryManager: (([ClipID]) -> Void)?
    public var quitApplication: (() -> Void)?
    public var registerShortcut: ((Shortcut) -> Bool)?
    /// 粘贴队列快捷键只在队列进行中注册；由宿主接到系统全局快捷键，by AI.Coding。
    public var registerQueueShortcut: ((Shortcut) -> Bool)?
    public var unregisterQueueShortcut: (() -> Void)?
    public var pasteQueueChanged: (() -> Void)?
    /// 第二个参数表示失败；回退（内容已复制）与失败使用不同图标，by AI.Coding。
    public var showPasteFeedback: ((String, Bool) -> Void)?
    public var panelInteractionChanged: (() -> Void)?
    public init(store: HistoryStore, capture: CaptureCoordinator, paste: PasteCoordinator, derived: DerivedContentService, clock: any ClipClock = SystemClock()) {
        self.store = store; self.capture = capture; self.paste = paste; self.derived = derived; self.clock = clock
    }
    /// 列表先刷新；来源和空间仅在相关入口读取，事实仍来自存储，by AI.Coding。
    public func start(resumeCapture: Bool = false) async throws {
        settings = try await store.settings()
        configureHistoryViewport(width: historyViewport, cardWidth: HistoryView.cardSide(height: settings.panelHeight))
        categories = try await store.categories()
        capture.onState = { [weak self] state in self?.acceptCaptureState(state) }
        capture.onSourcePending = { [weak self] source in
            self?.onCaptureSource?(source)
            guard let self, !self.sourceSuggestions.contains(where: { $0.bundleID == source.bundleID }) else { return }
            self.sourcesNeeded = true
        }
        // 持久变更流已负责刷新，避免同一次采集同时触发两轮查询和布局。
        try await capture.start(resumeCapture: resumeCapture); settings = capture.policy; status = capture.state
        let stream = await store.events()
        subscription = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                // 新图片提交后在后台识别，不阻塞采集与查询；索引自身的写入只会命中运行中的任务而不重启。
                if case .changed = event { self.syncImageTextIndex() }
                if case .derived = event {
                    if self.settingsVisible { await self.refreshUsage() }
                    continue
                }
                if case .unavailable = event { self.message = "提交后存储不可用，请重启。已提交操作不会重放。" }
                // 删除可能来自历史管理窗口；面板的⌘Z入口跟随存储里的真实撤销状态，by AI.Coding。
                self.assignIfChanged(\.canUndoDeletion, await self.store.undoAvailable())
                if !self.panelVisible {
                    self.hiddenChanges = true
                    // 历史管理窗口可在面板隐藏时增删分类；只刷新共享分类，不改面板筛选与选择，by AI.Coding。
                    await self.reloadCategories()
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
        syncImageTextIndex()
        // 旧版缺索引只在后台有界修复；空间不足仍从原格式检索，不删除历史。
        indexRepair = Task { [weak self] in
            while let self, !Task.isCancelled {
                do { if try await self.store.rebuildSearchIndex() == 0 { return } }
                catch { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    /// 记录真正可见的卡片；窗口隐藏产生的离屏通知不丢掉最后一屏的热缓存，by AI.Coding。
    func thumbnailVisibilityChanged(id: ClipID, visible: Bool) {
        guard panelVisible else { return }
        if visible { visibleThumbnailIDs.insert(id) } else { visibleThumbnailIDs.remove(id) }
    }
    /// 隐藏期间只记失效，30秒后回收离屏图片；快速重开取消清理，by AI.Coding。
    /// 打开面板显示第一张卡片：回到最左并选中首项；隐藏期间有新记录时，随后的刷新也选中新的首项，by AI.Coding。
    func showFirstCard() {
        scrollAnchor = nil; historyOffset = 0; firstCardPending = hiddenChanges
        listState.update { scrollRestoration = .init(offset: 0); select(items.first?.id) }
    }
    private var firstCardPending = false
    public func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        refreshPastePermissionNotice()
        thumbnailCleanup?.cancel(); thumbnailCleanup = nil
        if !visible {
            firstCardPending = false
            // 尚未打开的编辑请求与Space预览不在隐藏面板上弹出；已经输入的草稿保留到下次打开。
            contentEditRequest = UUID(); if quickLookTask != nil { endQuickLook() }
            answerPanelConfirmation(false)
            quickPreview.close()
            transformMenuRequest = UUID(); transformMenu?.close()
            cancelRename()
            let delay = thumbnailCleanupDelay
            thumbnailCleanup = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled, !self.panelVisible else { return }
                // 仅释放可再生的离屏缓存，保留视口、选择、SwiftUI树和语法引擎，避免重开变慢。
                self.thumbnails.retainOnly(self.visibleThumbnailIDs)
                self.thumbnailCleanup = nil
                await self.store.releaseThumbnailMemoryCache()
            }
        }
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
        do { assignIfChanged(\.usage, try await store.usage()); assignIfChanged(\.dragFilesBytes, try await store.dragFilesBytes()) }
        catch { message = "空间计量失败" }
    }
    /// 手动清理拖出图片文件；失败时如实提示，计量以实际剩余为准，by AI.Coding。
    public func clearDragFiles() {
        Task {
            do { try await store.clearDragFiles(); notice("已清理拖出图片文件") }
            catch { message = "拖出图片文件清理未完成，请检查访问权限" }
            await refreshUsage()
        }
    }
    /// 更新输入立即作废旧queryID，防抖20ms给检索和绘制保留延迟预算。
    /// 输入防抖；点击筛选是一次性动作，不等防抖直接查询，by AI.Coding。
    public func searchChanged(debounce: Bool = true) {
        // 同一在途请求合并分类行的多个属性观察，不打断定位或重复查询，by AI.Coding。
        if locatedSearchSignature == currentSearchSignature { return }
        if queryPending, activeSearchSignature == currentSearchSignature { return }
        if let recordUndoQuery, recordUndoQuery != query { self.recordUndoQuery = nil }
        search(debounce: debounce)
    }
    /// 捕获/删除/到期刷新不额外防抖。
    public func refresh() { search(debounce: false, preserveWindow: true) }
    private var locatedSearchSignature: String?
    private var currentSearchSignature: String { searchRequest(sources: querySources).signature }
    /// 搜索框前缀条件与筛选面板合成一份请求；同一维度前缀优先，前缀不写回面板，清空搜索框即失效，by AI.Coding。
    private func searchRequest(sources: [SourceAttribution], cursor: SearchCursor? = nil, queryID: UUID = UUID(), pageSize: Int = 50) -> SearchRequest {
        let parsed = SearchQueryParser.parse(query, sources: sources, categories: categories, now: clock.now())
        let bounds = dateBounds
        return SearchRequest(parsed.literal, favorites: favorites || parsed.favorites, kind: parsed.kind ?? kind, cursor: cursor, queryID: queryID, pageSize: pageSize,
                             categoryIDs: parsed.categoryIDs.isEmpty ? activeCategories : parsed.categoryIDs, sourceBundleID: parsed.sourceBundleID ?? sourceFilter,
                             from: parsed.from ?? (parsed.until == nil ? bounds?.0 : nil), until: parsed.until ?? (parsed.from == nil ? bounds?.1 : nil), sort: .manual)
    }
    /// app:前缀需要来源列表；面板未加载时按需读取一次，后续翻页沿用同一份，by AI.Coding。
    private var querySources: [SourceAttribution] { sourceSuggestions.isEmpty ? prefixSources : sourceSuggestions }
    private var prefixSources: [SourceAttribution] = []
    /// 状态行显示的前缀条件与无法应用的原因；只在变化时发布，输入其他字符不重建列表，by AI.Coding。
    @Published public private(set) var queryConditions: [String] = []
    @Published public private(set) var queryProblems: [String] = []
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
        locatedSearchSignature = nil
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
        if !preserveWindow { listState.queryStatus.update(switching: true) }
        searching = Task { [weak self] in
            guard let self else { return }
            defer {
                // 范围切换标记只由接管查询结束时清除；变更作废查询不提前露出新范围空提示，by AI.Coding。
                if id == queryID { queryPending = false; delayedLoading?.cancel(); delayedLoading = nil; listState.queryStatus.update(switching: false) }
            }
            do {
                // 服务P95约57ms；输入防抖缩至20ms，避免单防抖就耗尽100ms预算。
                if debounce { try await Task.sleep(for: .milliseconds(20)) }
                let metadata = cheapMetadataTask ?? (metadataNeedsRetry ? prepareEventMetadata() : nil)
                try await metadata?.value
                try Task.checkCancellation()
                guard id == queryID else { return }
                // 廉价元数据裁剪完成后才固定请求，避免已删分类发布旧空结果，by AI.Coding。
                if querySources.isEmpty, query.range(of: "(^|\\s)app:", options: [.regularExpression, .caseInsensitive]) != nil { prefixSources = (try? await store.sources()) ?? [] }
                guard id == queryID else { return }
                let request = searchRequest(sources: querySources, queryID: id, pageSize: preserveWindow ? min(50, max(viewportPageSize, windowSize)) : viewportPageSize)
                let parsed = SearchQueryParser.parse(query, sources: querySources, categories: categories, now: clock.now())
                assignIfChanged(\.queryConditions, parsed.labels); assignIfChanged(\.queryProblems, parsed.problems)
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
                // 图片文字是派生数据、写入不改修订号，翻页之间新命中会把后续结果后移一位；按ID去重避免重复卡片。
                var seen = Set<ClipID>()
                let visible = window.items.filter { isVisible($0) && seen.insert($0.id).inserted }
                // 新记录插入头部时保留正在浏览的卡片与卡内偏移，不用旧像素位置显示别的记录，by AI.Coding。
                if preserveWindow, !cardReorderAnimationPending, historyOffset > 0,
                   let anchor = scrollAnchor, let index = visible.firstIndex(where: { $0.id == anchor.id }) {
                    let offset = max(0, HistoryView.cardInset + CGFloat(index) * historyStride + anchor.relative)
                    if abs(offset - historyOffset) > 0.5 { scrollRestoration = .init(offset: offset) }
                }
                listState.update {
                    if !preserveWindow {
                        selectedIDs.removeAll()
                        anchorID = nil
                        scrollAnchor = nil; historyOffset = 0
                        scrollRestoration = .init(offset: 0)
                        listState[\.scrollEpoch] += 1
                    }
                    if cardReorderAnimationPending {
                        listState[\.reorderRevision] += 1; cardReorderAnimationPending = false
                    }
                    items = visible; cursor = window.cursor; loading = false; listState.queryStatus.update(failed: false)
                    if preserveWindow {
                        selectedIDs.formIntersection(Set(items.map(\.id)))
                        if firstCardPending { firstCardPending = false; select(items.first?.id) }
                        else if let selectedID, contains(selectedID) { select(selectedID, preserveSelection: true) }
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
                listState.update { loading = false; items = []; cursor = nil; select(nil) }; listState.queryStatus.update(failed: true); message = "历史查询失败，请重试"
            }
        }
    }
    public var hasMore: Bool { cursor != nil }
    /// 首屏只读足够填满可见区域的摘要；尺寸变化只补不足，不截断浏览窗口或选择，by AI.Coding。
    func configureHistoryViewport(width: CGFloat, cardWidth: CGFloat) {
        guard width.isFinite, cardWidth.isFinite, width > 48, cardWidth > 0 else { return }
        historyViewport = width; historyStride = cardWidth + HistoryView.cardSpacing
        viewportPageSize = min(50, max(1, Int(ceil((width - 2 * HistoryView.cardInset + HistoryView.cardSpacing) / historyStride))))
        fillHistoryViewport()
    }
    /// 发布后复核最新视口；补屏查询只取缺少的行，零偏移也不会一直留空，by AI.Coding。
    private func fillHistoryViewport() {
        if started, !historyBusy, hasMore, items.count < viewportPageSize { loadMore(advanceSelection: false, pageSize: viewportPageSize - items.count) }
    }
    /// 只在实际滚动后预读一屏距离内的下一批；首屏布局/卡片appear不能级联加载，by AI.Coding。
    func historyScrolled(offset: CGFloat, epoch: Int) {
        // 已移除列表的排队回调不能污染新查询的锚点或触发额外分页，by AI.Coding。
        guard epoch == listState.snapshot.scrollEpoch else { return }
        guard historyViewport > 0, offset.isFinite else { return }
        historyOffset = max(0, offset)
        if !items.isEmpty {
            let index = min(items.count - 1, max(0, Int(floor((historyOffset - HistoryView.cardInset) / historyStride))))
            scrollAnchor = (items[index].id, historyOffset - (HistoryView.cardInset + CGFloat(index) * historyStride))
        }
        guard historyOffset > 1, !dragActive, !historyBusy, hasMore else { return }
        let end = 2 * HistoryView.cardInset + CGFloat(items.count) * historyStride - HistoryView.cardSpacing
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
        let id = queryID; loading = true; loadMoreFailed = false
        let previousCount = items.count, previousSelection = selectedID
        let request = pageRequest(cursor: cursor, queryID: id, pageSize: pageSize ?? min(50, max(8, viewportPageSize * 2)))
        // 一个在途分页任务合并连续滚动；查询切换立即取消，旧页不能混入新筛选，by AI.Coding。
        paging = Task {
            do {
                let started = ContinuousClock.now
                let page = try await store.search(request)
                if settings.timingEnabled { StageTiming.record("history_query", since: started, count: page.items.count) }
                guard !Task.isCancelled, id == queryID else { return }
                var seen = Set(items.map(\.id))
                items += page.items.filter { isVisible($0) && seen.insert($0.id).inserted }; self.cursor = page.next; loading = false
                let queued = pendingPageNavigation; pendingPageNavigation = nil; paging = nil
                let advance = (advanceSelection && selectedID == previousSelection) || (queued != nil && queued?.selection == selectedID)
                if advance, items.count > previousCount { if queued?.extend ?? extend { choose(items[previousCount].id, modifiers: .shift) } else { select(items[previousCount].id, keepDetail: previewFollowsSelection) } }
                scheduleVisibilityDeadline()
                fillHistoryViewport()
            } catch is CancellationError { }
            catch { if id == queryID { loading = false; loadMoreFailed = true; refresh() } }
        }
    }
    /// 高亮立即更新；快速连续选择取消旧元数据请求，完整正文仅在详情打开时读取。
    public func select(_ id: ClipID?, preserveSelection: Bool = false, keepDetail: Bool = false) {
        guard !dragActive else { return }
        if !preserveSelection { selectedIDs = Set(id.map { [$0] } ?? []); anchorID = id }
        if selectedID == id {
            guard let id else { return }
            // 同一ID仅元数据变化时保留正文；内容变化时重载详情，避免复制或检视旧版本。
            metadataTask?.cancel()
            let generation = selectionGeneration
            metadataTask = Task {
                guard let latest = try? await store.metadata(id: id, at: clock.now()),
                      !Task.isCancelled, selectedID == id, generation == selectionGeneration else { return }
                selectedMetadata = latest
                if var detail, detail.summary.id == id {
                    if detail.summary.contentFingerprint != latest.summary.contentFingerprint {
                        invalidateDetail(); if showingDetail { loadDetail() }
                    } else { detail.summary = latest.summary; detail.categoryIDs = latest.categoryIDs; detail.revision = latest.revision; self.detail = detail }
                }
            }
            return
        }
        // 普通选卡同步关闭旧详情，显式详情入口随后打开目标，避免视图异步回调误关闭新弹窗。
        if showingDetail && !keepDetail { showingDetail = false }
        // Space打开的预览窗口与Quick Look一致随方向键换选；其它换选关闭窗口，by AI.Coding。
        let followPreview = keepDetail && previewFollowsSelection && quickPreview.isVisible
        invalidateSelection(keepPreview: followPreview); selectedID = id
        guard let id else { if followPreview { quickPreview.close() }; return }
        if followPreview { quickLook() }
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
    /// 明确打开指定卡片详情；不依赖主队列与 SwiftUI onChange 的先后顺序，by AI.Coding。
    func showDetail(id: ClipID) {
        guard canDisplayContents, contains(id), !dragActive else { return }
        select(id); previewFollowsSelection = false; showingDetail = true
        detailVisibilityChanged()
    }
    /// 详情显示才加载完整格式；关闭时释放大内容，保留轻量选择状态。
    public func detailVisibilityChanged() {
        panelInteractionChanged?()
        // 从详情发起的识别随详情关闭取消，不写剪贴板，by AI.Coding。
        if !showingDetail, imageTextFromDetail { imageTextTask?.cancel(); imageTextTask = nil }
        // 关闭详情只是释放预览；从详情接续的转换不应被视为记录失效而取消，by AI.Coding。
        if showingDetail { loadDetail() } else { invalidateDetail(cancelTransformMenu: false, keepPreview: true) }
    }
    private func loadDetail() {
        guard canDisplayContents, let id = selectedID, !pendingDeletion.contains(id) else { return }
        if detail?.summary.id == id { return }
        invalidateDetail(); detailLoading = true
        let generation = detailID
        detailSlowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, generation == detailID, detailLoading else { return }
            detailSlow = true
        }
        detailing = Task { [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                if detailDelayForTesting > .zero { try await Task.sleep(for: detailDelayForTesting) }
                #endif
                let detail = try await store.detail(id: id, at: clock.now())
                guard !Task.isCancelled, generation == detailID, canDisplayContents, selectedID == id, showingDetail else { return }
                guard isVisible(detail.summary) else { revalidateVisibleContent(); return }
                // 正文高亮、识别结果与原图都在弹出前备好；弹窗只在详情发布后出现，不先显示加载态再撑高，by AI.Coding。
                let content = try await ClipDetailContent.load(detail)
                guard !Task.isCancelled, generation == detailID, canDisplayContents, selectedID == id else { return }
                let latest = try await store.metadata(id: id, at: clock.now())
                guard generation == detailID, canDisplayContents, selectedID == id, isVisible(latest.summary), !pendingDeletion.contains(id) else { return }
                // 异步高亮期间正文可能被编辑，旧详情不能在新摘要之后发布，by AI.Coding。
                guard latest.summary.contentFingerprint == detail.summary.contentFingerprint else {
                    invalidateDetail(); if showingDetail { loadDetail() }; return
                }
                richPreview = content.richPreview; detailInspection = content.inspection; detailHighlight = content.highlight
                if detail.summary.kind == .image || detail.summary.kind == .mixed {
                    image = content.image
                    if image == nil { previewMessage = "原图预览不可用或超过40MP；原始格式仍保留" }
                }
                detailEditable = content.editable
                self.detail = detail; detailLoading = false; detailSlowTask?.cancel(); detailSlow = false
            } catch { if generation == detailID { invalidateDetail(); detailFailed = !(error is CancellationError) } }
        }
    }
    /// 存储变更/删除作废两个请求世代，不让旧详情或旧元数据重新覆盖当前选择。
    private func invalidateSelection(keepPreview: Bool = false) {
        metadataTask?.cancel(); metadataTask = nil; selectionGeneration = UUID(); selectedMetadata = nil
        invalidateDetail(keepPreview: keepPreview)
    }
    /// 数据变更使派生内容与转换一起失效；单纯收起详情只释放预览，by AI.Coding。
    /// keepPreview：仅收起详情弹窗时保留预览窗口与待弹出的预览，换卡或内容变化仍一并关闭，by AI.Coding。
    private func invalidateDetail(cancelTransformMenu: Bool = true, keepPreview: Bool = false) {
        detailing?.cancel(); detailing = nil; detailID = UUID()
        if !keepPreview { quickLookTask?.cancel(); quickLookTask = nil; contentGeneration = UUID(); quickPreview.close() }
        // 选择/内容变更仍关闭旧转换；详情移交焦点的延迟回调不能销毁新菜单，by AI.Coding。
        if cancelTransformMenu { transformMenuRequest = UUID(); transformMenu?.close() }
        if detailEditable { detailEditable = false }
        if detail != nil { detail = nil }; if image != nil { image = nil }; if richPreview != nil { richPreview = nil }
        if detailInspection != nil { detailInspection = nil }; if detailHighlight != nil { detailHighlight = nil }
        if !previewMessage.isEmpty { previewMessage = "" }; if detailLoading { detailLoading = false }
        if !keepPreview || quickLookTask == nil { detailSlowTask?.cancel(); detailSlowTask = nil; if detailSlow { detailSlow = false } }
        if detailFailed { detailFailed = false }
    }
    /// 状态槽“重试”：保持详情打开意图，重新读取当前选择，by AI.Coding。
    func retryDetail() {
        guard showingDetail else { return }
        loadDetail()
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
    /// 搜索上下键选择记录后进入结果，下一次Return可直接执行；空结果或查询中保留输入焦点，by AI.Coding。
    func navigateFromSearch(_ delta: Int) {
        guard !historyBusy, !items.isEmpty, !dragActive else { return }
        navigate(delta)
        focusResults?()
    }
    /// 搜索焦点中的方向键导航与默认Enter操作。
    public func navigate(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        if delta > 0, current == items.count - 1, hasMore { loadMore(advanceSelection:true); return }
        select(items[min(items.count - 1, max(0, current + delta))].id, keepDetail: previewFollowsSelection)
    }
    /// 按配置动作执行；输出状态不会写成目标已接收。
    public func perform(_ format: OutputFormat? = nil, action: PasteAction? = nil, transform: TextTransform? = nil, join: JoinStyle = .newline, ids: [ClipID]? = nil) {
        let ids = ids ?? orderedSelection
        guard !ids.isEmpty else { return }
        Task {
            let result = await output(.init(ids: ids, format: format ?? settings.defaultFormat, action: action ?? settings.defaultAction, target: pasteTarget(), transform: transform, join: join))
            showPasteResult(result)
            notifyPasteResult(result)
        }
    }
    /// 输出并记录使用；面板与历史管理窗口共用，结果提示由调用方决定，by AI.Coding。
    func output(_ request: PasteRequest) async -> PasteResult {
        let result = await paste.perform(request)
        await recordUse(request.ids, result)
        return result
    }
    /// 按完整选择检查，不能由当前主卡片代表其它所选项目，by AI.Coding。
    func canCopyAsText(_ ids: Set<ClipID>) async -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            for id in ids {
                try Task.checkCancellation()
                guard try await store.metadata(id: id, at: clock.now()).hasTextRepresentations else { return false }
            }
            try Task.checkCancellation()
            return true
        } catch { return false }
    }
    private var renameGeneration = UUID()
    private var renameTask: Task<Void, Never>?
    @Published public private(set) var renamingID: ClipID?
    @Published private(set) var contentEditor: ClipContentEditorState?
    private var contentEditRequest = UUID()
    /// 隐藏面板或内容时只保留草稿，不能继续拦截历史复制等快捷键，by AI.Coding。
    var contentEditorPresented: Bool { contentEditor != nil && canDisplayContents && panelVisible }
    /// 所选记录的快捷键入口复用菜单编辑行为，多选时不任取一项，by AI.Coding。
    func editSelectedContent() {
        guard selectedIDs.count == 1, let id = selectedID else { return }
        beginContentEdit(id)
    }
    /// 读取完整载荷后再显示编辑器，原卡片双击粘贴和标题重命名保持原样，by AI.Coding。
    func beginContentEdit(_ id: ClipID) {
        if let existing = contentEditor {
            if existing.id == id { return }
            if !existing.hasChanges && !existing.saving { discardContentEdit() }
            else { requestCancelContentEdit(); return }
        }
        guard canDisplayContents, panelVisible, !dragActive, contains(id), contentEditor == nil else { return }
        cancelRename(); showingDetail = false; showingCategoryEditor = false; showingFilters = false; showingStatusDetail = false
        let request = UUID(); contentEditRequest = request
        Task {
            do {
                let detail = try await store.detail(id: id, at: clock.now())
                guard request == contentEditRequest, panelVisible, canDisplayContents, contains(id), contentEditor == nil else { return }
                guard let editor = ClipContentEditorState(detail: detail) else { message = ContentEditError.unsupportedContent.message; return }
                contentEditor = editor
                panelInteractionChanged?()
                await editor.detectLanguage()
            } catch { if request == contentEditRequest { message = ClipContentEditorState.loadFailure } }
        }
    }
    /// 取消有修改时先确认，失焦或列表刷新不删除草稿，by AI.Coding。
    func requestCancelContentEdit() {
        guard let editor = contentEditor, !editor.saving else { return }
        if editor.hasChanges { editor.confirmingDiscard = true } else { discardContentEdit() }
    }
    /// 明确放弃后释放草稿，不向存储发送写操作，by AI.Coding。
    func discardContentEdit() {
        guard contentEditor?.saving != true else { return }
        contentEditor = nil; contentEditRequest = UUID(); panelInteractionChanged?()
    }
    /// 保存失败保留草稿和错误；只在原子提交成功后关闭编辑器，by AI.Coding。
    func saveContentEdit() {
        guard let editor = contentEditor, let saving = editor.save(to: store) else { return }
        Task {
            guard await saving.value else { return }
            finishSavedContentEdit(editor)
            notice("内容已保存"); panelInteractionChanged?()
        }
    }
    /// 保存成功时编辑器仍处于锁定态，不能使用只允许未保存态的 discard 入口。
    func finishSavedContentEdit(_ editor: ClipContentEditorState) {
        if contentEditor === editor { contentEditor = nil; contentEditRequest = UUID(); panelInteractionChanged?() }
    }
    static let renameFailure = "重命名失败：名称需为单行且不超过1024字节，记录和容量仍须有效"
    /// 只编辑指定卡片的名称，不改变单选/多选与当前滚动窗口，by AI.Coding。
    public func beginRename(_ id: ClipID) {
        guard !dragActive, contains(id), contentEditor == nil else { return }
        renameGeneration = UUID(); renamingID = id
    }
    /// 取消仅移除编辑状态，不写库，by AI.Coding。
    public func cancelRename(id: ClipID? = nil) {
        if let id, id != renamingID { return }
        renameGeneration = UUID(); renamingID = nil
    }
    /// 本地输入变动只推进草稿版本，不发布全局状态或改写已提交的名称。
    func renameDraftChanged(id: ClipID) {
        guard renamingID == id else { return }
        renameGeneration = UUID()
    }
    /// 按提交顺序保存；旧结果不得关闭用户继续编辑或再次提交的新草稿。
    public func saveRename(id: ClipID, title: String) {
        guard renamingID == id else { return }
        renameGeneration = UUID()
        let generation = renameGeneration, previous = renameTask
        renameTask = Task {
            await previous?.value
            do {
                try await store.renameClip(id: id, title: title)
                guard generation == renameGeneration else { return }
                renamingID = nil
                notice("已重命名")
            }
            catch {
                if generation == renameGeneration { message = Self.renameFailure }
            }
        }
    }
    /// 切换前等待与原入口相同的改名任务；失败继续保留编辑界面。
    func saveRenameBeforeLeaving(id: ClipID, title: String) async -> Bool {
        saveRename(id: id, title: title)
        await renameTask?.value
        return renamingID == nil
    }
    /// 双击恢复原格式后向原应用焦点粘贴；Finder文件对象仍复制到其当前实际目录。
    public func doubleClick(_ id: ClipID) {
        guard contains(id) else { return }
        if !selectedIDs.contains(id) { select(id) }
        focusResults?()
        let ids = orderedSelection
        let rememberedTarget = pasteTarget()
        let copyFiles = ids.allSatisfy { id in items.first(where: { $0.id == id })?.kind == .file } && rememberedTarget?.bundleID == "com.apple.finder"
        Task {
            let result = await paste.perform(.init(ids: ids, format: settings.defaultFormat, action: copyFiles ? .copy : .directPaste, target: rememberedTarget), copyFilesToFinder: copyFiles)
            showPasteResult(result)
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
        // 授权向导已说明原因和操作，不再叠加同义提示，by AI.Coding。
        if AccessibilityGuide.shared.isVisible { return }
        switch result {
        // 本该粘贴却只完成复制、失败或智能粘贴降级，都是需要用户留意的问题。
        case .fallback, .failed: showPasteFeedback?(message, true)
        case _ where paste.smartPasteNotice != nil: showPasteFeedback?(message, true)
        default: break
        }
    }
    /// 破坏性操作只能经预览和用户确认；过期token要求再次预览。
    /// 确认位置按调用来源在发起时确定，不在预览返回后读取当时的key窗口，by AI.Coding。
    public func change(_ change: HistoryChange, fromSettings: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !changingHistory else { completion?(false); return }
        changingHistory = true
        Task {
            var succeeded = false
            defer { changingHistory = false; completion?(succeeded) }
            do {
                let result = try await commit(change, confirm: { preview in
                    confirmingChange = true; panelInteractionChanged?()
                    let accepted = fromSettings ? await ChangeConfirmation.confirm(preview) : await confirmInPanel(preview)
                    confirmingChange = false; panelInteractionChanged?()
                    return accepted
                }, willApply: {
                    searching?.cancel(); delayedLoading?.cancel(); queryPending = false; queryID = UUID(); cursor = nil; loading = false
                    invalidateSelection()
                    if case .delete(let ids) = change {
                        // 确认后仅撤销被删记录，保留相邻卡片；在途旧查询也受删除集合过滤。
                        let previous = items.firstIndex(where: { $0.id == selectedID }) ?? 0
                        selectedIDs.subtract(ids); pendingDeletion.formUnion(ids)
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.2)) { items.removeAll { pendingDeletion.contains($0.id) } }
                        select(items.isEmpty ? nil : items[min(previous, items.count - 1)].id)
                    } else { selectedMetadata = nil }
                }, didApply: {
                    // 提交前查询已作废；提交事件拥有刷新，不能在返回时取消新版本查询，by AI.Coding。
                    pendingDeletion.removeAll()
                })
                guard let result else { return }
                if case .delete = change { recordUndoQuery = canUndoDeletion ? query : nil }
                notice(changeMessage(change, result: result)); succeeded = true
            } catch StoreError.stalePreview { pendingDeletion.removeAll(); message = "历史已变化，请重新预览并确认"; refresh() }
            catch { pendingDeletion.removeAll(); message = "变更未完成，旧内容保持或存储不可用，请检查状态"; refresh() }
        }
    }
    /// 预览→确认→提交→容量/计量/撤销收尾；面板与历史管理窗口共用，确认方式与界面反馈由调用方决定。
    /// 用户取消返回nil；willApply在提交前、didApply在提交成功后立即执行，by AI.Coding。
    func commit(_ change: HistoryChange, isCurrent: (ChangePreview) -> Bool = { _ in true }, confirm: (ChangePreview) async -> Bool,
                willApply: () -> Void = {}, didApply: () -> Void = {}) async throws -> ChangeResult? {
        let preview = try await store.preview(change)
        // 调用方的目标集合基于旧版本时不提交，by AI.Coding。
        guard isCurrent(preview) else { throw StoreError.stalePreview }
        if preview.requiresConfirmation, !(await confirm(preview)) { return nil }
        willApply()
        let result = try await store.apply(preview.token)
        // 新删除替换全局撤销包，旧的搜索框撤销资格随之失效；面板删除在返回后重新绑定，by AI.Coding。
        if case .delete = change { recordUndoQuery = nil }
        didApply()
        switch change { case .delete, .clearOrdinary: capture.discardPendingRetries(); default: break }
        await capture.refreshCapacity()
        // 删除和容量/期限操作后更新计量，其他变更只在设置窗口可见时读取，by AI.Coding。
        switch change {
        case .delete, .clearOrdinary, .quota, .retention, .deleteCategory: await refreshUsage()
        default: if settingsVisible { await refreshUsage() }
        }
        canUndoDeletion = await store.undoAvailable()
        return result
    }
    /// 分类归属成功后明确目标名称；只有提交完成才报告加入成功。
    /// 结果在界面上已可见，只给简短提示；删除保留撤销入口，by AI.Coding。
    func changeMessage(_ change: HistoryChange, result: ChangeResult) -> String {
        switch change {
        case .category(_, let categoryID, true): "已加入“\(categories.first(where: { $0.id == categoryID })?.name ?? "分类")”"
        case .category(_, _, false): "已移出分类"
        case .favorite(_, let on), .favorites(_, let on): on ? "已收藏" : "已取消收藏"
        case .delete: canUndoDeletion ? "已删除 \(result.removed) 条 · ⌘Z 撤销" : "已删除 \(result.removed) 条"
        case .clearOrdinary, .retention, .quota, .deleteCategory:
            result.removed > 0 ? "已清理 \(result.removed) 条，释放 \(Self.bytes(result.reclaimedBytes))" : "已保存"
        }
    }
    /// 面板内确认不新建窗口，面板frame与焦点保持不变；保留预览版本校验，by AI.Coding。
    /// 预览返回前面板已收起则视为取消，不在隐藏面板上留下确认；浮层不压在详情等自有弹窗之下。
    func confirmInPanel(_ preview: ChangePreview) async -> Bool {
        guard panelVisible else { return false }
        answerPanelConfirmation(false)
        // 与隐藏面板相同地作废在途的编辑、转换菜单与Space预览，避免晚到的弹窗压在浮层上。
        contentEditRequest = UUID(); transformMenuRequest = UUID(); transformMenu?.close()
        if quickLookTask != nil { endQuickLook() }
        if quickPreview.isVisible { quickPreview.close(); previewFollowsSelection = false }
        showingDetail = false; showingCategoryEditor = false; showingFilters = false; showingStatusDetail = false
        return await withCheckedContinuation { continuation in
            panelConfirmationAnswer = continuation
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.18)) { panelConfirmation = ChangeConfirmationCopy(preview) }
        }
    }
    /// 按钮、Return/Esc或面板隐藏只响应一次，取消不改变持久化数据，by AI.Coding。
    func answerPanelConfirmation(_ accepted: Bool) {
        guard let continuation = panelConfirmationAnswer else { return }
        panelConfirmationAnswer = nil
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.18)) { panelConfirmation = nil }
        continuation.resume(returning: accepted)
    }
    /// 键盘删除沿用同一预览/确认/事务流程，不另造直接删库入口。
    public func deleteSelected() {
        guard let id = selectedID, contains(id), !changingHistory else { return }
        change(.delete(orderedSelection))
    }
    /// 分类色板：编辑器显示顺序与新建分类的默认色轮换顺序，by AI.Coding。
    static let categoryPalette: [(hex: String, name: String)] = [("34C759", "绿色"), ("007AFF", "蓝色"), ("AF52DE", "紫色"), ("FFCC00", "黄色"), ("FF3B30", "红色"), ("8E8E93", "灰色")]
    /// 新建分类默认取首个未被使用的颜色；全部用过则按分类数取模轮换，by AI.Coding。
    var nextCategoryColor: String {
        let used = Set(categories.map { $0.colorHex.uppercased() })
        return Self.categoryPalette.first { !used.contains($0.hex) }?.hex ?? Self.categoryPalette[categories.count % Self.categoryPalette.count].hex
    }
    /// 分类在面板内编辑，只有持久化成功后才更新标签和归属入口。
    private let categorySurfaceDraftID = UUID()
    private var categoryDraftBaseline: (name: String, color: String)?
    public func editCategory(_ category: ClipCategory? = nil) {
        guard !savingCategory, !surfaceEdits.resolving else { return }
        // 双击和右键遵循同一保护规则：未保存的旧稿只能重开，不能被另一分类覆盖。
        if let baseline = categoryDraftBaseline, categoryDraft != baseline.name || categoryColor != baseline.color {
            showingCategoryEditor = true; return
        }
        categoryBeingEdited = category; categoryDraft = category?.name ?? ""; categoryColor = category?.colorHex ?? nextCategoryColor; categoryError = ""
        categoryDraftBaseline = (categoryDraft, categoryColor)
        showingDetail = false; showingCategoryEditor = true
        let initialColor = categoryColor
        surfaceEdits.register(categorySurfaceDraftID, surface: .cards, draft: .init(title: "分类修改", dirty: { [weak self] in
            guard let self else { return false }
            return self.savingCategory || self.categoryDraft != (category?.name ?? "") || self.categoryColor != initialColor
        }, save: { [weak self] in await self?.saveCategoryBeforeLeaving() ?? false }, discard: { [weak self] in self?.cancelCategoryEditor() }))
    }
    /// 明确取消分类编辑才清除草稿保护，原生浮层临时失焦不丢输入。
    func cancelCategoryEditor() { showingCategoryEditor = false; categoryDraftBaseline = nil; surfaceEdits.remove(categorySurfaceDraftID) }
    /// 只更新共享分类列表；面板筛选裁剪仍在可见刷新时进行，by AI.Coding。
    func reloadCategories() async {
        if let value = try? await store.categories() { assignIfChanged(\.categories, value) }
    }
    static func categoryFailure(_ error: Error) -> String { (error as? CategoryError)?.message ?? "分类保存失败，请检查容量或存储状态" }
    public func saveCategory() { Task { await saveCategoryBeforeLeaving() } }
    /// 返回真实保存结果，窗口切换不得早于持久化成功。
    @discardableResult func saveCategoryBeforeLeaving() async -> Bool {
        guard !savingCategory else { return false }
        let category = categoryBeingEdited, name = categoryDraft
        savingCategory = true; categoryError = ""
        defer { savingCategory = false }
        do {
                if let category {
                    try await store.renameCategory(id: category.id, name: name, colorHex: categoryColor)
                    notice("已保存分类")
                } else {
                    let created = try await store.createCategory(name: name, colorHex: categoryColor)
                    selectCategories([created.id])
                    notice("已创建分类")
                }
                showingCategoryEditor = false; categoryDraftBaseline = nil; surfaceEdits.remove(categorySurfaceDraftID); return true
        } catch { categoryError = Self.categoryFailure(error); showingCategoryEditor = true; return false }
    }
    /// 开始拖动只生成短期ID令牌，正文由公开提供者按需读取。
    public func registerDragAccess(_ access: ClipExportAccess) { dragAccesses.append(access) }
    /// 起手登记同步会话对象，不用异步URL回调，避免结束拖动时漏掉延迟创建的文件，by AI.Coding。
    func registerDragSession(_ session: ImageDragSession) { dragFileSessions.append(session) }
    /// 下次写入之前等待上一轮回收，防止同名路径复用竞争。
    func waitForDragCleanup() async { await dragCleanup?.value }
    /// 内部分类或取消只回收本次新建图片文件；失败可见，不能假报已释放。
    private func finishDragFiles(keepFiles: Bool) {
        let files = dragFileSessions.flatMap { $0.finish(keepFiles: keepFiles) }, previous = dragCleanup, store = store
        dragFileSessions.removeAll()
        guard !files.isEmpty else { return }
        dragCleanup = Task { [weak self] in
            await previous?.value
            do { try await store.removeDragFiles(files) }
            catch { self?.message = "部分拖出临时文件未能清理，可在存储设置中查看" }
        }
    }
    /// 结束拖动保持既有选择恢复；取消/内部归类释放新建文件，外部引用继续保留。
    public func finishDrag(cancelled: Bool) {
        if cancelled { for access in dragAccesses { access.cancel() }; categoryDrag = nil }
        finishDragFiles(keepFiles: !cancelled && !internalCategoryDrop)
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
        dragSelection = nil; dragQuerySignature = nil; panelInteractionChanged?()
        #if DEBUG
        GUIAcceptanceProbe.event(cancelled ? "drag-cancelled" : "drag-completed", self)
        #endif
    }
    /// 准备原生拖动时冻结选择和查询身份，后续内部投放必须属于同一浏览范围，by AI.Coding。
    public func prepareDrag(_ clipID: ClipID) -> String {
        internalCategoryDrop = false
        dragQuerySignature = currentSearchSignature
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
    /// 冻结来源范围，避免拖动期间切换分类后把同一批记录排入其他范围，by AI.Coding。
    private var dragQuerySignature: String?
    private(set) var reorderingCards = false
    private var cardReorderAnimationPending = false
    /// 仅当前内部会话可调整卡片；正文检索有匹配排名，不提供与排名冲突的插入反馈。
    func canReorderCards(_ token: String, relativeTo anchor: ClipID? = nil) -> Bool {
        let request = searchRequest(sources: querySources)
        guard dragActive, !changingHistory, !historyBusy, !reorderingCards,
              let drag = categoryDrag, drag.token == token, clock.now() <= drag.expiresAt,
              dragQuerySignature == currentSearchSignature,
              SearchNormalizer.normalize(request.literal).isEmpty else { return false }
        if let anchor, !contains(anchor) || drag.ids.contains(anchor) || pendingDeletion.contains(anchor) { return false }
        return !drag.ids.isEmpty && drag.ids.allSatisfy { contains($0) && !pendingDeletion.contains($0) }
    }
    /// 同步认领内部令牌后持久化；失败不乐观重排，也不把内部整理当成外部导出保留文件。
    func reorderCards(_ token: String, relativeTo anchor: ClipID, after: Bool) -> Bool {
        guard canReorderCards(token, relativeTo: anchor), let drag = categoryDrag else { return false }
        let request = searchRequest(sources: querySources)
        let category = request.categoryIDs.count == 1 ? request.categoryIDs.first : nil
        categoryDrag = nil; internalCategoryDrop = true; reorderingCards = true; cardReorderAnimationPending = true
        finishDragFiles(keepFiles: false)
        Task {
            defer { reorderingCards = false }
            do {
                try await store.reorderItems(drag.ids, categoryID: category, relativeTo: anchor, after: after)
                refresh()
            } catch { cardReorderAnimationPending = false; message = "卡片顺序未保存，请重试" }
        }
        return true
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
        internalCategoryDrop = true
        finishDragFiles(keepFiles: false)
        change(.category(drag.ids, categoryID, true))
        return true
    }
    /// 分类变更只影响归属，成功后刷新查询版本，旧分页结果不能混入新分类。
    public func setCategory(_ clipID: ClipID, categoryID: String, included: Bool) {
        let ids = selectedIDs.contains(clipID) ? orderedSelection : [clipID]
        change(.category(ids, categoryID, included))
    }
    /// 恢复动作同时取消定时暂停，避免按钮显示恢复却仍不记录，by AI.Coding。
    public func resumeRecording() {
        updateSettings { $0.captureEnabled = true; $0.pauseUntil = nil }
    }
    /// 菜单和面板共用暂停意图，不依赖异步状态文案；到期暂停不再显示为暂停，by AI.Coding。
    var recordingPaused: Bool {
        !settings.captureEnabled || settings.pauseUntil.map { $0 > clock.now() } == true
    }
    /// 恢复入口同时清除手动和定时暂停，暂停入口保持即时阻止采集的原有语义。
    func toggleRecording() {
        if recordingPaused { resumeRecording() }
        else { setCaptureEnabled(false) }
    }
    /// 统一清除范围筛选；搜索词保持不变，由独立清除搜索动作控制，by AI.Coding。
    public func clearHistoryFilters() {
        sourceFilter = nil; dateFilterEnabled = false; categoryFilters = []; categoryID = nil
        kind = nil; favorites = false
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
            let previousQueueShortcut = activeQueueShortcut
            let replacingQueueShortcut = pasteQueueActive && next.queueShortcut != previous.queueShortcut
            if replacingQueueShortcut, registerQueueShortcut?(next.queueShortcut) != true {
                if next.shortcut != previous.shortcut { _ = registerShortcut?(previous.shortcut) }
                capture.updatePolicy(previous); message = "队列快捷键注册冲突，保留原快捷键"; return
            }
            if replacingQueueShortcut { activeQueueShortcut = next.queueShortcut; pendingQueueShortcut = next.queueShortcut }
            defer { pendingQueueShortcut = nil }
            do {
                settings = try await store.updateCaptureSettings(next); capture.updatePolicy(settings); settingsChanged?()
                notice("设置已保存")
            } catch {
                if replacingQueueShortcut, pasteQueueActive, activeQueueShortcut == next.queueShortcut, let previousQueueShortcut {
                    if registerQueueShortcut?(previousQueueShortcut) == true { activeQueueShortcut = previousQueueShortcut }
                    else { stopPasteQueue() }
                }
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
    /// 清理在首轮维护（启动约60秒后）、此后每分钟和唤醒调用；导出文件仍按10分钟租约到期，所有读取入口自行检查到期。
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
    nonisolated public static func bytes(_ value: Int64) -> String {
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
        searchRequest(sources: querySources, cursor: cursor, queryID: queryID, pageSize: pageSize)
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
    public func toggleCategory(_ id: String, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        // 普通单击只切换，不把已选分类反向取消；双击的第一次点击因此也保持原范围。
        guard modifiers.contains(.command) else { selectCategories([id]); return }
        var next = activeCategories
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
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
        Task { if await restoreDeleted() { notice("已撤销删除") } else { message = Self.undoFailure } }
    }
    static let undoFailure = "不能撤销：期限、容量、策略或内容已变化"
    /// 撤销最近一次删除；面板与历史管理窗口共用，提示由调用方决定，by AI.Coding。
    func restoreDeleted() async -> Bool {
        do { try await store.undoDelete(); recordUndoQuery = nil; canUndoDeletion = false; pendingDeletion.removeAll(); return true }
        catch { canUndoDeletion = false; return false }
    }
    /// 依据当前记录ID逐页定位，不使用旧偏移。
    public func jumpToHistory(category: String? = nil, id: ClipID? = nil) {
        guard let wanted = id ?? selectedID else { return }
        firstCardPending = false
        searching?.cancel(); paging?.cancel(); paging = nil; pendingPageNavigation = nil
        queryID = UUID(); let generation = queryID
        let targetCategories = Set(category.map { [$0] } ?? [])
        activeSearchSignature = currentSearchSignature; beginQueryLoading(generation); listState.queryStatus.update(switching: true)
        // 定位也拥有完整查询生命周期；取消、失败和空结果都释放逻辑忙碌状态，by AI.Coding。
        searching = Task {
            defer {
                if generation == queryID { queryPending = false; delayedLoading?.cancel(); delayedLoading = nil; loading = false; listState.queryStatus.update(switching: false) }
            }
            do {
                _ = try await store.metadata(id: wanted, at: clock.now())
                try Task.checkCancellation(); guard generation == queryID else { return }
                var next: SearchCursor?; var found: [ClipSummary] = []
                repeat {
                    let page = try await store.search(SearchRequest(cursor: next, queryID: generation, categoryIDs: targetCategories, sort: .manual))
                    guard !Task.isCancelled, generation == queryID else { return }; found += page.items; next = page.next
                } while !found.contains(where: { $0.id == wanted }) && next != nil
                let visible = found.filter(isVisible)
                guard let index = visible.firstIndex(where: { $0.id == wanted }) else { message = "记录已删除、到期或离开分类"; return }
                // 查到目标后才提交筛选；同一选择也发布独立滚动请求，by AI.Coding。
                query = ""; favorites = false; kind = nil; sourceFilter = nil; dateFilterEnabled = false
                categoryID = category; categoryFilters = targetCategories
                queryConditions = []; queryProblems = []
                activeSearchSignature = currentSearchSignature; locatedSearchSignature = currentSearchSignature
                listState.update {
                    items = visible; cursor = next; loading = false; listState.queryStatus.update(failed: false); select(wanted)
                    scrollRestoration = .init(offset: max(0, HistoryView.cardInset + CGFloat(index) * historyStride))
                }
                focusResults?()
            } catch is CancellationError { }
            catch { if generation == queryID { message = "无法定位：记录已变化" } }
        }
    }
    /// Space开关预览：已打开则关闭，否则打开并让方向键换选跟随，by AI.Coding。
    /// 读取中再按Space取消待弹出的预览，by AI.Coding。
    func toggleQuickLook() {
        if quickLookTask != nil { endQuickLook(); previewFollowsSelection = false; return }
        if quickPreview.isVisible { quickPreview.close(); previewFollowsSelection = false; return }
        if showingDetail { showingDetail = false; return }
        previewFollowsSelection = true; quickLook()
    }
    /// “预览”菜单与Space同一入口：先选中该卡，再按相同规则打开并让方向键跟随，by AI.Coding。
    func preview(id: ClipID) {
        guard canDisplayContents, contains(id) else { return }
        select(id); previewFollowsSelection = true; quickLook()
    }
    /// 从跟随的详情弹窗换到预览窗口时，收起弹窗不结束方向键跟随，by AI.Coding。
    private func closeDetailKeepingFollow() {
        guard showingDetail else { return }
        let follows = previewFollowsSelection
        showingDetail = false; previewFollowsSelection = follows
    }
    /// 结束待弹出的预览请求并清掉它的等待反馈。
    private func endQuickLook() {
        quickLookTask?.cancel(); quickLookTask = nil
        detailSlowTask?.cancel(); detailSlowTask = nil
        if detailSlow { detailSlow = false }
    }
    /// Space按需预览；读取前后复查展示策略、选择与请求身份；等待反馈从按下起覆盖整个读取，by AI.Coding。
    /// 主界面交接前取消图片读取，收回所有只读浮层，防止异步预览迟到。
    func closeQuickLookForTransition() {
        endQuickLook(); quickPreview.close(); previewFollowsSelection = false
        showingDetail = false; showingFilters = false; showingStatusDetail = false; showingCategoryEditor = false
        transformMenu = nil
    }
    public func quickLook() {
        guard canDisplayContents, let selectedID else { return }
        endQuickLook()
        let generation = contentGeneration
        quickLookTask = Task {
            do {
                #if DEBUG
                if detailDelayForTesting > .zero { try await Task.sleep(for: detailDelayForTesting) }
                #endif
                let detail = try await store.detail(id: selectedID, at: clock.now())
                let latest = try await store.metadata(id: selectedID, at: clock.now())
                let currentSettings = try await store.settings()
                // 纯图片在等待反馈内解码原图，Space再按仍可取消；超过40MP或损坏时不分配巨大位图。
                // 多张图片逐项解码，与文件引用一样可在窗口内上一项/下一项切换；单项损坏不遮蔽其它图片。
                // 仅把Sendable图片数据带回主线程；旧版SDK的NSImage/预览条目不能跨任务传递，by AI.Coding。
                let previewItems = await QuickPreview.loadItems(detail)
                // 被取消或代次变化的旧请求不碰任何状态，等待与失败由取消方清理。
                guard !Task.isCancelled, generation == contentGeneration else { return }
                let slow = detailSlow
                endQuickLook()
                // 跟随换选时窗口仍显示上一项；本项无法预览时关闭，不能把旧内容当成新选择。
                guard canDisplayContents, panelVisible, !currentSettings.hideContents, self.selectedID == selectedID, isVisible(latest.summary) else { quickPreview.close(); return }
                // 文件与纯图片打开预览窗口（文件按内容选择正文/系统预览，图片可缩放）；其余内容沿用详情弹窗。
                if detail.payload.fileURLs != nil {
                    closeDetailKeepingFollow()
                    quickPreview.show(previewItems, parent: previewParent?(), excludeFromSharing: settings.excludeFromSharing)
                } else if detail.summary.kind == .image {
                    closeDetailKeepingFollow()
                    guard !previewItems.isEmpty else { quickPreview.close(); message = "图片预览不可用：数据无法解码或超过40MP，原始数据已保留"; return }
                    quickPreview.show(previewItems, parent: previewParent?(), excludeFromSharing: settings.excludeFromSharing)
                } else {
                    quickPreview.close()
                    showingDetail = true; detailVisibilityChanged()
                    // 已经显示等待时接续到详情读取，不在两段读取之间熄灭。
                    if slow, detailLoading { detailSlow = true }
                }
            } catch {
                guard !Task.isCancelled, generation == contentGeneration else { return }
                endQuickLook(); quickPreview.close(); message = "预览不可用，记录已变化"
            }
        }
        detailSlowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, generation == contentGeneration, quickLookTask != nil else { return }
            detailSlow = true
        }
    }
    // MARK: F19 连续粘贴队列：只存在内存里，按选择顺序每按一次快捷键粘贴下一项，by AI.Coding。
    @Published public private(set) var pasteQueue: [ClipID] = []
    @Published public private(set) var pasteQueuePosition = 0
    /// 发布处理中状态，浮窗在重试在途时禁用确认/重试按钮，不静默吞掉点击。
    @Published private(set) var pasteQueueBusy = false
    private var pasteQueueGeneration = UUID()
    private var pasteQueueTask: Task<Void, Never>?
    private var activeQueueShortcut: Shortcut?
    private var pendingQueueShortcut: Shortcut?
    private var pasteQueueIdle: Task<Void, Never>?
    public var pasteQueueActive: Bool { pasteQueuePosition < pasteQueue.count }
    /// 意图直接粘贴却只完成复制（修饰键降级或权限/目标回退）：停在当前项，等用户手动粘贴后确认或重试；再按快捷键不覆盖剪贴板，by AI.Coding。
    @Published public private(set) var pasteQueueAwaiting = false
    /// 当前项已记过一次使用；重试或确认不重复增加复制次数。
    private var pasteQueueRecordedPosition: Int?
    /// 进入等待时的原因；再按快捷键的提醒保留它，用户仍知道重试前该先处理什么。
    private var pasteQueueAwaitingMessage = ""
    /// 宿主显示队列浮窗时，开始与每步成功只更新浮窗，失败与回退写入浮窗警告，不另弹提示，by AI.Coding。
    public var showsQueuePanel = false
    @Published private(set) var pasteQueueWarning: String?
    /// 入队时记下每项一行摘要；队列不随列表翻页或筛选变化，by AI.Coding。
    private var pasteQueueSummaries: [String] = []
    var pasteQueueNextSummary: String {
        if !canDisplayContents { return "内容已隐藏" }
        return pasteQueueSummaries.indices.contains(pasteQueuePosition) ? pasteQueueSummaries[pasteQueuePosition] : "—"
    }
    var pasteQueueShortcutLabel: String { HotKeyService.label(activeQueueShortcut ?? settings.queueShortcut) }
    /// note：成功时仍需留在浮窗里的说明（如中途跳过的项），不改变成功/失败语义，by AI.Coding。
    private func queueFeedback(_ text: String, failed: Bool, note: String? = nil) {
        guard showsQueuePanel, pasteQueueActive else { showPasteFeedback?(text, failed); return }
        pasteQueueWarning = failed ? text : note; pasteQueueChanged?()
    }
    public var pasteQueueStatus: String? {
        guard pasteQueueActive else { return nil }
        if pasteQueueAwaiting { return "粘贴队列 \(pasteQueuePosition)/\(pasteQueue.count) · 当前项已复制，等待手动粘贴后确认" }
        return "粘贴队列 \(pasteQueuePosition)/\(pasteQueue.count) · \(HotKeyService.label(activeQueueShortcut ?? settings.queueShortcut)) 粘贴下一项"
    }
    static let pasteQueueAwaitingReminder = "快捷键不会覆盖当前项：请手动粘贴后点“已手动粘贴，继续”，或点“重试当前项”"
    /// 新队列替换旧队列；快捷键注册失败（冲突）则不启动，by AI.Coding。
    public func startPasteQueue(_ ids: [ClipID]) {
        guard ids.count >= 2 else { return }
        let shortcut = pendingQueueShortcut ?? settings.queueShortcut
        guard registerQueueShortcut?(shortcut) == true else {
            message = "队列快捷键 \(HotKeyService.label(settings.queueShortcut)) 注册冲突，请在设置 › 粘贴中更换"; showPasteFeedback?(message, true); return
        }
        pasteQueueTask?.cancel(); pasteQueueTask = nil; pasteQueueGeneration = UUID(); pasteQueueBusy = false
        activeQueueShortcut = shortcut
        pasteQueueSummaries = ids.map { id in
            items.first { $0.id == id }.map(HistoryView.displayTitle) ?? "—"
        }
        pasteQueue = ids; pasteQueuePosition = 0; pasteQueueWarning = nil; pasteQueueAwaiting = false; pasteQueueRecordedPosition = nil; touchPasteQueue()
        closePanel?(false)
        queueFeedback("已加入粘贴队列 0/\(ids.count) · \(HotKeyService.label(shortcut)) 粘贴下一项", failed: false)
        pasteQueueChanged?()
    }
    /// 停止使尚未发布的请求失效；不能撤回已发出的系统命令，by AI.Coding。
    public func stopPasteQueue() {
        pasteQueueTask?.cancel(); pasteQueueTask = nil; pasteQueueGeneration = UUID(); pasteQueueBusy = false
        activeQueueShortcut = nil
        guard !pasteQueue.isEmpty else { return }
        pasteQueue = []; pasteQueuePosition = 0; pasteQueueSummaries = []; pasteQueueWarning = nil; pasteQueueAwaiting = false; pasteQueueRecordedPosition = nil
        pasteQueueIdle?.cancel(); pasteQueueIdle = nil
        unregisterQueueShortcut?(); pasteQueueChanged?()
    }
    /// 10分钟没有按键自动结束，避免快捷键长期占用。
    private func touchPasteQueue() {
        pasteQueueIdle?.cancel()
        pasteQueueIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.stopPasteQueue()
        }
    }
    /// 宿主在按键时已记住当前前台应用与焦点；处理中再按忽略，不排队。
    /// 物理修饰键（如队列快捷键的⌃⌥）未松开时最多等500ms，超时只复制并停在当前项等待确认，by AI.Coding。
    /// retry：用户点“重试当前项”，重新输出等待确认的那一项；当前项已失效时只跳过并说明，不顺带粘贴下一项。
    public func pasteQueueNext(target: TargetToken?, retry: Bool = false, modifiersHeld: @escaping () -> Bool) {
        guard pasteQueueActive, !pasteQueueBusy else { return }
        if pasteQueueAwaiting, !retry { touchPasteQueue(); queueFeedback(pasteQueueAwaitingMessage + "；" + Self.pasteQueueAwaitingReminder, failed: true); return }
        guard let target else { queueFeedback("请先切换到要粘贴的应用", failed: true); return }
        pasteQueueBusy = true; touchPasteQueue()
        // 请求开始时固定用户原始动作与格式，等待修饰键期间改设置不改变本次判定。
        let generation = pasteQueueGeneration, ids = pasteQueue, intended = settings.defaultAction, format = settings.defaultFormat
        pasteQueueTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == pasteQueueGeneration { pasteQueueBusy = false; pasteQueueTask = nil } }
            let deadline = ContinuousClock.now + .milliseconds(500)
            while modifiersHeld(), ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard generation == pasteQueueGeneration else { return }
            }
            guard !Task.isCancelled, generation == pasteQueueGeneration else { return }
            let degraded = intended == .directPaste && modifiersHeld()
            var skipped: [Int] = [], shown = false
            while pasteQueuePosition < ids.count {
                let index = pasteQueuePosition, id = ids[index]
                let result = await paste.perform(.init(ids: [id], format: format, action: degraded ? .copy : intended, target: target))
                guard !Task.isCancelled, generation == pasteQueueGeneration else { return }
                if result == .failed("内容已删除或到期，请重新选择") {
                    pasteQueuePosition += 1; pasteQueueAwaiting = false; skipped.append(index + 1)
                    if retry { break } else { continue }
                }
                // 只有已发送粘贴指令或用户本就选择仅复制才推进；本该粘贴却只复制时停在当前项等待确认；明确失败留在当前项，快捷键可直接重试。
                let awaiting: Bool
                switch result {
                case .copied: awaiting = degraded
                case .fallback: awaiting = true
                case .commandSent, .filesCopied, .failed: awaiting = false
                }
                if case .failed = result { } else if !awaiting { pasteQueuePosition += 1 }
                if case .failed = result { } else if pasteQueueRecordedPosition != index {
                    pasteQueueRecordedPosition = index; await recordUse([id], result)
                }
                guard !Task.isCancelled, generation == pasteQueueGeneration else { return }
                // 记录使用后再显示确认按钮，按钮出现时请求已可确认。
                pasteQueueAwaiting = awaiting
                let progress = "\(pasteQueuePosition)/\(ids.count)"
                let skippedNote = skipped.isEmpty ? nil : "第 \(skipped.map(String.init).joined(separator: "、")) 项已不存在，已跳过"
                let skippedText = skippedNote.map { "（\($0)）" } ?? ""
                switch result {
                case .commandSent: queueFeedback(result.message + " \(progress)" + skippedText, failed: false, note: skippedNote)
                case .copied where awaiting:
                    pasteQueueAwaitingMessage = "修饰键未松开，当前项已复制，请手动粘贴（\(progress)）"
                    queueFeedback(pasteQueueAwaitingMessage + skippedText, failed: true)
                case .copied: queueFeedback("已复制 \(progress)" + skippedText, failed: false, note: skippedNote)
                case .fallback(let reason):
                    // 权限回退的通用说明是“重新打开历史”；队列里改为指向重试按钮。
                    let next = reason == PasteCoordinator.permissionFallbackReason ? "请授予当前LocalClip辅助功能权限后点“重试当前项”" : reason
                    pasteQueueAwaitingMessage = "当前项已复制，\(next)（\(progress)）"
                    queueFeedback(pasteQueueAwaitingMessage + skippedText, failed: true)
                default: queueFeedback(result.message + "（\(progress)）" + skippedText, failed: true)
                }
                shown = true; break
            }
            if !shown, !skipped.isEmpty { queueFeedback("第 \(skipped.map(String.init).joined(separator: "、")) 项已不存在，已跳过", failed: true) }
            if !pasteQueueActive { stopPasteQueue() } else { pasteQueueChanged?() }
        }
    }
    /// 用户确认已手动粘贴等待中的当前项：只推进一次，不再写剪贴板或记使用，by AI.Coding。
    public func confirmPasteQueueManualPaste() {
        guard pasteQueueActive, pasteQueueAwaiting, !pasteQueueBusy else { return }
        pasteQueueAwaiting = false; pasteQueuePosition += 1; touchPasteQueue()
        queueFeedback("已确认手动粘贴 \(pasteQueuePosition)/\(pasteQueue.count)", failed: false)
        if !pasteQueueActive { stopPasteQueue() } else { pasteQueueChanged?() }
    }
    // MARK: A2 图片文字搜索：后台索引与手动“复制图中文字”分开控制，关闭本功能不影响手动识别，by AI.Coding。
    private(set) lazy var imageTextIndexer: ImageTextIndexer = {
        let indexer = ImageTextIndexer(store: store); indexer.clock = clock
        indexer.onStatus = { [weak self] status in
            guard let self else { return }
            imageTextStatus = status; imageTextIndexing = imageTextIndexer.backfilling
        }
        return indexer
    }()
    @Published public private(set) var imageTextStatus: String?
    /// 只反映用户触发的补建；自动处理新图片在后台进行，不让按钮闪烁。
    @Published public private(set) var imageTextIndexing = false
    public var imageTextSearchAvailable: Bool { store.imageTextReady }
    /// 开启时记下时间：之后复制的图片自动识别；已有图片只在用户点“为已有图片建立索引”时处理。
    public func setImageTextSearch(_ enabled: Bool) {
        let now = clock.now(); imageTextIndexer.halted = false
        updateSettings { $0.imageTextSearchSince = enabled ? ($0.imageTextSearchSince ?? now) : nil }
    }
    public func indexExistingImages() {
        guard store.imageTextReady, let since = settings.imageTextSearchSince, !settings.hideContents else { return }
        imageTextIndexer.start(since: since, backfill: true); imageTextIndexing = true
    }
    public func stopImageTextIndexing() { imageTextIndexer.stop(); imageTextIndexing = false }
    public func clearImageTextIndex() {
        imageTextIndexer.stop(status: nil); imageTextIndexing = false; imageTextIndexer.halted = false
        // 开启状态下清除：先把起点移到现在，已清除的图片不会被自动重新识别；需要时再点“为已有图片建立索引”。
        // 闭包作用于最新设置：用户同时关闭功能时保持关闭，不会被清除操作重新打开。
        let now = clock.now()
        updateSettings { if $0.imageTextSearchSince != nil { $0.imageTextSearchSince = now } }
        Task {
            do { try await store.clearImageText(); imageTextStatus = "已清除图片文字索引" }
            catch { imageTextStatus = "图片文字索引清除未完成" }
        }
    }
    /// 关闭、隐藏内容或派生表不可用时停止并丢弃在途结果；开启时只自动处理开启后的新图片，运行中重复调用不重启。
    func syncImageTextIndex() {
        guard store.imageTextReady, let since = settings.imageTextSearchSince, !settings.hideContents else {
            imageTextIndexer.stop(status: nil); imageTextIndexing = false; return
        }
        imageTextIndexer.start(since: since, backfill: false); imageTextIndexing = imageTextIndexer.backfilling
    }
    // 内部只读任务句柄让并发回归等待真实完成，不用固定sleep猜测识别时序。
    private(set) var imageTextTask: Task<Void, Never>?
    private var imageTextFromDetail = false
    private var imageTextGeneration = UUID()
    /// 可控识别边界用于验证延迟完成；生产仍使用本地Vision识别，by AI.Coding。
    var recognizeImageText: @Sendable (ClipboardPayload) async throws -> [String] = { try await ImageTextRecognizer.recognize($0) }
    /// 复制图中文字：只在用户点击时识别原图，只复制不粘贴（识别可能超过1秒）；隐藏内容时不提供，by AI.Coding。
    public func copyImageText(id: ClipID, fromDetail: Bool = false) {
        guard canDisplayContents else { return }
        imageTextTask?.cancel(); imageTextFromDetail = fromDetail; imageTextGeneration = UUID()
        let generation = imageTextGeneration, clipboardCount = paste.clipboardChangeCount
        notice("正在识别图中文字…")
        imageTextTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await store.loadPayload(id: id, at: clock.now())
                let lines = try await recognizeImageText(payload)
                let metadata = try await store.metadata(id: id, at: clock.now())
                let currentSettings = try await store.settings()
                try Task.checkCancellation()
                guard generation == imageTextGeneration, canDisplayContents,
                      !currentSettings.hideContents, isVisible(metadata.summary) else { return }
                let result = paste.copyText(lines.joined(separator: "\n"), expectedChangeCount: clipboardCount)
                let text = result == .copied ? "已复制图中文字（\(lines.count) 行）" : result.message
                notice(text); showPasteFeedback?(text, result != .copied)
            } catch is CancellationError { if generation == imageTextGeneration, message == "正在识别图中文字…" { message = "" } }
            catch let error as ImageTextRecognizer.Failure { if generation == imageTextGeneration && canDisplayContents { message = error.message; showPasteFeedback?(error.message, true) } }
            catch { if generation == imageTextGeneration && canDisplayContents { message = "识别失败，记录已变化"; showPasteFeedback?(message, true) } }
        }
    }
    /// 两列转换菜单按需读取所选内容并逐项判定；不适用置灰，按住⌥沿用仅复制，by AI.Coding。
    public func showTransformMenu(ids explicit: [ClipID]? = nil, atSelectedCard: Bool = false) {
        let ids = explicit ?? orderedSelection
        guard canDisplayContents, panelVisible, !ids.isEmpty else { return }
        // 主动完成详情到转换的交接，不把新菜单挂在即将关闭的详情浮窗上，by AI.Coding。
        if showingDetail { showingDetail = false; detailVisibilityChanged() }
        transformMenu?.close()
        transformMenuRequest = UUID()
        let request = transformMenuRequest
        Task {
            var records: [ClipboardPayload] = []
            do {
                try await OutputBudget.preflight(ids, store: store, at: clock.now(), transform: true)
                for id in ids { try Task.checkCancellation(); records.append(try await store.loadPayload(id: id, at: clock.now())) }
            } catch is OutputBudget { message = OutputBudget.message; return }
            catch let error as TransformError { message = error.message; return }
            catch { message = "转换不可用，记录已变化"; return }
            let (available, reason) = await Task.detached { Self.transformAvailability(records) }.value
            // 转换使用自己的请求代次；内容/选择失效仍会撤销，单纯释放详情预览不会误取消。
            guard canDisplayContents, panelVisible, request == transformMenuRequest,
                  explicit != nil || ids == orderedSelection else { return }
            // ⌘T在所选卡片左上角弹出；鼠标入口在指针处弹出。
            let view = HistoryDragBridge.DragView.view(for: ids[0])
            guard let parent = view?.window ?? (atSelectedCard ? nil : NSApp.keyWindow) else { return }
            var point = NSEvent.mouseLocation
            if atSelectedCard, let view {
                point = parent.convertPoint(toScreen: view.convert(NSPoint(x: 12, y: view.isFlipped ? 12 : view.bounds.height - 12), to: nil))
            }
            let menu = makeTransformMenu(ids: ids, available: available, reason: reason)
            menu.onDismiss = { [weak self] in
                self?.rememberNativePopoverDismissal()
                self?.transformMenu = nil
            }
            menu.onParentClick = { [weak self] event in self?.dismissPopoverForBackdropClick(count: event.clickCount, timestamp: event.timestamp) ?? false }
            transformMenu = menu
            #if DEBUG
            if let presentTransformMenuForTesting { presentTransformMenuForTesting(menu, parent, point); return }
            #endif
            menu.present(parent: parent, at: point)
        }
    }
    /// 构造菜单与显示窗口分离；鼠标/键盘共用原有转换管线，也可用fake客户端安静验证，by AI.Coding。
    func makeTransformMenu(ids: [ClipID], available: Set<TextTransform>, reason: String?) -> TransformMenuController {
        TransformMenuController(available: available, reason: reason, allowsCopyOnly: settings.defaultAction == .directPaste) { [weak self] transform, copyOnly in
            self?.perform(.plainText, action: copyOnly ? .copy : nil, transform: transform, ids: ids)
        }
    }
    /// 转换菜单的可用项与整体不可用原因；文件记录的纯文本只是路径，与图片一样不提供转换，by AI.Coding。
    nonisolated static func transformAvailability(_ records: [ClipboardPayload]) -> (Set<TextTransform>, String?) {
        guard !records.contains(where: \.hasFileReferences), let text = try? OutputComposer.combine(records, format: .plainText).plainText else { return ([], "所选内容不含文本，无法转换") }
        guard text.utf8.count <= TextTransform.byteLimit else { return ([], "内容过大（超过 4 MiB），无法转换") }
        return (TextTransform.applicableTransforms(text), nil)
    }
    /// 单项记录另存为文件，沿用拖出的格式规则；富文本可改选纯文本、RTF或HTML，链接存为.webloc。文件引用本身就是文件，不提供此操作，by AI.Coding。
    public func saveSelectedToFile() {
        guard let selectedID else { return }
        Task {
            do {
                let access = try await store.exportAccess(id: selectedID)
                let summary = try await store.metadata(id: selectedID, at: clock.now()).summary
                let items = try await Task.detached { try access.itemTypes() }.value
                guard items.count == 1, let types = items.first, !types.contains(SupportedType.fileURL) else { message = "多项记录请拖到Finder，每项生成一个文件"; return }
                var options: [(title: String, fileExtension: String, data: @Sendable () throws -> Data)] = []
                if let plan = try await ContentExportProvider.plan(access: access, index: 0, types: types) {
                    options.append(("自动（.\(plan.fileExtension)）", plan.fileExtension, { try ContentExportProvider.data(plan, access: access, index: 0, types: types) }))
                    // 富文本另可选择其余格式；自动方案已覆盖的格式不重复列出。
                    let rich = types.contains(SupportedType.rtf) || types.contains(SupportedType.html)
                    if rich, case .original = plan.format {
                        options.append(("纯文本（.txt）", "txt", { try ContentExportProvider.data(.init(fileType: SupportedType.string, fileExtension: "txt", format: .plain("txt")), access: access, index: 0, types: types) }))
                    }
                    for (type, ext, title) in [(SupportedType.rtf, "rtf", "RTF（.rtf）"), (SupportedType.html, "html", "HTML（.html）")] where types.contains(type) && plan.fileExtension != ext {
                        options.append((title, ext, { try access.itemData(index: 0, type: type) }))
                    }
                }
                // 链接（含纯文本网址）默认存为.webloc，纯文本网址另保留文本格式可选，by AI.Coding。
                let link: String? = if types.contains(SupportedType.url) { String(decoding: try access.itemData(index: 0, type: SupportedType.url), as: UTF8.self) }
                    else if summary.kind == .url, types.contains(SupportedType.string) { ClipboardPayload.webLink(String(decoding: try access.itemData(index: 0, type: SupportedType.string), as: UTF8.self))?.absoluteString }
                    else { nil }
                if let link {
                    options.insert(("链接（.webloc）", "webloc", { try PropertyListSerialization.data(fromPropertyList: ["URL": link], format: .xml, options: 0) }), at: 0)
                }
                guard !options.isEmpty else { message = "该记录没有可存储的内容"; return }
                let panel = NSSavePanel()
                panel.canCreateDirectories = true; panel.isExtensionHidden = false
                panel.nameFieldStringValue = ContentInspector.fileName(base: ContentInspector.exportBaseName(title: summary.title, copiedAt: summary.lastCopiedAt), index: nil, fileExtension: options[0].fileExtension)
                let picker = SaveFormatPicker(panel: panel, extensions: options.map(\.fileExtension))
                if options.count > 1 {
                    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
                    popup.addItems(withTitles: options.map(\.title)); popup.target = picker; popup.action = #selector(SaveFormatPicker.changed(_:))
                    panel.accessoryView = popup
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let chosen = options[(panel.accessoryView as? NSPopUpButton)?.indexOfSelectedItem ?? 0].data
                withExtendedLifetime(picker) {}
                // 用户已在保存面板确认覆盖；原子写入不留下半截文件。
                try await Task.detached { try chosen().write(to: url, options: .atomic) }.value
            } catch { message = "存储失败，记录已变化或目标不可写" }
        }
    }
    /// 用户明确选择单个对象再打开，混合记录不会自动打开所有资源。
    /// 可打开对象：文件引用，否则声明的网址；纯文本网址没有public.url表示，按同一识别规则回退，by AI.Coding。
    static func openTargets(_ payload: ClipboardPayload) -> [URL] {
        let declared = payload.items.flatMap { $0.representations }.filter { $0.type == SupportedType.url }.compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }.filter { ["http","https","mailto"].contains($0.scheme?.lowercased() ?? "") }
        return payload.fileURLs ?? (declared.isEmpty && payload.kind == .url ? payload.plainText.flatMap(ClipboardPayload.webLink).map { [$0] } ?? [] : declared)
    }
    public func openSelected(reveal: Bool = false, withApplication: Bool = false) {
        guard canDisplayContents, let selectedID else { return }
        let visibility = contentGeneration
        Task {
            do {
                let value = try await store.detail(id: selectedID, at: clock.now())
                guard canDisplayContents, visibility == contentGeneration, self.selectedID == selectedID else { return }
                let urls = Self.openTargets(value.payload)
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
/// 切换格式时同步修改文件名扩展名，保存面板的覆盖确认针对最终文件名，by AI.Coding。
private final class SaveFormatPicker: NSObject {
    let panel: NSSavePanel
    let extensions: [String]
    init(panel: NSSavePanel, extensions: [String]) { self.panel = panel; self.extensions = extensions }
    @MainActor @objc func changed(_ sender: NSPopUpButton) {
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + extensions[sender.indexOfSelectedItem]
    }
}
