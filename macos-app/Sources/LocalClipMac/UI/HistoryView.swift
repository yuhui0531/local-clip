// Paste 类横向底部卡片面板，真实数据驱动的原生界面，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
public struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var categoryContentWidth: CGFloat = 0
    @State private var categoryFadeLeading = false
    @State private var categoryFadeTrailing = false
    @State private var resizingHeight: Double?
    public init(model: HistoryViewModel) { self.model = model }
    /// 单行工具栏释放的高度用于卡片，首屏查询仍共用实际边长，by AI.Coding。
    static func cardSide(height: CGFloat, filtered: Bool) -> CGFloat {
        let dense = height < 300
        let available = max(1, height - 8 - (dense ? 40 : 48) - (filtered ? 22 : 0) - (dense ? 36 : 44) - 1 - 20)
        return available
    }
    public var body: some View {
        // 根布局只接受真实窗口视口；卡片最小内容尺寸不能反过来扩大托管视图。
        GeometryReader { viewport in
            // 用户可在宽屏主动启用紧凑工具栏；窄屏仍保持已有自适应行为，by AI.Coding。
            let compact = model.settings.compactLayout || viewport.size.width < 1000
            let dense = viewport.size.height < 300
            let toolbarHeight: CGFloat = dense ? 40 : 48
            let footerHeight: CGFloat = dense ? 36 : 44
            let filterHeight: CGFloat = model.sourceFilter != nil || model.dateFilterEnabled ? 22 : 0
            // 正方形宽高一起收缩，完整边界始终留在实际视口内。
            let cardHeight = Self.cardSide(height: viewport.size.height, filtered: filterHeight > 0)
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.3)).frame(width: 36, height: 3).frame(maxWidth: .infinity).frame(height: 8).contentShape(Rectangle())
                    .help("上下拖动调整高度")
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        if resizingHeight == nil { resizingHeight = model.actualPanelHeight }
                        model.resizePanel?((resizingHeight ?? 340) - value.translation.height, false)
                    }.onEnded { value in model.resizePanel?((resizingHeight ?? 340) - value.translation.height, true); resizingHeight = nil })
                HStack(spacing: compact ? 12 : 18) {
                    HStack(spacing: 9) {
                        ZStack { RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.92, green: 0.32, blue: 0.38)).frame(width: 30, height: 30)
                            Image(systemName: "square.on.square.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
                        if !compact { Text("LocalClip").font(.system(size: 16, weight: .bold, design: .default)) }
                    }
                    // 全部/收藏固定可见，类型与分类紧随其后，避免重复历史入口，by AI.Coding。
                    // 范围与类型之间用和分类前相同的分隔线，间距与标签一致，by AI.Coding。
                    HStack(spacing: 2) {
                        HStack(spacing: 2) { filter("剪贴板", nil); favoritesTab }.fixedSize()
                        Divider().frame(height: 16).padding(.horizontal, 6)
                        categoryNavigation(compact: compact)
                    }
                    HistorySearchInput(model: model, input: model.queryState, focus: model.focusRequest).frame(width: compact ? 160 : 240, height: 30)
                    HStack(spacing: 2) {
                        let filtering = model.sourceFilter != nil || model.dateFilterEnabled
                        ToolbarIconButton(symbol: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", tint: filtering ? .accentColor : nil, help: "筛选") { model.showingFilters.toggle() }
                            .popover(isPresented: $model.showingFilters) { FilterEditor(model: model) }
                        // 暂停时图标转为醒目的恢复入口，状态与动作一眼可辨，by AI.Coding。
                        let recording = !model.recordingPaused
                        ToolbarIconButton(symbol: recording ? "pause.circle" : "play.circle.fill", tint: recording ? nil : .orange, help: recording ? "暂停记录" : "恢复记录", action: model.toggleRecording)
                        Menu {
                            Button(model.settings.hideContents ? "显示内容" : "隐藏内容") { model.updateSettings { $0.hideContents.toggle() } }
                            Button("筛选…") { model.showingFilters.toggle() }
                            Button("撤销删除 · ⌘Z") { model.undoDeletion() }.disabled(!model.canUndoDeletion)
                            Divider()
                            Button("设置… · ⌘,") { model.openSettings?() }
                            Button("清空普通历史…", role: .destructive) { model.change(.clearOrdinary) }
                            Divider(); Button("退出 LocalClip") { model.quitApplication?() }.keyboardShortcut("q", modifiers: .command)
                        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(Color.primary.opacity(0.72)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 28).help("更多").accessibilityLabel("更多")
                        ToolbarIconButton(symbol: "xmark.circle", help: "关闭 · Esc") { model.closePanel?() }
                    }
                }.padding(.horizontal, 24).frame(height: toolbarHeight)
                if filterHeight > 0 { FilterStrip(model: model) }
                HistoryStrip(model: model, list: model.listState, cardHeight: cardHeight,
                    categoryID: model.categoryID, categories: model.categories,
                    target: model.target, draggedIDs: model.draggedIDs, hideContents: model.settings.hideContents, focusRequest: model.focusRequest, renamingID: model.renamingID, showingDetail: model.showingDetail)
                Divider().opacity(0.5)
                HStack(spacing: 12) {
                    Circle().fill(model.status == "正常" ? Color.green : model.capture.capacityBlocked ? Color.red : Color.orange).frame(width: 6, height: 6)
                    Text(model.message.isEmpty ? Self.statusLabel(model.status) : model.message).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(model.message.isEmpty ? Color.secondary : Color.primary)
                        .help(model.ignoreDescription)
                    // 暂停时就地提供恢复入口，不必去找工具栏或菜单，by AI.Coding。
                    if model.recordingPaused && model.message.isEmpty {
                        Button("恢复记录") { model.resumeRecording() }.buttonStyle(.link).font(.system(size: 11))
                    }
                    HistoryListStatistics(footer: model.listState.footerState)
                    Spacer()
                    // 始终保留操作栏的位置，加载或切换选择只改启用状态，避免右侧整块出现/消失。
                    HistorySelectionActions(model: model, footer: model.listState.footerState, compact: compact)
                }.padding(.horizontal, 24).frame(height: footerHeight)
            // 顶部保留圆角，底边与屏幕贴合，不留可拖动的悬浮窗口边距。
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .background { ZStack { HistoryBackdrop(); Color(nsColor: .windowBackgroundColor).opacity(0.76) } }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18).strokeBorder(.white.opacity(0.30), lineWidth: 1))
                .clipped()
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
                            if compact { kindMenu } else { ForEach(ClipKind.allCases, id: \.self) { filter(Self.kindName($0), $0) } }
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
                        } label: { Image(systemName: "chevron.down.circle").font(.system(size: 15)) }
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
    /// 标签直接注册原生拖放目标，接收卡片拖动并保留点击与右键管理。
    private func categoryTab(_ category: ClipCategory) -> some View {
        CategoryDropTarget(category: category, selected: model.activeCategories.contains(category.id), model: model)
    }
    /// 采集状态改用面向用户的说法，内部状态值保持不变。
    static func statusLabel(_ state: String) -> String {
        switch state { case "正常": "正在记录"; case "用户暂停": "已暂停记录"; case "定时暂停": "已定时暂停"; case "容量已满": "容量已满，新内容未记录"; default: state }
    }
    /// 类型名称与新增文件筛选保持一致。
    public static func kindName(_ kind: ClipKind) -> String { switch kind { case .text: "文本"; case .url: "链接"; case .richText: "富文本"; case .image: "图片"; case .file: "文件"; case .mixed: "混合" } }
}

