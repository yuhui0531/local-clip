// 原生辅助功能悬浮引导：拖出当前应用、监听真实授权、成功后自动收起，by AI.Coding。
import AppKit
import SwiftUI
@preconcurrency import ApplicationServices

enum AccessibilityGuideStep { case intro, drag, done }

/// 不读取窗口标题或内容，只用窗口身份、几何和可见性关联授权会话，by AI.Coding。
struct AccessibilitySettingsWindow {
    var id: CGWindowID
    var frame: NSRect
    var isOnScreen: Bool
    var isFrontmost: Bool
}

/// 引导状态只由悬浮窗口订阅，by AI.Coding。
@MainActor final class AccessibilityGuideState: ObservableObject {
    @Published var step: AccessibilityGuideStep = .intro
    @Published var waitedLong = false
    @Published var panelWidth: CGFloat = 360
}

/// 系统不允许应用自行授权；仅在引导会话存续期间检查当前进程的实际权限，by AI.Coding。
@MainActor public final class AccessibilityGuide: NSObject, NSWindowDelegate {
    public static let shared = AccessibilityGuide()
    private static let shownKey = "accessibilityGuideShown"
    let state = AccessibilityGuideState()
    private(set) var panel: NSPanel?
    private var watcher: Task<Void, Never>?
    private(set) var isGuiding = false
    private var settingsWindowID: CGWindowID?
    private var openingDeadline: ContinuousClock.Instant?
    private let settingsWindow: (CGWindowID?) -> AccessibilitySettingsWindow?
    private let openingTimeout: Duration
    private var lastAnchor: NSRect?
    private var lastVisibleFrame: NSRect?
    private let isTrusted: () -> Bool
    private let openSystemSettings: () -> Void

