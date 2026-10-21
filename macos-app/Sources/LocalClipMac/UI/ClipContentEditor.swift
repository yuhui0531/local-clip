// 原生多行编辑复用系统文字操作，独立草稿避免每个按键重建历史列表，by AI.Coding。
import AppKit
import Combine
import SwiftUI
import LocalClipCore

/// 文本与链接的查看、编辑共享外框和留白，切换时保持气泡尺寸稳定，by AI.Coding。
enum ClipContentLayout {
    static let size = NSSize(width: 520, height: 350)
    static let padding: CGFloat = 16
}

@MainActor final class ClipContentEditorState: ObservableObject {
    let id: ClipID
    let fingerprint: String
    let originalText: String
    let warning: String?
    @Published private(set) var itemTitle: String
    let sourceName: String
    let kind: ClipKind
    private let hasCustomTitle: Bool
    @Published var text: String
    @Published var monospaced: Bool
    @Published var saving = false
    @Published var error = ""
    @Published var confirmingDiscard = false
    var hasChanges: Bool { text != originalText }
    var canSave: Bool { hasChanges && !saving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var characterCount: Int { text.count }
    var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for character in text where character == "\n" { count += 1 }
        return count
    }
    /// 草稿完整保留原文；不使用卡片中被截断的预览作为编辑数据。
    init(detail: ClipDetail, text: String, language: String? = nil) {
        id = detail.summary.id; fingerprint = detail.payload.fingerprint
        originalText = text; self.text = text; warning = detail.payload.textEditWarning
        kind = detail.summary.kind
        sourceName = detail.summary.source.name
        let languageName = language.flatMap { ContentInspector.languageNames[$0] }
        let fullInspection = detail.summary.kind == .text ? ContentInspector.inspectFull(String(text.prefix(16_384)), language: language) : nil
        let detectedKind = fullInspection.flatMap { $0.kind == "文本" ? nil : $0.kind }
        if let title = detail.summary.title, !title.isEmpty {
            hasCustomTitle = true
            itemTitle = title
        } else {
            hasCustomTitle = false
            itemTitle = languageName ?? detectedKind ?? HistoryView.kindName(detail.summary.kind)
        }
        monospaced = detail.summary.kind == .url || languageName != nil || detectedKind != nil
    }
    /// 异步识别到代码语言时补充标题与等宽默认，不覆盖自定义卡片名称，by AI.Coding。
    func applyDetectedLanguage(_ language: String?) {
        guard let language, let name = ContentInspector.languageNames[language] else { return }
        if !hasCustomTitle && itemTitle == HistoryView.kindName(kind) { itemTitle = name }
        if !monospaced { monospaced = true }
    }
    static let loadFailure = "内容读取失败，记录可能已删除或过期。"
    /// 不可编辑的内容返回nil，by AI.Coding。
    convenience init?(detail: ClipDetail) {
        guard let text = detail.payload.editableText else { return nil }
        self.init(detail: detail, text: text)
    }
    /// 编辑器只用识别结果决定排版；用户已改动草稿时不再套用旧原文的结论。
    func detectLanguage() async {
        guard kind == .text, !monospaced else { return }
        let sample = String(originalText.prefix(4_096))
        let language = await SyntaxHighlighter.shared.guess(of: sample, truncated: sample.count < originalText.count).language
        if !hasChanges { applyDetectedLanguage(language) }
    }
    /// 同步锁定保存状态并冻结本次正文，再异步写入；不能保存返回nil，保存中不能重复提交或放弃。
    /// 失败保留草稿并写入错误；仅原子提交成功返回true，by AI.Coding。
    func save(to store: HistoryStore) -> Task<Bool, Never>? {
        guard canSave else { return nil }
        saving = true; error = ""
        let text = text
        return Task { await self.write(text, to: store) }
    }
    private func write(_ text: String, to store: HistoryStore) async -> Bool {
        do {
            try await store.updateText(id: id, text: text, expectedFingerprint: fingerprint)
            return true
        } catch {
            saving = false
            if let failure = error as? ContentEditError { self.error = failure.message }
            else if let failure = error as? StoreError {
                switch failure {
                case .notFound: self.error = "记录已删除或过期，草稿已保留。"
                case .quotaExceeded, .diskFull: self.error = "可用空间不足，保存失败；原内容与草稿均已保留。"
                case .postCommitUnavailable: self.error = "提交后存储不可用，请保留草稿并重启核对；修改可能已保存。"
                default: self.error = "保存失败，草稿已保留，请重试。"
                }
            } else { self.error = "保存失败，草稿已保留，请重试。" }
            return false
        }
    }
    /// 一键还原到初始原文，清除未保存错误与放弃确认态，by AI.Coding。
    func revert() {
        guard !saving else { return }
        text = originalText
        error = ""
        confirmingDiscard = false
    }
}