// 输入只让搜索框与列表读取，不引起工具栏、分类行和整条底栏重算，by AI.Coding。
private struct HistorySearchInput: View {
    let model: HistoryViewModel
    @ObservedObject var input: HistoryQueryState
    let focus: UUID
    var body: some View {
        SearchField(text: $input.literal, focus: focus, onChange: { model.searchChanged() },
            onNavigate: model.navigate, onEnter: { model.focusResults?() }, onEscape: { model.closePanel?() })
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
    var body: some View {
        ZStack {
            if model.items.isEmpty {
                HistoryEmptyState(model: model, input: model.queryState, loading: list.snapshot.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 换筛选整组重建滚动区，新列表首帧就在最左侧，不先按旧偏移绘制再跳回，by AI.Coding。
                HistoryScroller(strip: self, list: list).id(list.snapshot.scrollEpoch)
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
        .onChange(of: list.snapshot.selectedID) { _, _ in if model.showingDetail { model.showingDetail = false } }
    }
}
/// 滚动位置与滚轮状态随滚动区身份重建；列表就地刷新时身份不变，保持浏览位置，by AI.Coding。
private struct HistoryScroller: View {
    let strip: HistoryStrip
    /// 列表就地刷新必须重算本视图，不能依赖父视图传入的值相等判断。
    @ObservedObject var list: HistoryListState
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollWheelState = HistoryScrollWheel.State()
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(strip.model.items.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, selected: strip.model.selectedIDs.contains(item.id), dragging: strip.draggedIDs.contains(item.id), editing: strip.renamingID == item.id, hidden: strip.hideContents, quickModifiers: strip.model.settings.quickModifiers, height: strip.cardHeight, categoryID: strip.categoryID, categories: strip.categories, target: strip.target, model: strip.model).equatable().id(item.id)
                            // 详情贴着所选卡片弹出，而不是远在底栏右侧的按钮，by AI.Coding。
                            .popover(isPresented: Binding(get: { strip.showingDetail && strip.model.selectedID == item.id }, set: { if !$0 { strip.model.showingDetail = false } }), arrowEdge: .top) {
                                ClipInspector(model: strip.model).frame(width: 520)
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
                }.padding(.horizontal, 24).padding(.vertical, 10)
                    .background(OverlayScrollerStyle())
            }.scrollIndicators(.visible)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: HistoryScrollMetrics.self) { geometry in
                    HistoryScrollMetrics(offset: max(0, geometry.contentOffset.x), maximum: max(0, geometry.contentSize.width - geometry.containerSize.width), viewport: geometry.containerSize.width)
                } action: { _, metrics in scrollWheelState.update(metrics); strip.model.historyScrolled(offset: metrics.offset) }
                .background(HistoryScrollWheel(state: scrollWheelState) { x in scrollPosition.scrollTo(x: x) })
                .onChange(of: strip.model.selectedID) { _, id in
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
        let filtered = model.sourceFilter != nil || model.dateFilterEnabled || model.kind != nil || model.activeCategories.count > 1
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
                        Button("恢复记录") { model.resumeRecording() }
                    }
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(.horizontal, 24)
    }
}
// 底栏只有统计和选择动作订阅列表，状态文本及其他界面不订阅，by AI.Coding。
private struct HistoryListStatistics: View {
    @ObservedObject var footer: HistoryFooterState
    var body: some View {
        let value = footer.snapshot
        HStack(spacing: 12) {
            ZStack { if value.loading { ProgressView().controlSize(.small) } }.frame(width: 14, height: 14)
            Text("\(value.selectedCount > 1 ? "已选\(value.selectedCount) · " : "")\(value.itemCount)\(value.hasMore ? "+" : "") 条")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
private struct HistorySelectionActions: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var footer: HistoryFooterState
    let compact: Bool
    var body: some View {
        let value = footer.snapshot
            Group {
                let selected = value.selectedItem
                if compact {
                    Menu {
                        Section("分类") {
                            ForEach(model.categories) { category in
                                let included = value.selectedMetadata?.summary.id == selected?.id && value.selectedMetadata?.categoryIDs.contains(category.id) == true
                                Button { if let selected { model.setCategory(selected.id, categoryID: category.id, included: !included) } } label: {
                                    if included { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
                                }
                            }
                            Button("新建分类…") { model.editCategory() }
                        }
                        Button(selected?.isFavorite == true ? "取消收藏" : "收藏") {
                            if let selected { model.change(.favorites(model.orderedSelection, !selected.isFavorite)) }
                        }.disabled(selected == nil)
                        Button("纯文本复制") { model.perform(.plainText, action: .copy) }
                            .disabled(value.selectedMetadata?.hasTextRepresentations != true || selected == nil)
                    } label: { Label("更多", systemImage: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(selected == nil)
                } else {
                    Menu {
                        ForEach(model.categories) { category in
                            let included = value.selectedMetadata?.summary.id == selected?.id && value.selectedMetadata?.categoryIDs.contains(category.id) == true
                            Button { if let selected { model.setCategory(selected.id, categoryID: category.id, included: !included) } } label: {
                                if included { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
                            }
                        }
                        Divider(); Button("新建分类…") { model.editCategory() }
                    } label: { Label("分类", systemImage: "folder") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(selected == nil || value.selectedMetadata?.summary.id != selected?.id)
                    Button { if let selected { model.change(.favorites(model.orderedSelection, !selected.isFavorite)) } } label: { Image(systemName: selected?.isFavorite == true ? "star.fill" : "star").foregroundStyle(selected?.isFavorite == true ? Color.orange : Color.secondary).frame(width: 18) }.buttonStyle(.plain).help("收藏/取消收藏").accessibilityLabel(selected?.isFavorite == true ? "取消收藏" : "收藏")
                }
                Button { model.showingDetail.toggle() } label: { if compact { Image(systemName: "info.circle") } else { Label("详情", systemImage: "info.circle") } }.buttonStyle(.plain)
                    .accessibilityLabel("详情").help("详情")
                Divider().frame(height: 20)
                if !compact {
                    Button { model.perform(.plainText, action: .copy) } label: { Text("纯文本复制") }
                        .disabled(value.selectedMetadata?.hasTextRepresentations != true).buttonStyle(.plain).foregroundStyle(.secondary).help("纯文本复制")
                }
                // Enter执行的动作作为主按钮并标↩，另一个为次按钮，图标与按键行为一致。
                if model.settings.defaultAction == .directPaste { copyButton(primary: false); pasteButton(primary: true) }
                else { pasteButton(primary: false); copyButton(primary: true) }
            }.disabled(value.selectedID == nil)
    }
    private func primaryLabel(_ title: String, _ hint: String) -> some View {
        HStack(spacing: compact ? 4 : 12) { Text(title).fontWeight(.semibold); Text(hint).font(.system(size: compact ? 9 : 10)).opacity(0.7) }
            .padding(.horizontal, compact ? 7 : 17).padding(.vertical, 7)
            .foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
    }
    // 明示面板记住的应用，避免把向后台窗口发送测试输入误认为已激活该应用。
    @ViewBuilder private func pasteButton(primary: Bool) -> some View {
        Button { model.perform(action: .directPaste) } label: {
            if primary { primaryLabel("粘贴", "↩") } else { Label("直接粘贴", systemImage: "arrow.right.doc.on.clipboard") }
        }.buttonStyle(.plain)
            .help("粘贴到：\(MacApplicationClient.targetName(model.target))；请确认目标输入位置")
            .accessibilityLabel("直接粘贴到：\(MacApplicationClient.targetName(model.target))")
    }
    @ViewBuilder private func copyButton(primary: Bool) -> some View {
        Button { model.perform(action: .copy) } label: {
            if primary { primaryLabel("复制", "↩") } else { Label("复制 ⌘C", systemImage: "doc.on.doc") }
        }.buttonStyle(.plain).keyboardShortcut("c", modifiers: .command)
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
private struct ClipCard: View, Equatable {
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
    let model: HistoryViewModel
    @State private var characterCount: Int?
    @State private var fileText: String?
    @State private var fileTextFailed = false
    @State private var thumbnailState: ThumbnailPreviewState = .loading
    /// 离屏会丢弃解码状态；缓存命中时直接显示，不经过加载占位，by AI.Coding。
    private var displayedThumbnail: ThumbnailPreviewState {
        if case .loading = thumbnailState, let image = model.thumbnails.object(forKey: item.id as NSString) { return .ready(image) }
        return thumbnailState
    }
    private var thumbnail: NSImage? { displayedThumbnail.image }
    /// 预览是路径列表且最多180字符；截断时末行不完整，只按完整行判断，加载时再用完整路径复核，by AI.Coding。
    private func filePaths(_ rule: (String) -> Bool) -> (first: String, count: Int?)? {
        guard item.kind == .file else { return nil }
        let lines = item.preview.split(separator: "\n").map(String.init)
        let truncated = item.preview.count >= 180 && lines.count > 1
        let complete = truncated ? Array(lines.dropLast()) : lines
        guard let first = complete.first, complete.allSatisfy(rule) else { return nil }
        return (first, truncated ? nil : lines.count)
    }
    private var imageFilePaths: (first: String, count: Int?)? { filePaths(ClipboardPayload.isImageFile) }
    /// 全部为文本文件时显示第一个文件的开头内容；读取失败退回文件样式，by AI.Coding。
    private var textFilePaths: (first: String, count: Int?)? { filePaths(TextFilePreview.isCandidate) }
    /// 缓存中的空串表示已确认不是文本，不再重复读取。
    private var cachedFileText: String? { model.fileTexts.object(forKey: item.id as NSString).map(String.init) }
    private var displayedFileText: String? { fileText ?? cachedFileText.flatMap { $0.isEmpty ? nil : $0 } }
    /// 第一个文件名加总数，预览文本截断且尚未读取时写“多个”。
    private func fileCaption(_ paths: (first: String, count: Int?), unit: String) -> String {
        let more = (model.fileCounts.object(forKey: item.id as NSString)?.intValue ?? paths.count).map { $0 > 1 ? " 等\($0)\(unit)" : "" } ?? " 等多\(unit)"
        return (paths.first as NSString).lastPathComponent + more
    }
    /// 全部为图片的文件引用以第一张预览；仍是文件记录，粘贴与Finder操作不变，by AI.Coding。
    private var isImageFile: Bool { imageFilePaths != nil }
    /// 文件已删或无法解码时退回普通文件卡片，不显示图片错误态。
    private var showsImageFile: Bool {
        guard isImageFile else { return false }
        switch displayedThumbnail { case .ready, .loading: return true; case .failed, .tooLarge: return false }
    }
    private var displayedCharacterCount: Int? { characterCount ?? model.characterCounts.object(forKey: item.id as NSString)?.intValue }
    @State private var isOnscreen = false
    @State private var detectedLanguage: String?
    @State private var hovering = false
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.index == rhs.index && lhs.selected == rhs.selected && lhs.dragging == rhs.dragging && lhs.editing == rhs.editing && lhs.hidden == rhs.hidden && lhs.quickModifiers == rhs.quickModifiers && lhs.height == rhs.height
            && lhs.categoryID == rhs.categoryID && lhs.categories == rhs.categories && lhs.target == rhs.target
    }
    private var code: Bool { item.kind == .text && detectedLanguage != nil }
    /// 卡片合并辅助功能子元素后仍朗读预览状态；隐藏内容时不泄露状态或正文。
    private var accessibilityDescription: String {
        let title = "\(item.title ?? HistoryView.kindName(item.kind))，\(item.source.name)"
        if hidden { return title + "，内容已隐藏" }
        if item.kind == .image || item.kind == .mixed { return title + "，" + item.preview + "，" + displayedThumbnail.label }
        return title + "，" + item.preview
    }
    private var tint: Color { switch item.kind {
        // 文本与链接色相拉开，且都不同于选中强调色，选中环不会与标题栏混在一起，by AI.Coding。
        case .text: Color(red: 0.36, green: 0.38, blue: 0.80)
        case .url: Color(red: 0.11, green: 0.55, blue: 0.80)
        case .richText: Color(red: 0.66, green: 0.39, blue: 0.62)
        case .image: Color(red: 0.24, green: 0.62, blue: 0.55)
        case .file: Color(red: 0.35, green: 0.49, blue: 0.70)
        case .mixed: Color(red: 0.73, green: 0.53, blue: 0.25) } }
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
                TextField("名称", text: $nameDraft).textFieldStyle(.plain).focused($nameFocused)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                    .onSubmit { model.saveRename(id: item.id, title: nameDraft) }
                    .onExitCommand { model.cancelRename() }
            } else { Text(item.title ?? HistoryView.kindName(item.kind)) }
        }.font(.system(size: tiny ? 10 : height < 150 ? 12 : 14, weight: .semibold)).lineLimit(1)
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
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)

                    }
                }
                Spacer(minLength: 2)
                if item.isFavorite && !tiny { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.orange).accessibilityLabel("已收藏") }
                // 应用图标自带外形，直接显示不再垫白底；系统图标四周留有透明边距，略放大与标题对齐，by AI.Coding。
                Group {
                    if let appIcon { Image(nsImage: appIcon).resizable().interpolation(.high).scaledToFit().scaleEffect(1.12) }
                    else { Image(systemName: symbol).font(.system(size: tiny ? 11 : 15, weight: .medium)).foregroundStyle(tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous)) }
                }.frame(width: iconSize, height: iconSize).help(sourceDescription)
            }.foregroundStyle(.primary).padding(.leading, tiny ? 8 : 14).padding(.trailing, tiny ? 6 : 10)
                .frame(height: headerHeight).background(tint.opacity(0.13))
                // 整个彩色标题栏双击均重命名，时间/图标/留白不能误发粘贴，by AI.Coding。
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(item.id)) } action: { headerRect = $0 }
            // 正文独占剩余区域；长文件名和多行文字只能在正文内截断，不挤掉标题和底栏。
            GeometryReader { region in
                cardContent.frame(width: region.size.width, height: region.size.height, alignment: .topLeading).clipped()
            }.frame(height: max(0, height - headerHeight - footerHeight))
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        if !tiny { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16) }
                    }
                }
            HStack(spacing: 4) {
                Text(displayedCharacterCount.map { "\($0) 个字符" } ?? (item.kind == .file ? "文件引用" : "复制\(item.copyCount)次")).lineLimit(1)
                Spacer(minLength: 2)
                // 详情入口跟随卡片：悬停或选中时出现，点按在本卡上方弹出详情，by AI.Coding。
                if (hovering || selected) && !tiny && !hidden {
                    Button { model.select(item.id); DispatchQueue.main.async { model.showingDetail = true } } label: {
                        Image(systemName: "info.circle").font(.system(size: 13)).frame(width: 18, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor).help("详情 · ⌘I").accessibilityLabel("详情")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(item.id)) } action: { infoRect = $0 }
                        .onDisappear { infoRect = .zero }
                }
                if index < 9 && !tiny {
                    Text(HotKeyService.label(Shortcut(keyCode: [18,19,20,21,23,22,26,28,25][index], modifiers: quickModifiers)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
                        .help("快捷粘贴第\(index + 1)条记录")
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
    }
    private var interactiveCard: some View {
        cardBody
            // 原生桥必须有明确卡片尺寸，否则透明NSView会占满滚动视口并误认其他卡片，by AI.Coding。
            .background(HistoryDragBridge(model: model, id: item.id, headerRect: headerRect, passThroughRect: infoRect).frame(width: height, height: height))
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
            .help(item.kind == .file ? "双击复制到Finder当前目录或原应用" : "单击选择，双击粘贴到：\(MacApplicationClient.targetName(model.target))")
            // 隐藏内容时辅助功能也不朗读正文，与界面模糊保持同一隐私承诺，by AI.Coding。
            // 每张卡片只暴露一个可操作元素；重命名时保留原生输入框，by AI.Coding。
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityLabel(accessibilityDescription).accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { model.select(item.id) }
            .accessibilityAction(named: Text("复制并粘贴")) { model.doubleClick(item.id) }
            .accessibilityAction(named: Text("重命名")) { model.beginRename(item.id) }
            .onChange(of: editing) { _, active in if active { startNameEditing() } else { nameFocused = false } }
            .onChange(of: nameFocused) { _, focused in if !focused && model.renamingID == item.id { model.cancelRename() } }
            .onAppear { if editing { startNameEditing() } }
    }
    /// 菜单独立展开，避免单个SwiftUI泛型表达式超出编译器推断范围，by AI.Coding。
    private var menuCard: some View {
        interactiveCard.contextMenu {
                Button("重命名") { model.beginRename(item.id) }
                Button("原格式复制") { if !model.selectedIDs.contains(item.id) { model.select(item.id) }; model.perform(.original, action: .copy) }
                Button("转换后粘贴… · ⌘T") { if !model.selectedIDs.contains(item.id) { model.select(item.id) }; model.showTransformMenu() }
                    .disabled(item.kind == .image || item.kind == .file)
                Button(item.isFavorite ? "取消收藏" : "收藏") { model.change(.favorites(model.selectedIDs.contains(item.id) ? model.orderedSelection : [item.id], !item.isFavorite)) }
                Menu("加入分类") {
                    ForEach(model.categories) { category in Button(category.name) { model.setCategory(item.id, categoryID: category.id, included: true) } }
                    Divider(); Button("新建分类…") { model.editCategory() }
                }
                if let categoryID { Button("从当前分类移除") { model.setCategory(item.id, categoryID: categoryID, included: false) } }
                Button("在历史中定位 · ⌘G") { model.select(item.id); model.jumpToHistory() }
                Menu("在分类中定位") { ForEach(categories) { category in Button(category.name) { model.select(item.id); model.jumpToHistory(category: category.id) } } }
                if categoryID != nil { Button("向前移动") { model.select(item.id); model.moveSelected(-1) }; Button("向后移动") { model.select(item.id); model.moveSelected(1) } }
                // 选择变化会关闭旧详情；等选择生效后再打开，避免刚打开即被关闭。
                Button("详情") { model.select(item.id); DispatchQueue.main.async { model.showingDetail = true } }
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
                if !visible { model.cancelRename(id: item.id); thumbnailState = .loading; Task { await model.derived.cancel(id: item.id) } }
            }
            .task(id: isOnscreen) {
                guard isOnscreen else { return }
                // 只为实际出现的文字卡片统计全文，计数缓存不随选中状态重算。
                if [.text, .url, .richText].contains(item.kind), displayedCharacterCount == nil {
                    let count = try? await model.store.textCharacterCount(id: item.id, at: SystemClock().now())
                    guard !Task.isCancelled, model.contains(item.id),
                          (try? await model.store.metadata(id: item.id, at: SystemClock().now())) != nil else { return }
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    characterCount = count
                    if let count { model.characterCounts.setObject(count as NSNumber, forKey: item.id as NSString) }
                }
                if textFilePaths != nil, cachedFileText == nil, fileText == nil, !fileTextFailed {
                    let urls = try? await model.store.detail(id: item.id, at: SystemClock().now()).payload.fileURLs
                    var text: String?
                    if let urls, urls.allSatisfy({ TextFilePreview.isCandidate($0.path) }), let url = urls.first {
                        text = await Task.detached(priority: .utility) { TextFilePreview.read(url) }.value
                    }
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    guard let text, let urls else {
                        fileTextFailed = true
                        if urls != nil { model.fileTexts.setObject("", forKey: item.id as NSString) }
                        return
                    }
                    fileText = text
                    model.fileTexts.setObject(text as NSString, forKey: item.id as NSString)
                    model.fileCounts.setObject(urls.count as NSNumber, forKey: item.id as NSString)
                    return
                }
                guard item.kind == .image || item.kind == .mixed || isImageFile, thumbnail == nil else { return }
                // 可见即自动加载；失败必须退出加载态，不把错误伪装成等待用户操作。
                thumbnailState = .loading
                let result: ThumbnailResult
                if isImageFile {
                    guard let urls = try? await model.store.detail(id: item.id, at: SystemClock().now()).payload.fileURLs,
                          urls.allSatisfy({ ClipboardPayload.isImageFile($0.path) }), let url = urls.first else { thumbnailState = .failed; return }
                    model.fileCounts.setObject(urls.count as NSNumber, forKey: item.id as NSString)
                    result = await Task.detached(priority: .utility) { ThumbnailRenderer.render(fileAt: url) }.value
                } else {
                    result = await model.derived.thumbnail(id: item.id)
                }
                guard !Task.isCancelled, model.contains(item.id) else { return }
                do { _ = try await model.store.metadata(id: item.id, at: SystemClock().now()) }
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
        if showsImageFile {
            VStack(spacing: 0) {
                ThumbnailPreview(state: displayedThumbnail, tint: tint, compact: tiny)
                if !tiny, let paths = imageFilePaths {
                    Text(fileCaption(paths, unit: "张")).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        } else if let text = displayedFileText, let paths = textFilePaths {
            VStack(spacing: 0) {
                SyntaxText(text: text, size: tiny ? 10 : height < 200 ? 12 : height < 260 ? 13 : 15, spacing: tiny ? 0 : 3, onLanguage: { detectedLanguage = $0 })
                    .lineSpacing(tiny ? 0 : 3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
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
            VStack(alignment: .leading, spacing: 8) {
                let paths = item.preview.split(separator: "\n")
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 14, weight: .regular)).foregroundStyle(tint)
                    Text(paths.map { (String($0) as NSString).lastPathComponent }.joined(separator: "\n"))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(height < 150 ? 1 : 3)
                }
                if height >= 150 {
                    Text(paths.first.map { (String($0) as NSString).deletingLastPathComponent } ?? "文件引用")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.top, 10)
        } else if item.kind == .image || item.kind == .mixed {
            ThumbnailPreview(state: displayedThumbnail, tint: tint, compact: tiny)
        } else if tiny && item.kind == .url {
            Text(ClipboardPayload.webLink(item.preview)?.host ?? item.context).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 6).padding(.top, 3)
        } else if item.kind == .url {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: "link").font(.system(size: 22, weight: .light)).foregroundStyle(tint); Text(ClipboardPayload.webLink(item.preview)?.host ?? "链接").font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1); Text(item.context).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4); Spacer(minLength: 0) }.padding(14)
        } else {
            // 卡片正文自动高亮代码，普通内容保持原有排版，by AI.Coding。
            SyntaxText(text: item.context, size: tiny ? 10 : height < 200 ? 12 : height < 260 ? 13 : 15, spacing: tiny ? 0 : 3, onLanguage: { detectedLanguage = $0 })
                .lineSpacing(tiny ? 0 : 3).frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, tiny ? 6 : height < 200 ? 10 : 14).padding(.top, tiny ? 3 : 10).padding(.bottom, tiny ? 0 : 4)
        }
    }

    private var symbol: String { switch item.kind { case .text: code ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"; case .url: "link"; case .richText: "textformat"; case .image: "photo"; case .file: "doc.on.doc"; case .mixed: "square.stack" } }
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
// 详情按“标题 / 预览 / 信息 / 操作”排列，高度随内容，按钮与面板主次样式一致，by AI.Coding。
struct ClipInspector: View {
    @ObservedObject var model: HistoryViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detail = model.detail {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.summary.title ?? HistoryView.kindName(detail.summary.kind)).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text("\(detail.summary.source.name) · \(detail.summary.source.basis == "frontmost" ? "复制时前台应用推断" : detail.summary.source.basis == "declared" ? "应用声明" : "来源未知")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                preview(detail)
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
                Divider()
                HStack(spacing: 8) {
                    Button(role: .destructive) { model.change(.delete([detail.summary.id])) } label: { Label("删除", systemImage: "trash").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                    Spacer()
                    Button { model.showTransformMenu(ids: [detail.summary.id]) } label: { Label("转换", systemImage: "wand.and.stars") }
                        .buttonStyle(ToolbarTabStyle(selected: true)).disabled(detail.payload.plainText == nil).help("转换后粘贴 · ⌘T")
                    // 默认输出格式为主按钮，放在最右侧，与面板 Return 的默认结果一致，by AI.Coding。
                    if model.settings.defaultFormat == .plainText { copyButton("原格式复制", .original, enabled: true); copyButton("纯文本复制", .plainText, enabled: detail.payload.plainText != nil) }
                    else { copyButton("纯文本复制", .plainText, enabled: detail.payload.plainText != nil); copyButton("原格式复制", .original, enabled: true) }
                }
            } else if model.detailLoading { ProgressView("正在读取完整内容…").frame(maxWidth: .infinity).frame(height: 220) }
            else { ContentUnavailableView("内容已变化", systemImage: "doc.text.magnifyingglass", description: Text("请选择仍存在的历史条目。")).frame(height: 220) }
        }.padding(20)
            .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }
    /// 预览放入浅底圆角容器；文件显示图标、名称与所在文件夹，不把路径当代码高亮，by AI.Coding。
    @ViewBuilder private func preview(_ detail: ClipDetail) -> some View {
        let urls = detail.summary.kind == .file ? detail.payload.fileURLs ?? [] : []
        let text = urls.isEmpty && detail.summary.kind != .image ? model.richPreview.flatMap { $0.length > 0 ? $0 : nil } : nil
        if model.image != nil || !urls.isEmpty || text != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let image = model.image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: text == nil ? 220 : 150).clipShape(RoundedRectangle(cornerRadius: 6)) }
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
                if let text { SyntaxDetailPreview(content: text).frame(height: 180) }
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
// 筛选条件显示为可移除标签，与字面检索共同生效，by AI.Coding。
private struct FilterStrip: View {
    @ObservedObject var model: HistoryViewModel
    var body: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if let source = model.sourceFilter { chip(source.isEmpty ? "未知来源" : model.sourceSuggestions.first(where: { $0.bundleID == source })?.name ?? source) { model.sourceFilter = nil } }
                    if model.dateFilterEnabled { chip("日期区间") { model.dateFilterEnabled = false } }
                }
            }.scrollIndicators(.hidden)
        }.padding(.horizontal,24).frame(height: 22)
    }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View { Button(action: remove) { HStack(spacing: 5) { Text(title); Image(systemName: "xmark").font(.system(size:8)) }.font(.system(size:10)).padding(.horizontal,8).padding(.vertical,3).background(.primary.opacity(0.07), in: Capsule()) }.buttonStyle(.plain) }
}
// 筛选按来源/日期/分类分组，与设置同一原生分组表单样式，by AI.Coding。
struct FilterEditor: View {
    @ObservedObject var model: HistoryViewModel
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
            }.formStyle(.grouped).frame(height: min(440, 230 + CGFloat(model.categories.count) * 32))
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
/// 工具栏图标按钮：SF Symbols、统一28pt命中区与悬停底色，by AI.Coding。
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
            Image(systemName: symbol).font(.system(size: 17)).symbolRenderingMode(.monochrome)
                .foregroundStyle(tint ?? Color.primary.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(label ?? help.components(separatedBy: " · ")[0])
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}