    /// 默认使用真实系统API；测试注入权限读数，不修改系统授权或打开设置。
    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         openSystemSettings: @escaping () -> Void = { MacApplicationClient.openAccessibilitySettings() },
         settingsWindow: @escaping (CGWindowID?) -> AccessibilitySettingsWindow? = { AccessibilityGuide.settingsWindowSnapshot(id: $0) },
         openingTimeout: Duration = .seconds(8)) {
        self.isTrusted = isTrusted
        self.openSystemSettings = openSystemSettings
        self.settingsWindow = settingsWindow
        self.openingTimeout = openingTimeout
        super.init()
    }

    public var isVisible: Bool { panel?.isVisible == true }

    /// 首次启动提示一次；用户仍可从粘贴或设置入口重新打开。
    public func showOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        show(skipIntro: false)
    }

    /// 设置入口直接展示拖拽提示；不激活LocalClip，保留系统设置的操作焦点。
    public func show(skipIntro: Bool) {
        guard !isTrusted() else { close(); return }
        watcher?.cancel()
        let panel = self.panel ?? makePanel()
        isGuiding = true
        state.waitedLong = false
        state.panelWidth = AccessibilityGuideView.panelWidth
        state.step = skipIntro ? .drag : .intro
        lastAnchor = nil; lastVisibleFrame = nil
        resizePanel()
        panel.center()
        if skipIntro { openSettings() }
        else { panel.orderFrontRegardless(); watchPermission() }
    }

    /// 打开辅助功能页面；重新打开时沿用同一窗口并重新计时。
    func openSettings() {
        state.step = .drag; state.waitedLong = false
        settingsWindowID = nil
        openingDeadline = .now + openingTimeout
        lastAnchor = nil; lastVisibleFrame = nil
        resizePanel()
        panel?.orderOut(nil)
        openSystemSettings()
        synchronizeSettingsWindow()
        watchPermission()
    }

    /// 轮询与成功停留共用可取消任务，关闭或重开不会留下延迟关闭旧窗口的任务。
    private func watchPermission() {
        watcher?.cancel()
        let began = ContinuousClock.now
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard let self, !Task.isCancelled, self.isGuiding else { return }
                if self.state.step == .drag {
                    self.synchronizeSettingsWindow()
                    guard self.isGuiding else { return }
                }
                if self.isTrusted() {
                    self.state.step = .done
                    // 最小化、隐藏或切到其他应用时直接结束，不重新弹出成功提示。
                    guard self.isVisible else { self.close(); return }
                    self.resizePanel()
                    // 成功反馈不夺取焦点；给用户短暂确认后自动收起。
                    do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self.close()
                    return
                }
                if self.state.step == .drag {
                    if !self.state.waitedLong, ContinuousClock.now - began > .seconds(20) {
                        self.state.waitedLong = true
                        self.resizePanel()
                    }
                }
            }
        }
    }

    /// 手动关闭和自动关闭均停止后台检查。
    func close() {
        isGuiding = false
        watcher?.cancel(); watcher = nil
        settingsWindowID = nil; openingDeadline = nil
        panel?.orderOut(nil)
    }

    /// 原生窗口关闭同样取消轮询与成功停留。
    public func windowWillClose(_ notification: Notification) { close() }

    /// 无标题栏的非激活面板复用现有系统磨砂材质，关闭按钮和拖动区由内容提供。
    private func makePanel() -> NSPanel {
        let panel = AccessibilityGuidePanel(contentRect: .init(x: 0, y: 0, width: AccessibilityGuideView.panelWidth, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "LocalClip 辅助功能授权"
        panel.isMovableByWindowBackground = false; panel.isReleasedWhenClosed = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: AccessibilityGuideView(state: state, openSettings: { [weak self] in self?.openSettings() }, close: { [weak self] in self?.close() }, fitContent: { [weak self] height in self?.fitContent(height: height) }))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// 按SwiftUI的自然高度测量，不为说明、帮助或成功状态预留空白。
    private func resizePanel() {
        guard let host = panel?.contentView else { return }
        host.layoutSubtreeIfNeeded()
        fitContent(height: host.fittingSize.height)
    }

    /// 几何回调在文案换行或状态变化后再次贴合；保持底边稳定并避免布局反馈循环。
    private func fitContent(height: CGFloat) {
        guard let panel, height.isFinite, height > 0 else { return }
        let size = NSSize(width: state.panelWidth, height: ceil(height))
        guard panel.frame.size != size else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visible { panel.setFrame(Self.frame(anchor: nil, visible: visible, size: size, origin: panel.frame.origin), display: true) }
        else { panel.setContentSize(size) }
    }

    /// 只伴随此次打开的系统设置窗口：最小化/切走隐藏，恢复显示，关闭则结束会话。
    private func synchronizeSettingsWindow() {
        guard let panel else { return }
        guard let snapshot = settingsWindow(settingsWindowID) else {
            panel.orderOut(nil)
            // 启动窗口可能尚未创建；已跟踪的窗口消失后不自动绑定下一次打开的设置。
            if settingsWindowID != nil || ContinuousClock.now >= (openingDeadline ?? .now) { close() }
            return
        }
        settingsWindowID = snapshot.id
        guard snapshot.isOnScreen, snapshot.isFrontmost else { panel.orderOut(nil); return }
        dock(to: snapshot.frame, force: !panel.isVisible)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 悬浮提示放在系统设置右下方，避开侧栏；移动和恢复时贴靠，普通轮询不覆盖手动位置。
    private func dock(to anchor: NSRect, force: Bool) {
        guard let panel else { return }
        let screen = NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(anchor), b = rhs.frame.intersection(anchor)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        guard let visible = screen?.visibleFrame,
              force || anchor != lastAnchor || visible != lastVisibleFrame else { return }
        // 参考图横条约占设置窗口64%的宽度；随窗口缩放，但限制极宽显示器上的长度。
        let width = Self.guideWidth(anchor: anchor, visible: visible)
        if state.panelWidth != width { state.panelWidth = width; resizePanel() }
        lastAnchor = anchor; lastVisibleFrame = visible
        panel.setFrame(Self.frame(anchor: anchor, visible: visible, size: panel.frame.size), display: true)
    }

    /// 按参考图的内容区比例估算宽度，不读取授权前不可访问的系统设置控件树。
    static func guideWidth(anchor: NSRect, visible: NSRect) -> CGFloat {
        min(max(360, (anchor.width * 0.64).rounded()), max(1, min(600, min(anchor.width, visible.width) - 24)))
    }

    /// 纯几何布局便于覆盖负坐标副屏、窄屏及窗口部分离屏的情况。
    static func frame(anchor: NSRect?, visible: NSRect, size: NSSize, origin: NSPoint? = nil) -> NSRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        let x = anchor.map { $0.maxX - width - 12 } ?? origin?.x ?? (visible.midX - width / 2)
        let y = anchor.map { $0.minY + 16 } ?? origin?.y ?? (visible.minY + 24)
        return .init(x: min(max(x, visible.minX), visible.maxX - width),
                     y: min(max(y, visible.minY), visible.maxY - height), width: width, height: height)
    }

    /// 包含离屏窗口才能区分最小化与关闭；不访问标题、像素或AX授权前不可读的属性。
    private static func settingsWindowSnapshot(id: CGWindowID?) -> AccessibilitySettingsWindow? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        for info in windows {
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  id == nil || windowID == id,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200, rect.height > 200 else { continue }
            // CoreGraphics以主屏左上为原点，转换为AppKit左下原点。
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return .init(id: windowID, frame: NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height),
                         isOnScreen: !app.isHidden && (info[kCGWindowIsOnscreen as String] as? Bool == true),
                         isFrontmost: foreground == app.processIdentifier)
        }
        return nil
    }
}