struct ClipContentEditor: View {
    static let preferredSize = ClipContentLayout.size
    @ObservedObject var state: ClipContentEditorState
    let save: () -> Void
    let cancel: () -> Void
    let discard: () -> Void
    @State private var focused = false
    /// 固定编辑区容纳长文；Return换行，⌘S/⌘↩显式保存，Escape优先收起页内放弃确认。
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("编辑内容").font(.system(size: LCStyle.FontSize.heading, weight: .semibold))
                        Text(state.itemTitle)
                            .font(.system(size: LCStyle.FontSize.meta, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .lineLimit(1)
                        if state.hasChanges {
                            Text("已修改")
                                .font(.system(size: LCStyle.FontSize.caption, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(
                        (state.sourceName.isEmpty || state.sourceName == "未知" ? "" : "\(state.sourceName) · ")
                        + "\(state.characterCount) 个字符 · \(state.lineCount) 行"
                    )
                        .font(.system(size: LCStyle.FontSize.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if state.hasChanges && !state.saving {
                    Button {
                        state.revert()
                        focused = true
                    } label: {
                        Label("还原", systemImage: "arrow.uturn.backward")
                            .font(.system(size: LCStyle.FontSize.meta, weight: .medium))
                    }
                    .buttonStyle(ToolbarTabStyle(selected: false))
                    .help("还原为修改前的内容")
                }
                Button {
                    state.monospaced.toggle()
                } label: {
                    Label("等宽", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: LCStyle.FontSize.meta, weight: state.monospaced ? .semibold : .regular))
                }
                .buttonStyle(ToolbarTabStyle(selected: state.monospaced))
                .help(state.monospaced ? "切换为标准字体" : "切换为等宽字体")
            }
            if let warning = state.warning {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: LCStyle.FontSize.meta))
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.system(size: LCStyle.FontSize.meta))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: LCStyle.Radius.control))
            }
            // 原生文本视图：输入、选择、复制、粘贴、撤销与重做走系统实现，语法着色随输入实时刷新，by AI.Coding。
            HighlightingTextEditor(text: $state.text, monospaced: state.monospaced, editable: !state.saving, focused: focused,
                                   onFocus: { focused = $0 })
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10), lineWidth: focused ? 1.2 : 1)
                )
                .accessibilityLabel("卡片内容")
                .frame(minHeight: 180, maxHeight: .infinity)
                .onChange(of: state.text) { _, _ in
                    if state.confirmingDiscard && !state.hasChanges { state.confirmingDiscard = false }
                    if !state.error.isEmpty { state.error = "" }
                }
            if !state.error.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: LCStyle.FontSize.meta))
                        .foregroundStyle(.red)
                    Text(state.error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: LCStyle.Radius.control))
            }
            if state.confirmingDiscard {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("放弃未保存的修改？")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("继续编辑") {
                        state.confirmingDiscard = false
                        focused = true
                    }
                    .buttonStyle(ToolbarTabStyle(selected: true))
                    Button(role: .destructive, action: discard) {
                        Text("放弃修改")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: LCStyle.Radius.control))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    Text("⌘S / ⌘↩ 保存 · Esc 取消").font(.system(size: LCStyle.FontSize.meta)).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", action: cancel)
                        .buttonStyle(ToolbarTabStyle(selected: true))
                        .disabled(state.saving)
                    Button(action: save) {
                        Text(state.saving ? "正在保存…" : "保存")
                            .font(.system(size: LCStyle.FontSize.body, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: LCStyle.Radius.control))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!state.canSave)
                    .opacity(state.canSave ? 1 : 0.45)
                }
            }
        }
        .padding(ClipContentLayout.padding)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onExitCommand {
            if state.confirmingDiscard {
                state.confirmingDiscard = false
                focused = true
            } else {
                cancel()
            }
        }
    }
}

