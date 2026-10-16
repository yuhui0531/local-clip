// 原生多行编辑复用系统文字操作，独立草稿避免每个按键重建历史列表，by AI.Coding。
import SwiftUI
import LocalClipCore

@MainActor final class ClipContentEditorState: ObservableObject {
    let id: ClipID
    let fingerprint: String
    let originalText: String
    let warning: String?
    @Published var text: String
    @Published var saving = false
    @Published var error = ""
    @Published var confirmingDiscard = false
    var hasChanges: Bool { text != originalText }
    var canSave: Bool { hasChanges && !saving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 草稿完整保留原文；不使用卡片中被截断的预览作为编辑数据。
    init(detail: ClipDetail, text: String) {
        id = detail.summary.id; fingerprint = detail.payload.fingerprint
        originalText = text; self.text = text; warning = detail.payload.textEditWarning
    }
}

struct ClipContentEditor: View {
    @ObservedObject var state: ClipContentEditorState
    let save: () -> Void
    let cancel: () -> Void
    let discard: () -> Void
    @FocusState private var focused: Bool
    /// 固定编辑区容纳长文；Return换行，⌘S显式保存，Escape走取消保护。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑内容").font(.system(size: 16, weight: .semibold))
            if let warning = state.warning {
                Text(warning).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextEditor(text: $state.text).font(.system(size: 14))
                .focused($focused).disabled(state.saving)
                .padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityLabel("卡片内容")
                .frame(minHeight: 220, maxHeight: .infinity)
            if !state.error.isEmpty { Text(state.error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("⌘S 保存 · Esc 取消").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: cancel).disabled(state.saving)
                Button(state.saving ? "正在保存…" : "保存", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(!state.canSave)
            }
        }.padding(20).frame(width: 560, height: 390)
            .background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled()
            .onAppear { focused = true }
            .onExitCommand(perform: cancel)
            .confirmationDialog("放弃未保存的修改？", isPresented: $state.confirmingDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive, action: discard)
                Button("继续编辑", role: .cancel) { }
            }
    }
}
