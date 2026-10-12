// 设置窗口的取消和失焦生命周期；子弹窗与录制保持原生事件优先级，by AI.Coding。
import AppKit

@MainActor final class SettingsWindow: NSWindow, NSWindowDelegate {
    private var dismissal: Task<Void, Never>?

    /// Esc沿响应链到达窗口时关闭设置；附属确认框优先消费取消命令。
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil, NSApp.modalWindow == nil else { return }
        dismissal?.cancel(); close()
    }

    /// 文本编辑器也可用Esc关闭；快捷键录制的本地监视器先消费Esc，附属窗口单独收事件。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil, NSApp.modalWindow == nil {
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
