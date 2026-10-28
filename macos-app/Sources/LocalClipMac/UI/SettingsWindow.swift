// 设置窗口的取消和失焦生命周期；子弹窗与录制保持原生事件优先级，by AI.Coding。
import AppKit

@MainActor final class SettingsWindow: NSPanel, NSWindowDelegate {
    private var fitted = false
    var requestClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 红色关闭按钮与 Esc 共用宿主的保护、淡出和释放。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let requestClose else { return true }; requestClose(); return false
    }

    /// 窗口贴合当前分组内容，保持标题栏位置不动；首次直接定尺寸，之后切换分组时动画过渡，by AI.Coding。
    func fitContent(height: CGFloat) {
        guard height > 0 else { return }
        // 屏幕足够时完整显示表单；屏幕不足时限制高度并保留长表单滚动。
        let target = Self.fittedFrame(current: frame, requestedHeight: height,
                                      frameExtra: frame.height - contentLayoutRect.height,
                                      visible: (screen ?? NSScreen.main)?.visibleFrame)
        guard abs(frame.height - target.height) > 0.5 || !fitted else { return }
        setFrame(target, display: true, animate: fitted && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        fitted = true
    }

    /// 保持窗口顶边；空间不足时限制高度并将窗口留在当前屏幕，by AI.Coding。
    static func fittedFrame(current: NSRect, requestedHeight: CGFloat, frameExtra: CGFloat, visible: NSRect?) -> NSRect {
        let frameHeight = min(requestedHeight + frameExtra, visible?.height ?? .greatestFiniteMagnitude)
        var target = NSRect(x: current.minX, y: current.maxY - frameHeight, width: current.width, height: frameHeight)
        if let visible { target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height) }
        return target
    }

    /// Esc沿响应链到达窗口时关闭设置；附属确认框优先消费取消命令。
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, NSApp.modalWindow == nil,
              (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if let requestClose { requestClose() } else { close() }
    }

    /// 文本编辑器也可用Esc关闭；快捷键录制的本地监视器先消费Esc，附属窗口单独收事件。
    override func sendEvent(_ event: NSEvent) {
        // 输入法先取消组合文字，不能把一次Esc误当作关闭设置窗口。
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil, NSApp.modalWindow == nil,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            cancelOperation(nil); return
        }
        super.sendEvent(event)
    }

    // 设置保留页面和待应用草稿；仅显式关闭/Esc结束窗口，by AI.Coding。
}
