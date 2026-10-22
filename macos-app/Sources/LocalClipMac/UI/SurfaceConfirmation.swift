// 底栏编辑保护使用独立子窗，避免系统Sheet为容纳内容而抬起父面板，by AI.Coding。
import AppKit
import SwiftUI

@MainActor final class SurfaceConfirmation: NSWindowController, NSWindowDelegate {
    /// 非激活子窗仅取得键盘焦点，不切换应用菜单或出现Dock图标。
    final class Panel: NSPanel {
        var cancel: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { cancel() }
        override func performClose(_ sender: Any?) { cancel() }
    }
    private var answer: CheckedContinuation<SurfaceEdits.Choice, Never>?
    private var finishing = false
    private weak var parentWindow: NSWindow?
    private weak var previousKeyWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var ownerClose: NSObjectProtocol?
    private var blockedWindows: [(NSWindow, Bool)] = []
    private let animator = SurfaceAnimator()

    private var bodySize: NSSize = .zero

    /// 紧凑横排按钮使确认内容能放入最低高度的卡片区域，不撑开父窗。
    convenience init(title: String, closing: Bool) {
        self.init(title: "未保存的修改") { answer in AnyView(Content(title: title, closing: closing, answer: answer)) }
    }
    /// 面板发起的历史变更确认沿用同一子窗，取消与确认分别映射为cancel/save，by AI.Coding。
    convenience init(change copy: ChangeConfirmationCopy) {
        self.init(title: copy.title) { answer in
            AnyView(ChangeConfirmation.Content(copy: copy) { answer($0 ? .save : .cancel) }
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
                .accessibilityAddTraits(.isModal))
        }
    }
    private init(title: String, content: (@escaping (SurfaceEdits.Choice) -> Void) -> AnyView) {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isMovable = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.animationBehavior = .none; panel.title = title
        super.init(window: panel)
        panel.delegate = self; panel.cancel = { [weak self] in self?.finish(.cancel) }
        let host = NSHostingView(rootView: Bubble(content: content { [weak self] in self?.finish($0) }))
        bodySize = host.fittingSize
        panel.contentView = host; panel.setContentSize(bodySize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// 只计算子窗坐标；即便贴住屏幕底边也不改动父窗frame。
    static func frame(size: NSSize, owner: NSRect, screen: NSRect) -> NSRect {
        let x = min(max(owner.midX - size.width / 2, screen.minX + 12), screen.maxX - size.width - 12)
        let y = min(max(owner.midY - size.height / 2, screen.minY + 12), screen.maxY - size.height - 12)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
    /// 气泡优先在触发元素上方，放不下翻到下方；箭头指向锚点中线并避开圆角，by AI.Coding。
    static func frame(size: NSSize, anchor: NSRect, screen: NSRect) -> (frame: NSRect, arrowX: CGFloat, arrowUp: Bool) {
        let height = size.height + Bubble.arrowHeight
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 12), screen.maxX - size.width - 12)
        let above = anchor.maxY + 4 + height <= screen.maxY - 12
        let y = above ? anchor.maxY + 4 : max(screen.minY + 12, anchor.minY - 4 - height)
        let arrowX = min(max(anchor.midX - x, 24), size.width - 24)
        return (NSRect(x: x, y: y, width: size.width, height: height), arrowX, !above)
    }
    /// 箭头指向目标上沿细条（卡片、编辑框本身都很高）；几乎覆盖整块父窗的视图指不出触发元素，返回nil回退居中，by AI.Coding。
    static func anchorEdge(_ rect: NSRect, owner: NSRect) -> NSRect? {
        rect.height >= owner.height * 0.9 ? nil : NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)
    }
    /// 锚点只取视图在屏幕上的可见部分；已滚出或隐藏时返回nil，回退为居中。
    static func screenRect(of view: NSView) -> NSRect? {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isEmpty else { return nil }
        return window.convertToScreen(view.convert(visible, to: nil))
    }

