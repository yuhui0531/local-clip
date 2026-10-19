// 历史卡片的本地滚轮适配，不监听其他应用，不依赖私有滚动视图，by AI.Coding。
import AppKit
import SwiftUI

/// 历史横向滚动条固定为细的悬浮样式：连接鼠标或系统设为“始终显示”时也不出现粗的常驻滚动条，
/// 仍可拖动，只在滚动时出现。放在滚动内容内部以取得所在的NSScrollView，by AI.Coding。
struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.apply() }
    @MainActor final class Probe: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            // 系统偏好变化时NSScrollView会重置样式，需要重新应用；selector观察者随视图释放自动移除。
            NotificationCenter.default.addObserver(self, selector: #selector(preferenceChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        @objc private func preferenceChanged() { DispatchQueue.main.async { [weak self] in self?.apply() } }
        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            scrollView.autohidesScrollers = true
            scrollView.horizontalScroller?.controlSize = .small
        }
    }
}

struct HistoryScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maximum: CGFloat = 0
    var viewport: CGFloat = 0
}

@MainActor struct HistoryScrollWheel: NSViewRepresentable {
    var state: State
    /// 面板呈现状态由模型提供；淡出期间窗口仍可见但不再消费滚轮，by AI.Coding。
    var presented: () -> Bool = { true }
    var onScroll: (CGFloat) -> Void

    /// 背景只用于限定事件区域，不接管卡片点击和双击。
    func makeNSView(context: Context) -> NSView {
        let view = WheelRegion()
        context.coordinator.attach(to: view)
        return view
    }

    /// 真实滚动几何同步边界；尚未渲染的连续滚轮增量不能丢失。
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll; context.coordinator.presented = presented
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    /// 背景覆盖实际滚动视口，避免无固有尺寸的NSView缩成零而收不到区域内事件。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    /// SwiftUI移除列表时立即卸载本地事件适配。
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor private final class WheelRegion: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// 几何只同步事件状态，不触发整排卡片每个滚动帧重新计算。
    @MainActor final class State {
        fileprivate var metrics = HistoryScrollMetrics()
        fileprivate var pendingOffset: CGFloat?
        /// 已完整可见的选中卡片不再次滚动，避免连续方向键制造重叠滚动动画。
        func needsReveal(index: Int, cardWidth: CGFloat) -> Bool {
            guard metrics.viewport > 0 else { return false }
            // 正方形卡片随视口高度变化；定位与实际渲染使用相同边长。
            let left = HistoryView.cardInset + CGFloat(index) * (cardWidth + HistoryView.cardSpacing)
            return left < metrics.offset || left + cardWidth > metrics.offset + metrics.viewport
        }

        /// 到达请求位置后回到实际偏移；内容变短时不能继续使用旧边界。
        func update(_ metrics: HistoryScrollMetrics) {
            if self.metrics.maximum != metrics.maximum { pendingOffset = nil }
            self.metrics = metrics
            if let pendingOffset {
                if abs(pendingOffset - metrics.offset) < 0.5 { self.pendingOffset = nil }
                else { self.pendingOffset = min(metrics.maximum, max(0, pendingOffset)) }
            }
        }
    }

    @MainActor final class Coordinator {
        private weak var region: NSView?
        private var monitor: Any?
        private let state: State
        var onScroll: ((CGFloat) -> Void)?
        var presented: () -> Bool = { true }

        init(state: State) { self.state = state }

        /// 只消费当前历史区域内的垂直滚轮；横向手势保留系统惯性/自然滚动。
        func attach(to view: NSView) {
            region = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, let region = self.region, let window = region.window,
                      window.isVisible, self.presented(), event.window === window, !region.isHiddenOrHasHiddenAncestor,
                      region.visibleRect.contains(region.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .leftMouseDown {
                    self.state.pendingOffset = nil
                    return event
                }
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let x = event.scrollingDeltaX, y = event.scrollingDeltaY
                if abs(x) >= abs(y) {
                    self.state.pendingOffset = nil
                    return event
                }
                guard y.isFinite, self.state.metrics.maximum > 0 else { return event }
                // 系统delta已包含自然滚动方向；普通离散滚轮按行放大，触控板按精确像素移动。
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 36
                let next = min(self.state.metrics.maximum, max(0, (self.state.pendingOffset ?? self.state.metrics.offset) - y * scale))
                self.state.pendingOffset = next
                // 离散滚轮短动画平滑跳格；触控板沿用逐像素即时跟随，by AI.Coding。
                if event.hasPreciseScrollingDeltas || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.onScroll?(next) }
                else { withAnimation(.smooth(duration: 0.15)) { self.onScroll?(next) } }
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; region = nil; onScroll = nil
        }
    }
}
