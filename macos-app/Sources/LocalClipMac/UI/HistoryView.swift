// Paste 类横向底部卡片面板，真实数据驱动的原生界面，by AI.Coding。
import AppKit
import SwiftUI
@preconcurrency import VisionKit
import LocalClipCore
public struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var categoryContentWidth: CGFloat = 0
    @State private var categoryFadeLeading = false
    @State private var categoryFadeTrailing = false
    @State private var resizingHeight: Double?
    public init(model: HistoryViewModel) { self.model = model }
    /// 几何常量各只定义一次；卡片区、滚轮、分页和编辑气泡共用，by AI.Coding。
    static let dragHandleHeight: CGFloat = 8
    static let toolbarHeight: CGFloat = 44
    static let cardVerticalPadding: CGFloat = 10
    static let cardInset: CGFloat = 24
    static let cardSpacing: CGFloat = 16
    /// 边长只随面板高度严格单调变化；筛选、队列、多选和状态不改变卡片几何，by AI.Coding。
    static func cardSide(height: CGFloat) -> CGFloat { max(1, height - dragHandleHeight - toolbarHeight - 2 * cardVerticalPadding) }
    public var body: some View {
        // 根布局只接受真实窗口视口；卡片最小内容尺寸不能反过来扩大托管视图。
        GeometryReader { viewport in
            // 用户可在宽屏主动启用紧凑工具栏；窄屏仍保持已有自适应行为，by AI.Coding。
            let compact = model.settings.compactLayout || viewport.size.width < 1000
            // 正方形宽高一起收缩，完整边界始终留在实际视口内。
            let cardHeight = Self.cardSide(height: viewport.size.height)
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.3)).frame(width: 36, height: 3).frame(maxWidth: .infinity).frame(height: Self.dragHandleHeight).contentShape(Rectangle())
                    .help("上下拖动调整高度")
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        if resizingHeight == nil { resizingHeight = model.actualPanelHeight }
                        model.resizePanel?((resizingHeight ?? 340) - value.translation.height, false)
                    }.onEnded { value in model.resizePanel?((resizingHeight ?? 340) - value.translation.height, true); resizingHeight = nil })
                // 品牌由菜单栏、关于与设置窗口承担，工具栏只放导航与操作，by AI.Coding。
                HStack(spacing: compact ? 12 : 18) {
                    // 全部/收藏固定可见，类型与分类紧随其后，避免重复历史入口，by AI.Coding。
                    // 范围与类型之间用和分类前相同的分隔线，间距与标签一致，by AI.Coding。
                    HStack(spacing: 2) {
                        HStack(spacing: 2) { filter("剪贴板", nil); favoritesTab }.fixedSize()
                        Divider().frame(height: 16).padding(.horizontal, 6)
                        categoryNavigation(compact: compact)
                    }
                    // 状态槽与多选操作条共用同一位置；导航区和搜索在多选时保持可用，by AI.Coding。
                    HistoryToolbarStatus(model: model, footer: model.listState.footerState, input: model.queryState, compact: compact)
                    HistorySearchInput(model: model, input: model.queryState, footer: model.listState.footerState, focus: model.searchFocusRequest).frame(width: compact ? 160 : 200, height: 30)
                    HStack(spacing: 2) {
                        filterButton
                            .popover(isPresented: $model.showingFilters) { FilterEditor(model: model) }
                        HistoryMoreMenu(model: model, footer: model.listState.footerState)
                        ToolbarIconButton(symbol: model.pinned ? "pin.fill" : "pin", tint: model.pinned ? .accentColor : nil, help: model.pinned ? "取消置顶" : "置顶（失焦不隐藏）", label: model.pinned ? "取消置顶" : "置顶") { model.pinned.toggle(); model.panelInteractionChanged?() }
                        ToolbarIconButton(symbol: "xmark", help: "关闭 · Esc") { model.closePanel?(true) }
                    }
                }.padding(.horizontal, Self.cardInset).frame(height: Self.toolbarHeight)
                HistoryStrip(model: model, list: model.listState, cardHeight: cardHeight,
                    categoryID: model.categoryID, categories: model.categories,
                    target: model.target, draggedIDs: model.draggedIDs, hideContents: model.settings.hideContents, focusRequest: model.focusRequest, renamingID: model.renamingID, showingDetail: model.showingDetail && model.detail != nil, detailPending: model.detailSlow, quickBadges: model.quickBadgesVisible)
            // 顶部保留圆角，底边与屏幕贴合，不留可拖动的悬浮窗口边距。
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .background { ZStack { HistoryBackdrop(); Color(nsColor: .windowBackgroundColor).opacity(0.76) } }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18).strokeBorder(.white.opacity(0.30), lineWidth: 1))
                .clipped()
                .offset(y: model.panelEntrance)
                .onGeometryChange(for: CGSize.self) { CGSize(width: $0.size.width, height: cardHeight) } action: { size in
                    model.configureHistoryViewport(width: size.width, cardWidth: size.height)
                }
                .onChange(of: model.favorites) { _, _ in model.searchChanged(debounce: false) }
                .onChange(of: model.categoryID) { _, _ in model.searchChanged(debounce: false) }
                .onChange(of: model.categoryFilters) { _, _ in model.searchChanged(debounce: false) }
                .onChange(of: model.sourceFilter) { _, _ in model.searchChanged(debounce: false) }
                .onChange(of: model.dateFilterEnabled) { _, _ in model.searchChanged(debounce: false) }
                .onChange(of: model.dateFrom) { _, _ in if model.dateFilterEnabled { model.searchChanged(debounce: false) } }
                .onChange(of: model.dateUntil) { _, _ in if model.dateFilterEnabled { model.searchChanged(debounce: false) } }
                .onChange(of: model.kind) { _, _ in model.searchChanged(debounce: false) }
                .onChange(of: model.showingDetail) { _, _ in model.detailVisibilityChanged() }
                .onChange(of: model.showingCategoryEditor) { _, _ in model.panelInteractionChanged?() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // 编辑气泡贴靠目标卡片顶部弹出，独立于滚动卡片存活，不作为Sheet撑高或抬起底栏面板，by AI.Coding。
            .background { ClipContentEditorPopover(model: model) }
    }
    /// 筛选按钮携带生效条件数；单项清除与“清除筛选”仍在FilterEditor中，by AI.Coding。
    @ViewBuilder private var filterButton: some View {
        let count = model.filterCount
        if count == 0 {
            ToolbarIconButton(symbol: "line.3.horizontal.decrease", help: "筛选") { model.showingFilters.toggle() }
        } else {
            Button { model.showingFilters.toggle() } label: {
                HStack(spacing: 4) { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .medium)); Text("筛选 · \(count)") }
                    .foregroundStyle(Color.accentColor)
            }.buttonStyle(ToolbarTabStyle(selected: true)).fixedSize().help("筛选（\(count) 项生效）").accessibilityLabel("筛选，\(count) 项生效")
        }
    }
    /// 类型与分类共享工具栏剩余宽度；溢出只滚动这段，主入口与搜索保持可见，by AI.Coding。
    private func categoryNavigation(compact: Bool) -> some View {
        GeometryReader { geometry in
            let overflow = categoryContentWidth > geometry.size.width + 1
            ScrollViewReader { proxy in
                HStack(spacing: 2) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            // 紧凑布局把类型收进一个菜单，窄屏剩余宽度优先留给自定义分类，by AI.Coding。
                            if compact { kindMenu } else { ForEach(ClipKind.allCases, id: \.self) { kindTab($0) } }
                            if !model.categories.isEmpty { Divider().frame(height: 16).padding(.horizontal, 6) }
                            ForEach(model.categories) { categoryTab($0).id($0.id) }
                            ToolbarIconButton(symbol: "plus", help: "新建分类") { model.editCategory() }
                        // 标签从收藏右侧依次排列，剩余空间不能把分类推到第二行，by AI.Coding。
                        }.fixedSize(horizontal: true, vertical: false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { categoryContentWidth = $0 }
                            .frame(minHeight: 32, alignment: .leading)
                    }.scrollIndicators(.hidden)
                        // 仅在还有被遮挡标签的一侧透明渐隐，滚到端点时完整显示首尾标签，by AI.Coding。
                        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 1 } action: { _, value in categoryFadeLeading = value }
                        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x < $0.contentSize.width - $0.containerSize.width - 1 } action: { _, value in categoryFadeTrailing = value }
                        .mask {
                            HStack(spacing: 0) {
                                if categoryFadeLeading { LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 28) }
                                Rectangle()
                                if categoryFadeTrailing { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28) }
                            }
                        }
                        .onChange(of: model.categoryID) { _, id in
                            if let id, overflow { proxy.scrollTo(id, anchor: .center) }
                        }
                    // 被截断的标签仍可从全部分类菜单直达。
                    if overflow {
                        Menu {
                            ForEach(model.categories) { category in
                                Button(category.name) { model.selectCategories([category.id]); proxy.scrollTo(category.id, anchor: .center) }
                            }
                            Divider()
                            Button("新建分类…") { model.editCategory() }
                        } label: { Image(systemName: "chevron.down").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("全部分类").accessibilityLabel("全部分类")
                    }
                }.frame(width: geometry.size.width, alignment: .leading)
            }
        }.frame(height: 32)
            // 弹窗锚定可见导航区域；加号滚出视口时，溢出菜单和快捷键仍能打开编辑器。
            .popover(isPresented: $model.showingCategoryEditor, arrowEdge: .top) { CategoryEditor(model: model) }
    }
    /// 类型菜单与类型标签同一选择规则；选中时显示类型名并高亮，by AI.Coding。
    private var kindMenu: some View {
        let selected = model.kind != nil && model.activeCategories.isEmpty && !model.favorites
        return Menu {
            ForEach(ClipKind.allCases, id: \.self) { kind in
                Button { model.selectKind(kind) } label: {
                    if selected && model.kind == kind { Label(Self.kindName(kind), systemImage: "checkmark") } else { Text(Self.kindName(kind)) }
                }
            }
        } label: {
            HStack(spacing: 3) { Text(selected ? model.kind.map(Self.kindName) ?? "类型" : "类型"); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }.menuStyle(.button).buttonStyle(ToolbarTabStyle(selected: selected)).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(selected ? "类型：\(model.kind.map(Self.kindName) ?? "")" : "类型")
    }
    /// 收藏独立于类型与分类；全部是唯一的完整历史入口，by AI.Coding。
    private var favoritesTab: some View {
        Button { model.categoryID = nil; model.categoryFilters = []; model.kind = nil; model.favorites = true } label: {
            Label("收藏", systemImage: model.favorites ? "star.fill" : "star")
        }.buttonStyle(ToolbarTabStyle(selected: model.favorites)).accessibilityAddTraits(model.favorites ? .isSelected : [])
    }
    /// 类型入口退出自定义分类；全部按钮不会在分类页面伪装成已选中，by AI.Coding。
    private func filter(_ title: String, _ kind: ClipKind?) -> some View {
        let selected = model.kind == kind && model.activeCategories.isEmpty && !model.favorites
        return Button(title) { model.selectKind(kind) }.buttonStyle(ToolbarTabStyle(selected: selected)).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// 类型图标分段：一次点击、与卡片类型符号一致，名称由提示和朗读给出，by AI.Coding。
    private func kindTab(_ kind: ClipKind) -> some View {
        let selected = model.kind == kind && model.activeCategories.isEmpty && !model.favorites
        return Button { model.selectKind(kind) } label: { Image(systemName: Self.kindSymbol(kind)).font(.system(size: 13, weight: .medium)) }
            .buttonStyle(ToolbarTabStyle(selected: selected)).help(Self.kindName(kind)).accessibilityLabel(Self.kindName(kind))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// 标签直接注册原生拖放目标，接收卡片拖动并保留点击与右键管理。
    private func categoryTab(_ category: ClipCategory) -> some View {
        CategoryDropTarget(category: category, selected: model.activeCategories.contains(category.id), model: model)
    }
    /// 采集状态改用面向用户的说法，内部状态值保持不变。
    static func statusLabel(_ state: String) -> String {
        switch state { case "正常": "正在监控"; case "用户暂停": "已停止监控"; case "定时暂停": "已定时停止监控"; case "正在暂停": "正在停止监控"; case "容量已满": "容量已满，新内容未记录"; default: state }
    }
    /// 类型符号在工具栏与卡片共用。
    static func kindSymbol(_ kind: ClipKind) -> String { switch kind { case .text: "text.alignleft"; case .url: "link"; case .image: "photo"; case .file: "doc.on.doc"; case .mixed: "square.stack" } }
    /// 类型名称与新增文件筛选保持一致。
    public static func kindName(_ kind: ClipKind) -> String { switch kind { case .text: "文本"; case .url: "链接"; case .image: "图片"; case .file: "文件"; case .mixed: "混合" } }
}

// 输入只让搜索框与列表读取，不引起工具栏、分类行和整条底栏重算，by AI.Coding。
// 条数与查询转圈只订阅统计快照，替代原底栏统计，by AI.Coding。
private struct HistorySearchInput: View {
    let model: HistoryViewModel
    @ObservedObject var input: HistoryQueryState
    @ObservedObject var footer: HistoryFooterState
    let focus: UUID
    var body: some View {
        let value = footer.snapshot
        SearchField(text: $input.literal, focus: focus, onChange: { model.searchChanged() },
            onNavigate: model.navigate, onEnter: { model.focusResults?() }, onEscape: { if model.handleEscape() { model.closePanel?(true) } },
            placeholder: "搜索 \(value.itemCount)\(value.hasMore ? "+" : "") 条", onRegister: { model.searchField = $0 })
            .overlay(alignment: .trailing) {
                if value.loading { ProgressView().controlSize(.mini).padding(.trailing, 26).accessibilityLabel("正在读取") }
            }
    }
}
private struct HistoryStrip: View {
    let model: HistoryViewModel
    @ObservedObject var list: HistoryListState
    let cardHeight: CGFloat
    let categoryID: String?
    let categories: [ClipCategory]
    let target: TargetToken?
    let draggedIDs: Set<ClipID>
    let hideContents: Bool
    let focusRequest: UUID
    let renamingID: ClipID?
    let showingDetail: Bool
    let detailPending: Bool
    let quickBadges: Bool
    var body: some View {
        ZStack {
            if model.items.isEmpty {
                HistoryEmptyState(model: model, input: model.queryState, loading: list.snapshot.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 换筛选整组重建滚动区，新列表首帧就在最左侧，不先按旧偏移绘制再跳回，by AI.Coding。
                HistoryScroller(strip: self, list: list, epoch: list.snapshot.scrollEpoch).id(list.snapshot.scrollEpoch)
            }
        }.frame(maxWidth: .infinity).frame(height: cardHeight + 20).clipped()
        // 隐藏状态用明确占位替代整层模糊，避免正文轮廓泄露及持续模糊合成，by AI.Coding。
        .opacity(hideContents ? 0 : 1).allowsHitTesting(!hideContents).accessibilityHidden(hideContents)
        .overlay {
            if hideContents {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("历史内容已隐藏").font(.headline)
                    Button("显示内容") { model.updateSettings { $0.hideContents = false } }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            #if DEBUG
            if GUIAcceptanceProbe.configuration != nil {
                GUIRenderWitness(displayCycle: focusRequest, query: model.query, generation: model.guiQueryGeneration, first: model.items.first?.preview, firstID: model.items.first?.id, firstImage: model.items.first?.kind == .image, ready: model.items.first?.kind != .image || GUIAcceptanceProbe.imageReadyIDs.contains(model.items.first?.id ?? ""), loading: model.historyBusy).frame(width: 1, height: 1)
            }
            #else
            EmptyView()
            #endif
        }

    }
}
/// 滚动位置与滚轮状态随滚动区身份重建；列表就地刷新时身份不变，保持浏览位置，by AI.Coding。
private struct HistoryScroller: View {
    let strip: HistoryStrip
    /// 列表就地刷新必须重算本视图，不能依赖父视图传入的值相等判断。
    @ObservedObject var list: HistoryListState
    let epoch: Int
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollWheelState = HistoryScrollWheel.State()
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: HistoryView.cardSpacing) {
                    ForEach(Array(strip.model.items.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, selected: strip.model.selectedIDs.contains(item.id) || (strip.model.contentEditorPresented && strip.model.contentEditor?.id == item.id), dragging: strip.draggedIDs.contains(item.id), editing: strip.renamingID == item.id, hidden: strip.hideContents, quickModifiers: strip.model.settings.quickModifiers, height: strip.cardHeight, categoryID: strip.categoryID, categories: strip.categories, target: strip.target, selectionCount: strip.model.selectedIDs.contains(item.id) ? strip.model.selectedIDs.count : 0, selectionHasNonText: strip.model.items.contains { strip.model.selectedIDs.contains($0.id) && ($0.kind == .image || $0.kind == .mixed) }, queueShortcut: strip.model.settings.queueShortcut, model: strip.model, previewGeneration: strip.focusRequest, detailPending: strip.detailPending && strip.model.selectedID == item.id, showsQuickBadge: strip.quickBadges).equatable().id(item.id)
                            // 详情贴着所选卡片弹出，而不是远在底栏右侧的按钮，by AI.Coding。
                            // 详情内容备好后才弹出，弹出即最终尺寸，by AI.Coding。
                            .popover(isPresented: Binding(get: { strip.showingDetail && strip.model.selectedID == item.id && strip.model.detail?.summary.id == item.id }, set: { if !$0 { strip.model.showingDetail = false } }), attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                                ClipInspector(model: strip.model)
                            }
                    }
                    if strip.model.hasMore {
                        Button(action: strip.model.loadMore) {
                            VStack(spacing: 10) {
                                if strip.model.loading { ProgressView() } else { Image(systemName: "arrow.right").font(.title2) }
                                Text(strip.model.loading ? "正在读取…" : "更多历史")
                            }.frame(width: 130, height: strip.cardHeight)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, HistoryView.cardInset).padding(.vertical, HistoryView.cardVerticalPadding)
                    .background(OverlayScrollerStyle())
            }.scrollIndicators(.visible)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: HistoryScrollMetrics.self) { geometry in
                    HistoryScrollMetrics(offset: max(0, geometry.contentOffset.x), maximum: max(0, geometry.contentSize.width - geometry.containerSize.width), viewport: geometry.containerSize.width)
                } action: { _, metrics in scrollWheelState.update(metrics); strip.model.historyScrolled(offset: metrics.offset, epoch: epoch) }
                .background(HistoryScrollWheel(state: scrollWheelState, presented: { strip.model.panelVisible }) { x in scrollPosition.scrollTo(x: x) })
                .onChange(of: strip.model.selectedID) { _, id in
                    if let id, let index = strip.model.items.firstIndex(where: { $0.id == id }), scrollWheelState.needsReveal(index: index, cardWidth: strip.cardHeight) {
                        proxy.scrollTo(id)
                    }
                }
                .onChange(of: strip.model.contentEditor?.id) { _, id in
                    if let id, let index = strip.model.items.firstIndex(where: { $0.id == id }), scrollWheelState.needsReveal(index: index, cardWidth: strip.cardHeight) {
                        proxy.scrollTo(id)
                    }
                }
                .onChange(of: strip.model.scrollRestoration) { _, restore in
                    if let restore { scrollPosition.scrollTo(x: restore.offset) }
                }
        }
    }
}
/// 搜索词只让空结果提示订阅，避免每个输入字符重建整条卡片列表，by AI.Coding。
private struct HistoryEmptyState: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var input: HistoryQueryState
    let loading: Bool
    var body: some View {
        let searched = !input.literal.isEmpty
        let filtered = model.sourceFilter != nil || model.dateFilterEnabled || model.kind != nil || model.activeCategories.count > 1 || !model.queryConditions.isEmpty
        VStack(spacing: 10) {
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: searched || filtered ? "magnifyingglass" : model.favorites ? "star" : "square.on.square")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary) }
            Text(loading ? "正在读取历史…" : searched || filtered ? "没有匹配的记录" : model.favorites ? "收藏常用内容，随时取用" : !model.activeCategories.isEmpty ? "这个分类还没有记录" : "下一次复制，就从这里开始")
                .font(.system(size: 16, weight: .semibold))
            if !loading {
                Text(searched || filtered ? "试试其他关键词，或清除筛选条件。" : model.favorites ? "选中记录后点按星标，或右键选择“收藏”。" : !model.activeCategories.isEmpty ? "将记录拖到分类标签，即可加入这个分类。" : "复制文字、链接、图片或文件后，会自动显示在这里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if searched { Button("清除搜索") { input.literal = ""; model.searchChanged() } }
                    if filtered { Button("清除筛选") { model.clearHistoryFilters() } }
                    if !searched && !filtered && (model.favorites || !model.activeCategories.isEmpty) {
                        Button("查看剪贴板") { model.selectKind(nil) }
                    }
                    if model.recordingPaused {
                        Button("开始监控") { model.resumeRecording() }
                    }
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(.horizontal, 24)
    }
}
/// 状态槽与多选操作条交叉淡入，同一位置、固定宽度，工具栏其余控件不位移，by AI.Coding。
private struct HistoryToolbarStatus: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var footer: HistoryFooterState
    @ObservedObject var input: HistoryQueryState
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let multi = footer.snapshot.selectedCount > 1
        let entry = model.statusEntry(queryEmpty: input.literal.isEmpty)
        ZStack(alignment: .trailing) {
            if multi { HistoryMultiSelectBar(model: model, value: footer.snapshot, failure: entry?.level == .failure, compact: compact).transition(.opacity) }
            else { HistoryStatusSlot(model: model, entry: entry, compact: compact).transition(.opacity) }
        }.frame(width: compact ? nil : multi ? 300 : 260, alignment: .trailing)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: multi)
            // 优先级1–4的状态变化朗读给VoiceOver；焦点提示不打断朗读，by AI.Coding。
            .onChange(of: entry) { _, entry in
                if let entry, entry.level < .hint { AccessibilityNotification.Announcement(entry.text).post() }
            }
            // 弹窗依托的内容消失时同步复位，免得残留标志拦截结果区按键与下一次点击，by AI.Coding。
            .onChange(of: multi ? entry?.level == .failure : entry != nil || !model.ignoreDescription.isEmpty) { _, available in
                if !available && model.showingStatusDetail { model.showingStatusDetail = false }
            }
    }
}
/// 单行截断显示最高优先级内容，点按弹出全文与就地操作，by AI.Coding。
private struct HistoryStatusSlot: View {
    @ObservedObject var model: HistoryViewModel
    let entry: HistoryViewModel.StatusEntry?
    let compact: Bool
    var body: some View {
        HStack(spacing: 6) {
            Button { if detailAvailable { model.showingStatusDetail.toggle() } } label: {
                HStack(spacing: 5) {
                    // 正常状态仍保留原底栏“最近忽略”的悬停、键盘与VoiceOver入口，by AI.Coding。
                    if entry == nil, detailAvailable { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    if let entry {
                        if let symbol = Self.symbol(entry.level) { Image(systemName: symbol) }
                        if entry.level == .hint, model.historyFocus == .results, model.settings.defaultAction == .directPaste, let icon = targetIcon {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                        }
                        if !compact { Text(entry.text).lineLimit(1).truncationMode(.tail).foregroundStyle(entry.level == .hint ? Color.secondary : Color.primary) }
                    }
                }.font(.system(size: 11, weight: .medium)).frame(maxWidth: compact ? 28 : .infinity, minHeight: 28, alignment: compact ? .center : .trailing).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(entry.map { Self.tint($0.level) } ?? Color.secondary).disabled(!detailAvailable)
                .help(model.ignoreDescription.isEmpty ? entry?.text ?? "" : model.ignoreDescription)
                .accessibilityLabel(entry?.text ?? HistoryView.statusLabel(model.status))
                .accessibilityHint(entry == nil ? model.ignoreDescription : "")
                .accessibilityHidden(!detailAvailable)
                .popover(isPresented: Binding(get: { model.showingStatusDetail && detailAvailable }, set: { model.showingStatusDetail = $0 }), arrowEdge: .top) {
                    HistoryStatusDetail(model: model, entry: entry)
                }
            // 原底栏“开始监控”与筛选条“结束”一次点击直达；紧凑时收进弹窗，by AI.Coding。
            if !compact, let entry {
                if entry.level == .monitoring && model.recordingPaused { Button("开始监控") { model.resumeRecording() }.buttonStyle(.link).font(.system(size: 11)).fixedSize() }
                if entry.level == .queue { Button("结束") { model.stopPasteQueue() }.buttonStyle(.link).font(.system(size: 11)).fixedSize().accessibilityLabel("结束粘贴队列") }
            }
        }
    }
    private var detailAvailable: Bool { entry != nil || !model.ignoreDescription.isEmpty }
    private var targetIcon: NSImage? { model.target.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon } }
    static func symbol(_ level: HistoryViewModel.StatusEntry.Level) -> String? {
        switch level { case .failure: "exclamationmark.triangle.fill"; case .monitoring: "pause.circle.fill"; case .queue: "list.number"; case .notice: "checkmark.circle.fill"; case .hint: nil }
    }
    static func tint(_ level: HistoryViewModel.StatusEntry.Level) -> Color {
        switch level { case .failure: .orange; case .monitoring: .orange; default: .accentColor }
    }
}
/// 状态全文与下一步操作；“开始监控”“结束队列”在此就地提供，by AI.Coding。
private struct HistoryStatusDetail: View {
    @ObservedObject var model: HistoryViewModel
    let entry: HistoryViewModel.StatusEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry?.text ?? HistoryView.statusLabel(model.status)).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !model.ignoreDescription.isEmpty { Text(model.ignoreDescription).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                if model.recordingPaused { Button("开始监控") { model.resumeRecording(); model.showingStatusDetail = false } }
                if model.pasteQueueActive { Button("结束粘贴队列") { model.stopPasteQueue(); model.showingStatusDetail = false } }
                if model.detailFailed { Button("重试") { model.retryDetail(); model.showingStatusDetail = false } }
                if model.messageSeverity == .failure && !model.message.isEmpty { Button("关闭") { model.dismissMessage() } }
            }.controlSize(.small)
        }.padding(14).frame(width: 300)
    }
}
/// 多选操作条：按钮直接调用右键菜单同一接口；含图片时合并粘贴禁用并说明原因，by AI.Coding。
private struct HistoryMultiSelectBar: View {
    @ObservedObject var model: HistoryViewModel
    let value: HistoryFooterState.Snapshot
    let failure: Bool
    let compact: Bool
    var body: some View {
        let blocked = model.items.contains { value.selectedIDs.contains($0.id) && ($0.kind == .image || $0.kind == .mixed) }
        let favorite = value.selectedItem?.isFavorite == true
        if compact {
            HStack(spacing: 2) {
                if failure { errorButton }
                Menu {
                    joinMenu(blocked)
                    Button("加入粘贴队列") { model.startPasteQueue(model.orderedSelection) }
                    Menu("加入分类") { SelectedCategoryItems(model: model, value: value, divided: true) }.disabled(categoryDisabled)
                    Button(favorite ? "取消收藏" : "收藏") { model.change(.favorites(model.orderedSelection, !favorite)) }.disabled(!model.canDisplayContents)
                    Divider()
                    Button("删除", role: .destructive) { model.change(.delete(model.orderedSelection)) }.disabled(!model.canDisplayContents)
                    Button("取消选择") { model.select(nil) }
                } label: { Text("已选 \(value.selectedCount)").font(.system(size: 12, weight: .medium)) }
                    .menuStyle(.button).buttonStyle(ToolbarTabStyle(selected: true)).fixedSize().accessibilityLabel("已选 \(value.selectedCount) 项操作")
            }
        } else {
            HStack(spacing: 2) {
                if failure { errorButton }
                Text("已选 \(value.selectedCount) 项").font(.system(size: 12, weight: .medium)).lineLimit(1).padding(.trailing, 4)
                Menu { joinItems } label: { barIcon("text.append") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .disabled(blocked).help(blocked ? "合并粘贴：所选内容包含无文本项目" : "合并粘贴").accessibilityLabel("合并粘贴")
                ToolbarIconButton(symbol: "list.number", help: "加入粘贴队列：每按一次 \(HotKeyService.label(model.settings.queueShortcut)) 依次粘贴下一项", label: "加入粘贴队列") { model.startPasteQueue(model.orderedSelection) }
                Menu { SelectedCategoryItems(model: model, value: value, divided: true) } label: { barIcon("folder") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(categoryDisabled).help("加入分类").accessibilityLabel("加入分类")
                ToolbarIconButton(symbol: favorite ? "star.fill" : "star", tint: favorite ? .orange : nil, help: favorite ? "取消收藏" : "收藏") { model.change(.favorites(model.orderedSelection, !favorite)) }
                    .disabled(!model.canDisplayContents)
                ToolbarIconButton(symbol: "trash", help: "删除所选") { model.change(.delete(model.orderedSelection)) }.disabled(!model.canDisplayContents)
                ToolbarIconButton(symbol: "xmark.square", help: "取消选择") { model.select(nil) }
            }
        }
    }
    /// 分类勾选沿用原底栏规则：主选记录元数据未到达时禁用。
    private var categoryDisabled: Bool { !model.canDisplayContents || value.selectedMetadata?.summary.id != value.selectedItem?.id }
    private var errorButton: some View {
        ToolbarIconButton(symbol: "exclamationmark.triangle.fill", tint: .orange, help: "查看错误") { model.showingStatusDetail.toggle() }
            .popover(isPresented: $model.showingStatusDetail, arrowEdge: .top) { HistoryStatusDetail(model: model, entry: model.statusEntry(queryEmpty: true)) }
    }
    @ViewBuilder private func joinMenu(_ blocked: Bool) -> some View {
        Menu("合并粘贴") { joinItems }.disabled(blocked)
    }
    /// 图标菜单直接列出合并方式：一次点击加一次选择，by AI.Coding。
    private var joinItems: some View {
        ForEach(JoinStyle.allCases, id: \.self) { style in
            Button(style.title) { style == .newline ? model.perform() : model.perform(.plainText, join: style) }
        }
    }
    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
    }
}
/// 勾选所选记录已属分类，点按切换；“更多 › 所选记录”与多选操作条共用，by AI.Coding。
private struct SelectedCategoryItems: View {
    let model: HistoryViewModel
    let value: HistoryFooterState.Snapshot
    var divided = false
    var body: some View {
        let selected = value.selectedItem
        ForEach(model.categories) { category in
            let included = value.selectedMetadata?.summary.id == selected?.id && value.selectedMetadata?.categoryIDs.contains(category.id) == true
            Button { if let selected { model.setCategory(selected.id, categoryID: category.id, included: !included) } } label: {
                if included { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
            }
        }
        if divided { Divider() }
        Button("新建分类…") { model.editCategory() }
    }
}
/// “更多 › 所选记录”各项可用性，逐项沿用原底栏规则；无选中时整组禁用，by AI.Coding。
struct SelectedRecordAvailability: Equatable {
    var any, plainCopy, favorite, category, detail, edit: Bool
    init(_ value: HistoryFooterState.Snapshot, canDisplay: Bool, canCopyText: Bool) {
        any = value.selectedID != nil
        plainCopy = any && canCopyText
        favorite = any && canDisplay
        // 分类归属尚未到达时不能把未知当成未加入。
        category = favorite && value.selectedItem != nil && value.selectedMetadata?.summary.id == value.selectedItem?.id
        detail = favorite
        edit = favorite && value.selectedCount == 1 && [ClipKind.text, .url].contains(value.selectedItem?.kind ?? .mixed)
    }
}
/// “更多”菜单：原有项目不变，新增“所选记录”承接原底栏单条操作，键盘与VoiceOver可达，by AI.Coding。
private struct HistoryMoreMenu: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var footer: HistoryFooterState
    @State private var canCopyText = false
    var body: some View {
        let value = footer.snapshot
        let selected = value.selectedItem
        let available = SelectedRecordAvailability(value, canDisplay: model.canDisplayContents, canCopyText: canCopyText)
        Menu {
            // 可用性与原底栏一致；无选中时整组禁用。
            Menu("所选记录") {
                Button("直接粘贴") { model.perform(action: .directPaste) }
                Button("原格式复制") { model.perform(.original, action: .copy) }
                Button("纯文本复制") { model.perform(.plainText, action: .copy) }.disabled(!available.plainCopy)
                Divider()
                Button(selected?.isFavorite == true ? "取消收藏" : "收藏") {
                    if let selected { model.change(.favorites(model.orderedSelection, !selected.isFavorite)) }
                }.disabled(!available.favorite)
                Menu("加入分类") { SelectedCategoryItems(model: model, value: value, divided: true) }.disabled(!available.category)
                Divider()
                Button("详情") { model.showingDetail.toggle() }.disabled(!available.detail)
                Button("编辑内容") { if let id = value.selectedID { model.beginContentEdit(id) } }.disabled(!available.edit)
            }.disabled(!available.any)
            Divider()
            Button(model.recordingPaused ? "开始监控" : "停止监控", action: model.toggleRecording)
            Divider()
            Button(model.settings.hideContents ? "显示内容" : "隐藏内容") { model.updateSettings { $0.hideContents.toggle() } }
            Button("撤销删除 · ⌘Z") { model.undoDeletion() }.disabled(!model.canUndoDeletion)
            Divider()
            Button("设置… · ⌘,") { model.openSettings?() }
            Button("清空普通历史…", role: .destructive) { model.change(.clearOrdinary) }
            Divider(); Button("退出 LocalClip") { model.quitApplication?() }.keyboardShortcut("q", modifiers: .command)
        } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Circle()) }
            // borderlessButton 由 AppKit 按自身尺寸绘制图标，改用 SwiftUI 渲染标签以与相邻按钮同尺寸，by AI.Coding。
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("更多").accessibilityLabel("更多")
            // 只有真实换选/内容变化才重查能力；不能沿用旧组结果，也不因分页或元数据回填闪烁。
            .task(id: value.textCapability) {
                canCopyText = false
                let allowed = await model.canCopyAsText(value.selectedIDs)
                if !Task.isCancelled { canCopyText = allowed }
            }
    }
}
private struct CategoryEditor: View {
    @ObservedObject var model: HistoryViewModel
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.categoryBeingEdited == nil ? "新建分类" : "重命名分类").font(.system(size: 15, weight: .semibold))
            TextField("分类名称", text: $model.categoryDraft).textFieldStyle(.roundedBorder)
                .focused($nameFocused).disabled(model.savingCategory).onSubmit { model.saveCategory() }
            HStack(spacing: 10) {
                ForEach([("34C759","绿色"),("8E8E93","灰色"),("FFCC00","黄色"),("FF3B30","红色"),("007AFF","蓝色"),("AF52DE","紫色")], id: \.0) { hex, name in
                    Button { model.categoryColor = hex } label: { Circle().fill(Color(nsColor: RichContent.colorValue(hex))).frame(width:20,height:20).overlay(Circle().strokeBorder(model.categoryColor == hex ? Color.primary : .clear, lineWidth:2).padding(-3)) }.buttonStyle(.plain)
                        .help(name).accessibilityLabel(name).accessibilityAddTraits(model.categoryColor == hex ? .isSelected : [])
                }
            }
            Text(model.categoryError.isEmpty ? "1–64个字符，名称不能重复" : model.categoryError)
                .font(.system(size: 11)).foregroundStyle(model.categoryError.isEmpty ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("取消") { model.showingCategoryEditor = false }.disabled(model.savingCategory)
                Button(model.savingCategory ? "正在保存…" : model.categoryBeingEdited == nil ? "创建" : "保存") { model.saveCategory() }
                    .buttonStyle(.borderedProminent).disabled(model.savingCategory || model.categoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 300).onAppear { nameFocused = true }
            .onExitCommand { if !model.savingCategory { model.showingCategoryEditor = false } }
    }
}
// 卡片只比较自身显示值，选择/详情变化不使全部卡片反复读取图标和重建内容，by AI.Coding。
struct ClipCard: View, Equatable {
    let item: ClipSummary
    let index: Int
    let selected: Bool
    let dragging: Bool
    let editing: Bool
    let hidden: Bool
    let quickModifiers: UInt32
    @State private var headerRect: CGRect = .zero
    @State private var infoRect: CGRect = .zero
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let height: Double
    let categoryID: String?
    let categories: [ClipCategory]
    let target: TargetToken?
    // 菜单结构依赖作为值传入；其他卡片加入多选也会使当前卡菜单更新。
    let selectionCount: Int
    let selectionHasNonText: Bool
    let queueShortcut: Shortcut
    let model: HistoryViewModel
    let previewGeneration: UUID
    /// 详情读取超过100ms时在本卡详情位置显示小转圈，by AI.Coding。
    var detailPending = false
    /// 按住快速粘贴修饰键时才显示⌘N角标，by AI.Coding。
    var showsQuickBadge = false
    @State private var checkedFileGeneration: UUID?
    @State private var fileVersion: FileReferencePreviewVersion?
    @State private var characterCount: (fingerprint: String?, count: Int)?
    @State private var fileText: String?
    @State private var thumbnailState: ThumbnailPreviewState = .loading
    /// N-01：仅图片/文件记录取值；文件每次进入视口重新查询，不把旧值当作实时值。
    @State private var contentSize: ClipContentSize = .loading
    /// 离屏会丢弃解码状态；缓存命中时直接显示，不经过加载占位，by AI.Coding。
    private var displayedThumbnail: ThumbnailPreviewState {
        if item.kind == .file, checkedFileGeneration != previewGeneration { return .loading }
        if case .loading = thumbnailState, let image = model.thumbnails.object(forKey: item.id as NSString) { return .ready(image) }
        return thumbnailState
    }
    private var thumbnail: NSImage? { displayedThumbnail.image }
    /// 完整路径来自已验证的原始引用；摘要只在加载前用于标题，不能决定预览格式，by AI.Coding。
    private var filePaths: (first: String, count: Int?)? {
        guard item.kind == .file else { return nil }
        if checkedFileGeneration == previewGeneration, let urls = fileVersion?.references, let first = urls.first {
            return (first.path, urls.count)
        }
        let lines = item.preview.split(separator: "\n").map(String.init)
        guard let first = lines.first else { return nil }
        return (first, item.preview.count >= 180 ? nil : lines.count)
    }
    /// 缓存中的空串表示已确认不是文本，不再重复读取。
    private var cachedFileText: String? { checkedFileGeneration == previewGeneration ? model.fileTexts.object(forKey: item.id as NSString).map(String.init) : nil }
    private var displayedFileText: String? { checkedFileGeneration == previewGeneration ? fileText ?? cachedFileText.flatMap { $0.isEmpty ? nil : $0 } : nil }
    /// 第一个文件名加总数，预览文本截断且尚未读取时写“多个”。
    private func fileCaption(_ paths: (first: String, count: Int?), unit: String) -> String {
        let more = (model.fileCounts.object(forKey: item.id as NSString)?.intValue ?? paths.count).map { $0 > 1 ? " 等\($0)\(unit)" : "" } ?? " 等多\(unit)"
        return (paths.first as NSString).lastPathComponent + more
    }
    /// OCR仍沿用图片文件组判断；卡片内容预览独立于此规则，by AI.Coding。
    private var isImageFile: Bool {
        guard item.kind == .file else { return false }
        if checkedFileGeneration == previewGeneration, let urls = fileVersion?.references {
            return !urls.isEmpty && urls.allSatisfy { ClipboardPayload.isImageFile($0.path) }
        }
        let paths = item.preview.split(separator: "\n")
        return !paths.isEmpty && paths.allSatisfy { ClipboardPayload.isImageFile(String($0)) }
    }
    /// 文件已删或无法解码时退回普通文件卡片，不显示图片错误态。
    private var showsFileThumbnail: Bool {
        guard item.kind == .file else { return false }
        switch displayedThumbnail { case .ready: return true; case .loading: return isImageFile; case .failed, .tooLarge: return false }
    }
    // 编辑后可能因搜索条件离开当前列表；缓存键携带内容身份，返回列表也不会显示旧计数，by AI.Coding。
    private var characterCountKey: NSString { "\(item.id):\(item.contentFingerprint ?? "")" as NSString }
    private var displayedCharacterCount: Int? {
        characterCount.flatMap { $0.fingerprint == item.contentFingerprint ? $0.count : nil }
            ?? model.characterCounts.object(forKey: characterCountKey)?.intValue
    }
    @State private var isOnscreen = false
    @State private var detectedLanguage: String?
    @State private var detection: ContentInspector.Detection?
    @State private var hovering = false
    @State private var textHeight: CGFloat = 0
    @State private var fileIcon: NSImage?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.index == rhs.index && lhs.selected == rhs.selected && lhs.dragging == rhs.dragging && lhs.editing == rhs.editing && lhs.hidden == rhs.hidden && lhs.quickModifiers == rhs.quickModifiers && lhs.height == rhs.height
            && lhs.categoryID == rhs.categoryID && lhs.categories == rhs.categories && lhs.target == rhs.target
            && lhs.selectionCount == rhs.selectionCount && lhs.selectionHasNonText == rhs.selectionHasNonText && lhs.queueShortcut == rhs.queueShortcut
            && (lhs.item.kind != .file || lhs.previewGeneration == rhs.previewGeneration) && lhs.detailPending == rhs.detailPending
            && lhs.showsQuickBadge == rhs.showsQuickBadge
    }
    private var code: Bool { item.kind == .text && detectedLanguage != nil }
    /// 代码上限12.5pt，普通文本沿用原字号与紧凑布局，by AI.Coding。
    private var previewFontSize: CGFloat {
        let size: CGFloat = tiny ? 10 : height < 200 ? 12 : height < 260 ? 13 : 15
        return detectedLanguage == nil ? size : min(size, 12.5)
    }
    /// 卡片合并辅助功能子元素后仍朗读预览状态；隐藏内容时不泄露状态或正文。
    /// 大小只附加在原有次级信息之后，不替换类型、次数等字段；隐藏内容时不显示。
    private var sizeLabel: String? { [.image, .file].contains(item.kind) && !hidden ? contentSize.label : nil }
    /// 按类型给出度量：文本/链接为字数，图片为大小，文件为项数与大小或“文件夹”；复制次数见详情，by AI.Coding。
    private var footerText: String {
        switch item.kind {
        case .text, .url: return displayedCharacterCount.map { "\($0) 字" } ?? ""
        case .image: return sizeLabel ?? ""
        case .mixed: return "混合内容"
        case .file:
            guard !hidden, case let .files(known, count, unknown, folders) = contentSize else { return sizeLabel ?? "文件引用" }
            if folders == count { return count == 1 ? "文件夹" : "\(count) 个文件夹" }
            return "\(count) 项 · " + (unknown + folders == count ? "大小未知" : HistoryViewModel.bytes(known))
        }
    }
    /// 仅文本与代码在内容溢出时加底部渐隐，图片与短文本不被遮住，by AI.Coding。
    private var fadesBody: Bool {
        !tiny && (item.kind == .text || displayedFileText != nil) && !showsFileThumbnail && textHeight > max(0, height - headerHeight - footerHeight) + 0.5
    }
    /// 仅为颜色值的文本铺满该颜色；明度决定黑或白字，by AI.Coding。
    private var colorValue: (color: Color, dark: Bool)? {
        guard !hidden, item.kind == .text, case .color(let value)? = detection,
              !item.preview.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isWhitespace) else { return nil }
        func linear(_ channel: Int) -> Double { let c = Double(channel) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
        return (Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255, opacity: value.alpha), luminance > 0.179)
    }
    private var accessibilityDescription: String {
        let title = "\(item.title ?? HistoryView.kindName(item.kind))，\(item.source.name)"
        if hidden { return title + "，内容已隐藏" }
        if let sizeLabel { return Self.describe(item, thumbnail: displayedThumbnail.label, detection: detection) + "，" + (contentSize.detail.map { $0 + "：" } ?? "") + sizeLabel }
        return Self.describe(item, thumbnail: displayedThumbnail.label, detection: detection)
    }
    private static func describe(_ item: ClipSummary, thumbnail: String, detection: ContentInspector.Detection?) -> String {
        let title = "\(item.title ?? HistoryView.kindName(item.kind))，\(item.source.name)"
        if item.kind == .image || item.kind == .mixed { return title + "，" + item.preview + "，" + thumbnail }
        return title + (detection.map { "，\($0.kindName) \($0.badge)" } ?? "") + "，" + item.preview
    }
    private var tint: Color { switch item.kind {
        // 文本与链接色相拉开，且都不同于选中强调色，选中环不会与标题栏混在一起，by AI.Coding。
        case .text: Color(red: 0.36, green: 0.38, blue: 0.80)
        case .url: Color(red: 0.11, green: 0.55, blue: 0.80)
        case .image: Color(red: 0.24, green: 0.62, blue: 0.55)
        case .file: Color(red: 0.35, green: 0.49, blue: 0.70)
        case .mixed: Color(red: 0.73, green: 0.53, blue: 0.25) } }
    /// 来源图标主色校正后的实色头部；无来源图标回退到校正后的类型色，by AI.Coding。
    private var headerColor: Color {
        if let id = item.source.bundleID, let color = SourceApplicationObserver.headerColor(for: id) { return Color(nsColor: color) }
        return Color(nsColor: SourceApplicationObserver.headerColor(fallback: "\(item.kind)", base: NSColor(tint)))
    }
    private var appIcon: NSImage? {
        guard let id = item.source.bundleID else { return nil }
        return SourceApplicationObserver.icon(for: id)
    }
    private var tiny: Bool { height < 130 }
    // 来源只是辅助信息，缩小标题与图标，把固定方形卡片的高度优先留给正文。
    private var headerHeight: Double { tiny ? 28 : height < 150 ? 32 : 40 }
    private var footerHeight: Double { tiny ? 18 : 22 }
    private var iconSize: Double { tiny ? 18 : 26 }
    // 圆角为原来的一半，卡片更规整，by AI.Coding。
    private var cardRadius: Double { min(11, height * 0.06) }
    /// 展示身份与依据分开，前台推断不伪装成应用主动声明。
    private var sourceDescription: String {
        switch item.source.basis {
        case "frontmost": "来源：\(item.source.name)（复制时前台应用推断）"
        case "declared": "来源：\(item.source.name)（应用声明）"
        default: "来源未知"
        }
    }
    /// 编辑状态只由本卡片订阅，输入字符不发布整个历史模型，by AI.Coding。
    private var cardTitle: some View {
        Group {
            if editing {
                TextField("名称", text: Binding(get: { nameDraft }, set: {
                    if nameDraft != $0 { nameDraft = $0; model.renameDraftChanged(id: item.id) }
                })).textFieldStyle(.plain).focused($nameFocused)
                    .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                    .onSubmit { model.saveRename(id: item.id, title: nameDraft) }
                    .onExitCommand { model.cancelRename() }
            } else { Text(item.title ?? languageTitle ?? HistoryView.kindName(item.kind)) }
        }.font(.system(size: tiny ? 10 : height < 150 ? 12 : 14, weight: .semibold)).lineLimit(1)
    }
    /// 识别出代码语言时以语言名替换"文本"；隐藏内容时不透露，by AI.Coding。
    private var languageTitle: String? {
        guard !hidden, item.kind == .text else { return nil }
        return detectedLanguage.flatMap { ContentInspector.languageNames[$0] }
    }
    /// 初始化编辑内容，不把种类默认标题误存成自定义名称，by AI.Coding。
    private func startNameEditing() { nameDraft = item.title ?? ""; nameFocused = true }
    private var cardBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: tiny ? 4 : 7) {
                VStack(alignment: .leading, spacing: 2) {
                    cardTitle
                    if height >= 150 {
                        CopyAge(copiedAt: item.lastCopiedAt)
                            .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)

                    }
                }
                Spacer(minLength: 2)
                if let detection, !hidden, !tiny { DetectionBadge(detection: detection) }
                if item.isFavorite && !tiny {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.orange)
                        .background { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.white).scaleEffect(1.12) }
                        .accessibilityLabel("已收藏")
                }
                // 应用图标自带外形，直接显示不再垫白底；系统图标四周留有透明边距，略放大与标题对齐，by AI.Coding。
                Group {
                    if let appIcon { Image(nsImage: appIcon).resizable().interpolation(.high).scaledToFit().scaleEffect(1.12) }
                    else { Image(systemName: symbol).font(.system(size: tiny ? 11 : 15, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
                }.frame(width: iconSize, height: iconSize).help(sourceDescription)
            }.foregroundStyle(.white).padding(.leading, tiny ? 8 : 14).padding(.trailing, tiny ? 6 : 10)
                .frame(height: headerHeight).background(headerColor)
                .help("双击标题栏重命名卡片")
                // 整个彩色标题栏双击均重命名，时间/图标/留白不能误发粘贴，by AI.Coding。
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(item.id)) } action: { headerRect = $0 }
            // 正文独占剩余区域；长文件名和多行文字只能在正文内截断，不挤掉标题和底栏。
            GeometryReader { region in
                cardContent.frame(width: region.size.width, height: region.size.height, alignment: .topLeading).clipped()
            }.frame(height: max(0, height - headerHeight - footerHeight))
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        if fadesBody { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16) }
                    }
                }
            HStack(spacing: 4) {
                Text(footerText).lineLimit(1)
                Spacer(minLength: 2)
                // 编辑、详情、收藏三个固定槽位始终占位，悬停或选中才显示，度量文字与角标位置不随之移动，by AI.Coding。
                if !tiny {
                    HStack(spacing: 0) {
                        Group {
                            if [ClipKind.text, .url].contains(item.kind) {
                                Button {
                                    if !model.selectedIDs.contains(item.id) { model.select(item.id) }
                                    model.beginContentEdit(item.id)
                                } label: { slotIcon("square.and.pencil") }
                                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("编辑内容 · ⌘E").accessibilityLabel("编辑内容")
                            } else { Color.clear.frame(width: 24, height: 24) }
                            Button { model.showDetail(id: item.id) } label: {
                                if detailPending { ProgressView().controlSize(.mini).frame(width: 24, height: 24) } else { slotIcon("info.circle") }
                            }.buttonStyle(.plain).foregroundStyle(Color.accentColor).help("详情 · ⌘I").accessibilityLabel(detailPending ? "正在准备预览" : "详情")
                            Button { model.change(.favorites(model.selectedIDs.contains(item.id) ? model.orderedSelection : [item.id], !item.isFavorite)) } label: {
                                slotIcon(item.isFavorite ? "star.fill" : "star")
                            }.buttonStyle(.plain).foregroundStyle(item.isFavorite ? Color.orange : Color.accentColor).help(item.isFavorite ? "取消收藏" : "收藏").accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
                        }
                    }.opacity(slotsVisible ? 1 : 0).allowsHitTesting(slotsVisible).accessibilityHidden(!slotsVisible)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(item.id)) } action: { infoRect = $0 }
                }
                if index < 9 && !tiny {
                    Text(HotKeyService.label(Shortcut(keyCode: [18,19,20,21,23,22,26,28,25][index], modifiers: quickModifiers)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
                        .opacity(showsQuickBadge ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsQuickBadge)
                        .accessibilityHidden(true)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, tiny ? 8 : 12)
                .frame(height: footerHeight)
        }.frame(width: height, height: height).background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7))
            // 选中用卡片外侧的强调色环，与任何类型标题色都可区分；悬停仅轻微抬升，by AI.Coding。
            .overlay {
                if selected { RoundedRectangle(cornerRadius: cardRadius + 4, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4) }
            }
            .shadow(color: .black.opacity(hovering && !selected ? 0.16 : 0.09), radius: hovering && !selected ? 7 : 3, y: hovering && !selected ? 4 : 2)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .coordinateSpace(name: item.id)
            // 只识别≤180字符预览；预览达到上限视为被截断，只认JWT头部，by AI.Coding。
            .task(id: item.preview) {
                detection = item.kind == .text ? ContentInspector.inspect(item.preview, truncated: item.preview.count >= 180) : nil
            }
    }
    private var interactiveCard: some View {
        cardBody
            // 原生桥必须有明确卡片尺寸，否则透明NSView会占满滚动视口并误认其他卡片，by AI.Coding。
            .background(HistoryDragBridge(model: model, id: item.id, headerRect: headerRect, passThroughRect: slotsVisible ? infoRect : .zero).frame(width: height, height: height))
            .background {
                #if DEBUG
                if GUIAcceptanceProbe.configuration != nil, index == 0 {
                    GUIRenderWitness(displayCycle: model.focusRequest, query: model.query, generation: model.guiQueryGeneration, first: item.preview, firstID: item.id, firstImage: item.kind == .image, ready: item.kind != .image || thumbnail != nil, loading: model.historyBusy).frame(width: 1, height: 1)
                }
                #else
                EmptyView()
                #endif
            }
            .scaleEffect(dragging ? 0.96 : 1)
            .opacity(dragging ? 0.55 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: dragging)
            .help((item.kind == .file ? "双击复制到Finder当前目录或原应用" : "单击选择，双击粘贴到：\(MacApplicationClient.targetName(model.target))") + quickPasteHelp)
            // 隐藏内容时辅助功能也不朗读正文，与界面模糊保持同一隐私承诺，by AI.Coding。
            // 每张卡片只暴露一个可操作元素；重命名时保留原生输入框，by AI.Coding。
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityLabel(accessibilityDescription).accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { model.select(item.id) }
            .accessibilityAction(named: Text("复制并粘贴")) { model.doubleClick(item.id) }
            .accessibilityAction(named: Text("重命名")) { model.beginRename(item.id) }
            .accessibilityAction(named: Text("编辑内容")) { model.beginContentEdit(item.id) }
            // 原底栏按钮迁为卡片命名动作，可用性与原底栏一致，by AI.Coding。
            .accessibilityActions {
                ForEach(Self.voiceOverActions(kind: item.kind, hidden: hidden, favorite: item.isFavorite), id: \.self) { name in
                    Button(name) { performVoiceOverAction(name) }
                }
            }
            .onChange(of: editing) { _, active in if active { startNameEditing() } else { nameFocused = false } }
            .onChange(of: nameFocused) { _, focused in if !focused && model.renamingID == item.id { model.cancelRename() } }
            .onAppear { if editing { startNameEditing() } }
    }
    private var slotsVisible: Bool { (hovering || selected || detailPending) && !hidden }
    private func slotIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    /// 角标只在按住修饰键时出现，悬停说明仍写明快速粘贴键，可发现性不降为零，by AI.Coding。
    private var quickPasteHelp: String {
        index < 9 ? "\n\(HotKeyService.label(Shortcut(keyCode: [18,19,20,21,23,22,26,28,25][index], modifiers: quickModifiers))) 快速粘贴第 \(index + 1) 条" : ""
    }
    /// 隐藏内容只留原格式复制；无文本类型不提供纯文本复制，by AI.Coding。
    static func voiceOverActions(kind: ClipKind, hidden: Bool, favorite: Bool) -> [String] {
        if hidden { return ["原格式复制"] }
        return ["详情", favorite ? "取消收藏" : "收藏", "原格式复制"] + (kind == .image ? [] : ["纯文本复制"]) + ["直接粘贴"]
    }
    private func performVoiceOverAction(_ name: String) {
        if !model.selectedIDs.contains(item.id) { model.select(item.id) }
        switch name {
        case "详情": model.showDetail(id: item.id)
        case "收藏", "取消收藏": model.change(.favorites(model.orderedSelection, !item.isFavorite))
        case "原格式复制": model.perform(.original, action: .copy)
        case "纯文本复制": model.perform(.plainText, action: .copy)
        default: model.perform(action: .directPaste)
        }
    }
    /// 菜单独立展开，避免单个SwiftUI泛型表达式超出编译器推断范围，by AI.Coding。
    private var menuCard: some View {
        interactiveCard.contextMenu {
                Button("原格式复制") { if !model.selectedIDs.contains(item.id) { model.select(item.id) }; model.perform(.original, action: .copy) }
                // 与原格式复制共用选择规则和输出管线；无文本项由整组校验拒绝，绝不静默跳过。
                Button("纯文本复制") { if !model.selectedIDs.contains(item.id) { model.select(item.id) }; model.perform(.plainText, action: .copy) }.disabled(hidden)
                Button("直接粘贴") { if !model.selectedIDs.contains(item.id) { model.select(item.id) }; model.perform(action: .directPaste) }.disabled(hidden)
                Button("转换后粘贴… · ⌘T") { if !model.selectedIDs.contains(item.id) { model.select(item.id) }; model.showTransformMenu() }
                    .disabled(item.kind == .image || item.kind == .file)
                if item.kind == .image || item.kind == .mixed || isImageFile { Button("复制图中文字") { model.copyImageText(id: item.id) }.disabled(hidden) }
                // 多选时才出现；换行沿用原有合并（含原格式），其余只输出纯文本；含图片时整组置灰，by AI.Coding。
                if selectionCount > 1 && selected {
                    let blocked = selectionHasNonText
                    Menu("合并粘贴") {
                        ForEach(JoinStyle.allCases, id: \.self) { style in
                            Button(style.title) { style == .newline ? model.perform() : model.perform(.plainText, join: style) }
                        }
                    }.disabled(blocked).help(blocked ? "所选内容包含无文本项目" : "按所选方式合并后粘贴")
                    Button("加入粘贴队列") { model.startPasteQueue(model.orderedSelection) }
                        .help("每按一次 \(HotKeyService.label(model.settings.queueShortcut)) 依次粘贴下一项")
                }
                // 输出、整理、检视各自分组，保留全部已有菜单项，by AI.Coding。
                Divider()
                Button("编辑内容… · ⌘E") {
                    if !model.selectedIDs.contains(item.id) { model.select(item.id) }
                    model.beginContentEdit(item.id)
                }
                    .disabled(hidden || ![ClipKind.text, .url].contains(item.kind))
                Button("重命名") { model.beginRename(item.id) }
                Button(item.isFavorite ? "取消收藏" : "收藏") { model.change(.favorites(model.selectedIDs.contains(item.id) ? model.orderedSelection : [item.id], !item.isFavorite)) }
                Menu("加入分类") {
                    ForEach(model.categories) { category in Button(category.name) { model.setCategory(item.id, categoryID: category.id, included: true) } }
                    Divider(); Button("新建分类…") { model.editCategory() }
                }
                if let categoryID { Button("从当前分类移除") { model.setCategory(item.id, categoryID: categoryID, included: false) } }
                if categoryID != nil { Button("向前移动") { model.select(item.id); model.moveSelected(-1) }; Button("向后移动") { model.select(item.id); model.moveSelected(1) } }
                Divider()
                Button("在历史中定位 · ⌘G") { model.select(item.id); model.jumpToHistory() }
                Menu("在分类中定位") { ForEach(categories) { category in Button(category.name) { model.select(item.id); model.jumpToHistory(category: category.id) } } }
                // 显式详情入口同步完成选择，再开启目标详情。
                Button("详情") { model.showDetail(id: item.id) }
                Button("预览 · Space") { model.select(item.id); model.quickLook() }
                Button("打开 · ⌘O") { model.select(item.id); model.openSelected() }
                if item.kind != .file { Button("存储为文件…") { model.select(item.id); model.saveSelectedToFile() } }
                if item.kind == .file { Button("在Finder中显示") { model.select(item.id); model.openSelected(reveal: true) }; Button("打开方式…") { model.select(item.id); model.openSelected(withApplication: true) } }
                Divider(); Button("删除", role: .destructive) { model.change(.delete(model.selectedIDs.contains(item.id) ? model.orderedSelection : [item.id])) }
            }
    }
    var body: some View {
        menuCard
            // LazyHStack可能提前创建邻近卡片；正文/图片任务只在真实可见时运行，离屏释放解码图，by AI.Coding。
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isOnscreen = visible
                model.thumbnailVisibilityChanged(id: item.id, visible: visible)
                if !visible { if item.kind == .file { checkedFileGeneration = nil; contentSize = .loading; fileIcon = nil }; model.cancelRename(id: item.id); thumbnailState = .loading; Task { await model.derived.cancel(id: item.id) } }
            }
            .task(id: [String(isOnscreen), item.kind == .file ? previewGeneration.uuidString : item.contentFingerprint ?? "immutable"]) {
                guard isOnscreen else { return }
                // 文本内容身份变化重新取计数，不能仅凭截断预览判断是否更新，by AI.Coding。
                if [.text, .url].contains(item.kind) { characterCount = nil }
                // 外部文件每次进入视口/重开面板先验证身份；慢卷期间只显示占位，by AI.Coding。
                if item.kind == .file {
                    checkedFileGeneration = nil
                    let urls = try? await model.previewDetail(id: item.id).payload.fileURLs
                    let version = await Task.detached(priority: .utility) { urls.flatMap(FileReferencePreviewVersion.read) }.value
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    // 大小与预览身份分开：目录或不可读文件没有预览版本，仍可给出“未知/文件夹”而不影响其他功能。
                    let size = await Task.detached(priority: .utility) { urls.map(ClipContentSize.measure) ?? .unknown }.value
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    contentSize = size
                    if let path = urls?.first?.path { fileIcon = await Task.detached(priority: .utility) { NSWorkspace.shared.icon(forFile: path) }.value }
                    if !model.validateFilePreview(id: item.id, version: version) {
                        fileText = nil; thumbnailState = .loading
                    }
                    fileVersion = version; checkedFileGeneration = previewGeneration
                    guard let version, let url = version.references.first else { thumbnailState = .failed; return }
                    model.fileCounts.setObject(version.references.count as NSNumber, forKey: item.id as NSString)
                    if displayedFileText != nil || thumbnail != nil { return }
                    // 图片、文本和常见文档共用内容预览入口，文本解码失败不能提前吞掉图片/文档预览。
                    let result = await FileCardPreview.render(fileAt: url)
                    guard !Task.isCancelled, model.contains(item.id),
                          (try? await model.previewMetadata(id: item.id)) != nil else { return }
                    guard await Task.detached(priority: .utility, operation: { version.isCurrent() }).value,
                          !Task.isCancelled else { thumbnailState = .failed; return }
                    switch result {
                    case .text(let text):
                        fileText = text
                        model.fileTexts.setObject(text as NSString, forKey: item.id as NSString)
                    case .image(let data):
                        thumbnailState = ThumbnailPreviewState(.image(data))
                        if let image = thumbnailState.image { model.thumbnails.setObject(image, forKey: item.id as NSString, encodedBytes: data.count) }
                    case .unavailable: thumbnailState = .failed
                    }
                    return
                }
                if item.kind == .image, contentSize == .loading {
                    let size = try? await model.previewImageSize(id: item.id)
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    contentSize = size.map { .stored(bytes: $0.bytes, items: $0.items) } ?? .unknown
                }
                // 只为实际出现的文字卡片统计全文，计数缓存不随选中状态重算。
                if [.text, .url].contains(item.kind), displayedCharacterCount == nil {
                    let count = try? await model.previewCharacterCount(id: item.id)
                    guard !Task.isCancelled, model.contains(item.id),
                          (try? await model.previewMetadata(id: item.id)) != nil else { return }
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    characterCount = count.map { (item.contentFingerprint, $0) }
                    if let count { model.characterCounts.setObject(count as NSNumber, forKey: characterCountKey) }
                }
                guard item.kind == .image || item.kind == .mixed, thumbnail == nil else { return }
                // 可见即自动加载；失败必须退出加载态，不把错误伪装成等待用户操作。
                thumbnailState = .loading
                let result = await model.derived.thumbnail(id: item.id)
                guard !Task.isCancelled, model.contains(item.id) else { return }
                do { _ = try await model.previewMetadata(id: item.id) }
                catch {
                    if !Task.isCancelled, model.contains(item.id) { thumbnailState = .failed }
                    return
                }
                guard !Task.isCancelled, model.contains(item.id) else { return }
                thumbnailState = ThumbnailPreviewState(result)
                if let image = thumbnailState.image, case .image(let data) = result {
                    model.thumbnails.setObject(image, forKey: item.id as NSString, encodedBytes: data.count)
                }
                #if DEBUG
                if thumbnail != nil { GUIAcceptanceProbe.imageReadyIDs.insert(item.id) }
                #endif
            }.onDisappear {
                model.thumbnailVisibilityChanged(id: item.id, visible: false)
                model.cancelRename(id: item.id); thumbnailState = .loading; characterCount = nil
                Task { await model.derived.cancel(id: item.id) }
            }
    }
    @ViewBuilder private var cardContent: some View {
        if showsFileThumbnail {
            VStack(spacing: 0) {
                ThumbnailPreview(state: displayedThumbnail, tint: tint, compact: tiny)
                if !tiny, let paths = filePaths {
                    Text(fileCaption(paths, unit: isImageFile ? "张" : "个")).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        } else if let text = displayedFileText, let paths = filePaths {
            VStack(spacing: 0) {
                SyntaxText(text: text, size: previewFontSize, spacing: tiny ? 0 : 3, onLanguage: { detectedLanguage = $0 })
                    .lineSpacing(tiny ? 0 : 3).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height + 28 } action: { textHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                    .padding(.horizontal, tiny ? 6 : height < 200 ? 10 : 14).padding(.top, tiny ? 3 : 10).padding(.bottom, tiny ? 0 : 4)
                if !tiny {
                    Text(fileCaption(paths, unit: "个")).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        } else if tiny && item.kind == .file {
            Text(((item.preview.split(separator: "\n").first.map(String.init) ?? "文件引用") as NSString).lastPathComponent)
                .font(.system(size: 10)).lineLimit(1).padding(.horizontal, 6).padding(.top, 3)
        } else if item.kind == .file {
            // 不可预览文件、目录与失效文件居中显示系统图标与文件名，正文不再空白，by AI.Coding。
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Group {
                    if let fileIcon { Image(nsImage: fileIcon).resizable().interpolation(.high).scaledToFit() }
                    else { Image(systemName: "doc").font(.system(size: 34, weight: .light)).foregroundStyle(tint) }
                }.frame(width: height < 200 ? 40 : 56, height: height < 200 ? 40 : 56).accessibilityHidden(true)
                if let paths = filePaths {
                    Text(fileCaption(paths, unit: "个")).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                }
                if let status = fileStatus { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12)
        } else if let colorValue {
            ZStack {
                Rectangle().fill(colorValue.color)
                Text(item.preview.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colorValue.dark ? Color.black : Color.white)
            }
        } else if item.kind == .image || item.kind == .mixed {
            ThumbnailPreview(state: displayedThumbnail, tint: tint, compact: tiny)
        } else if tiny && item.kind == .url {
            Text(ClipboardPayload.webLink(item.preview)?.host ?? item.context).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 6).padding(.top, 3)
        } else if item.kind == .url {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: "link").font(.system(size: 22, weight: .light)).foregroundStyle(tint); Text(ClipboardPayload.webLink(item.preview)?.host ?? "链接").font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1); Text(item.context).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4); Spacer(minLength: 0) }.padding(14)
        } else {
            // 卡片正文自动高亮代码，普通内容保持原有排版，by AI.Coding。
            SyntaxText(text: item.context, size: previewFontSize, spacing: tiny ? 0 : 3, onLanguage: { detectedLanguage = $0 })
                .lineSpacing(tiny ? 0 : 3).frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, tiny ? 6 : height < 200 ? 10 : 14).padding(.top, tiny ? 3 : 10).padding(.bottom, tiny ? 0 : 4)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
        }
    }

    /// 目录与失效文件给出状态文字；可读普通文件不加说明，by AI.Coding。
    private var fileStatus: String? {
        guard case let .files(_, count, unknown, folders) = contentSize else { return nil }
        if folders == count { return "文件夹" }
        return unknown == count ? "文件已移动、删除或无法访问" : nil
    }
    private var symbol: String { code ? "chevron.left.forwardslash.chevron.right" : HistoryView.kindSymbol(item.kind) }
}
// 复制时间只按分钟更新，紧凑卡片不被秒数长文本挤压，by AI.Coding。
private struct CopyAge: View {
    let copiedAt: Instant
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.label(seconds: max(0, Int(context.date.timeIntervalSince1970) - Int(copiedAt / 1000))))
        }
    }
    /// 相对时间使用单个最大单位，保持标题区域稳定。
    private static func label(seconds: Int) -> String {
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60)分钟前" }
        if seconds < 86400 { return "\(seconds / 3600)小时前" }
        return "\(seconds / 86400)天前"
    }
}
// 文本/链接详情与编辑共享固定外框，其他类型保持原有自适应布局，by AI.Coding。
struct ClipInspector: View {
    @ObservedObject var model: HistoryViewModel
    /// 中间信息区最大高度；整窗约为此值加标题与按钮的120pt。
    static let maxInfoHeight: CGFloat = 520
    /// 仅文本和链接使用编辑框尺寸；图片、文件与混合内容不改变展示方式，by AI.Coding。
    private var usesTextLayout: Bool {
        model.detail?.summary.kind == .text || model.detail?.summary.kind == .url
    }
    /// 正文与附加信息在固定气泡内滚动，标题和底部操作始终可见，by AI.Coding。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detail = model.detail {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.summary.title ?? HistoryView.kindName(detail.summary.kind)).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text("\(detail.summary.source.name) · \(detail.summary.source.basis == "frontmost" ? "复制时前台应用推断" : detail.summary.source.basis == "declared" ? "应用声明" : "来源未知")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // 中间信息区封顶，超出在区内滚动；标题与操作按钮始终可见，弹窗不随识别行数无限增高，by AI.Coding。
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                preview(detail)
                if let inspection = model.detailInspection, !model.settings.hideContents { InspectionSection(model: model, detail: detail, inspection: inspection) }
                if !model.previewMessage.isEmpty { Text(model.previewMessage).font(.caption).foregroundStyle(.secondary) }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("大小", "\(detail.payload.items.count) 项 · \(HistoryViewModel.bytes(detail.payload.byteCount))")
                    row("复制", "\(detail.summary.copyCount) 次 · 最近 \(Date(timeIntervalSince1970: Double(detail.summary.lastCopiedAt)/1000).formatted(date: .abbreviated, time: .shortened))")
                    row("格式", detail.payload.items.flatMap { $0.representations.map(\.type) }.sorted().joined(separator: ", "))
                }.font(.caption)
                let notes = (detail.summary.kind == .file ? ["保存的是文件引用，未备份文件本体；移动或删除原件后请重新复制。Finder中双击会复制副本到当前实际文件夹，同名冲突会停止，不覆盖已有文件。"] : [])
                    + (detail.payload.items.contains(where: { !Set($0.declaredTypes).subtracting(SupportedType.all).isEmpty }) ? ["仅保留支持格式，附加私有格式未保存"] : [])
                if !notes.isEmpty {
                    Label(notes.joined(separator: "\n"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: usesTextLayout ? .infinity : Self.maxInfoHeight)
                    .fixedSize(horizontal: false, vertical: !usesTextLayout)
                Divider()
                HStack(spacing: 8) {
                    Button(role: .destructive) { model.change(.delete([detail.summary.id])) } label: { Label("删除", systemImage: "trash").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                    Spacer()
                    let hasOCR = detail.summary.kind == .image || detail.summary.kind == .mixed || detail.payload.fileURLs?.contains(where: { ClipboardPayload.isImageFile($0.path) }) == true
                    if hasOCR {
                        Button { model.copyImageText(id: detail.summary.id, fromDetail: true) } label: { Label("复制图中文字", systemImage: "text.viewfinder") }
                            .buttonStyle(ToolbarTabStyle(selected: true)).disabled(model.settings.hideContents).help("识别图片中的文字并复制")
                    }
                    // 详情内可一键切入同卡原位编辑；混合记录仍保留原有文字转换入口，by AI.Coding。
                    if [ClipKind.text, .url].contains(detail.summary.kind), model.detailEditable {
                        Button { model.beginContentEdit(detail.summary.id) } label: { Label("编辑", systemImage: "square.and.pencil") }
                            .buttonStyle(ToolbarTabStyle(selected: true)).disabled(model.settings.hideContents).help("编辑内容 · ⌘E")
                    }
                    if detail.summary.kind != .image && (!hasOCR || detail.payload.plainText != nil) {
                        Button { model.showTransformMenu(ids: [detail.summary.id]) } label: { Label("转换", systemImage: "wand.and.stars") }
                            .buttonStyle(ToolbarTabStyle(selected: true)).disabled(detail.payload.plainText == nil).help("转换后粘贴 · ⌘T")
                    }
                    // 默认输出格式为主按钮，放在最右侧，与面板 Return 的默认结果一致，by AI.Coding。
                    if model.settings.defaultFormat == .plainText { copyButton("原格式复制", .original, enabled: true); copyButton("纯文本复制", .plainText, enabled: detail.payload.plainText != nil) }
                    else { copyButton("纯文本复制", .plainText, enabled: detail.payload.plainText != nil); copyButton("原格式复制", .original, enabled: true) }
                }
            } else if model.detailLoading { ProgressView("正在读取完整内容…").frame(maxWidth: .infinity).frame(height: 220) }
            else { ContentUnavailableView("内容已变化", systemImage: "doc.text.magnifyingglass", description: Text("请选择仍存在的历史条目。")).frame(height: 220) }
        }.padding(usesTextLayout ? ClipContentLayout.padding : 20)
            .frame(width: ClipContentLayout.size.width, height: usesTextLayout ? ClipContentLayout.size.height : nil, alignment: .topLeading)
            .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }
    /// 预览放入浅底圆角容器；文件显示图标、名称与所在文件夹，不把路径当代码高亮，by AI.Coding。
    @ViewBuilder private func preview(_ detail: ClipDetail) -> some View {
        let urls = detail.summary.kind == .file ? detail.payload.fileURLs ?? [] : []
        let text = model.richPreview
        if model.image != nil || !urls.isEmpty || text != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let image = model.image {
                    LiveTextImage(image: image, interactive: !model.settings.hideContents)
                        .aspectRatio(image.size.width > 0 && image.size.height > 0 ? image.size : CGSize(width: 1, height: 1), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: text == nil ? 220 : 150).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                ForEach(Array(urls.prefix(4).enumerated()), id: \.offset) { _, url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if urls.count > 4 { Text("另有 \(urls.count - 4) 个文件").font(.caption).foregroundStyle(.secondary) }
                if let text {
                    // LC-F01：高度计算只测量短文，长文直接使用滚动视口；传入预览的全文保持不变，by AI.Coding。
                    SyntaxDetailPreview(content: text, highlight: model.detailHighlight)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
    /// 主按钮沿用面板蓝色胶囊，次按钮沿用工具栏标签胶囊，by AI.Coding。
    @ViewBuilder private func copyButton(_ title: String, _ format: OutputFormat, enabled: Bool) -> some View {
        if model.settings.defaultFormat == format {
            Button { model.perform(format, action: .copy) } label: {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 28)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7)).contentShape(Capsule())
            }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
        } else { Button(title) { model.perform(format, action: .copy) }.buttonStyle(ToolbarTabStyle(selected: true)).disabled(!enabled) }
    }
}
// 筛选按来源/日期/分类分组，与设置同一原生分组表单样式，by AI.Coding。
struct FilterEditor: View {
    @ObservedObject var model: HistoryViewModel
    @State private var contentHeight: CGFloat = 320
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("来源") {
                    Picker("来源", selection: Binding(get: { model.sourceFilter ?? "*" }, set: { model.sourceFilter = $0 == "*" ? nil : $0 })) {
                        Text("全部来源").tag("*")
                        ForEach(Array(model.sourceSuggestions.enumerated()), id: \.offset) { _, source in Text(source.name).tag(source.bundleID ?? "") }
                    }
                }
                Section {
                    Toggle("限定复制日期", isOn: $model.dateFilterEnabled)
                    Group {
                        DatePicker("从", selection: $model.dateFrom, displayedComponents: .date)
                        DatePicker("至", selection: $model.dateUntil, displayedComponents: .date)
                    }.disabled(!model.dateFilterEnabled)
                } header: { Text("日期") } footer: {
                    Text("日期按本机日历；类型与自定义分类互斥，来源和日期作用于当前范围。").settingsFootnote()
                }
                if !model.categories.isEmpty {
                    Section("分类") {
                        ForEach(model.categories) { category in Toggle(category.name, isOn: Binding(get: { model.activeCategories.contains(category.id) }, set: { included in var values = model.activeCategories; if included { values.insert(category.id) } else { values.remove(category.id) }; model.selectCategories(values) })) }
                    }
                }
            }.formStyle(.grouped)
                // 使用真实表单高度；大量分类保留滚动条，不挤压底部按钮，by AI.Coding。
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                    if height > 0 { contentHeight = height }
                }
                .scrollIndicators(.visible)
                .frame(height: min(460, max(contentHeight, model.categories.isEmpty ? 300 : 320 + CGFloat(model.categories.count) * 36)))
            Divider()
            HStack { Button("清除筛选") { model.clearHistoryFilters() }; Spacer(); Button("完成") { model.showingFilters = false; model.focusResults?() } }
                .padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 360)
    }
}