    /// 子窗关系保留层级与归属；不调用beginSheet，系统没有移动父面板的机会。
    /// 有锚点时贴近触发元素弹出并以箭头指向它；无锚点时居中于父窗。
    /// freezesOwner为false时父窗自行吸收点击（面板确认用透明层），避免点击穿透到下层应用或Dock，by AI.Coding。
    func present(for owner: NSWindow, anchor: NSView? = nil, freezesOwner: Bool = true, visible: Bool = true) async -> SurfaceEdits.Choice {
        guard let window else { return .cancel }
        parentWindow = owner
        // 内容编辑气泡也属于父面板；确认期间一并冻结，避免从背后的编辑器提交草稿。
        func descendants(_ window: NSWindow) -> [NSWindow] {
            [window] + (window.childWindows ?? []).flatMap { descendants($0) }
        }
        let family = descendants(owner)
        blockedWindows = family.filter { freezesOwner || $0 !== owner }.map { ($0, $0.ignoresMouseEvents) }
        previousKeyWindow = family.first(where: \.isKeyWindow) ?? owner
        previousResponder = previousKeyWindow?.firstResponder
        blockedWindows.forEach { $0.0.ignoresMouseEvents = true }
        window.sharingType = owner.sharingType; window.appearance = owner.effectiveAppearance
        window.level = owner.level
        // 底栏覆盖Dock，下沿取整屏；上沿避开菜单栏。
        let full = owner.screen?.frame ?? owner.frame
        let screen = NSRect(x: full.minX, y: full.minY, width: full.width, height: (owner.screen?.visibleFrame.maxY ?? full.maxY) - full.minY)
        // 锚点须属于父窗或其子窗，且不能是几乎整块面板的大视图，否则箭头指不出触发元素。
        let target = anchor.flatMap { view in family.contains { $0 === view.window } ? Self.screenRect(of: view) : nil }
        if let edge = target.flatMap({ Self.anchorEdge($0, owner: owner.frame) }), let host = window.contentView as? NSHostingView<Bubble> {
            let placed = Self.frame(size: bodySize, anchor: edge, screen: screen)
            host.rootView.arrow = (placed.arrowX, placed.arrowUp)
            window.setFrame(placed.frame, display: false)
        } else {
            window.setFrame(Self.frame(size: bodySize, owner: owner.frame, screen: screen), display: false)
        }
        ownerClose = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelImmediately() }
        }
        return await withCheckedContinuation { continuation in
            answer = continuation
            // 隐藏窗口测试不排序到屏幕；真实呈现只淡化确认窗，父窗保持原位。
            guard visible else { return }
            window.alphaValue = 0
            owner.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            // 父面板所属应用保持后台身份，确认窗也要显式排到同层最前。
            window.orderFrontRegardless()
            animator.animate([(window, 1)], reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {}
        }
    }

    /// 每次只接收一个答案；淡出结束后再恢复父窗的交互和原切换流程。
    func finish(_ choice: SurfaceEdits.Choice) {
        guard answer != nil, !finishing else { return }
        finishing = true
        guard let window, window.isVisible else { complete(choice); return }
        window.ignoresMouseEvents = true
        animator.animate([(window, 0)], reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self] in self?.complete(choice) }
    }

    /// 父窗关闭或应用结束时不等待动画，也不遗留悬挂的确认continuation。
    func cancelImmediately() { complete(.cancel, restoringFocus: false) }
    private func complete(_ choice: SurfaceEdits.Choice, restoringFocus: Bool = true) {
        guard let answer else { return }; self.answer = nil
        animator.cancel()
        if let ownerClose { NotificationCenter.default.removeObserver(ownerClose); self.ownerClose = nil }
        if let window {
            parentWindow?.removeChildWindow(window)
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        blockedWindows.forEach { $0.0.ignoresMouseEvents = $0.1 }; blockedWindows = []
        // 取消时回到原内容编辑气泡，而非一律将键盘焦点转给底部父面板。
        let focus = previousKeyWindow?.isVisible == true ? previousKeyWindow : parentWindow
        if restoringFocus, focus?.isVisible == true {
            focus?.makeKey()
            if focus === previousKeyWindow, let previousResponder { focus?.makeFirstResponder(previousResponder) }
        }
        answer.resume(returning: choice)
    }
    func windowWillClose(_ notification: Notification) { cancelImmediately() }

    /// 确认内容加可选箭头；箭头与卡片同底色，指向触发元素，by AI.Coding。
    struct Bubble: View {
        static let arrowHeight: CGFloat = 8
        let content: AnyView
        var arrow: (x: CGFloat, up: Bool)?
        var body: some View {
            VStack(spacing: 0) {
                if let arrow, arrow.up { tip(arrow) }
                content
                if let arrow, !arrow.up { tip(arrow) }
            }
        }
        private func tip(_ arrow: (x: CGFloat, up: Bool)) -> some View {
            Path { path in
                let base: CGFloat = arrow.up ? Self.arrowHeight : 0, point: CGFloat = arrow.up ? 0 : Self.arrowHeight
                path.move(to: .init(x: 0, y: base)); path.addLine(to: .init(x: 9, y: point)); path.addLine(to: .init(x: 18, y: base)); path.closeSubpath()
            }.fill(Color(nsColor: .windowBackgroundColor)).frame(width: 18, height: Self.arrowHeight)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, arrow.x - 9)
                .accessibilityHidden(true)
        }
    }

    /// 三个明确选项沿用原有保存语义，键盘默认动作与Esc仍由确认窗接管。
    private struct Content: View {
        let title: String
        let closing: Bool
        let answer: (SurfaceEdits.Choice) -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(title)尚未保存").font(.system(size: 16, weight: .semibold))
                Text("保存后继续，或放弃本次修改。").font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(closing ? "取消关闭" : "取消切换") { answer(.cancel) }.keyboardShortcut(.cancelAction)
                    Spacer(minLength: 12)
                    Button("放弃修改") { answer(.discard) }
                    Button(closing ? "保存并关闭" : "保存并继续") { answer(.save) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }.controlSize(.regular)
            }.padding(22).frame(width: 420).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
                .accessibilityAddTraits(.isModal)
                .onExitCommand { answer(.cancel) }
        }
    }
}
