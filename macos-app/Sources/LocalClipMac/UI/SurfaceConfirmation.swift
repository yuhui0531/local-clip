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

    /// 紧凑横排按钮使确认内容能放入最低高度的卡片区域，不撑开父窗。
    init(title: String, closing: Bool) {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isMovable = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.animationBehavior = .none; panel.title = "未保存的修改"
        super.init(window: panel)
        panel.delegate = self; panel.cancel = { [weak self] in self?.finish(.cancel) }
        let host = NSHostingView(rootView: Content(title: title, closing: closing) { [weak self] in self?.finish($0) })
        panel.contentView = host; panel.setContentSize(host.fittingSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// 只计算子窗坐标；即便贴住屏幕底边也不改动父窗frame。
    static func frame(size: NSSize, owner: NSRect, screen: NSRect) -> NSRect {
        let x = min(max(owner.midX - size.width / 2, screen.minX + 12), screen.maxX - size.width - 12)
        let y = min(max(owner.midY - size.height / 2, screen.minY + 12), screen.maxY - size.height - 12)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// 子窗关系保留层级与归属；不调用beginSheet，系统没有移动父面板的机会。
    func present(for owner: NSWindow, visible: Bool = true) async -> SurfaceEdits.Choice {
        guard let window else { return .cancel }
        parentWindow = owner
        // 内容编辑气泡也属于父面板；确认期间一并冻结，避免从背后的编辑器提交草稿。
        func descendants(_ window: NSWindow) -> [NSWindow] {
            [window] + (window.childWindows ?? []).flatMap { descendants($0) }
        }
        blockedWindows = descendants(owner).map { ($0, $0.ignoresMouseEvents) }
        previousKeyWindow = blockedWindows.first(where: { $0.0.isKeyWindow })?.0 ?? owner
        previousResponder = previousKeyWindow?.firstResponder
        blockedWindows.forEach { $0.0.ignoresMouseEvents = true }
        window.sharingType = owner.sharingType; window.appearance = owner.effectiveAppearance
        window.level = owner.level
        window.setFrame(Self.frame(size: window.frame.size, owner: owner.frame, screen: owner.screen?.frame ?? owner.frame), display: false)
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