/// 允许键盘操作和Escape关闭，但不成为主窗口，by AI.Coding。
private final class AccessibilityGuidePanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Escape只收起引导，不影响系统设置。
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// 紧凑的原生磨砂卡片；系统语义颜色适配明暗主题和降低透明度，by AI.Coding。
struct AccessibilityGuideView: View {
    static let panelWidth: CGFloat = 360
    @ObservedObject var state: AccessibilityGuideState
    let openSettings: () -> Void
    let close: () -> Void
    var fitContent: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                header.frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(GuideWindowDragArea().accessibilityHidden(true))
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction).help("关闭引导").accessibilityLabel("关闭授权引导")
            }
            switch state.step {
            case .intro: intro
            case .drag: drag
            case .done: EmptyView()
            }
        }
        .padding(12)
        .frame(width: state.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitContent($0) }
        .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { HistoryBackdrop() } }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    /// 说明页采用图标与文字并排，不再保留居中的大图标展示区。
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if state.step == .intro {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: state.step == .done ? "checkmark.circle.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(state.step == .done ? Color.green : Color.accentColor).frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.step == .drag ? "拖入 LocalClip 并打开开关" : state.step == .done ? "辅助功能已开启" : "允许 LocalClip 直接粘贴")
                    .font(.headline)
                Text(state.step == .drag ? "已在列表中，直接打开开关即可。" : state.step == .done ? "现在可以直接粘贴到其他应用。" : "开启辅助功能，可直接粘贴到其他应用。\n暂不开启，也可复制后按 ⌘V 粘贴。")
                    .font(state.step == .intro ? .callout : .caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 使用常规尺寸的原生按钮，按macOS对话框习惯在右侧排列。
    private var intro: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("稍后", action: close)
            Button("打开系统设置", action: openSettings).keyboardShortcut(.defaultAction)
        }.controlSize(.regular)
    }

    /// 保留整行拖拽面积，压缩图标和内边距，不重复展示“拖入列表”文字。
    private var drag: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("LocalClip").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("授权后自动关闭").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                // 整行仍为真实应用文件的拖拽源，不牺牲鼠标可操作区域。
                .overlay(AppIconDragSource())
                .help("将 LocalClip 拖入系统设置的辅助功能列表，再打开开关")
            if state.waitedLong {
                Text("开关已打开但仍未生效？可移除列表中的旧 LocalClip，再拖入当前应用并开启。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 只允许标题说明区域移动面板，不与应用文件拖拽争抢手势，by AI.Coding。
private struct GuideWindowDragArea: NSViewRepresentable {
    /// 使用原生窗口拖动，让系统处理多显示器和鼠标移动。
    func makeNSView(context: Context) -> DragArea { DragArea() }
    /// 拖动区域无额外状态。
    func updateNSView(_ view: DragArea, context: Context) {}
    final class DragArea: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// 不激活应用即可拖动悬浮提示。
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// 系统设置在前台时第一下即可拖动整行，载荷保持当前应用本身的文件URL，by AI.Coding。
struct AppIconDragSource: NSViewRepresentable {
    /// 生产环境只使用当前运行应用包，不从固定安装路径推断授权对象。
    func makeNSView(context: Context) -> DragView { DragView(appURL: Bundle.main.bundleURL) }
    /// 文件路径在当前进程生命周期内不变。
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView, NSDraggingSource {
        private let appURL: URL
        /// 提供明确的无障碍说明，拖动图标不会被误识别为移动窗口。
        init(appURL: URL) {
            self.appURL = appURL
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("LocalClip 应用，拖到辅助功能列表")
        }
        required init?(coder: NSCoder) { nil }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// 开手光标提示整行可拖动。
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        /// 按下不交给父视图，避免窗口进入移动流程。
        override func mouseDown(with event: NSEvent) {}
        /// URL写入器与Finder拖出应用的格式一致，预览只显示应用图标。
        func draggingItem() -> NSDraggingItem {
            let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
            item.setDraggingFrame(.init(x: 10, y: max(0, (bounds.height - 28) / 2), width: 28, height: 28), contents: NSApp.applicationIconImage)
            return item
        }
        /// 在系统设置接收应用后仍继续等待实际权限，不能以拖放完成判定成功。
        override func mouseDragged(with event: NSEvent) {
            beginDraggingSession(with: [draggingItem()], event: event, source: self)
        }
        /// 只提供非移动操作，避免源应用文件被移动。
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