/// 工具栏标签统一样式：选中为浅色胶囊，未选中次要色并带悬停反馈，by AI.Coding。
struct ToolbarTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { TabBody(configuration: configuration, selected: selected) }
    struct TabBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.primary.opacity(selected ? 0.09 : configuration.isPressed ? 0.08 : hovering ? 0.05 : 0), in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}
/// 工具栏图标按钮：无圆圈SF Symbols、14pt次要色、统一28pt命中区与悬停底色，by AI.Coding。
struct ToolbarIconButton: View {
    let symbol: String
    var tint: Color? = nil
    let help: String
    /// 朗读名称默认去掉提示中的“ · 快捷键”部分，by AI.Coding。
    var label: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).symbolRenderingMode(.monochrome)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 28, height: 28)
                // 选中态（置顶等）用强调色底，未选中只在悬停时显示浅底，by AI.Coding。
                .background((tint ?? Color.primary).opacity(tint != nil ? 0.15 : hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(label ?? help.components(separatedBy: " · ")[0])
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}
/// 卡片识别徽标：沿用快捷键标签的小胶囊样式，颜色附色块，by AI.Coding。
private struct DetectionBadge: View {
    let detection: ContentInspector.Detection
    var body: some View {
        HStack(spacing: 3) {
            if case .color(let value) = detection {
                Circle().fill(Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255, opacity: value.alpha))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5)).frame(width: 9, height: 9)
            }
            Text(detection.badge).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
        }.foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1).fixedSize()
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .help(detection.kindName + "：" + detection.badge)
    }
}
/// 详情"识别结果"：类型、明细与可直接执行的转换；操作走转换后粘贴管线，by AI.Coding。
private struct InspectionSection: View {
    @ObservedObject var model: HistoryViewModel
    let detail: ClipDetail
    let inspection: ContentInspector.Inspection
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("识别为 " + inspection.kind).font(.caption.weight(.semibold))
                if let note = inspection.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                Spacer(minLength: 4)
                if let color = inspection.color {
                    RoundedRectangle(cornerRadius: 4).fill(Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255, opacity: color.alpha))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2))).frame(width: 44, height: 22).accessibilityHidden(true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(Array(inspection.rows.enumerated()), id: \.offset) { _, row in
                    // 多行JSON占满两列、标题在上，避免无基线内容把标签挤到下方。
                    if row.block {
                        GridRow {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.label).foregroundStyle(.secondary)
                                // 跨列文字按完整自然高度排版，避免Grid将JSON压成首行，by AI.Coding。
                                Text(row.value).font(.system(size: 11, design: .monospaced)).lineLimit(14)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.gridCellColumns(2)
                        }
                    } else {
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
            }.font(.caption)
            if !inspection.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(inspection.actions, id: \.title) { action in
                        Button(action.title) { model.perform(.plainText, transform: action.transform, ids: [detail.summary.id]) }.buttonStyle(ToolbarTabStyle(selected: true))
                    }
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
/// 详情图片支持实况文本：框选文字、⌘C复制与系统数据检测；只在详情显示时分析，移除视图即取消，by AI.Coding。
struct LiveTextImage: NSViewRepresentable {
    let image: NSImage
    let interactive: Bool
    final class Coordinator { var overlay: ImageAnalysisOverlayView?; var task: Task<Void, Never>?; var analyzed: NSImage? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        // 尺寸交给SwiftUI按比例布局，不让原图固有尺寸撑大详情。
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentCompressionResistancePriority(.defaultLow, for: orientation); view.setContentHuggingPriority(.defaultLow, for: orientation)
        }
        if ImageAnalyzer.isSupported {
            let overlay = ImageAnalysisOverlayView()
            overlay.trackingImageView = view; overlay.preferredInteractionTypes = .automatic
            overlay.autoresizingMask = [.width, .height]; overlay.frame = view.bounds
            view.addSubview(overlay); context.coordinator.overlay = overlay
        }
        update(view, context.coordinator)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { update(view, context.coordinator) }
    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) { coordinator.task?.cancel() }
    private func update(_ view: NSImageView, _ coordinator: Coordinator) {
        if view.image !== image { view.image = image }
        guard let overlay = coordinator.overlay else { return }
        overlay.isHidden = !interactive
        guard interactive, coordinator.analyzed !== image else { return }
        coordinator.task?.cancel(); coordinator.analyzed = image; overlay.analysis = nil
        let image = self.image
        coordinator.task = Task { @MainActor in
            var configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            configuration.locales = ["zh-Hans", "zh-Hant", "en-US"]
            guard let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration), !Task.isCancelled else { return }
            overlay.analysis = analysis
        }
    }
}