/// 编辑区与文件预览共用CodeTextView；高亮在后台按有界前缀计算，文字未变才着色，输入法组字期间不改属性，by AI.Coding。
struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    let monospaced: Bool
    let editable: Bool
    let focused: Bool
    var onFocus: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeTextView.make(text: text, editable: editable)
        if let view = scroll.documentView as? NSTextView {
            view.delegate = context.coordinator; view.textContainerInset = NSSize(width: 0, height: 0)
            view.setAccessibilityLabel("卡片内容")
            context.coordinator.view = view; context.coordinator.applyFont(monospaced); context.coordinator.scheduleHighlight(delay: .zero)
            // 深浅色切换时重新着色，自定义配色不停留在旧外观。
            context.coordinator.appearance = view.observe(\.effectiveAppearance) { [weak coordinator = context.coordinator] _, _ in
                MainActor.assumeIsolated { coordinator?.scheduleHighlight(delay: .zero) }
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let view = coordinator.view else { return }
        // 外部改写（如“还原”）走可撤销的替换，撤销栈不会指向已失效的范围。
        if view.string != text, !view.hasMarkedText() {
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            view.breakUndoCoalescing()
            if view.shouldChangeText(in: range, replacementString: text) { view.replaceCharacters(in: range, with: text); view.didChangeText() }
            coordinator.applyFont(monospaced); coordinator.scheduleHighlight(delay: .zero)
        }
        if view.isEditable != editable { view.isEditable = editable }
        if coordinator.monospaced != monospaced { coordinator.applyFont(monospaced) }
        // 只在请求聚焦的那一刻转移焦点，不和用户点击其它控件争抢。
        if focused, !coordinator.focusRequested, let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
        coordinator.focusRequested = focused
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.highlighting?.cancel(); coordinator.appearance = nil }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var view: NSTextView?
        var monospaced = false
        var focusRequested = false
        var appearance: NSKeyValueObservation?
        var highlighting: Task<Void, Never>?
        init(_ parent: HighlightingTextEditor) { self.parent = parent }
        func applyFont(_ value: Bool) {
            monospaced = value
            guard let view, let storage = view.textStorage else { return }
            let font = value ? NSFont.monospacedSystemFont(ofSize: LCStyle.FontSize.body, weight: .regular) : NSFont.systemFont(ofSize: LCStyle.FontSize.body)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            storage.beginEditing()
            storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            view.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        }
        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            if parent.text != view.string { parent.text = view.string }
            scheduleHighlight(delay: .milliseconds(120))
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocus(false) }
        /// 新输入的字符不继承相邻关键字颜色，等下一次着色再上色。
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var value = new; value[.foregroundColor] = NSColor.labelColor; return value
        }
        /// 合并连续输入，只给最终文字着色；长文仅分析前缀，后续保持系统文字色。
        func scheduleHighlight(delay: Duration) {
            highlighting?.cancel()
            guard let view else { return }
            let text = view.string
            highlighting = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                let result = await SyntaxHighlighter.shared.highlight(text, limit: QuickPreview.highlightLimit)
                guard let self, !Task.isCancelled, let view = self.view, view.string == text, !view.hasMarkedText() else { return }
                if let result { CodeTextView.apply(result, to: view) }
                else if let storage = view.textStorage {
                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
                }
            }
        }
    }
}

