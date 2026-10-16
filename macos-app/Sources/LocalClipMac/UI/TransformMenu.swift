// 历史转换菜单：两列紧凑布局、固定标题与按住⌥仅复制，转换仍交给原有粘贴管线，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore

@MainActor final class TransformMenuController: NSObject, ObservableObject, NSWindowDelegate {
    let transforms = TextTransform.allCases
    let available: Set<TextTransform>
    let reason: String?
    let allowsCopyOnly: Bool
    @Published var highlighted: TextTransform?
    @Published var optionHeld = false
    private(set) var window: NSPanel?
    private weak var parent: NSWindow?
    private var localClicks: Any?
    private var outsideClicks: Any?
    private var closed = false
    private let handler: (TextTransform, Bool) -> Void
    var onDismiss: (() -> Void)?

    /// 可用性沿用内容判定；构造不创建窗口，便于无桌面副作用地验证选择与分派，by AI.Coding。
    init(available: Set<TextTransform>, reason: String?, allowsCopyOnly: Bool,
         handler: @escaping (TextTransform, Bool) -> Void) {
        self.available = available; self.reason = reason; self.allowsCopyOnly = allowsCopyOnly
        self.handler = handler
        super.init()
    }

    /// 逐行从左到右排布；保留固定顺序和全部禁用项，不因内容不同而跳位，by AI.Coding。
    var rows: [[TextTransform]] {
        stride(from: 0, to: transforms.count, by: 2).map { Array(transforms[$0..<min($0 + 2, transforms.count)]) }
    }

    /// 弹窗限制在所在屏幕内；短屏仅滚动选项，标题始终可见，by AI.Coding。
    static func frame(at point: NSPoint, visibleFrame: NSRect, rowCount: Int, hasReason: Bool) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(500, bounds.width), height: min(CGFloat(rowCount) * 32 + 64 + (hasReason ? 44 : 0), bounds.height))
        return NSRect(x: min(max(point.x, bounds.minX), bounds.maxX - size.width),
                      y: min(max(point.y - size.height, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    /// 非激活子面板保留原目标应用；父子关系让历史的既有失焦策略识别菜单归属，by AI.Coding。
    func present(parent: NSWindow, at point: NSPoint) {
        guard window == nil, !closed else { return }
        self.parent = parent
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? parent.screen ?? NSScreen.main
        let rect = Self.frame(at: point, visibleFrame: screen?.visibleFrame ?? parent.frame, rowCount: rows.count, hasReason: reason != nil)
        let panel = TransformMenuPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true; panel.animationBehavior = .none; panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = parent.effectiveAppearance; panel.sharingType = parent.sharingType
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onFlags = { [weak self] flags in self?.optionHeld = flags.contains(.option) }
        optionHeld = NSEvent.modifierFlags.contains(.option)
        let host = NSHostingView(rootView: TransformMenuContent(menu: self))
        host.sizingOptions = []; panel.contentView = host; window = panel
        parent.addChildWindow(panel, ordered: .above)
        // 监听只负责菜单关闭，不吞掉点击，不读取外部按键，by AI.Coding。
        localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.window { self.close() }
            return event
        }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 鼠标与键盘共用提交入口；按下时读取修饰键，避免先按⌥后移动或松开时状态滞后，by AI.Coding。
    func choose(_ transform: TextTransform, modifiers: NSEvent.ModifierFlags) {
        guard !closed, available.contains(transform) else { return }
        let copyOnly = allowsCopyOnly && modifiers.contains(.option)
        close(restoreFocus: true)
        handler(transform, copyOnly)
    }

    /// 方向键按两列移动并跳过同列禁用项；Tab按阅读顺序切换，Escape只关闭转换菜单，by AI.Coding。
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close(restoreFocus: true)
        case 36, 76, 49:
            if let selected = highlighted { choose(selected, modifiers: event.modifierFlags) }
        case 123, 124, 125, 126, 48:
            move(keyCode: event.keyCode, backwards: event.modifierFlags.contains(.shift))
        default: return false
        }
        return true
    }

    /// 水平移动不跨行，垂直移动不换列；首次方向键选中首个可用项，by AI.Coding。
    func move(keyCode: UInt16, backwards: Bool = false) {
        let enabled = transforms.indices.filter { available.contains(transforms[$0]) }
        guard let first = enabled.first else { return }
        guard let highlighted, let current = transforms.firstIndex(of: highlighted) else { self.highlighted = transforms[first]; return }
        if keyCode == 48 {
            guard let index = enabled.firstIndex(of: current) else { self.highlighted = transforms[first]; return }
            self.highlighted = transforms[enabled[(index + (backwards ? enabled.count - 1 : 1)) % enabled.count]]
            return
        }
        let step = keyCode == 123 ? -1 : keyCode == 124 ? 1 : keyCode == 126 ? -2 : 2
        var next = current + step
        while transforms.indices.contains(next) {
            if abs(step) == 1, next / 2 != current / 2 { return }
            if available.contains(transforms[next]) { self.highlighted = transforms[next]; return }
            next += step
        }
    }

    /// 所有关闭入口幂等释放监视器和托管视图；外部失焦不抢回历史焦点，by AI.Coding。
    func close(restoreFocus: Bool = false) {
        guard !closed else { return }; closed = true
        if let localClicks { NSEvent.removeMonitor(localClicks); self.localClicks = nil }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks); self.outsideClicks = nil }
        if let window {
            window.delegate = nil; parent?.removeChildWindow(window)
            window.orderOut(nil); window.contentView = nil; window.close(); self.window = nil
        }
        if restoreFocus, let parent, parent.isVisible { parent.makeKey() }
        onDismiss?(); onDismiss = nil
    }

    /// 外部窗口取得key时同步收起菜单，父面板继续执行原有失焦策略，by AI.Coding。
    func windowDidResignKey(_ notification: Notification) { close() }
}

/// 菜单独占自己的方向键和Escape，避免被历史面板解释成选记录或粘贴，by AI.Coding。
@MainActor private final class TransformMenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 修饰键更新标题提示，点击/回车提交仍以该次事件的真实标志为准，by AI.Coding。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged { onFlags?(event.modifierFlags) }
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// 标题固定、选项两列；SwiftUI按钮保留禁用态与辅助功能名称，by AI.Coding。
@MainActor private struct TransformMenuContent: View {
    @ObservedObject var menu: TransformMenuController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("转换后粘贴").font(.system(size: 14, weight: .semibold))
                Spacer()
                if menu.allowsCopyOnly {
                    Text("⌥ 仅复制").font(.system(size: 12))
                        .foregroundStyle(menu.optionHeld ? Color.accentColor : .secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            if let reason = menu.reason {
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 0) {
                        ForEach(menu.transforms, id: \.self) { transform in
                            Button { menu.choose(transform, modifiers: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags) } label: {
                                Text(transform.title).font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(!menu.available.contains(transform))
                            .foregroundStyle(menu.available.contains(transform) ? Color.primary : Color(nsColor: .disabledControlTextColor))
                            .background(menu.highlighted == transform ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .onHover { inside in
                                if inside, menu.available.contains(transform) { menu.highlighted = transform }
                                else if !inside, menu.highlighted == transform { menu.highlighted = nil }
                            }
                            .id(transform)
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
                .onChange(of: menu.highlighted) { _, selected in if let selected { proxy.scrollTo(selected) } }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
    }
}
