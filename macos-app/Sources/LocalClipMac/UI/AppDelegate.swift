// 正式菜单栏、面板、依赖组装与生命周期；无 mock 入口，by AI.Coding。
import AppKit
import SwiftUI
import Carbon
import ApplicationServices
import LocalClipCore
@MainActor final class ClipPanel: NSPanel {
    /// Esc与取消命令：先经模型分级处理，最后才收起面板，by AI.Coding。
    var onCancel: () -> Void = {}
    /// 标准关闭命令直接收起，不受搜索词或弹窗分级影响，by AI.Coding。
    var onClose: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 标准取消命令也关闭历史，不依赖搜索框是否处于编辑状态。
    override func cancelOperation(_ sender: Any?) { onCancel() }
    /// 无标题栏面板也支持标准关闭命令，沿用收起而非销毁历史窗口，by AI.Coding。
    override func performClose(_ sender: Any?) {
        guard attachedSheet == nil, NSApp.modalWindow == nil else { return }
        onClose()
    }
    /// AppKit 默认按 closable 样式禁用关闭项；本面板虽无标题栏，仍有安全收起动作。
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.performClose(_:)) { return attachedSheet == nil && NSApp.modalWindow == nil }
        return super.validateMenuItem(menuItem)
    }
    /// 非文本第一响应者未消费按键时，窗口兜底处理Esc。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}
