// 分类标签由AppKit直接处理拖放，避免原生拖出与异步SwiftUI接收之间的令牌时序差异，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore

struct CategoryDropTarget: NSViewRepresentable {
    let category: ClipCategory
    let selected: Bool
    let model: HistoryViewModel

    /// 原生按钮同时承载点击、右键与拖放，不叠加透明视图截断命中链。
    func makeNSView(context: Context) -> CategoryButton {
        let button = CategoryButton()
        button.isBordered = false; button.bezelStyle = .rounded
        button.imagePosition = .imageLeft; button.imageHugsTitle = true
        button.wantsLayer = true; button.layer?.cornerRadius = 14
        button.target = button; button.action = #selector(CategoryButton.choose)
        button.registerForDraggedTypes([.init(HistoryViewModel.categoryDragType)])
        updateNSView(button, context: context)
        return button
    }

    /// 选择变化只更新标签外观，拖放会话及高亮保留在同一个原生按钮中。
    func updateNSView(_ button: CategoryButton, context: Context) {
        button.model = model; button.category = category; button.selected = selected
        // 与SwiftUI工具栏标签一致：未选中次要色，选中主色加粗，by AI.Coding。
        button.font = .systemFont(ofSize: LCStyle.FontSize.body, weight: selected ? .semibold : .regular)
        button.attributedTitle = NSAttributedString(string: category.name, attributes: [.font: button.font!, .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor])
        let color = RichContent.colorValue(category.colorHex)
        // 8pt圆点与13pt文字垂直居中，标签更轻，by AI.Coding。
        button.image = NSImage(size: .init(width: 12, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: .init(x: 0, y: 3, width: 8, height: 8))
            color.setFill(); circle.fill()
            NSColor.black.withAlphaComponent(0.14).setStroke(); circle.lineWidth = 0.5; circle.stroke()
            return true
        }
        button.setAccessibilityLabel(category.name)
        button.toolTip = "把历史卡片拖到这里加入分类；右键重命名"
        button.updateAppearance(); button.invalidateIntrinsicContentSize()
    }

    /// 为分类名称保留完整宽度；整个分类行负责溢出滚动。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CategoryButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class CategoryButton: NSButton {
        weak var model: HistoryViewModel?
        var category: ClipCategory?
        var selected = false
        private var targeted = false
        private var hovering = false
        override var intrinsicContentSize: NSSize {
            let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
            // 图片宽减4pt、内边距与SwiftUI标签同为8pt，共减8pt，by AI.Coding。
            return .init(width: ceil(width) + 32, height: 28)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovering = true; updateAppearance() }
        override func mouseExited(with event: NSEvent) { hovering = false; updateAppearance() }

