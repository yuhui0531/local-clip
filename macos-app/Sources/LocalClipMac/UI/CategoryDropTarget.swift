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
        button.wantsLayer = true; button.layer?.cornerRadius = 16
        button.target = button; button.action = #selector(CategoryButton.choose)
        button.registerForDraggedTypes([.init(HistoryViewModel.categoryDragType)])
        updateNSView(button, context: context)
        return button
    }

    /// 选择变化只更新标签外观，拖放会话及高亮保留在同一个原生按钮中。
    func updateNSView(_ button: CategoryButton, context: Context) {
        button.model = model; button.category = category; button.selected = selected
        button.title = category.name
        button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        let color = RichContent.colorValue(category.colorHex)
        button.image = NSImage(size: .init(width: 16, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: .init(x: 0, y: 1, width: 12, height: 12))
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
        override var intrinsicContentSize: NSSize {
            let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
            return .init(width: ceil(width) + 48, height: 32)
        }

        /// 悬停反馈直接改变原生层，不触发历史卡片的整体刷新。
        func updateAppearance() {
            let tint = RichContent.colorValue(category?.colorHex ?? "34C759")
            layer?.backgroundColor = (targeted ? tint.withAlphaComponent(0.18) : selected ? NSColor.labelColor.withAlphaComponent(0.08) : .clear).cgColor
            layer?.borderColor = (targeted ? tint : .clear).cgColor
            layer?.borderWidth = targeted ? 1.5 : 0
        }

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
            let type = NSPasteboard.PasteboardType(HistoryViewModel.categoryDragType)
            guard let data = sender.draggingPasteboard.data(forType: type), data.count == 36,
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
            guard let token = token(from: sender), let category else { return false }
            return model?.dropIntoCategory(token, categoryID: category.id) == true
        }
        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { targeted = false; updateAppearance() }
    }
}
