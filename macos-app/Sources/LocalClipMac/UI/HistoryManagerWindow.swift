// 独立历史管理窗口：可缩放、记住尺寸位置，关闭即释放查询与订阅，by AI.Coding。
import AppKit

@MainActor final class HistoryManagerWindow: NSWindow, NSWindowDelegate {
    static let autosaveName = "LocalClipHistoryManagerWindow"
    var onClose: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        delegate = self
        title = "历史管理"
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        contentViewController = content
        minSize = NSSize(width: 900, height: 560)
        // 内容控制器会按首选尺寸改窗口，之后再恢复记住的位置。
        if !setFrameUsingName(Self.autosaveName) { setContentSize(NSSize(width: 1120, height: 700)); center() }
        setFrameAutosaveName(Self.autosaveName)
    }

    /// 附页（编辑、确认）与窗口同样排除共享；设置变化时同步已打开的附页，by AI.Coding。
    override var sharingType: NSWindow.SharingType {
        didSet { attachedSheet?.sharingType = sharingType }
    }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        sheetWindow.sharingType = sharingType
        super.beginSheet(sheetWindow, completionHandler: handler)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
