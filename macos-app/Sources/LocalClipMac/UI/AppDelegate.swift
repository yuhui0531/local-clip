// 正式菜单栏、面板、依赖组装与生命周期；无 mock 入口，by AI.Coding。
import AppKit
import SwiftUI
import Carbon
import ApplicationServices
import LocalClipCore
@MainActor private final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 标准取消命令也关闭历史，不依赖搜索框是否处于编辑状态。
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
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
    private var pinnedScreenID: NSNumber?
    private var maintenance: Task<Void, Never>?
    private var focusObservers: [NSObjectProtocol] = []
    private var focusDismissal: Task<Void, Never>?
    private var menuTrackingDepth = 0
    private var outsideClickMonitor: Any?
    private var externalInteractionPending = false
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
    /// 获得独占启动权限后建立服务，先恢复存储再记录新变化。
    private func startServices() {
        makeMenu()
        let location = Self.storageLocation(); let firstLaunch = !FileManager.default.fileExists(atPath: location.appendingPathComponent("History/history.sqlite").path)
        do {
            var initialSettings = SettingsSnapshot()
            if firstLaunch { initialSettings.captureEnabled = false }
            let store = try HistoryStore(location: location, initialSettings:initialSettings, extractor: ContentDecoder.extract)
            let access: NativePasteboardAccess
            #if DEBUG
            if let name = GUIAcceptanceProbe.configuration?["board"] { access = NativePasteboardAccess(NSPasteboard(name: .init(name))) }
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
            model.panelInteractionChanged = { [weak self] in self?.scheduleFocusDismissal() }
            model.openSettings = { [weak self] in self?.showSettings() }
            model.registerShortcut = { [weak self] in self?.hotkeys.register($0) ?? false }
            model.focusResults = { [weak self] in guard let panel = self?.panel else { return }; panel.makeFirstResponder(panel) }
            model.settingsChanged = { [weak self] in self?.applyAppearanceSettings() }
            model.resizePanel = { [weak self] height, persist in self?.resizeHistory(height, persist: persist) }
            model.showPasteFeedback = { [weak self] message in self?.showPasteFeedback(message) }
            paste.closePanel = model.closePanel
            hotkeys.onInvoke = { [weak self] in self?.toggleHistory() }
            modelStartup = Task {
                var wantsCapture = false
                if firstLaunch {
                    let notice = NSAlert(); notice.messageText = "LocalClip 只在本机保存剪贴板历史"
                    notice.informativeText = "保存文本、URL、限定富文本、图片和文件引用的新变化；使用全新本地体验数据目录，不兼容或迁移旧库。不导入当前剪贴板，不备份文件本体。敏感/临时标记会过滤，未知来源仍会记录。您可以从菜单栏暂停、排除声明来源应用、删除历史。默认复制，登录启动关闭。数据未宣称加密。"
                    notice.addButton(withTitle: "暂不记录"); notice.addButton(withTitle: "开始记录")
                    wantsCapture = notice.runModal() == .alertSecondButtonReturn
                }
                do {
                    if firstLaunch { var settings = try await store.settings(); settings.captureEnabled = wantsCapture; _ = try await store.updateCaptureSettings(settings) }
                    try await model.start()
                    if !hotkeys.register(model.settings.shortcut) { model.message = "快捷键注册冲突，菜单栏仍可使用" }
                    applyAppearanceSettings(); updateMenu()
                    // 再次打开应用触发接替时，新进程完成启动后继续展示用户请求的历史。
                    if CommandLine.arguments.contains("--show-history") { showHistory() }
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
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "LocalClip 无法打开存储"; alert.informativeText = "原库未覆盖。请检查磁盘、权限或数据库版本。错误类别：\(error)"; alert.runModal()
        }
    }
    /// LaunchServices可能把再次打开交给旧进程；显式启动新实例，由其接替当前进程。
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !relaunchRequested else { return false }
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
    /// 菜单栏始终保留，即使快捷键或权限不可用。
    private func makeMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "LocalClip")
        updateMenu()
    }
    /// 状态在打开菜单前同步，所有操作指向真实服务。
    private func updateMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "LocalClip · \(model?.capture.state ?? "准备中")", action: nil, keyEquivalent: "")
        let show = menu.addItem(withTitle: "打开历史", action: #selector(showHistory), keyEquivalent: ""); show.target = self
        let pause = menu.addItem(withTitle: model?.settings.captureEnabled == false ? "恢复采集" : "暂停采集", action: #selector(toggleCapture), keyEquivalent: ""); pause.target = self
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "退出 LocalClip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self; status?.menu = menu
    }
    /// 同一快捷键按实际可见状态切换；关闭不刷新历史或重记粘贴目标。
    private func toggleHistory() {
        if panel?.isVisible == true { dismissHistory() }
        else { showHistory() }
    }
    /// 记住外部目标后展示面板，铺满当前显示器底边，禁止拖动和缩放。
    @objc public func showHistory() {
        guard let model else { return }
        externalInteractionPending = false
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
        let panelHeight = min(max(280,model.settings.panelHeight), min(520,rect.height))
        model.configureHistoryViewport(width: rect.width, cardWidth: HistoryView.cardSide(height: panelHeight, filtered: model.sourceFilter != nil || model.dateFilterEnabled))
        model.panelVisibilityChanged(true)
        model.target = lastExternal
        model.revalidateVisibleContent()
        if model.items.isEmpty && !model.loading { model.refresh() }
        let initialFrame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(max(280,model.settings.panelHeight), min(520,rect.height)))
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
            self.panel = panel
        }
        if let panel {
            pinnedScreenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            model.actualPanelHeight = min(max(280,model.settings.panelHeight), min(520,rect.height))
            panel.sharingType = model.settings.excludeFromSharing ? .none : .readOnly
            pinPanel(to: screen)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
            panel.makeKeyAndOrderFront(nil)
            model.focusRequest = UUID()
        }
    }
    /// 使用物理显示器frame而不是visibleFrame，让侧边Dock也不会缩短面板宽度。
    private func pinPanel(to screen: NSScreen?) {
        guard let panel, let rect = screen?.frame else { return }
        // 紧凑布局380pt，只有尺寸确实变化才重排；隐藏阶段不触发显示更新。
        let frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(max(280,model?.actualPanelHeight ?? model?.settings.panelHeight ?? 340), min(520,rect.height)))
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
        model.actualPanelHeight = min(max(280,height),min(520,panel?.screen?.frame.height ?? 520))
        pinPanel(to: panel?.screen)
        if persist { model.updateSettings { $0.panelHeight = model.actualPanelHeight } }
    }
    /// 隐藏图标必须仍有已注册快捷键；共享设置使用系统公开窗口属性。
    private func applyAppearanceSettings() {
        guard let model else { return }
        let registered = hotkeys.register(model.settings.shortcut)
        status?.isVisible = model.settings.showMenuIcon || !registered
        if !registered { model.message = "快捷键冲突，菜单栏入口保留" }
        panel?.sharingType = model.settings.excludeFromSharing ? .none : .readOnly
        model.actualPanelHeight = model.settings.panelHeight; pinPanel(to: panel?.screen)
    }
    /// 隐藏历史和其详情，不激活旧目标，也不改变系统剪贴板。
    private func dismissHistory() {
        externalInteractionPending = false
        model?.panelVisibilityChanged(false)
        focusDismissal?.cancel(); model?.showingDetail = false; model?.showingCategoryEditor = false; model?.showingFilters = false
        panel?.orderOut(nil)
        #if DEBUG
        if let model { GUIAcceptanceProbe.event("panel-dismissed", model) }
        #endif
    }
    /// key窗口切换稳定后核对整个面板交互，菜单/详情临时接管焦点不能误关闭。
    private func scheduleFocusDismissal(externalInteraction: Bool = false) {
        externalInteractionPending = externalInteractionPending || externalInteraction
        focusDismissal?.cancel()
        guard let panel, panel.isVisible else { return }
        focusDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, !Task.isCancelled, panel.isVisible, (!panel.isKeyWindow || self.externalInteractionPending),
                  self.menuTrackingDepth == 0, self.model?.dragActive != true, self.model?.confirmingChange != true else { return }
            if !self.externalInteractionPending, let key = NSApp.keyWindow {
                var owner: NSWindow? = key
                while let window = owner {
                    if window === panel { return }
                    owner = window.parent
                }
                // SwiftUI详情可能没有公开parent关系；只在详情已打开且自己的弹窗仍为key时保留。
                if (self.model?.showingDetail == true || self.model?.showingCategoryEditor == true), key.isVisible,
                   key !== self.settingsWindow, key !== self.feedbackPanel { return }
            }
            // 本应用确认对话框期间允许用户完成或取消操作。
            if NSApp.modalWindow != nil { return }
            self.dismissHistory()
        }
    }
    /// 粘贴回退显示短暂非激活提示，不让关闭历史面板隐藏失败原因。
    private func showPasteFeedback(_ message: String) {
        feedbackTask?.cancel()
        if feedbackPanel == nil {
            let feedback = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 94), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            feedback.isOpaque = false; feedback.backgroundColor = .clear; feedback.hasShadow = true
            feedback.isReleasedWhenClosed = false; feedback.hidesOnDeactivate = false; feedback.ignoresMouseEvents = true
            feedback.level = .statusBar; feedback.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            feedbackPanel = feedback
        }
        let content = HStack(spacing: 12) {
            Image(systemName: "clipboard").font(.system(size: 24)).foregroundStyle(.secondary)
            Text(message).font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).frame(width: 480, height: 94)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.25)))
        feedbackPanel?.contentView = NSHostingView(rootView: content)
        if let screen = panel?.screen ?? NSScreen.main {
            let rect = screen.visibleFrame
            let y = panel?.isVisible == true ? (panel?.frame.maxY ?? rect.minY) + 12 : rect.minY + 16
            feedbackPanel?.setFrame(NSRect(x: rect.midX - 240, y: min(y, rect.maxY - 110), width: 480, height: 94), display: true)
        }
        // orderFront不激活应用，也不把反馈窗口设为key。
        feedbackPanel?.orderFrontRegardless()
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.feedbackPanel?.orderOut(nil)
        }
    }
    /// 设置不会改变已记住的面板目标。
    @objc public func showSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 730), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "LocalClip 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, login: login)); window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    /// 持久化后由 model 更新采集状态，恢复从新计数开始。
    @objc private func toggleCapture() { model?.updateSettings { $0.captureEnabled.toggle() } }
    /// 外部前台身份由系统公开事件更新，不用于复制来源归因。
    private func observeLifecycle() {
        // 非激活面板返回同一个外部应用时可能没有激活/失去key通知；鼠标点击明确结束交互。
        // 全局监视仅观察点击，不读取按键、不拦截外部事件，也不需要输入监控授权，by AI.Coding。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFocusDismissal(externalInteraction: true) }
        }
        // 非激活面板不能用NSApp.isActive判断失焦；观察自己的key窗口转移。
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFocusDismissal() }
            })
        }
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTrackingDepth += 1; self?.focusDismissal?.cancel() }
        })
        focusObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                self.scheduleFocusDismissal()
            }
        })
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == self.pinnedScreenID } ?? NSScreen.main
                self.pinPanel(to: screen)
            }
        }
        activatedObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let target = self.applications.target() {
                    // 外部应用切换使旧面板的目标失效；不能沿用旧textarea去抢焦点粘贴。
                    if let previous = self.model?.target,
                       previous.pid != target.pid || previous.bundleID != target.bundleID || previous.launchedAt != target.launchedAt {
                        self.model?.target = nil
                        self.applications.rememberFocus(for: nil)
                    }
                    self.lastExternal = target
                    self.scheduleFocusDismissal(externalInteraction: true)
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let model = self?.model else { return }; model.capture.rebaseline(); model.capture.updatePolicy(model.settings); await model.maintenance() }
        }
    }
    /// 仅面板本地按键；Esc优先关闭，其余组合输入交给输入法，不使用全局监听。
    private func installKeyboard() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, let model = self.model,
                  event.window === panel || event.window?.parent === panel || (event.window == nil && panel.isKeyWindow) else { return event }
            if event.keyCode == 53 {
                if model.showingCategoryEditor { model.showingCategoryEditor = false }
                else if model.showingFilters { model.showingFilters = false }
                else { self.dismissHistory() }
                return nil
            }
            if model.showingCategoryEditor || model.showingFilters { return event }
            let editor = panel.firstResponder as? NSTextView
            if editor?.hasMarkedText() == true { return event }
            let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
            let editing = editor?.isEditable == true
            if flags == [.command], event.keyCode == 3 {
                if editing { model.showingFilters = true } else { model.focusRequest = UUID() }; return nil
            }
            if event.keyCode == 48 { model.focusResults?(); return nil }
            if flags == [.shift], [UInt16(36),76].contains(event.keyCode) { model.perform(.plainText, action: .directPaste); return nil }
            let carbon = (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0) | (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
            if carbon == model.settings.boardModifiers {
                if event.keyCode == 123 || event.keyCode == 124 { model.switchBoard(event.keyCode == 123 ? -1 : 1); return nil }
                if event.keyCode == 45 { model.editCategory(); return nil }
            }
            if carbon == model.settings.quickModifiers, let number = [UInt16(18),19,20,21,23,22,26,28,25].firstIndex(of: event.keyCode), model.items.indices.contains(number) {
                model.select(model.items[number].id); model.perform(action: .directPaste); return nil
            }
            // 搜索文字未改变且最后动作是记录删除时，仍可撤销该记录。
            if flags == [.command], event.keyCode == 6, editing, model.canUndoFromSearch { model.undoDeletion(); return nil }
            if flags == [.command] && !editing {
                switch event.keyCode {
                case 0: model.selectAllResults(); return nil
                case 8: model.perform(action: .copy); return nil
                case 6: model.undoDeletion(); return nil
                case 5: model.jumpToHistory(); return nil
                case 31: model.openSelected(); return nil
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
                guard !event.isARepeat else { return nil }
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
        if let activatedObserver { NSWorkspace.shared.notificationCenter.removeObserver(activatedObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
extension AppDelegate: NSMenuDelegate {
    /// 打开菜单时反映真实状态，而不是创建时的开关值。
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.title = "LocalClip · \(model?.capture.state ?? "准备中")"
        if menu.items.count > 2 { menu.items[2].title = model?.settings.captureEnabled == false ? "恢复采集" : "暂停采集" }
    }
}
