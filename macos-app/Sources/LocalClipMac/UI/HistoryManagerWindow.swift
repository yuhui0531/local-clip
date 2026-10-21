// 独立历史管理窗口：可缩放、记住尺寸位置，关闭即释放查询与订阅，by AI.Coding。
import AppKit

@MainActor final class HistoryManagerWindow: NSWindow, NSWindowDelegate {
    static let autosaveName = "LocalClipHistoryManagerWindow"
    /// 首次打开的尺寸，与原型一致；已记住位置尺寸的用户不受影响。
    static let defaultSize = NSSize(width: 1180, height: 820)
    var onClose: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        delegate = self
        title = "历史管理"
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        // 先给内容默认尺寸再挂上：否则窗口先缩到内容的初始尺寸，检查器按窄窗口落在最小宽度，放大后不再回到理想宽度，by AI.Coding。
        content.view.setFrameSize(Self.defaultSize)
        contentViewController = content
        minSize = NSSize(width: 900, height: 560)
        // 内容控制器会按首选尺寸改窗口，之后再恢复记住的位置。
        if !setFrameUsingName(Self.autosaveName) { setContentSize(Self.defaultSize); center() }
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

    /// 与视图里 inspectorColumnWidth 的 ideal 一致。
    static let inspectorIdealWidth: CGFloat = 400
    /// SwiftUI（macOS 15）的检查器首次出现总落在最小宽度，忽略 ideal；分栏就绪后把分隔条放到理想宽度一次。
    /// 之后的拖动与最小、最大宽度照旧由 SwiftUI 约束，也不持久化宽度，by AI.Coding。
    /// 分栏建好后 SwiftUI 还会在随后几轮布局里把检查器定到最小宽度，所以放好后复核，被改回则再放，次数有限。
    func applyInspectorIdealWidth(retries: Int = 20) {
        contentView?.layoutSubtreeIfNeeded()
        if let split = Self.inspectorSplit(in: contentView), let inspector = split.arrangedSubviews.last, inspector.frame.width > 0 {
            if inspector.frame.width >= Self.inspectorIdealWidth { return }
            split.setPosition(split.bounds.width - Self.inspectorIdealWidth - split.dividerThickness, ofDividerAt: split.arrangedSubviews.count - 2)
        }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.applyInspectorIdealWidth(retries: retries - 1) }
    }
    /// 外层是侧栏分栏，检查器分栏嵌在它的详情一侧。
    static func inspectorSplit(in root: NSView?) -> NSSplitView? {
        func first(_ view: NSView) -> NSSplitView? {
            var queue = [view]
            while !queue.isEmpty { let next = queue.removeFirst(); if let split = next as? NSSplitView { return split }; queue += next.subviews }
            return nil
        }
        guard let root, let outer = first(root), outer.arrangedSubviews.count == 2, let detail = outer.arrangedSubviews.last else { return nil }
        return first(detail).flatMap { $0.arrangedSubviews.count == 2 ? $0 : nil }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
