// 辅助功能授权向导：打开系统设置并贴靠其窗口，提供可拖入列表的应用图标，授权后自动收起，by AI.Coding。
import AppKit
import SwiftUI
@preconcurrency import ApplicationServices

enum AccessibilityGuideStep { case intro, drag, done }

/// 向导步骤与贴靠方向只由向导窗口订阅，by AI.Coding。
@MainActor final class AccessibilityGuideState: ObservableObject {
    @Published var step: AccessibilityGuideStep = .intro
    /// 拖入后仍未生效时提示旧签名条目，避免用户以为开关已开就完成。
    @Published var waitedLong = false
    /// 向导位于系统设置左侧时箭头指向右侧。
    @Published var dockedOnLeft = false
}

/// 系统不允许应用自行授权；向导只缩短用户亲手授权的路径，by AI.Coding。
@MainActor public final class AccessibilityGuide: NSObject, NSWindowDelegate {
    public static let shared = AccessibilityGuide()
    private static let shownKey = "accessibilityGuideShown"
    private let state = AccessibilityGuideState()
    private var panel: NSPanel?
    private var watcher: Task<Void, Never>?
    private var lastAnchor: NSRect?

    /// 首次启动且尚未授权时弹出一次；之后只从粘贴或设置入口打开。
    /// 向导已在屏幕上时，其他“请授权”提示不再重复弹出。
    public var isVisible: Bool { panel?.isVisible == true }

    public func showOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        show(skipIntro: false)
    }

    /// 已授权时不打扰；设置入口跳过说明直接进入拖入步骤。
    public func show(skipIntro: Bool) {
        guard !AXIsProcessTrusted() else { return }
        let panel = self.panel ?? makePanel()
        state.waitedLong = false; state.step = .intro; lastAnchor = nil
        if skipIntro { openSettings() } else { panel.center() }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }

    /// 打开辅助功能页面并开始等待用户授权。
    func openSettings() {
        state.step = .drag
        MacApplicationClient.openAccessibilitySettings()
        watcher?.cancel()
        let began = ContinuousClock.now
        // 系统没有可靠的授权回调；只在向导打开期间轮询，关闭即停止。
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                if AXIsProcessTrusted() { self.finish(); return }
                self.dock()
                if ContinuousClock.now - began > .seconds(20) { self.state.waitedLong = true }
            }
        }
    }

    func close() { watcher?.cancel(); watcher = nil; panel?.orderOut(nil) }

    public func windowWillClose(_ notification: Notification) { watcher?.cancel(); watcher = nil }

    private func finish() {
        watcher = nil; state.step = .done
        NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, self.state.step == .done else { return }
            self.close()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden; panel.title = "LocalClip 辅助功能授权"
        // 背景拖动会抢走图标拖拽；窗口只能用顶部区域移动，by AI.Coding。
        panel.isMovableByWindowBackground = false; panel.isReleasedWhenClosed = false
        // 系统设置成为前台后向导仍需留在其上方，供用户拖动图标。
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingView(rootView: AccessibilityGuideView(state: state, openSettings: { [weak self] in self?.openSettings() }, close: { [weak self] in self?.close() }))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// 贴在系统设置窗口一侧并与其顶部对齐；读取窗口边界不需要录屏权限。
    private func dock() {
        guard let panel, let anchor = Self.settingsWindowFrame(), anchor != lastAnchor else { return }
        lastAnchor = anchor
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size, gap: CGFloat = 16
        let right = anchor.maxX + gap + size.width <= visible.maxX
        state.dockedOnLeft = !right
        var x = right ? anchor.maxX + gap : anchor.minX - gap - size.width
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let y = min(max(anchor.maxY - size.height - 52, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(.init(x: x, y: y))
    }

    private static func settingsWindowFrame() -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        for info in windows {
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.systempreferences",
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200 else { continue }
            // CoreGraphics以主屏左上为原点，转换为AppKit左下原点。
            return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

struct AccessibilityGuideView: View {
    @ObservedObject var state: AccessibilityGuideState
    let openSettings: () -> Void
    let close: () -> Void
    var body: some View {
        Group {
            switch state.step {
            case .intro: intro
            case .drag: drag
            case .done: done
            }
        }.padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 22)
            .animation(.easeOut(duration: 0.2), value: state.step)
            .animation(.easeOut(duration: 0.2), value: state.waitedLong)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("允许 LocalClip 直接粘贴").font(.title3.weight(.semibold))
            Text("开启“辅助功能”权限后，选中内容可直接粘贴到当前应用。\n不开启也能用：复制后按 ⌘V 手动粘贴。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("稍后", action: close).keyboardShortcut(.cancelAction).controlSize(.large)
                Button("打开系统设置", action: openSettings).keyboardShortcut(.defaultAction).controlSize(.large)
            }.padding(.top, 6)
        }.frame(width: 360)
    }

    private var drag: some View {
        VStack(spacing: 14) {
            Text("把图标拖到“辅助功能”列表").font(.headline)
            HStack(spacing: 14) {
                if !state.dockedOnLeft { DragArrow(pointsRight: false) }
                // 拖出的就是应用本身的路径，与从Finder拖入应用等效。
                VStack(spacing: 6) {
                    AppIconDragSource().frame(width: 64, height: 64)
                    Text("LocalClip").font(.caption.weight(.medium))
                }.padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .contentShape(Rectangle())
                    .help("拖到系统设置的辅助功能列表中")
                if state.dockedOnLeft { DragArrow(pointsRight: true) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("拖入后打开 LocalClip 的开关，可能需要输入密码或使用触控 ID", systemImage: "1.circle")
                Label("开启后此窗口会自动关闭", systemImage: "2.circle")
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.waitedLong {
                Text("列表里已有 LocalClip、开关也已打开，但仍未生效？更新后系统会把新版本视为另一个应用：选中旧的 LocalClip 点“−”删除，再把图标拖进去。")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            HStack {
                ProgressView().controlSize(.small)
                Text("等待授权…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新打开设置") { MacApplicationClient.openAccessibilitySettings() }.buttonStyle(.link).font(.caption)
                Button("关闭", action: close).controlSize(.small)
            }
        }.frame(width: 300)
    }

    private var done: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("辅助功能已开启").font(.title3.weight(.semibold))
            Text("现在可以直接粘贴到其他应用了。").font(.callout).foregroundStyle(.secondary)
        }.frame(width: 300).padding(.bottom, 8)
    }
}

/// 来回轻移的箭头提示拖动方向；系统减弱动态效果时保持静止。
private struct DragArrow: View {
    let pointsRight: Bool
    @State private var moved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: pointsRight ? "arrow.right" : "arrow.left").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.accentColor)
            .offset(x: moved ? (pointsRight ? 6 : -6) : 0)
            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { moved = true } }
            .accessibilityHidden(true)
    }
}

/// 原生拖拽源：不移动窗口，系统设置在前台时第一下即可拖动，拖出应用自身的文件URL，by AI.Coding。
private struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView, NSDraggingSource {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) { NSApp.applicationIconImage.draw(in: bounds) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        // 按下不交给父视图，避免窗口进入移动或激活流程。
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