/// 贴靠目标卡片顶部弹出原生编辑气泡，不作为Window Sheet撑高或抬起底栏面板，by AI.Coding。
@MainActor struct ClipContentEditorPopover: NSViewRepresentable {
    @ObservedObject var model: HistoryViewModel

    /// 优先贴着正在编辑的卡片顶部弹出；卡片不在当前视口时回退到左侧首卡位置，绝不居中撑高底栏。
    static func anchorRect(in hostBounds: NSRect, cardRect: NSRect?, cardHeight: CGFloat, isFlipped: Bool) -> NSRect {
        let horizontalInset: CGFloat = 16
        let available = hostBounds.insetBy(dx: horizontalInset, dy: 0)
        if let cardRect {
            let visible = cardRect.intersection(available)
            if !visible.isNull, visible.width >= 24, visible.height > 0 {
                let y = isFlipped ? visible.minY : max(hostBounds.minY, visible.maxY - 2)
                return NSRect(x: visible.minX, y: y, width: visible.width, height: 2)
            }
        }
        let width = min(max(cardHeight, 160), max(160, available.width))
        // 回退锚点贴在卡片区顶部：拖动条加固定工具栏，by AI.Coding。
        let topOffset = HistoryView.dragHandleHeight + HistoryView.toolbarHeight
        let y = isFlipped ? min(hostBounds.maxY - 2, topOffset) : max(hostBounds.minY, hostBounds.maxY - topOffset)
        return NSRect(x: max(hostBounds.minX + HistoryView.cardInset, available.minX), y: y, width: width, height: 2)
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.bind(model: model)
        context.coordinator.sync()
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        weak var hostView: AnchorView?
        weak var model: HistoryViewModel?
        private var popover: NSPopover?
        private var presentedEditor: ObjectIdentifier?
        private var localClicks: Any?
        private var cancellables: Set<AnyCancellable> = []
        private var deferredShow: Task<Void, Never>?

        init(model: HistoryViewModel) {
            self.model = model
            super.init()
            bind(model: model)
        }

        func attach(to view: AnchorView) {
            hostView = view
            sync()
        }

        func bind(model: HistoryViewModel) {
            guard self.model !== model || cancellables.isEmpty else { return }
            self.model = model
            cancellables.removeAll()
            model.$panelVisible.sink { [weak self] visible in
                if !visible { self?.closePopover(restoreFocus: false) }
                else { DispatchQueue.main.async { self?.sync() } }
            }.store(in: &cancellables)
            model.$contentEditor.sink { [weak self] editor in
                if editor == nil { self?.closePopover(restoreFocus: true) }
                else { DispatchQueue.main.async { self?.sync() } }
            }.store(in: &cancellables)
            model.$settings.sink { [weak self] settings in
                if settings.hideContents { self?.closePopover(restoreFocus: false) }
            }.store(in: &cancellables)
        }

        func sync() {
            guard let model, model.contentEditorPresented, let editor = model.contentEditor,
                  let hostView, let window = hostView.window, window.isVisible else {
                closePopover(restoreFocus: false)
                return
            }
            let identity = ObjectIdentifier(editor)
            if let popover, popover.isShown, presentedEditor == identity {
                if let popoverWindow = popover.contentViewController?.view.window {
                    popoverWindow.sharingType = window.sharingType
                    popoverWindow.appearance = window.effectiveAppearance
                }
                return
            }
            if popover?.isShown == true {
                closePopover(restoreFocus: false)
            }
            if resolvedCardRect(for: editor.id, in: hostView, window: window) == nil,
               model.contains(editor.id), deferredShow == nil {
                deferredShow = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled else { return }
                    self.deferredShow = nil
                    guard let hostView = self.hostView, let window = hostView.window else { return }
                    self.present(editor: editor, in: hostView, window: window)
                }
                return
            }
            present(editor: editor, in: hostView, window: window)
        }

