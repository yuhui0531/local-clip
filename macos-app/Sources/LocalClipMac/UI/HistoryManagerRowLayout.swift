// 管理表格的统一行高：离屏行重建不再改变滚动范围，保留原生滚动和辅助功能，by AI.Coding。
import AppKit
import SwiftUI

enum HistoryManagerRowLayout {
    static let previewWidth: CGFloat = 72
    static let contentHeight: CGFloat = 48
    // 原生表格上下各留 4pt，与原有实际行高一致。
    static let rowHeight: CGFloat = contentHeight + 8
}

/// 放在名称单元格内部，只配置祖先表格，不遍历或影响侧栏和其他窗口，by AI.Coding。
struct HistoryManagerFixedRowHeight: NSViewRepresentable {
    /// 标记没有交互和固有尺寸，不参与名称列测量。
    func makeNSView(context: Context) -> Marker { Marker() }

    /// 翻页或单元格重用时重新核对配置；值相同不触发布局。
    func updateNSView(_ view: Marker, context: Context) { view.apply() }

    @MainActor final class Marker: NSView {
        /// 背景标记不截获选择、勾选或拖动。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// SwiftUI 初次创建时尚无祖先表格，挂接后立即应用。
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
        /// 单元格随窗口重新挂接时也核对所在表格。
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

        /// 内容本已固定高度；关闭表格的动态估算，避免离屏行创建反复改写总高度。
        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
                    if table.rowHeight != HistoryManagerRowLayout.rowHeight { table.rowHeight = HistoryManagerRowLayout.rowHeight }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
