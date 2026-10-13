// 设置窗口的取消和失焦生命周期；子弹窗与录制保持原生事件优先级，by AI.Coding。
import AppKit

@MainActor final class SettingsWindow: NSWindow, NSWindowDelegate {
    private var dismissal: Task<Void, Never>?
    private var fitted = false

    /// 窗口贴合当前分组内容，保持标题栏位置不动；首次直接定尺寸，之后切换分组时动画过渡，by AI.Coding。
    func fitContent(height: CGFloat) {
        guard height > 0, abs(contentLayoutRect.height - height) > 0.5 || !fitted else { return }
        var target = frameRect(forContentRect: NSRect(x: 0, y: 0, width: contentLayoutRect.width, height: height))
        target.origin = NSPoint(x: frame.minX, y: frame.maxY - target.height)
        setFrame(target, display: true, animate: fitted && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        fitted = true
    }

    /// Esc沿响应链到达窗口时关闭设置；附属确认框优先消费取消命令。
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, NSApp.modalWindow == nil,
              (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        dismissal?.cancel(); close()
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

    /// 等待焦点转移稳定，避免应用选择器或附属确认框暂时接管key时误关闭。
    func windowDidResignKey(_ notification: Notification) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.isKeyWindow, self.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            self.close()
        }
    }

    /// 返回设置窗口时撤销过期关闭任务。
    func windowDidBecomeKey(_ notification: Notification) { dismissal?.cancel() }

    /// 关闭窗口后释放未完成的失焦任务。
    func windowWillClose(_ notification: Notification) { dismissal?.cancel() }
}