@MainActor public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var managerWindow: HistoryManagerWindow?
    private var manager: HistoryManagerModel?
    /// 主界面共享单一目标；轻量浏览状态独立于可释放的窗口，by AI.Coding。
    private var activeSurface: AppSurface?
    private var requestedSurface: AppSurface?
    private var surfaceRequestID = UUID()
    private var surfaceTask: Task<Void, Never>?
    private let surfaceAnimator = SurfaceAnimator()
    private var surfaceConfirmation: SurfaceConfirmation?
    private var managerBrowsing: HistoryManagerModel.BrowsingState?
    private var settingsSection = SettingsSection.general
    #if DEBUG
    /// 静默集成测试仅绕过可见呈现，查询、保护、动画代次和释放仍使用生产路径。
    private var hiddenSurfaceTest = false
    var surfaceWindowsForTesting: (NSWindow?, NSWindow?, NSWindow?) { (panel, settingsWindow, managerWindow) }
    var surfaceManagerForTesting: HistoryManagerModel? { manager }
    var surfaceChoiceForTesting: ((String) async -> SurfaceEdits.Choice)?
    func configureSurfacesForTesting(_ history: HistoryViewModel) {
        model = history; hiddenSurfaceTest = true
        history.closePanel = { [weak self] animated in
            if animated { self?.requestSurface(nil) } else { self?.dismissHistory(animated: false) }
        }
    }
    func switchSurfaceForTesting(_ surface: AppSurface?) { requestSurface(surface) }
    #endif
    /// 测试窗口始终隐藏；发布构建不存在替换开关。
    private var presentsSurfaces: Bool {
        #if DEBUG
        if hiddenSurfaceTest { return false }
        #endif
        return true
    }

    private var feedbackPanel: NSPanel?
    private var feedbackTask: Task<Void, Never>?
    private var model: HistoryViewModel?
    private let applications = MacApplicationClient()
    private let hotkeys = HotKeyService()
    private let login = LoginItemService()
    private var lastExternal: TargetToken?
    private var keyboardMonitor: Any?
    private var flagsMonitor: Any?
    /// 粘贴队列常驻浮窗：非激活、不成为key，只有“结束”按钮接收点击，by AI.Coding。
    private var queuePanel: NSPanel?
    private var queueFade: Task<Void, Never>?
    private var activatedObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var panelScreenID: NSNumber?
    private var maintenance: Task<Void, Never>?
    private var focusObservers: [NSObjectProtocol] = []
    private var focusDismissal: Task<Void, Never>?
    private var focusState = HistoryPanelFocusState()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var focusObservation: NSKeyValueObservation?
    /// 面板是否处于打开状态；淡出期间窗口仍可见但已视为关闭，by AI.Coding。
    private var panelPresented = false
    /// 每次显示或关闭递增；旧淡出结束时代次已变则不隐藏重新打开的面板，by AI.Coding。
    private var panelAnimationGeneration = 0
    private var panelFade: Task<Void, Never>?
    var requestTermination: () -> Void = { NSApp.terminate(nil) }
    private let instances = SingleInstanceService()
    private var startup: Task<Void, Never>?
    private var modelStartup: Task<Void, Never>?
    private var relaunchRequested = false
    private var sourceObserver: SourceApplicationObserver?
    /// Release始终使用自有Application Support，忽略测试环境覆盖。
    public static func storageLocation() -> URL {
        #if DEBUG
        if let root = GUIAcceptanceProbe.configuration?["root"] { return URL(fileURLWithPath: root, isDirectory: true) }
        if let override = ProcessInfo.processInfo.environment["LOCALCLIP_DATA_DIR"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalClip-LocalEdition", isDirectory: true)
    }
    /// 在任何历史读写/采集/菜单栏/快捷键之前等待旧进程退出，并持有进程锁。
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 所有运行入口均维持后台工具身份，验收包也不切成普通应用。
        NSApp.setActivationPolicy(.accessory)
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await instances.takeOver()
                guard !Task.isCancelled else { return }
                startServices()
            } catch SingleInstanceService.StartupError.superseded {
                NSApp.terminate(nil)
            } catch {
                guard !Task.isCancelled else { return }
                let alert = NSAlert(); alert.messageText = "LocalClip无法接替旧实例"
                alert.informativeText = (error as? SingleInstanceService.StartupError)?.message ?? "启动未完成，未开启采集或存储"
                alert.runModal(); NSApp.terminate(nil)
            }
        }
    }
    /// 获得独占启动权限后自动监听，恢复与隐私检查仍先于正文采集，by AI.Coding。
    private func startServices() {
        makeMenu()
        let location = Self.storageLocation()
        do {
            let initialSettings = SettingsSnapshot()
            let store = try HistoryStore(location: location, initialSettings:initialSettings, extractor: ContentDecoder.extract)
            let access: NativePasteboardAccess
            #if DEBUG
            if GUIAcceptanceProbe.usesExternalPasteboard { access = NativePasteboardAccess() }
            else if let name = GUIAcceptanceProbe.configuration?["board"] { access = NativePasteboardAccess(NSPasteboard(name: .init(name))) }
            else { access = NativePasteboardAccess() }
            #else
            access = NativePasteboardAccess()
            #endif
            let sources = SourceApplicationObserver(changeCount: { access.count })
            sourceObserver = sources
            let board = MacPasteboardClient(access: access, observedSource: { sources.source(for: $0) })
            let capture = CaptureCoordinator(board: board, store: store)
            // 前台暂停按实际区间收尾，不把展示用的来源推断当作可靠排除标记。
            sources.onDeactivate = { [weak capture] in capture?.applicationDidDeactivate($0) }
            let paste = PasteCoordinator(board: board, applications: applications, store: store, capture: capture)
            let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
            self.model = model; lastExternal = applications.target()
            // 在首次查询前提供屏幕尺寸；SwiftUI随后用实际视口修正，不先读固定50条，by AI.Coding。
            model.configureHistoryViewport(width: NSScreen.main?.frame.width ?? 1400, cardWidth: HistoryView.cardSide(height: initialSettings.panelHeight))
            model.panelVisibilityChanged(false)
            model.closePanel = { [weak self] animated in
                if animated { self?.requestSurface(nil) } else { self?.dismissHistory(animated: false) }
            }
            // 非激活面板不抢前台；置顶时前台应用即当前要粘贴的目标，by AI.Coding。
            model.refreshPinnedTarget = { [weak self, weak model] in
                guard let self, let model, let target = self.applications.target() else { return }
                self.lastExternal = target; self.applications.rememberFocus(for: target); model.target = target
            }
            model.panelInteractionChanged = { [weak self] in self?.scheduleFocusDismissal() }
            model.openSettings = { [weak self] in self?.showSettings() }
            model.openHistoryManager = { [weak self] ids in self?.showHistoryManager(reveal: ids) }
            model.quitApplication = { [weak self] in self?.quitApplication(nil) }
            model.registerShortcut = { [weak self] in self?.hotkeys.register($0) ?? false }
            model.focusResults = { [weak self] in guard let panel = self?.panel else { return }; panel.makeFirstResponder(panel) }
            model.previewParent = { [weak self] in self?.panel }
            model.settingsChanged = { [weak self] in self?.applyAppearanceSettings() }
            model.resizePanel = { [weak self] height, persist in self?.resizeHistory(height, persist: persist) }
            model.showPasteFeedback = { [weak self] message, failed in self?.showPasteFeedback(message, failed: failed) }
            paste.closePanel = model.closePanel
            let copyJournal = location.appendingPathComponent("FinderCopyJournal", isDirectory: true)
            paste.copyJournal = copyJournal
            hotkeys.onInvoke = { [weak self] in self?.toggleHistory() }
            model.registerQueueShortcut = { [weak self] in self?.hotkeys.registerQueue($0) ?? false }
            model.unregisterQueueShortcut = { [weak self] in self?.hotkeys.unregisterQueue() }
            model.pasteQueueChanged = { [weak self] in self?.updateMenu(); self?.updateQueuePanel() }
            model.showsQueuePanel = true
            hotkeys.onQueueInvoke = { [weak self] in self?.pasteQueueNext() }
            modelStartup = Task {
                do {
                    // 手动暂停只作用于上一轮运行，定时暂停和隐私规则由采集器保留，by AI.Coding。
                    try await model.start(resumeCapture: true)
                    // 上次进程崩溃遗留的已登记Finder复制暂存；后台执行，不阻塞回执与采集。
                    Task.detached(priority: .utility) { CopyStagingJournal.recover(copyJournal) }
                    // 先确认真实存储恢复，再给安装器回执；权限引导可能等待用户，不能阻塞回执，by AI.Coding。
                    if !Self.isolatedRun { UpdateInstaller.acknowledgeStartup(); UpdateChecker.shared.startupFinished() }
                    if !hotkeys.register(model.settings.shortcut) { model.message = "快捷键注册冲突，菜单栏仍可使用" }
                    applyAppearanceSettings(); updateMenu()
                    // 再次打开应用触发接替时，新进程完成启动后继续展示用户请求的历史。
                    if CommandLine.arguments.contains("--show-history") { showHistory() }
                    // 首次启动引导开启辅助功能并检查新版本；隔离验收进程不弹出、不联网。
                    if !Self.isolatedRun {
                        AccessibilityGuide.shared.showOnFirstLaunch()
                        UpdateChecker.shared.onChange = { [weak self] in self?.updateMenu() }
                        UpdateChecker.shared.checkIfDue(enabled: model.settings.autoCheckUpdates)
                    }
                    #if DEBUG
                    GUIAcceptanceProbe.attach(model: model, board: access, show: { [weak self] in self?.showHistory() }, hide: { [weak self] in self?.dismissHistory(animated: false) })
                    GUIAcceptanceProbe.commands = ["fade": { [weak self] in self?.dismissHistory() }, "manager": { [weak self] in self?.showHistoryManager() },
                                                   "close-manager": { [weak self] in self?.managerWindow?.performClose(nil) },
                                                   "detail": { model.showingDetail.toggle() }, "filters": { model.showingFilters.toggle() },
                                                   "ax": { GUIAcceptanceProbe.write(["trusted": AXIsProcessTrusted(), "target": self.applications.target().map { "\($0.pid)" } ?? ""], "ax.json") },
                                                   "queue": { model.startPasteQueue(Array(model.items.filter { $0.kind == .text }.prefix(3).map(\.id))) },
                                                   "queue-next": { [weak self] in self?.pasteQueueNext() }, "queue-retry": { [weak self] in self?.pasteQueueNext(retry: true) },
                                                   "queue-confirm": { model.confirmPasteQueueManualPaste() }, "queue-stop": { model.stopPasteQueue() },
                                                   "feedback": { [weak self] in self?.showPasteFeedback("已复制，请手动粘贴", failed: false) },
                                                   "light": { model.updateSettings { $0.appearance = .light } }, "dark": { model.updateSettings { $0.appearance = .dark } },
                                                   "backdrop": { GUIAcceptanceProbe.showBackdrop() }, "quiet": { GUIAcceptanceProbe.quiet.toggle() },
                                                   "transform": { if let id = model.items.first(where: { $0.kind == .text })?.id { model.select(id); model.showTransformMenu(atSelectedCard: true) } }]
                    #endif
                    // 等首屏查询完成再隐藏预热；若用户已经打开，则复用其面板，不重复创建或夺取焦点。
                    let preparationDeadline = ContinuousClock.now + .seconds(2)
                    while model.historyBusy && panel == nil && ContinuousClock.now < preparationDeadline && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    if !Task.isCancelled, !model.historyBusy, panel == nil {
                        let rect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1400, height: 380)
                        prepareHistoryPanel(frame: rect, height: Self.clampedPanelHeight(model.settings.panelHeight, screenHeight: rect.height))
                    }
                } catch { model.message = "启动恢复失败，未开启采集"; model.status = "存储异常"; updateMenu() }
            }
            observeLifecycle(); installKeyboard()
            maintenance = Task { [weak model] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let model, !Task.isCancelled else { break }
                    await model.maintenance()
                    if !Self.isolatedRun {
                        // 更新残留补偿在每轮维护重试；会话活跃时跳过，不阻塞采集与界面。
                        await UpdateChecker.shared.maintain()
                        UpdateChecker.shared.checkIfDue(enabled: model.settings.autoCheckUpdates)
                    }
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "LocalClip 无法打开存储"; alert.informativeText = "原库未覆盖。请检查磁盘、权限或数据库版本。错误类别：\(error)"; alert.runModal()
        }
    }
    /// 同版本再次打开直接显示历史；只有磁盘上已安装新版本时才启动新实例接替，by AI.Coding。
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !relaunchRequested else { return false }
        if !Self.installedVersionChanged(running: Bundle.main.infoDictionary, installed: NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) {
            requestSurface(activeSurface ?? .cards); return false
        }
        relaunchRequested = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--show-history"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                if error == nil, let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    NSApp.terminate(nil)
                } else {
                    self.relaunchRequested = false
                    let alert = NSAlert(); alert.messageText = "LocalClip新实例启动失败"
                    alert.informativeText = "原实例继续运行，请重新打开应用。"; alert.runModal()
                }
            }
        }
        return false
    }
    /// 读不到磁盘版本时按未变化处理，避免误杀当前实例。
    static func installedVersionChanged(running: [String: Any]?, installed: [String: Any]?) -> Bool {
        guard let installed else { return false }
        let key = { (info: [String: Any]?) in "\(info?["CFBundleShortVersionString"] ?? "")-\(info?["CFBundleVersion"] ?? "")" }
        return key(running) != key(installed)
    }
    /// 菜单栏始终保留，即使快捷键或权限不可用。
    private func makeMenu() {
        NSApp.mainMenu = makeMainMenu()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 与应用图标同一符号，模板渲染随菜单栏明暗；暂停时按系统禁用样式变淡，by AI.Coding。
        status?.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "LocalClip")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        status?.button?.appearsDisabled = model?.settings.captureEnabled == false
        updateMenu()
    }
    /// 文本编辑快捷键由原生响应链处理；历史快捷键仍先经过本地监视器。
    func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenuItem(title: "LocalClip", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "LocalClip")
        let quit = applicationMenu.addItem(withTitle: "退出 LocalClip", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quit.target = self; application.submenu = applicationMenu; menu.addItem(application)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key, modifiers) in [
            ("撤销", "undo:", "z", NSEvent.ModifierFlags.command),
            ("重做", "redo:", "z", [.command, .shift]),
            ("剪切", "cut:", "x", .command),
            ("复制", "copy:", "c", .command),
            ("粘贴", "paste:", "v", .command),
            ("全选", "selectAll:", "a", .command)
        ] {
            let item = editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        edit.submenu = editMenu; menu.addItem(edit)
        // 标准窗口响应链关闭当前窗口，历史面板保留其既有生命周期。
        let window = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let manage = windowMenu.addItem(withTitle: "历史管理…", action: #selector(showHistoryManagerFromMenu), keyEquivalent: "h")
        manage.keyEquivalentModifierMask = [.command, .option]; manage.target = self
        window.submenu = windowMenu; menu.addItem(window)
        return menu
    }
    /// 状态在打开菜单前同步，所有操作指向真实服务。
    private func updateMenu() { status?.menu = makeStatusMenu() }
    /// 菜单构造不创建系统状态项，退出路由可在无窗口测试中验证，by AI.Coding。
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // 参照应用菜单：关于与更新在最前，设置其次，状态与常用操作居中，退出最后；每项均配 SF Symbols，by AI.Coding。
        let about = menu.addItem(withTitle: "关于 LocalClip", action: #selector(showAbout), keyEquivalent: ""); about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        // 有新版本时更新项占据检查更新的位置，不额外加项，by AI.Coding。
        if let release = UpdateChecker.shared.available {
            let title = UpdateChecker.shared.phase == .ready ? "安装并重启 · \(release.version)…" : "更新 \(release.version)…"
            let update = menu.addItem(withTitle: title, action: #selector(openUpdate), keyEquivalent: ""); update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        } else {
            let check = menu.addItem(withTitle: "", action: #selector(checkForUpdates), keyEquivalent: ""); check.target = self
            check.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            updateCheckItem(check)
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(.separator())
        // 原生分区标题显示面向用户的状态，与面板用词一致，by AI.Coding。
        menu.addItem(.sectionHeader(title: statusMenuTitle))
        let show = menu.addItem(withTitle: "打开历史", action: #selector(showHistory), keyEquivalent: ""); show.target = self
        show.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
        let manage = menu.addItem(withTitle: "历史管理…", action: #selector(showHistoryManagerFromMenu), keyEquivalent: "h"); manage.target = self
        manage.keyEquivalentModifierMask = [.command, .option]
        manage.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        let pause = menu.addItem(withTitle: "", action: #selector(toggleCapture), keyEquivalent: ""); pause.target = self
        updateCaptureItem(pause)
        if let model, model.pasteQueueActive {
            let queue = menu.addItem(withTitle: "结束粘贴队列（\(model.pasteQueuePosition)/\(model.pasteQueue.count)）", action: #selector(stopPasteQueue), keyEquivalent: ""); queue.target = self
            queue.image = NSImage(systemSymbolName: "list.number", accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        // 菜单栏非激活窗口不依赖外部应用的响应链，by AI.Coding。
        let quit = menu.addItem(withTitle: "退出 LocalClip", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        // 检查中项需真实置灰，不能被自动启用覆盖。
        menu.autoenablesItems = false
        menu.delegate = self; return menu
    }
    private func updateCheckItem(_ item: NSMenuItem) {
        let updates = UpdateChecker.shared
        item.title = updates.phase == .downloading ? "正在下载更新…" : updates.checking ? "正在检查更新…" : "检查更新…"
        item.isEnabled = !updates.checking && updates.phase != .installing
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    /// 用户显式触发，结果用模态弹框告知；设置页按钮仍在页内显示结果，二者共用同一检查流程，by AI.Coding。
    @objc private func checkForUpdates() {
        Task { [weak self] in
            let updates = UpdateChecker.shared
            // 发现新版本即告知并转入后台下载；下载结果等首个弹框关闭后再弹，避免模态叠加。
            var foundAlert: Task<Void, Never>?
            await updates.check(manual: true) { release in
                foundAlert = Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "发现新版本 \(release.version)"
                    alert.informativeText = "当前版本 \(UpdateChecker.currentVersion)。正在后台下载并验签，完成后会提示安装并重启。"
                    alert.addButton(withTitle: "好"); alert.addButton(withTitle: "查看发布页")
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(release.page) }
                }
            }
            await foundAlert?.value
            let alert = NSAlert()
            var primary: (() -> Void)?
            if let release = updates.available {
                switch updates.phase {
                case .ready:
                    alert.messageText = "LocalClip \(release.version) 已下载"
                    alert.informativeText = "安装后自动重启，历史与设置会保留。"
                    alert.addButton(withTitle: "安装并重启"); alert.addButton(withTitle: "稍后")
                    primary = { Task { await updates.installAndRestart() } }
                case .manualOnly:
                    alert.messageText = "发现新版本 \(release.version)"
                    alert.informativeText = "此版本尚未提供签名更新包，请从发布页手动安装。"
                    alert.addButton(withTitle: "查看发布页"); alert.addButton(withTitle: "稍后")
                    primary = { NSWorkspace.shared.open(release.page) }
                case let .failed(message):
                    alert.alertStyle = .warning; alert.messageText = "更新下载失败"; alert.informativeText = message
                default: return
                }
            } else if let result = updates.manualResult {
                let latest = result == "已是最新版本"
                alert.alertStyle = latest ? .informational : .warning
                alert.messageText = latest ? "LocalClip 已是最新版本" : "检查更新失败"
                alert.informativeText = latest ? "当前版本 \(UpdateChecker.currentVersion)。" : "请检查网络连接后重试。"
            } else { return }
            self?.updateMenu()
            if alert.runModal() == .alertFirstButtonReturn { primary?() }
        }
    }
    /// 菜单与设置共享唯一显式安装入口，下载中只展示设置状态，by AI.Coding。
    @objc private func openUpdate() {
        if UpdateChecker.shared.phase == .ready { Task { await UpdateChecker.shared.installAndRestart() } }
        else { showSettings() }
    }
    /// 隔离验收进程不弹授权向导、不访问网络。
    private static var isolatedRun: Bool {
        #if DEBUG
        GUIAcceptanceProbe.configuration != nil
        #else
        false
        #endif
    }
    private var statusMenuTitle: String { "LocalClip · " + HistoryView.statusLabel(model?.capture.state ?? "准备中") }
    private func updateCaptureItem(_ item: NSMenuItem) {
        let paused = model?.recordingPaused == true
        item.title = paused ? "开始监控" : "停止监控"
        item.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
    }
    /// 队列快捷键在其他应用中按下：以当前前台应用为目标，先记住其焦点再粘贴；面板在前台时不粘贴到自身，by AI.Coding。
    /// retry：浮窗“重试当前项”；浮窗不激活，前台仍是用户的目标应用。
    private func pasteQueueNext(retry: Bool = false) {
        guard let model else { return }
        let target = applications.target()
        if let target { lastExternal = target; applications.rememberFocus(for: target) }
        model.pasteQueueNext(target: target, retry: retry) {
            !CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        }
    }
    @objc private func stopPasteQueue() { model?.stopPasteQueue() }
    /// 同一快捷键按实际可见状态切换；关闭不刷新历史或重记粘贴目标。
    private func toggleHistory() {
        requestSurface((requestedSurface ?? activeSurface) == .cards ? nil : .cards)
    }
    /// 记住外部目标后展示面板，铺满当前显示器底边，禁止拖动和缩放。
    @objc public func showHistory() { requestSurface(.cards) }
    /// 卡片布局与目标记忆沿用原逻辑，透明度由统一切换器控制。
    private func presentHistory() {
        guard let model else { return }
        let began = ContinuousClock.now
        applications.timingEnabled = model.settings.timingEnabled
        // 这里测到窗口提交而非首帧；首帧继续由GUI探针记录，by AI.Coding。
        defer { if model.settings.timingEnabled { StageTiming.record("show_history_submitted", since: began, count: 1) } }
        focusState.ownedInteraction()
        focusDismissal?.cancel(); model.showingDetail = false; model.showingCategoryEditor = false
        if let target = applications.target() {
            lastExternal = target
            // 必须先取外部输入控件身份，再把非激活面板搜索框设为key。
            applications.rememberFocus(for: target)
        } else if panel?.isKeyWindow != true {
            applications.rememberFocus(for: nil)
        }
        let screen = targetScreen()
        let rect = screen?.frame ?? NSRect(x: 0, y: 0, width: 1400, height: 380)
        let panelHeight = Self.clampedPanelHeight(model.settings.panelHeight, screenHeight: rect.height)
        model.configureHistoryViewport(width: rect.width, cardWidth: HistoryView.cardSide(height: panelHeight))
        if panel?.isVisible != true { model.showFirstCard() }
        model.panelVisibilityChanged(true)
        model.target = lastExternal
        model.revalidateVisibleContent()
        if model.items.isEmpty && !model.historyBusy { model.refresh() }
        // 显示周期与入场起点必须在挂载/布局前确定；首帧后改代次会重启文件预览并再次请求焦点，by AI.Coding。
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.actualPanelHeight = panelHeight
        model.focusRequest = UUID(); model.searchFocusRequest = UUID()
        if panel?.isVisible != true { model.panelEntrance = reduceMotion ? 0 : 12 }
        prepareHistoryPanel(frame: rect, height: panelHeight)
        if let panel {
            panelScreenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            panel.sharingType = model.settings.excludeFromSharing ? .none : .readOnly
            placePanel(to: screen)
            // 窗口frame一次定为最终值不移动；内容在窗口内位移12pt并淡入，减弱动态效果时直接显示。
            // 起始位移先于首帧布局写入，随后的动画才有起点，by AI.Coding。
            panelAnimationGeneration += 1; panelFade?.cancel(); panelFade = nil
            panel.ignoresMouseEvents = false
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
            panelPresented = true
            if presentsSurfaces { panel.makeKeyAndOrderFront(nil) }
            // 置前后的首次提交（窗口服务器同步）立即完成，不占用随后淡入与位移动画的前几帧，by AI.Coding。
            CATransaction.flush()
            if model.panelEntrance != 0 { withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.18)) { model.panelEntrance = 0 } }
        }
    }
    /// 只创建、布局隐藏面板，不置前、不变更目标应用；首屏成本不留到用户第一次点击，by AI.Coding。
    private func prepareHistoryPanel(frame rect: NSRect, height panelHeight: CGFloat) {
        guard panel == nil, let model else { return }
        let began = ContinuousClock.now
        model.actualPanelHeight = panelHeight
        let initialFrame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: panelHeight)
        // 非激活面板保留外部应用身份与文档焦点；搜索框仍可成为key接收键盘。
        // 先确定最终屏幕尺寸再挂载SwiftUI，避免1400pt初始布局到全宽的可见跳变。
        let panel = ClipPanel(contentRect: initialFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "LocalClip"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        // 底部覆盖Dock所在区域，避免按钮被Dock遮挡；关闭面板即恢复原桌面。
        panel.isReleasedWhenClosed = false; panel.level = .statusBar; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 窗口尺寸由屏幕和高度设置唯一决定，不让SwiftUI固有尺寸改变内容视口。
        let host = CategoryDropHostingView(rootView: HistoryView(model: model), model: model)
        host.sizingOptions = []
        panel.contentView = host; panel.minSize = NSSize(width: 680, height: 280)
        panel.onCancel = { [weak self] in if self?.model?.handleEscape() != false { self?.requestSurface(nil) } }
        panel.onClose = { [weak self] in self?.requestSurface(nil) }
        self.panel = panel
        focusObservation = Self.observeHistoryFocus(of: panel, model: model)
        panel.alphaValue = 0
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        if model.settings.timingEnabled { StageTiming.record("history_panel_prepared", since: began, count: model.items.count) }
    }
    /// 面板高度限制在280–520pt，且不超过所在屏幕。
    private static func clampedPanelHeight(_ height: Double, screenHeight: CGFloat) -> Double { min(max(280, height), min(520, screenHeight)) }
    /// 使用物理显示器frame而不是visibleFrame，让侧边Dock也不会缩短面板宽度。
    private func placePanel(to screen: NSScreen?) {
        guard let panel, let rect = screen?.frame else { return }
        // 紧凑布局380pt，只有尺寸确实变化才重排；隐藏阶段不触发显示更新。
        let frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: Self.clampedPanelHeight(model?.actualPanelHeight ?? model?.settings.panelHeight ?? 340, screenHeight: rect.height))
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }
    /// 外部焦点所在窗口优先决定显示器，取不到时才回退鼠标位置。
    private func targetScreen() -> NSScreen? {
        if let target = applications.target() ?? lastExternal, applications.permitted {
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let element = unsafeDowncast(window, to: AXUIElement.self)
                var position: CFTypeRef?, size: CFTypeRef?
                if AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success, AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success, let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var point = CGPoint.zero; var dimensions = CGSize.zero
                    if AXValueGetValue(unsafeDowncast(position,to: AXValue.self),.cgPoint,&point), AXValueGetValue(unsafeDowncast(size,to: AXValue.self),.cgSize,&dimensions) {
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        let rect = NSRect(x:point.x,y:top-point.y-dimensions.height,width:dimensions.width,height:dimensions.height)
                        return NSScreen.screens.max { $0.frame.intersection(rect).width * $0.frame.intersection(rect).height < $1.frame.intersection(rect).width * $1.frame.intersection(rect).height }
                    }
                }
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
    /// 调高只改变底部固定面板尺寸，结束手势后持久化一次。
    private func resizeHistory(_ height: Double, persist: Bool) {
        guard let model else { return }
        model.actualPanelHeight = Self.clampedPanelHeight(height, screenHeight: panel?.screen?.frame.height ?? 520)
        placePanel(to: panel?.screen)
        if persist { model.updateSettings { $0.panelHeight = model.actualPanelHeight } }
    }
    /// 隐藏图标必须仍有已注册快捷键；共享设置使用系统公开窗口属性。
    private func applyAppearanceSettings() {
        guard let model else { return }
        // 应用级外观覆盖同时作用于历史、设置及后续创建的窗口；nil恢复跟随系统。
        switch model.settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let registered = hotkeys.register(model.settings.shortcut)
        status?.isVisible = model.settings.showMenuIcon || !registered
        status?.button?.appearsDisabled = !model.settings.captureEnabled
        if !registered { model.message = "快捷键冲突，菜单栏入口保留" }
        // 已显示的队列浮窗与历史面板同时生效，不等下一次进度更新，by AI.Coding。
        Self.applySharing(model.settings.excludeFromSharing, to: [panel, queuePanel, managerWindow])
        model.actualPanelHeight = model.settings.panelHeight; placePanel(to: panel?.screen)
    }
    static func applySharing(_ exclude: Bool, to windows: [NSWindow?]) {
        for window in windows { window?.sharingType = exclude ? .none : .readOnly }
    }
    /// 隐藏历史和其详情，不激活旧目标，也不改变系统剪贴板。
    private func dismissHistory(animated: Bool = true) {
        guard panelPresented else { return }
        panelPresented = false
        if activeSurface == .cards { activeSurface = nil; requestedSurface = nil }
        focusState.reset()
        model?.panelVisibilityChanged(false)
        focusDismissal?.cancel(); model?.showingDetail = false; model?.showingCategoryEditor = false; model?.showingFilters = false; model?.showingStatusDetail = false
        panelAnimationGeneration += 1; panelFade?.cancel(); panelFade = nil
        if model?.quickBadgesVisible == true { model?.quickBadgesVisible = false }
        if let panel {
            // 用户关闭淡出0.12s且期间不接收鼠标；粘贴与入队立即隐藏，by AI.Coding。
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && panel.isVisible {
                let generation = panelAnimationGeneration
                panel.ignoresMouseEvents = true
                // 不用异步动画completion：其闭包跨并发边界，严格并发检查下无法编译，by AI.Coding。
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: nil)
                panelFade = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self else { return }
                    Self.finishPanelFade(panel, generation: generation, current: self.panelAnimationGeneration)
                }
            } else { Self.finishPanelFade(panel, generation: panelAnimationGeneration, current: panelAnimationGeneration) }
        }
        #if DEBUG
        if let model { GUIAcceptanceProbe.event("panel-dismissed", model) }
        #endif
    }
    /// key窗口切换稳定后核对整个面板交互，菜单/详情临时接管焦点不能误关闭。
    private func scheduleFocusDismissal(externalInteraction: Bool = false, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if externalInteraction { focusState.externalInteraction(at: time) }
        focusDismissal?.cancel()
        guard let panel, panelPresented, requestedSurface == nil || requestedSurface == .cards else { return }
        focusDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, !Task.isCancelled, self.panelPresented, self.requestedSurface == nil || self.requestedSurface == .cards else { return }
            let ownsKey = Self.ownsHistoryWindow(NSApp.keyWindow, panel: panel,
                settings: self.settingsWindow, feedback: self.feedbackPanel,
                showingDetail: self.model?.showingDetail == true,
                showingCategoryEditor: self.model?.showingCategoryEditor == true,
                showingFilters: self.model?.showingFilters == true || self.model?.showingStatusDetail == true,
                showingContentEditor: self.model?.contentEditorPresented == true, queue: self.queuePanel, manager: self.managerWindow)
            // 有未提交输入时外部点击只移开焦点，不能绕过显式关闭的保存保护。
            guard self.model?.surfaceEdits.hasChanges(.cards) != true, self.model?.surfaceEdits.resolving != true else { return }
            guard self.focusState.shouldDismiss(panelIsKey: panel.isKeyWindow, ownsKeyWindow: ownsKey,
                dragging: self.model?.dragActive == true, confirming: self.model?.confirmingChange == true || self.model?.contentEditorPresented == true,
                hasModal: NSApp.modalWindow != nil, pinned: self.model?.pinned == true) else { return }
            self.dismissHistory()
        }
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0) | (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }
    /// 修饰键恰好等于设置中的快速粘贴修饰键才显示角标；多按或少按都不显示，by AI.Coding。
    static func showsQuickBadges(_ flags: NSEvent.ModifierFlags, quickModifiers: UInt32) -> Bool {
        quickModifiers != 0 && carbonModifiers(flags.intersection([.command, .option, .control, .shift])) == quickModifiers
    }
    /// 淡出结束只在代次未变时隐藏并复原；重新打开已递增代次，旧结束不得隐藏面板，by AI.Coding。
    static func finishPanelFade(_ panel: NSWindow, generation: Int, current: Int) {
        guard generation == current else { return }
        panel.orderOut(nil); panel.alphaValue = 1; panel.ignoresMouseEvents = false
    }
    /// 父子窗口与自有弹窗共享面板交互，设置和反馈不属于历史，by AI.Coding。
    static func ownsHistoryWindow(_ window: NSWindow?, panel: NSWindow?, settings: NSWindow?,
                                  feedback: NSWindow?, showingDetail: Bool,
                                  showingCategoryEditor: Bool, showingFilters: Bool,
                                  showingContentEditor: Bool = false, queue: NSWindow? = nil, manager: NSWindow? = nil) -> Bool {
        guard let window, !ownedBy(window, manager) else { return false }
        var owner: NSWindow? = window
        while let value = owner {
            if value === panel { return true }
            owner = value.sheetParent ?? value.parent
        }
        return (showingDetail || showingCategoryEditor || showingFilters || showingContentEditor) && window.isVisible && window !== settings && window !== feedback && window !== queue
    }
    /// 窗口本身或其附页、子窗口归属于owner，by AI.Coding。
    static func ownedBy(_ window: NSWindow?, _ owner: NSWindow?) -> Bool {
        guard let owner else { return false }
        var current = window
        while let value = current {
            if value === owner { return true }
            current = value.sheetParent ?? value.parent
        }
        return false
    }
    /// 管理窗口里可编辑文字、或只读文字已有选区时，⌘C/⌫等按键交给文本视图，by AI.Coding。
    static func managerTextOwnsKeys(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView else { return false }
        return text.isEditable || text.selectedRange().length > 0
    }
    /// 所有退出入口共用系统终止请求，测试替换请求而不终止任何真实应用，by AI.Coding。
    @objc func quitApplication(_ sender: Any?) { requestTermination() }
    /// 面板快捷键入口不依赖隐藏的状态项，by AI.Coding。
    func handleQuitShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "q" else { return false }
        quitApplication(nil); return true
    }
    /// 自有弹窗保留焦点，但文字复制/删除与确认按键仍由其原生响应者处理，by AI.Coding。
    static func routesHistoryShortcuts(_ eventWindow: NSWindow?, panel: NSWindow,
                                      confirming: Bool, hasModal: Bool) -> Bool {
        !confirming && !hasModal && (eventWindow === panel || (eventWindow == nil && panel.isKeyWindow))
    }
    /// Space/Return/方向键由已聚焦的原生控件处理；结果响应者和搜索编辑器保留历史导航。
    /// 不依赖SwiftUI内部控件类名，也不查询其他应用的AX树，by AI.Coding。
    static func preservesFocusedControlKeys(_ event: NSEvent, firstResponder: NSResponder?, resultsResponder: NSResponder) -> Bool {
        guard let firstResponder, firstResponder !== resultsResponder, !(firstResponder is NSTextView) else { return false }
        return event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }
    /// 结果区无⌘⌃⌥的可打印字符转入搜索；Space、Return、Delete、Tab、Esc、方向与功能键保留原含义，by AI.Coding。
    static func forwardsToSearch(_ event: NSEvent, editing: Bool) -> Bool {
        guard !editing, event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              ![UInt16(49), 36, 76, 51, 117, 48, 53, 123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode),
              let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
    }
    /// 仅搜索框的原生field editor可借用记录快捷键，其他文字编辑仍由原控件处理，by AI.Coding。
    static func isHistorySearchEditor(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView, editor.isEditable, editor.isFieldEditor else { return false }
        return editor.delegate is NSSearchField
    }
    /// 原底栏复制按钮的⌘C在搜索框中复制所选记录；按钮移除后显式保留，无选择或输入法组合时仍归文字，by AI.Coding。
    static func copiesRecordFromSearch(_ event: NSEvent, responder: NSResponder?, model: HistoryViewModel) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command], event.keyCode == 8,
              isHistorySearchEditor(responder), (responder as? NSTextView)?.hasMarkedText() != true, model.selectedID != nil else { return false }
        model.perform(action: .copy); return true
    }
    /// 状态槽焦点提示的归类：搜索编辑器、结果响应者，其余控件不提示，by AI.Coding。
    static func historyFocus(_ responder: NSResponder?, panel: NSWindow) -> HistoryViewModel.HistoryFocus {
        // 搜索框成为第一响应者后由field editor接管，KVO只通知前一步，两者都算搜索焦点。
        if isHistorySearchEditor(responder) || responder is NSSearchField { return .search }
        return responder == nil || responder === panel ? .results : .other
    }
    /// 第一响应者变化时同步改写焦点归类，状态槽提示在同一渲染周期更新，by AI.Coding。
    static func observeHistoryFocus(of panel: NSWindow, model: HistoryViewModel) -> NSKeyValueObservation {
        panel.observe(\.firstResponder, options: [.initial, .new]) { [weak model] panel, _ in
            MainActor.assumeIsolated {
                // field editor接管瞬间尚未挂代理，沿用刚交出焦点的控件归类；之后不会再收到通知。
                if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor, editor.delegate == nil { return }
                let focus = historyFocus(panel.firstResponder, panel: panel)
                if model?.historyFocus != focus { model?.historyFocus = focus }
            }
        }
    }
    /// 搜索和结果共享明确的记录动作；不接管复制、全选、撤销及输入法候选，by AI.Coding。
    static func handleRecordCommand(_ event: NSEvent, responder: NSResponder?, model: HistoryViewModel) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
              [UInt16(5), 31, 14, 34, 17, 15].contains(event.keyCode) else { return false }
        let editor = responder as? NSTextView
        guard editor?.hasMarkedText() != true,
              editor?.isEditable != true || isHistorySearchEditor(responder) else { return false }
        // 搜索结果尚未更新时不对旧记录执行新开放的快捷键。
        if isHistorySearchEditor(responder), model.historyBusy { return true }
        switch event.keyCode {
        case 5: model.jumpToHistory()
        case 31: model.openSelected()
        case 14: model.editSelectedContent()
        case 34: if model.canDisplayContents, model.selectedID != nil { model.showingDetail.toggle() }
        case 17: model.showTransformMenu(atSelectedCard: true)
        case 15: if let id = model.selectedID { model.beginRename(id) }
        default: return false
        }
        return true
    }
    /// 队列进行中固定在当前屏幕右下角显示进度、下一项与“结束”；结束或耗尽后淡出，by AI.Coding。
    private func updateQueuePanel() {
        guard let model else { return }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.15
        guard model.pasteQueueActive else {
            guard let panel = queuePanel, panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = duration; panel.animator().alphaValue = 0 }, completionHandler: nil)
            queueFade = Task { try? await Task.sleep(for: .seconds(duration)); if !Task.isCancelled { panel.orderOut(nil) } }
            return
        }
        queueFade?.cancel()
        if queuePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
            panel.level = .statusBar; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = Self.queueHost(model: model) { [weak self] in self?.pasteQueueNext(retry: true) }; queuePanel = panel
        }
        guard let panel = queuePanel, let host = panel.contentView else { return }
        panel.sharingType = model.settings.excludeFromSharing ? .none : .readOnly
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let rect = screen.visibleFrame
            panel.setFrame(NSRect(x: rect.maxX - size.width - 16, y: rect.minY + 16, width: size.width, height: size.height), display: true)
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            // 首次置前的窗口服务器同步立即完成，不吞掉淡入的前几帧（与历史面板相同），by AI.Coding。
            CATransaction.flush()
            NSAnimationContext.runAnimationGroup { $0.duration = duration; panel.animator().alphaValue = 1 }
        }
    }
    /// 只保留固有尺寸：浮窗按 fittingSize 定尺寸，不让内容反向约束窗口。清空全部选项时 fittingSize 恒为 0，浮窗是 0×0 看不见，by AI.Coding。
    static func queueHost(model: HistoryViewModel, retry: @escaping () -> Void) -> NSHostingView<PasteQueueView> {
        let host = NSHostingView(rootView: PasteQueueView(model: model, retry: retry)); host.sizingOptions = [.intrinsicContentSize]
        return host
    }
    /// 粘贴回退显示短暂非激活提示，不让关闭历史面板隐藏失败原因。
    private func showPasteFeedback(_ message: String, failed: Bool) {
        feedbackTask?.cancel()
        if feedbackPanel == nil {
            let feedback = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            feedback.isOpaque = false; feedback.backgroundColor = .clear; feedback.hasShadow = true
            feedback.isReleasedWhenClosed = false; feedback.hidesOnDeactivate = false; feedback.ignoresMouseEvents = true
            feedback.level = .statusBar; feedback.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            feedbackPanel = feedback
        }
        let host = NSHostingView(rootView: PasteFeedbackView(message: message, failed: failed))
        feedbackPanel?.contentView = host
        let size = host.fittingSize
        if let screen = panel?.screen ?? NSScreen.main {
            let rect = screen.visibleFrame
            let y = panel?.isVisible == true ? (panel?.frame.maxY ?? rect.minY) + 12 : rect.minY + 24
            feedbackPanel?.setFrame(NSRect(x: rect.midX - size.width / 2, y: min(y, rect.maxY - size.height - 16), width: size.width, height: size.height), display: true)
        }
        // orderFront不激活应用，也不把反馈窗口设为key；淡入淡出避免突兀出现。
        feedbackPanel?.alphaValue = 0
        feedbackPanel?.orderFrontRegardless()
        CATransaction.flush()
        NSAnimationContext.runAnimationGroup {
            $0.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            feedbackPanel?.animator().alphaValue = 1
        }
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let panel = self?.feedbackPanel else { return }
            // 不用异步动画接口：其闭包跨并发边界，严格并发检查下无法编译，by AI.Coding。
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.25
            NSAnimationContext.runAnimationGroup({ $0.duration = duration; panel.animator().alphaValue = 0 }, completionHandler: nil)
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }
    /// 设置使用可取消、失焦隐藏的窗口，不改变已记住的面板目标，by AI.Coding。
    /// 所有入口只提交目标，保护、准备、动画与释放在一处完成。
    @objc public func showSettings() { requestSurface(.settings) }
    @objc private func showHistoryManagerFromMenu() { showHistoryManager() }
    func showHistoryManager(reveal ids: [ClipID] = []) { requestSurface(.manager, reveal: ids) }

    /// 已有确认不接受排队；草稿确认期间冻结原目标。普通动画则允许随时改向。
    private func requestSurface(_ destination: AppSurface?, reveal ids: [ClipID] = []) {
        guard let model, !model.surfaceEdits.resolving else { return }
        let windows = [managerWindow, settingsWindow, panel].compactMap { $0 }
        let contentEditor = manager?.editor ?? (model.contentEditorPresented ? model.contentEditor : nil)
        let editingWindow = manager?.editor != nil ? managerWindow : panel
        let editingSheet = contentEditor != nil ? editingWindow?.attachedSheet : nil
        if let modal = NSApp.modalWindow ?? windows.compactMap({ $0.attachedSheet }).first,
           modal !== editingSheet || contentEditor?.confirmingDiscard == true || modal.attachedSheet != nil {
            if presentsSurfaces { Self.presentWithoutActivation(modal) }; return
        }
        guard !model.confirmingChange, manager?.editor?.confirmingDiscard != true,
              model.contentEditor?.confirmingDiscard != true else { return }
        guard !model.surfaceOperationPending, manager?.surfaceOperationPending != true, contentEditor?.saving != true else { return }
        if destination == activeSurface, destination == requestedSurface, let destination, let window = window(for: destination), window.alphaValue >= 1 {
            if presentsSurfaces { Self.presentWithoutActivation(window) }
            if destination == .manager, !ids.isEmpty { manager?.reveal(ids) }
            return
        }
        let origin = activeSurface
        let request = UUID(); surfaceRequestID = request
        surfaceTask?.cancel()
        surfaceTask = Task { [weak self] in
            // 连续同步请求可能在任务开始前取消旧任务，旧任务连确认也不得发起。
            guard let self, !Task.isCancelled, request == self.surfaceRequestID else { return }
            if let origin, origin != destination {
                let owner = editingSheet ?? self.window(for: origin)
                let contentDraftID = UUID()
                if let contentEditor {
                    model.surfaceEdits.register(contentDraftID, surface: origin, draft: .init(title: "内容修改", dirty: { contentEditor.hasChanges }, save: {
                        guard let saving = contentEditor.save(to: model.store) else { return false }
                        let saved = await saving.value
                        if saved {
                            if self.manager?.editor === contentEditor { self.manager?.editor = nil }
                            model.finishSavedContentEdit(contentEditor)
                        }
                        return saved
                    }, discard: {}))
                }
                defer { model.surfaceEdits.remove(contentDraftID) }
                let sourceWindow = self.window(for: origin)
                sourceWindow?.ignoresMouseEvents = true
                let accepted = await model.surfaceEdits.resolve(origin) { title in
                    guard let owner else { return .cancel }
                    return await self.confirmLeaving(title, owner: owner, closing: destination == nil)
                }
                guard accepted, !Task.isCancelled, request == self.surfaceRequestID else {
                    sourceWindow?.ignoresMouseEvents = false; return
                }
                self.manager?.discardEdit(); model.discardContentEdit()
                // 准备目标期间保留原画面，但禁止继续修改已通过保护检查的输入。
                self.window(for: origin)?.ignoresMouseEvents = true
            }
            guard !Task.isCancelled, request == self.surfaceRequestID else { return }
            self.requestedSurface = destination
            await self.prepareSurface(destination, reveal: ids, request: request)
        }
    }
    /// 未提交编辑的保存结果决定是否继续；取消后恢复原来的第一响应者。
    private func confirmLeaving(_ title: String, owner: NSWindow, closing: Bool) async -> SurfaceEdits.Choice {
        #if DEBUG
        if let surfaceChoiceForTesting { return await surfaceChoiceForTesting(title) }
        #endif
        let responder = owner.firstResponder
        // 底栏面板不能承载系统Sheet：系统会为较高的确认框移动父窗，产生整条面板弹跳。
        if owner === panel {
            let confirmation = SurfaceConfirmation(title: title, closing: closing)
            surfaceConfirmation = confirmation
            defer { surfaceConfirmation = nil }
            return await confirmation.present(for: owner, visible: presentsSurfaces)
        }
        let alert = NSAlert(); alert.messageText = "\(title)尚未保存"
        alert.informativeText = "保存后继续，或放弃本次修改。"
        alert.addButton(withTitle: closing ? "保存并关闭" : "保存并继续")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: closing ? "取消关闭" : "取消切换").keyEquivalent = "\u{1b}"
        alert.window.sharingType = owner.sharingType
        let response = await alert.beginSheetModal(for: owner)
        if let responder { owner.makeFirstResponder(responder) }
        switch response { case .alertFirstButtonReturn: return .save; case .alertSecondButtonReturn: return .discard; default: return .cancel }
    }
    /// 仅供窗口路由使用，不将预览浮层误认成主窗口。
    private func window(for surface: AppSurface) -> NSWindow? {
        switch surface { case .cards: panel; case .settings: settingsWindow; case .manager: managerWindow }
    }
    /// 后台应用的普通orderFront可能排在前台应用后面；最终前置须明确忽略应用激活状态。
    /// 不激活NSApp、不提升窗口常驻层级，外部应用之后仍可正常覆盖本窗口。
    static func presentWithoutActivation(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    /// 新窗口在透明状态下完成布局，旧窗口仍保留画面，内容就绪后才开始交接。
    private func prepareSurface(_ destination: AppSurface?, reveal ids: [ClipID], request: UUID) async {
        guard let model else { return }
        let target: NSWindow?
        switch destination {
        case .manager:
            target = managerWindow ?? makeHistoryManager(model)
            if !ids.isEmpty { manager?.reveal(ids) }
        case .settings: target = settingsWindow ?? makeSettings(model)
        case .cards: target = nil
        case nil: target = nil
        }
        if let target, !target.isVisible {
            target.alphaValue = 0; target.ignoresMouseEvents = true
            target.contentView?.layoutSubtreeIfNeeded()
            if presentsSurfaces { target.orderFrontRegardless() }
            target.contentView?.displayIfNeeded()
        }
        if destination == .manager {
            while manager?.loading == true {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
        // 给 SwiftUI 首次布局与窗口服务器提交留出稳定帧；取消时新请求接管已有窗口。
        if destination != nil {
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
        }
        guard !Task.isCancelled, request == surfaceRequestID else { return }
        manager?.closeQuickLook()
        if destination != .cards { model.closeQuickLookForTransition() }
        if destination == .cards { presentHistory() }
        let current = destination.flatMap { window(for: $0) }
        if let current, presentsSurfaces {
            Self.presentWithoutActivation(current)
        }
        activeSurface = destination
        for window in [panel, settingsWindow, managerWindow].compactMap({ $0 }) { window.ignoresMouseEvents = window !== current }
        let transitions = [panel, settingsWindow, managerWindow].compactMap { $0 }.filter(\.isVisible).map { ($0, $0 === current ? 1.0 : 0.0) }
        surfaceAnimator.animate(transitions, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self] in
            guard let self, request == self.surfaceRequestID else { return }
            self.releaseSurfaces(except: destination)
        }
    }
    /// 释放退出的窗口和异步任务；只保留明确约定的浏览条件。
    private func releaseSurfaces(except destination: AppSurface?) {
        if destination != .cards { dismissHistory(animated: false); model?.surfaceEdits.removeAll(.cards) }
        if destination != .manager, let window = managerWindow {
            managerBrowsing = manager?.browsingState
            manager?.stop(); manager = nil; managerWindow = nil
            window.onClose = nil; window.close()
            // 主动清空托管根视图，避免 SwiftUI 图缓存继续持有旧管理模型。
            (window.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(EmptyView())
            window.contentViewController = nil; window.contentView = nil
            model?.surfaceEdits.removeAll(.manager)
        }
        if destination != .settings, let window = settingsWindow {
            settingsWindow = nil; window.close()
            (window.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
            window.contentView = nil
            model?.settingsVisibilityChanged(false); model?.surfaceEdits.removeAll(.settings)
        }
    }
    /// 设置窗口非激活、关闭即释放；仅恢复最后访问的分组。
    private func makeSettings(_ model: HistoryViewModel) -> SettingsWindow {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.delegate = window; window.title = "LocalClip 设置"; window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false; window.isFloatingPanel = false; window.level = .normal; window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.requestClose = { [weak self] in self?.requestSurface(nil) }
        var view = SettingsView(model: model, login: login, section: settingsSection, fitWindow: { [weak window] in window?.fitContent(height: $0) })
        view.sectionChanged = { [weak self] in self?.settingsSection = $0 }
        let host = NSHostingView(rootView: AnyView(view)); host.sizingOptions = []
        window.contentView = host; window.center(); settingsWindow = window
        Self.applySharing(model.settings.excludeFromSharing, to: [window])
        model.settingsVisibilityChanged(true)
        return window
    }
    /// 管理窗口复用非激活面板能力，保持外部应用菜单和焦点身份。
    private func makeHistoryManager(_ model: HistoryViewModel) -> HistoryManagerWindow {
        let manager = HistoryManagerModel(history: model)
        if let managerBrowsing { manager.restoreBrowsing(managerBrowsing) }
        manager.locate = { [weak self] id in self?.showHistory(); self?.model?.jumpToHistory(id: id) }
        let host = NSHostingController(rootView: AnyView(HistoryManagerView(model: manager, history: model)))
        host.sceneBridgingOptions = [.toolbars, .title]; host.sizingOptions = []
        let window = HistoryManagerWindow(content: host)
        manager.previewParent = { [weak window] in window }
        window.requestClose = { [weak self] in self?.requestSurface(nil) }
        managerWindow = window; self.manager = manager
        Self.applySharing(model.settings.excludeFromSharing, to: [window])
        manager.start(); window.applyInspectorIdealWidth()
        return window
    }
    /// 按点击时的状态保存明确意图，恢复仍从新计数开始，by AI.Coding。
    @objc private func toggleCapture() {
        model?.toggleRecording()
    }
    /// 外部前台身份由系统公开事件更新，不用于复制来源归因。
    private func observeLifecycle() {
        // 非激活面板返回同一个外部应用时可能没有激活/失去key通知；鼠标点击明确结束交互。
        // 全局监视仅观察点击，不读取按键、不拦截外部事件，也不需要输入监控授权，by AI.Coding。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let time = event.timestamp
            MainActor.assumeIsolated { self?.scheduleFocusDismissal(externalInteraction: true, at: time) }
        }
        // 全局监视不接收本应用事件；面板真实重入和点击设置由本地监视区分，by AI.Coding。
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, self.panelPresented else { return event }
            if Self.ownsHistoryWindow(event.window, panel: panel, settings: self.settingsWindow, feedback: self.feedbackPanel,
                showingDetail: self.model?.showingDetail == true, showingCategoryEditor: self.model?.showingCategoryEditor == true,
                showingFilters: self.model?.showingFilters == true || self.model?.showingStatusDetail == true, showingContentEditor: self.model?.contentEditorPresented == true, queue: self.queuePanel, manager: self.managerWindow) {
                // 迟到的旧输入不能取消较新的外部关闭任务，by AI.Coding。
                if self.focusState.ownedInteraction(at: event.timestamp) { self.focusDismissal?.cancel() }
            } else if event.window != nil {
                self.scheduleFocusDismissal(externalInteraction: true, at: event.timestamp)
            }
            return event
        }
        // 非激活面板不能用NSApp.isActive判断失焦；观察自己的key窗口转移。
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFocusDismissal() }
            })
        }
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            let identity = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.focusState.menuBegan(identity); self.scheduleFocusDismissal()
            }
        })
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            let identity = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.focusState.menuEnded(identity)
                self.scheduleFocusDismissal()
            }
        })
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == self.panelScreenID } ?? NSScreen.main
                self.placePanel(to: screen)
            }
        }
        activatedObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedPID = activated?.processIdentifier, activatedBundleID = activated?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.model?.capture.applicationDidActivate(activatedBundleID)
                guard let self, activatedPID != ProcessInfo.processInfo.processIdentifier else { return }
                if let target = self.applications.target() {
                    // 外部应用切换使旧面板的目标失效；不能沿用旧textarea去抢焦点粘贴。
                    if let previous = self.model?.target,
                       previous.pid != target.pid || previous.bundleID != target.bundleID || previous.launchedAt != target.launchedAt {
                        self.model?.target = nil
                        self.applications.rememberFocus(for: nil)
                    }
                    self.lastExternal = target
                } else {
                    // 外部目标身份缺失时不能在下次打开沿用旧应用，by AI.Coding。
                    self.lastExternal = nil
                    self.model?.target = nil; self.applications.rememberFocus(for: nil)
                }
                // 隐藏面板只需要外部激活事实，不能依赖可用于粘贴的bundle/启动身份，by AI.Coding。
                self.scheduleFocusDismissal(externalInteraction: true)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let model = self?.model else { return }; model.capture.rebaseline(); model.capture.updatePolicy(model.settings); await model.maintenance() }
        }
    }
    /// 仅面板本地按键；Esc优先关闭，其余组合输入交给输入法，不使用全局监听。
    private func installKeyboard() {
        // 修饰键变化只切换角标显示，不消费事件，by AI.Coding。
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.panelPresented, let model = self.model else { return event }
            let visible = Self.showsQuickBadges(event.modifierFlags, quickModifiers: model.settings.quickModifiers)
            if model.quickBadgesVisible != visible { model.quickBadgesVisible = visible }
            return event
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 本地Cmd-Q先于历史/IME分支，也适用于只有设置窗口或菜单图标隐藏时，by AI.Coding。
            if self.handleQuitShortcut(event) { return nil }
            if let eventWindow = event.window, eventWindow.ignoresMouseEvents { return nil }
            // 子确认窗自行处理Return/Esc/Tab，不能落入卡片重命名或内容编辑的快捷键分支。
            if event.window is SurfaceConfirmation.Panel { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == [.command], event.keyCode == 13,
               event.window === self.settingsWindow || event.window === self.managerWindow || event.window === self.panel {
                self.requestSurface(nil); return nil
            }
            // 管理窗口按键：附页、文字编辑与输入法组字交还系统，其余由窗口模型处理，by AI.Coding。
            // 附页按窗口归属认领，不再落入面板编辑器分支保存或取消另一份草稿，by AI.Coding。
            if let window = self.managerWindow, Self.ownedBy(event.window, window), let manager = self.manager {
                let editor = event.window?.firstResponder as? NSTextView
                if editor?.hasMarkedText() == true { return event }
                if event.window !== window {
                    // 编辑附页补上编辑器宣称的⌘↩保存；⌘S与Esc由附页自身处理，确认附页保持原生按键，by AI.Coding。
                    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    if manager.editor != nil, flags == [.command], event.keyCode == 36 || event.keyCode == 76 { manager.saveEdit(); return nil }
                    return event
                }
                guard window.attachedSheet == nil else { return event }
                return manager.handleKey(code: event.keyCode, flags: event.modifierFlags, editing: Self.managerTextOwnsKeys(editor), isRepeat: event.isARepeat) ? nil : event
            }
            // 编辑器接管文字按键；Esc优先收起页内放弃确认或取消编辑，⌘S/⌘↩显式保存，IME候选期间交给文本域，by AI.Coding。
            if let editorState = self.model?.contentEditor, self.model?.contentEditorPresented == true {
                let textEditor = event.window?.firstResponder as? NSTextView
                // ⌘W 与取消编辑共用草稿保护，不能绕过未保存确认关闭弹窗。
                if event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
                   event.keyCode == 13, event.window !== self.settingsWindow {
                    if textEditor?.hasMarkedText() != true { self.model?.requestCancelContentEdit() }
                    return nil
                }
                if textEditor?.hasMarkedText() == true { return event }
                if event.keyCode == 53 {
                    if editorState.confirmingDiscard { editorState.confirmingDiscard = false }
                    else { self.model?.requestCancelContentEdit() }
                    return nil
                }
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if flags == [.command], (event.keyCode == 1 || event.keyCode == 36 || event.keyCode == 76) {
                    if editorState.canSave { self.model?.saveContentEdit() }
                    return nil
                }
                return event
            }
            // 淡出中的面板不再接收按键，避免改动搜索词或触发历史操作，by AI.Coding。
            if let panel = self.panel, !self.panelPresented, panel.isVisible, event.window === panel { return nil }
            guard let panel = self.panel, self.panelPresented, let model = self.model,
                  Self.ownsHistoryWindow(event.window, panel: panel, settings: self.settingsWindow, feedback: self.feedbackPanel,
                      showingDetail: model.showingDetail, showingCategoryEditor: model.showingCategoryEditor,
                      showingFilters: model.showingFilters || model.showingStatusDetail, showingContentEditor: model.contentEditorPresented, queue: self.queuePanel, manager: self.managerWindow) || (event.window == nil && panel.isKeyWindow) else { return event }
            self.focusState.ownedInteraction(at: event.timestamp)
            // 面板内确认期间按键只作答：Return确认、Esc取消，其余不进入搜索或历史操作；输入法组字时先交给候选，by AI.Coding。
            if model.panelConfirmation != nil {
                if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                switch event.keyCode {
                case 36, 76: model.answerPanelConfirmation(true)
                case 53: model.answerPanelConfirmation(false)
                default: break
                }
                return nil
            }
            // 弹窗归属只用于保留交互，不能把详情文字或确认按钮按键当作历史操作，by AI.Coding。
            guard Self.routesHistoryShortcuts(event.window, panel: panel,
                confirming: model.confirmingChange, hasModal: NSApp.modalWindow != nil) else { return event }
            // 名称编辑的提交/撤销与IME交给文本域，绝不触发粘贴或板内快捷键，by AI.Coding。
            if model.renamingID != nil {
                let editor = panel.firstResponder as? NSTextView
                if editor?.hasMarkedText() == true { return event }
                if event.keyCode == 53 { model.cancelRename(); return nil }
                return event
            }
            // 输入法取消候选优先于面板关闭，和原生搜索框保持相同规则，by AI.Coding。
            let editor = panel.firstResponder as? NSTextView
            if editor?.hasMarkedText() == true { return event }
            if event.keyCode == 53 {
                if model.handleEscape() { self.dismissHistory() }
                return nil
            }
            if model.showingCategoryEditor || model.showingFilters || model.showingStatusDetail { return event }
            let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
            let editing = editor?.isEditable == true
            if flags == [.command], event.keyCode == 3 {
                model.searchFocusRequest = UUID(); return nil
            }
            // Tab/Shift-Tab和已聚焦控件的激活键交给原生焦点链，避免Space误开预览、Return误粘贴。
            if event.keyCode == 48 { return event }
            if Self.preservesFocusedControlKeys(event, firstResponder: panel.firstResponder, resultsResponder: panel) { return event }
            if flags == [.shift], [UInt16(36),76].contains(event.keyCode) { model.perform(.plainText, action: .directPaste); return nil }
            let carbon = Self.carbonModifiers(flags)
            if carbon == model.settings.boardModifiers {
                if event.keyCode == 123 || event.keyCode == 124 { model.switchBoard(event.keyCode == 123 ? -1 : 1); return nil }
                if event.keyCode == 45 { model.editCategory(); return nil }
            }
            if carbon == model.settings.quickModifiers, let number = [UInt16(18),19,20,21,23,22,26,28,25].firstIndex(of: event.keyCode), model.items.indices.contains(number) {
                model.select(model.items[number].id); model.perform(action: .directPaste); return nil
            }
            // ⌘, 是macOS打开设置的通用快捷键，面板内同样生效，by AI.Coding。
            if flags == [.command], event.keyCode == 43 { model.openSettings?(); return nil }
            if flags == [.command, .option], event.keyCode == 4 { model.openHistoryManager?([]); return nil }
            // 搜索文字未改变且最后动作是记录删除时，仍可撤销该记录。
            if flags == [.command], event.keyCode == 6, editing, model.canUndoFromSearch { model.undoDeletion(); return nil }
            if Self.copiesRecordFromSearch(event, responder: panel.firstResponder, model: model) { return nil }
            if Self.handleRecordCommand(event, responder: panel.firstResponder, model: model) { return nil }
            if flags == [.command] && !editing {
                switch event.keyCode {
                case 0: model.selectAllResults(); return nil
                case 8: model.perform(action: .copy); return nil
                case 6: model.undoDeletion(); return nil
                default: return event
                }
            }
            if !flags.intersection([.command,.control,.option]).isEmpty { return event }
            // 结果区键入同步转入搜索框后放行原事件，由field editor与输入法接收首键，不手动派发keyDown，by AI.Coding。
            if event.window === panel, panel.firstResponder == nil || panel.firstResponder === panel, Self.forwardsToSearch(event, editing: editing) {
                model.focusSearchSynchronously(); return event
            }
            if !editing {
                if event.keyCode == 49 { model.toggleQuickLook(); return nil }
                if event.keyCode == 115 || event.keyCode == 119 { model.edgeSelection(event.keyCode == 119, extend: flags.contains(.shift)); return nil }
                if flags.contains(.shift), [UInt16(123),124,125,126].contains(event.keyCode) { model.extendNavigation([UInt16(123),126].contains(event.keyCode) ? -1 : 1); return nil }
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                // 搜索框即使为空也只处理文字编辑；切到结果区后才允许删除历史。
                if editing { return event }
                // 隐藏内容时不盲删不可见记录，普通复制/粘贴契约保持，by AI.Coding。
                guard !event.isARepeat, model.canDisplayContents else { return nil }
                model.deleteSelected(); return nil
            }
            switch event.keyCode {
            case 36, 76: if editing { model.focusResults?() } else { model.perform() }; return nil
            case 125, 126:
                let delta = event.keyCode == 125 ? 1 : -1
                if flags.isEmpty, Self.isHistorySearchEditor(panel.firstResponder) { model.navigateFromSearch(delta) }
                else { model.navigate(delta) }
                return nil
            case 123, 124:
                if let editor = self.panel?.firstResponder as? NSTextView, !editor.string.isEmpty { return event }
                model.navigate(event.keyCode == 123 ? -1 : 1); return nil
            default: return event
            }
        }
    }
    /// 退出释放系统注册；未完成写入靠原子提交协议恢复。
    public func applicationWillTerminate(_ notification: Notification) {
        surfaceConfirmation?.cancelImmediately()
        surfaceTask?.cancel(); surfaceAnimator.cancel()
        manager?.stop(); model?.surfaceEdits.removeAll(.cards); model?.surfaceEdits.removeAll(.manager); model?.surfaceEdits.removeAll(.settings)
        sourceObserver?.stop(); sourceObserver = nil
        startup?.cancel(); modelStartup?.cancel()
        model?.capture.stop(); maintenance?.cancel(); hotkeys.stop()
        feedbackTask?.cancel(); feedbackPanel?.orderOut(nil); queueFade?.cancel(); queuePanel?.orderOut(nil)
        focusDismissal?.cancel()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let activatedObserver { NSWorkspace.shared.notificationCenter.removeObserver(activatedObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
extension AppDelegate: NSMenuDelegate {
    /// 打开菜单时反映真实状态，而不是创建时的开关值。
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first(where: \.isSectionHeader)?.title = statusMenuTitle
        // 可选队列/更新项不会改变采集动作身份，by AI.Coding。
        if let capture = menu.items.first(where: { $0.action == #selector(toggleCapture) }) { updateCaptureItem(capture) }
        if let check = menu.items.first(where: { $0.action == #selector(checkForUpdates) }) { updateCheckItem(check) }
    }
}

/// 紧凑胶囊提示：宽度随文字，图标区分“已复制需手动粘贴”与失败，by AI.Coding。
/// 队列浮窗内容：进度、下一项一行摘要（隐藏内容时不显示正文）、快捷键与失败原因，by AI.Coding。
struct PasteQueueView: View {
    @ObservedObject var model: HistoryViewModel
    var retry: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "list.number").foregroundStyle(Color.accentColor)
                Text("粘贴队列 \(model.pasteQueuePosition)/\(model.pasteQueue.count)").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button("结束") { model.stopPasteQueue() }.controlSize(.small).accessibilityLabel("结束粘贴队列")
            }
            Text((model.pasteQueueAwaiting ? "当前项：" : "下一项：") + model.pasteQueueNextSummary).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            if model.pasteQueueAwaiting {
                // 等待确认：快捷键不再覆盖剪贴板，由用户选择重试或确认已手动粘贴，by AI.Coding。
                HStack(spacing: 6) {
                    Button("重试当前项", action: retry)
                    Button("已手动粘贴，继续") { model.confirmPasteQueueManualPaste() }
                }.controlSize(.small).disabled(model.pasteQueueBusy)
            } else {
                Text("\(model.pasteQueueShortcutLabel) 粘贴下一项").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let warning = model.pasteQueueWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(width: 260, alignment: .leading)
            .floatingSurface()
            .padding(1)
    }
}
struct PasteFeedbackView: View {
    let message: String
    let failed: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "doc.on.clipboard.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(failed ? Color.orange : Color.accentColor)
            Text(message).font(.system(size: 13, weight: .medium)).frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 16).padding(.vertical, 11)
            .fixedSize()
            .floatingSurface()
            .padding(1)
    }
}
