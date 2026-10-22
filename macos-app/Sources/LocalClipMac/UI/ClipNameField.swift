// 非激活历史面板内的原生名称输入框，挂载后明确接管field editor，by AI.Coding。
import AppKit
import SwiftUI

struct ClipNameField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onFocusLost: (() -> Void)? = nil

    /// 原生单行文本域保留中文组合、选择与标准编辑快捷键。
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = .white; field.placeholderString = "名称"
        field.cell?.isScrollable = true; field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("记录名称")
        return field
    }
    /// 更新不能重设正在输入的选区；首次聚焦在原生窗口挂载完成后执行。
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.requestInitialFocus()
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Field: NSTextField {
        private var focusedOnce = false
        private var focusPending = false
        /// 非激活面板不能只依赖SwiftUI逻辑焦点，必须建立真实第一响应者。
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); requestInitialFocus() }
        func requestInitialFocus() {
            guard window != nil, !focusedOnce, !focusPending else { return }
            focusPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusPending = false
                guard let window = self.window, !self.focusedOnce else { return }
                if window.makeFirstResponder(self) {
                    // makeFirstResponder已建立field editor；再次selectText会结束旧编辑会话并误触发取消。
                    self.currentEditor()?.selectAll(nil)
                    self.focusedOnce = self.currentEditor() != nil
                }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ClipNameField
        init(_ parent: ClipNameField) { self.parent = parent }
        /// 原生输入只写本卡片草稿，不触发搜索。
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        /// 主动移开焦点取消改名；提交命令保持编辑到保存结果返回。
        func controlTextDidEndEditing(_ notification: Notification) {
            if let onFocusLost = parent.onFocusLost { onFocusLost() } else { parent.onCancel() }
        }
        /// 输入法先处理候选，Return保存、Escape取消，不交给面板粘贴路由。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if command == #selector(NSResponder.insertNewline(_:)) { parent.onCommit(); return true }
            if command == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }
    }
}