        private func resolvedCardRect(for id: ClipID, in hostView: AnchorView, window: NSWindow) -> NSRect? {
            guard let cardView = HistoryDragBridge.DragView.view(for: id), cardView.window === window else { return nil }
            let rect = hostView.convert(cardView.bounds, from: cardView)
            let visible = rect.intersection(hostView.bounds.insetBy(dx: 16, dy: 0))
            return (!visible.isNull && visible.width >= 24 && visible.height > 0) ? rect : nil
        }

        private func present(editor: ClipContentEditorState, in hostView: AnchorView, window: NSWindow) {
            guard let model, model.contentEditorPresented, model.contentEditor === editor, window.isVisible else { return }
            let root = ClipContentEditor(
                state: editor,
                save: { [weak model] in model?.saveContentEdit() },
                cancel: { [weak model] in model?.requestCancelContentEdit() },
                discard: { [weak model] in model?.discardContentEdit() }
            )
            let controller = NSHostingController(rootView: root)
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.contentSize = ClipContentEditor.preferredSize
            popover.behavior = .applicationDefined
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.delegate = self

            let cardHeight = HistoryView.cardSide(height: hostView.bounds.height)
            let cardRect = resolvedCardRect(for: editor.id, in: hostView, window: window)
            let rect = ClipContentEditorPopover.anchorRect(in: hostView.bounds, cardRect: cardRect, cardHeight: cardHeight, isFlipped: hostView.isFlipped)
            let edge: NSRectEdge = hostView.isFlipped ? .minY : .maxY

            self.popover = popover
            self.presentedEditor = ObjectIdentifier(editor)
            popover.show(relativeTo: rect, of: hostView, preferredEdge: edge)
            if let popoverWindow = controller.view.window {
                popoverWindow.sharingType = window.sharingType
                popoverWindow.appearance = window.effectiveAppearance
                popoverWindow.makeKey()
                Task { @MainActor in
                    @MainActor func findTextView(_ view: NSView) -> NSTextView? {
                        if let text = view as? NSTextView, text.isEditable { return text }
                        for child in view.subviews { if let found = findTextView(child) { return found } }
                        return nil
                    }
                    if let textView = findTextView(controller.view), popoverWindow.firstResponder !== textView {
                        popoverWindow.makeFirstResponder(textView)
                    }
                }
            }
            installClickMonitor()
        }

        private func installClickMonitor() {
            if let localClicks { NSEvent.removeMonitor(localClicks) }
            localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let model = self.model, model.contentEditorPresented,
                      let hostWindow = self.hostView?.window,
                      let popoverWindow = self.popover?.contentViewController?.view.window else { return event }
                guard event.window === hostWindow, event.window !== popoverWindow else { return event }
                if event.type == .leftMouseDown { _ = model.dismissPopoverForBackdropClick(count: event.clickCount, timestamp: event.timestamp) }
                else { model.requestCancelContentEdit() }
                // 首次外点仅关闭/确认编辑，后续正常点击仍沿原有卡片与拖拽路径。
                return nil
            }
        }

        func closePopover(restoreFocus: Bool) {
            deferredShow?.cancel(); deferredShow = nil
            if let localClicks { NSEvent.removeMonitor(localClicks); self.localClicks = nil }
            presentedEditor = nil
            guard let active = popover else { return }
            self.popover = nil
            active.delegate = nil
            if active.isShown { active.close() }
            if restoreFocus, let window = hostView?.window, window.isVisible {
                window.makeKey()
            }
        }

        func detach() {
            cancellables.removeAll()
            closePopover(restoreFocus: false)
            hostView = nil
        }
    }
}
