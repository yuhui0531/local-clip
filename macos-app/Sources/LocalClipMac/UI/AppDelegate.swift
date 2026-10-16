// 正式菜单栏、面板、依赖组装与生命周期；无 mock 入口，by AI.Coding。
import AppKit
import SwiftUI
import Carbon
import ApplicationServices
import LocalClipCore
@MainActor final class ClipPanel: NSPanel {
    /// 与Esc、关闭按钮走同一收起流程，复位焦点与可见状态。
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 标准取消命令也关闭历史，不依赖搜索框是否处于编辑状态。
    override func cancelOperation(_ sender: Any?) { onCancel() }
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
    private var feedbackPanel: NSPanel?
    private var feedbackTask: Task<Void, Never>?
    private var model: HistoryViewModel?
    private let applications = MacApplicationClient()
    private let hotkeys = HotKeyService()
    private let login = LoginItemService()
    private var lastExternal: TargetToken?
    private var keyboardMonitor: Any?
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
        #if DEBUG
        if GUIAcceptanceProbe.configuration != nil {
            _ = GUIAcceptanceProbe.launched
            // 独立验收宿主提供常规应用身份，生产仍为菜单栏非激活面板，by AI.Coding。
            NSApp.setActivationPolicy(.regular)
        }
        #endif
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
            let paste = PasteCoordinator(board: board, applications: applications, store: store, capture: capture)
            let model = HistoryViewModel(store: store, capture: capture, paste: paste, derived: DerivedContentService(store: store))
            self.model = model; lastExternal = applications.target()
            // 在首次查询前提供屏幕尺寸；SwiftUI随后用实际视口修正，不先读固定50条，by AI.Coding。
            model.configureHistoryViewport(width: NSScreen.main?.frame.width ?? 1400, cardWidth: HistoryView.cardSide(height: initialSettings.panelHeight, filtered: false))
            model.panelVisibilityChanged(false)
            model.closePanel = { [weak self] in self?.dismissHistory() }
            // 非激活面板不抢前台；置顶时前台应用即当前要粘贴的目标，by AI.Coding。
            model.refreshPinnedTarget = { [weak self, weak model] in
                guard let self, let model, let target = self.applications.target() else { return }
                self.lastExternal = target; self.applications.rememberFocus(for: target); model.target = target
            }
            model.panelInteractionChanged = { [weak self] in self?.scheduleFocusDismissal() }
            model.openSettings = { [weak self] in self?.showSettings() }
            model.quitApplication = { [weak self] in self?.quitApplication(nil) }
            model.registerShortcut = { [weak self] in self?.hotkeys.register($0) ?? false }
            model.focusResults = { [weak self] in guard let panel = self?.panel else { return }; panel.makeFirstResponder(panel) }
            model.settingsChanged = { [weak self] in self?.applyAppearanceSettings() }
            model.resizePanel = { [weak self] height, persist in self?.resizeHistory(height, persist: persist) }
            model.showPasteFeedback = { [weak self] message, failed in self?.showPasteFeedback(message, failed: failed) }
            paste.closePanel = model.closePanel
            let copyJournal = location.appendingPathComponent("FinderCopyJournal", isDirectory: true)
            paste.copyJournal = copyJournal
            hotkeys.onInvoke = { [weak self] in self?.toggleHistory() }
            model.registerQueueShortcut = { [weak self] in self?.hotkeys.registerQueue($0) ?? false }
            model.unregisterQueueShortcut = { [weak self] in self?.hotkeys.unregisterQueue() }
            model.pasteQueueChanged = { [weak self] in self?.updateMenu() }
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
                    GUIAcceptanceProbe.attach(model: model, board: access, show: { [weak self] in self?.showHistory() }, hide: { [weak self] in self?.dismissHistory() })
                    #endif
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
            showHistory(); return false
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
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 与应用图标同一符号，模板渲染随菜单栏明暗；暂停时按系统禁用样式变淡，by AI.Coding。
        status?.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "LocalClip")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        status?.button?.appearsDisabled = model?.settings.captureEnabled == false
        updateMenu()
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
        NSApp.activate(ignoringOtherApps: true)
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
                    NSApp.activate(ignoringOtherApps: true)
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
            NSApp.activate(ignoringOtherApps: true)
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
    private func pasteQueueNext() {
        guard let model else { return }
        let target = applications.target()
        if let target { lastExternal = target; applications.rememberFocus(for: target) }
        model.pasteQueueNext(target: target) {
            !CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        }
    }
    @objc private func stopPasteQueue() { model?.stopPasteQueue() }
    /// 同一快捷键按实际可见状态切换；关闭不刷新历史或重记粘贴目标。
    private func toggleHistory() {
        if panel?.isVisible == true { dismissHistory() }
        else { showHistory() }
    }
    /// 记住外部目标后展示面板，铺满当前显示器底边，禁止拖动和缩放。
    @objc public func showHistory() {
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
        model.configureHistoryViewport(width: rect.width, cardWidth: HistoryView.cardSide(height: panelHeight, filtered: model.sourceFilter != nil || model.dateFilterEnabled))
        model.panelVisibilityChanged(true)
        model.target = lastExternal
        model.revalidateVisibleContent()
        if model.items.isEmpty && !model.historyBusy { model.refresh() }
        let initialFrame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: panelHeight)
        if panel == nil {
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
            panel.onCancel = { [weak self] in self?.dismissHistory() }
            self.panel = panel
        }
        if let panel {
            panelScreenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            model.actualPanelHeight = panelHeight
            panel.sharingType = model.settings.excludeFromSharing ? .none : .readOnly
            placePanel(to: screen)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
            panel.makeKeyAndOrderFront(nil)
            model.focusRequest = UUID()
        }
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
        panel?.sharingType = model.settings.excludeFromSharing ? .none : .readOnly
        model.actualPanelHeight = model.settings.panelHeight; placePanel(to: panel?.screen)
    }
    /// 隐藏历史和其详情，不激活旧目标，也不改变系统剪贴板。
    private func dismissHistory() {
        focusState.reset()
        model?.panelVisibilityChanged(false)
        focusDismissal?.cancel(); model?.showingDetail = false; model?.showingCategoryEditor = false; model?.showingFilters = false
        panel?.orderOut(nil)
        #if DEBUG
        if let model { GUIAcceptanceProbe.event("panel-dismissed", model) }
        #endif
    }
    /// key窗口切换稳定后核对整个面板交互，菜单/详情临时接管焦点不能误关闭。
    private func scheduleFocusDismissal(externalInteraction: Bool = false, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if externalInteraction { focusState.externalInteraction(at: time) }
        focusDismissal?.cancel()
        guard let panel, panel.isVisible else { return }
        focusDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, !Task.isCancelled, panel.isVisible else { return }
            let ownsKey = Self.ownsHistoryWindow(NSApp.keyWindow, panel: panel,
                settings: self.settingsWindow, feedback: self.feedbackPanel,
                showingDetail: self.model?.showingDetail == true,
                showingCategoryEditor: self.model?.showingCategoryEditor == true,
                showingFilters: self.model?.showingFilters == true)
            guard self.focusState.shouldDismiss(panelIsKey: panel.isKeyWindow, ownsKeyWindow: ownsKey,
                dragging: self.model?.dragActive == true, confirming: self.model?.confirmingChange == true || self.model?.contentEditorPresented == true,
                hasModal: NSApp.modalWindow != nil, pinned: self.model?.pinned == true) else { return }
            self.dismissHistory()
        }
    }
    /// 父子窗口与自有弹窗共享面板交互，设置和反馈不属于历史，by AI.Coding。
    static func ownsHistoryWindow(_ window: NSWindow?, panel: NSWindow?, settings: NSWindow?,
                                  feedback: NSWindow?, showingDetail: Bool,
                                  showingCategoryEditor: Bool, showingFilters: Bool) -> Bool {
        guard let window else { return false }
        var owner: NSWindow? = window
        while let value = owner {
            if value === panel { return true }
            owner = value.sheetParent ?? value.parent
        }
        return (showingDetail || showingCategoryEditor || showingFilters) && window.isVisible && window !== settings && window !== feedback
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
    @objc public func showSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            // 与系统设置类窗口一致：尺寸随分组内容变化，不提供手动缩放，by AI.Coding。
            let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.delegate = window
            window.title = "LocalClip 设置"; window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(model: model, login: login)); host.sizingOptions = []
            window.contentView = host; window.center(); settingsWindow = window
        }
        model.settingsVisibilityChanged(true)
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
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
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if Self.ownsHistoryWindow(event.window, panel: panel, settings: self.settingsWindow, feedback: self.feedbackPanel,
                showingDetail: self.model?.showingDetail == true, showingCategoryEditor: self.model?.showingCategoryEditor == true,
                showingFilters: self.model?.showingFilters == true) {
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
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
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
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 本地Cmd-Q先于历史/IME分支，也适用于只有设置窗口或菜单图标隐藏时，by AI.Coding。
            if self.handleQuitShortcut(event) { return nil }
            // 编辑器接管文字按键，先返回系统事件，避免历史操作干扰草稿，by AI.Coding。
            if self.model?.contentEditorPresented == true { return event }
            guard let panel = self.panel, panel.isVisible, let model = self.model,
                  Self.ownsHistoryWindow(event.window, panel: panel, settings: self.settingsWindow, feedback: self.feedbackPanel,
                      showingDetail: model.showingDetail, showingCategoryEditor: model.showingCategoryEditor,
                      showingFilters: model.showingFilters) || (event.window == nil && panel.isKeyWindow) else { return event }
            self.focusState.ownedInteraction(at: event.timestamp)
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
                if model.showingCategoryEditor { model.showingCategoryEditor = false }
                else if model.showingFilters { model.showingFilters = false }
                else if model.showingDetail { model.showingDetail = false }
                else { self.dismissHistory() }
                return nil
            }
            if model.showingCategoryEditor || model.showingFilters { return event }
            let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
            let editing = editor?.isEditable == true
            if flags == [.command], event.keyCode == 3 {
                model.focusRequest = UUID(); return nil
            }
            // Tab/Shift-Tab和已聚焦控件的激活键交给原生焦点链，避免Space误开预览、Return误粘贴。
            if event.keyCode == 48 { return event }
            if Self.preservesFocusedControlKeys(event, firstResponder: panel.firstResponder, resultsResponder: panel) { return event }
            if flags == [.shift], [UInt16(36),76].contains(event.keyCode) { model.perform(.plainText, action: .directPaste); return nil }
            let carbon = (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0) | (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
            if carbon == model.settings.boardModifiers {
                if event.keyCode == 123 || event.keyCode == 124 { model.switchBoard(event.keyCode == 123 ? -1 : 1); return nil }
                if event.keyCode == 45 { model.editCategory(); return nil }
            }
            if carbon == model.settings.quickModifiers, let number = [UInt16(18),19,20,21,23,22,26,28,25].firstIndex(of: event.keyCode), model.items.indices.contains(number) {
                model.select(model.items[number].id); model.perform(action: .directPaste); return nil
            }
            // ⌘, 是macOS打开设置的通用快捷键，面板内同样生效，by AI.Coding。
            if flags == [.command], event.keyCode == 43 { model.openSettings?(); return nil }
            // 搜索文字未改变且最后动作是记录删除时，仍可撤销该记录。
            if flags == [.command], event.keyCode == 6, editing, model.canUndoFromSearch { model.undoDeletion(); return nil }
            if flags == [.command] && !editing {
                switch event.keyCode {
                case 0: model.selectAllResults(); return nil
                case 8: model.perform(action: .copy); return nil
                case 6: model.undoDeletion(); return nil
                case 5: model.jumpToHistory(); return nil
                case 31: model.openSelected(); return nil
                case 14: model.editSelectedContent(); return nil
                // ⌘I 是macOS“显示简介”的通用快捷键，在所选卡片上方切换详情，by AI.Coding。
                case 34: if model.canDisplayContents, model.selectedID != nil { model.showingDetail.toggle() }; return nil
                // ⌘T在所选卡片处弹出转换菜单，Esc只关闭菜单，by AI.Coding。
                case 17: model.showTransformMenu(atSelectedCard: true); return nil
                default: return event
                }
            }
            if !flags.intersection([.command,.control,.option]).isEmpty { return event }
            if !editing {
                if event.keyCode == 49 { model.quickLook(); return nil }
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
            case 125: model.navigate(1); return nil
            case 126: model.navigate(-1); return nil
            case 123, 124:
                if let editor = self.panel?.firstResponder as? NSTextView, !editor.string.isEmpty { return event }
                model.navigate(event.keyCode == 123 ? -1 : 1); return nil
            default: return event
            }
        }
    }
    /// 退出释放系统注册；未完成写入靠原子提交协议恢复。
    public func applicationWillTerminate(_ notification: Notification) {
        sourceObserver?.stop(); sourceObserver = nil
        startup?.cancel(); modelStartup?.cancel()
        model?.capture.stop(); maintenance?.cancel(); hotkeys.stop()
        feedbackTask?.cancel(); feedbackPanel?.orderOut(nil)
        focusDismissal?.cancel()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(1)
    }
}
