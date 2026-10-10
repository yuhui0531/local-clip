// 原生搜索输入保留中文组合状态与键盘导航，by AI.Coding。
import AppKit
import SwiftUI
public struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focus: UUID
    var onChange: () -> Void
    var onNavigate: (Int) -> Void
    var onEnter: () -> Void
    var onEscape: () -> Void
    var onDelete: () -> Void = {}
    /// 原生 field editor 决定输入法候选，不抢 Enter。
    public func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = "搜索中文、代码、URL 或来源"
        field.delegate = context.coordinator; field.sendsSearchStringImmediately = true
        field.controlSize = .large; field.setAccessibilityLabel("搜索历史")
        return field
    }
    /// 只有新的打开请求才聚焦，输入中不重复抢焦点。
    public func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor public final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var focus: UUID?
        init(_ parent: SearchField) { self.parent = parent }
        /// 每次输入只更新绑定与queryID；不将搜索词写入日志。
        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue; parent.onChange()
        }
        /// Esc始终关闭面板；中文组合输入中的Enter及方向键仍交给输入法。
        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            if textView.hasMarkedText() { return false }
            switch commandSelector {
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onDelete(); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onEnter(); return true
            case #selector(NSResponder.moveDown(_:)): parent.onNavigate(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onNavigate(-1); return true
            default: return false
            }
        }
    }
}
