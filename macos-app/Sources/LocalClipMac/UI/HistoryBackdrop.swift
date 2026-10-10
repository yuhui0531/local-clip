// 背后窗口磨砂仅调背景透明度，文字和卡片保持清晰；背景不随key状态闪变，by AI.Coding。
import AppKit
import SwiftUI

struct HistoryBackdrop: NSViewRepresentable {
    private final class BackdropView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BackdropView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        updateNSView(view, context: context)
        return view
    }
    /// 只减弱背景，不降低整个窗口alpha；尊重系统降低透明度选项。
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.78
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