        /// 悬停反馈直接改变原生层，不触发历史卡片的整体刷新。
        func updateAppearance() {
            let tint = RichContent.colorValue(category?.colorHex ?? "34C759")
            // 动态颜色需在当前外观下解析为CGColor，深浅切换后不残留旧值。
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = (targeted ? tint.withAlphaComponent(0.18) : selected ? tint.withAlphaComponent(0.16) : hovering ? NSColor.labelColor.withAlphaComponent(0.05) : .clear).cgColor
            }
            layer?.borderColor = (targeted ? tint : .clear).cgColor
            layer?.borderWidth = targeted ? 1.5 : 0
        }
        /// 托管层与按钮本身的原生接收共用反馈，不发布整个历史模型，by AI.Coding。
        func setDropTargeted(_ value: Bool) { targeted = value; updateAppearance() }

        /// AppKit外观切换时重新生成动态颜色。
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

        /// 点击与拖放使用不同入口，拖入不会切换浏览范围或清掉多选。
        @objc func choose() { if let category { model?.toggleCategory(category.id) } }
        /// 名称与颜色继续使用统一编辑弹层。
        @objc private func renameCategory() { if let category { model?.editCategory(category) } }
        /// 向前调整分类的持久顺序。
        @objc private func moveCategoryLeft() { if let category { model?.moveCategory(category, delta: -1) } }
        /// 向后调整分类的持久顺序。
        @objc private func moveCategoryRight() { if let category { model?.moveCategory(category, delta: 1) } }
        /// 删除仍经过影响预览与确认入口。
        @objc private func deleteCategory() { if let category { model?.change(.deleteCategory(category.id)) } }

        /// 保留标签右键操作，新增拖放不改变已有管理入口。
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            for (title, action) in [("名称与颜色…", #selector(renameCategory)), ("向左移动", #selector(moveCategoryLeft)), ("向右移动", #selector(moveCategoryRight)), ("删除分类…", #selector(deleteCategory))] {
                if title == "删除分类…" { menu.addItem(.separator()) }
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; menu.addItem(item)
            }
            return menu
        }

        /// 只接收当前LocalClip会话的随机令牌；公开文本／文件载荷不参与内部分类。
        private func token(from sender: any NSDraggingInfo) -> String? {
            acceptedToken(from: sender.draggingPasteboard)
        }
        /// 原生回调与回归检查共用真实命名剪贴板的令牌校验，不接受外部伪造身份，by AI.Coding。
        func acceptedToken(from pasteboard: NSPasteboard) -> String? {
            let type = NSPasteboard.PasteboardType(HistoryViewModel.categoryDragType)
            guard let data = pasteboard.data(forType: type), data.count == 36,
                  let value = String(data: data, encoding: .utf8), let category,
                  model?.canDropIntoCategory(value, categoryID: category.id) == true else { return nil }
            return value
        }

        /// 每次进入或移动都校验记录和目标身份，已删除条目不会获得可放下反馈。
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            targeted = token(from: sender) != nil; updateAppearance()
            return targeted ? .copy : []
        }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted = false; updateAppearance() }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { token(from: sender) != nil }

        /// 同步认领归属令牌，避免拖动结束的取消回调抢先使异步读取失效。
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { targeted = false; updateAppearance() }
            return performCategoryDrop(from: sender.draggingPasteboard)
        }
        /// 同步认领后异步持久化；只有当前会话的目标分类可认领一次，by AI.Coding。
        func performCategoryDrop(from pasteboard: NSPasteboard) -> Bool {
            guard let token = acceptedToken(from: pasteboard), let category else { return false }
            return model?.dropIntoCategory(token, categoryID: category.id) == true
        }
        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { targeted = false; updateAppearance() }
        /// 在目标上取消不会必然经过退出/放下，结束回调也必须清除高亮，by AI.Coding。
        override func draggingEnded(_ sender: any NSDraggingInfo) { setDropTargeted(false) }
    }
}

// 整个托管面板注册内部拖放类型，把原生回调按实际指针位置路由给可见分类，by AI.Coding。
@MainActor final class CategoryDropHostingView<Content: View>: NSHostingView<Content> {
    private weak var model: HistoryViewModel?
    private weak var highlighted: CategoryDropTarget.CategoryButton?
    init(rootView: Content, model: HistoryViewModel) {
        self.model = model
        super.init(rootView: rootView)
        registerForDraggedTypes([.init(HistoryViewModel.categoryDragType)])
    }
    @MainActor required init(rootView: Content) { fatalError("Use init(rootView:model:)") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// 使用窗口坐标和真实裁剪区域；拖动预览覆盖标签不能代替指针命中，by AI.Coding。
    func categoryTarget(at windowPoint: NSPoint) -> CategoryDropTarget.CategoryButton? {
        guard let model else { return nil }
        func find(_ view: NSView) -> CategoryDropTarget.CategoryButton? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let button = view as? CategoryDropTarget.CategoryButton, button.model === model {
                let point = button.convert(windowPoint, from: nil)
                if button.bounds.contains(point), button.visibleRect.contains(point) { return button }
            }
            for child in view.subviews { if let button = find(child) { return button } }
            return nil
        }
        return find(self)
    }
    /// 原生按钮和托管层回调共享同一剪贴板令牌校验，不凭公开格式或来源结束猜测接收，by AI.Coding。
    private func target(_ sender: any NSDraggingInfo) -> CategoryDropTarget.CategoryButton? {
        guard let window, sender.draggingDestinationWindow === window,
              let button = categoryTarget(at: sender.draggingLocation),
              button.acceptedToken(from: sender.draggingPasteboard) != nil else { return nil }
        return button
    }
    private func clearHighlight() {
        highlighted?.setDropTargeted(false); highlighted = nil
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let button = target(sender)
        if highlighted !== button { clearHighlight(); highlighted = button }
        button?.setDropTargeted(true)
        return button == nil ? [] : .copy
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearHighlight() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { target(sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearHighlight() }
        return target(sender)?.performCategoryDrop(from: sender.draggingPasteboard) == true
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clearHighlight() }
    /// Escape等取消路径可能不派发draggingExited，不能遗留目标反馈，by AI.Coding。
    override func draggingEnded(_ sender: any NSDraggingInfo) { clearHighlight() }
}
