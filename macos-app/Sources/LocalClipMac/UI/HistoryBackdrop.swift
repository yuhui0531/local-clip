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
        view.material = .popover
        view.state = .active
        updateNSView(view, context: context)
        return view
    }
    /// 保持系统模糊完整强度；降低整块材质alpha会让背后正文直接透出。
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = 1
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
