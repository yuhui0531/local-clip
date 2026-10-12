// Paste 类横向底部卡片面板，真实数据驱动的原生界面，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
public struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var categoryContentWidth: CGFloat = 0
    @State private var resizingHeight: Double?
    // 跟随SwiftUI实际外观，避免NSColor按宿主外观解析造成浅色工具栏白字。
    private var toolbarColor: Color { Color(white: colorScheme == .dark ? 0.82 : 0.28) }
    public init(model: HistoryViewModel) { self.model = model }
    /// 单行工具栏释放的高度用于卡片，首屏查询仍共用实际边长，by AI.Coding。
    static func cardSide(height: CGFloat, filtered: Bool) -> CGFloat {
        let dense = height < 300
        let available = max(1, height - 8 - (dense ? 40 : 48) - (filtered ? 22 : 0) - (dense ? 36 : 44) - 1 - 20)
        return available
    }
    /// 直接描画两种小工具图标，避免模板系统图标在材质面板中丢失指定颜色。
    private func toolbarGlyph(filter: Bool) -> some View {
        let enabled = model.settings.captureEnabled, color = toolbarColor
        return Canvas { context, size in
            let scale = size.width / 20
            context.scaleBy(x: scale, y: scale)
            context.stroke(Path(ellipseIn: CGRect(x: 1, y: 1, width: 18, height: 18)), with: .color(color), lineWidth: 1.4)
            var path = Path()
            if filter {
                for (y, left, right) in [(6.5, 5.0, 15.0), (10.0, 6.5, 13.5), (13.5, 8.0, 12.0)] {
                    path.move(to: CGPoint(x: left, y: y)); path.addLine(to: CGPoint(x: right, y: y))
                }
            } else if enabled {
                for x in [8.0, 12.0] { path.move(to: CGPoint(x: x, y: 6)); path.addLine(to: CGPoint(x: x, y: 14)) }
            } else {
                path.move(to: CGPoint(x: 8, y: 6)); path.addLine(to: CGPoint(x: 14, y: 10)); path.addLine(to: CGPoint(x: 8, y: 14)); path.closeSubpath()
                context.fill(path, with: .color(color)); return
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: filter ? 1.4 : 2, lineCap: .round))
        }.frame(width: 20, height: 20).accessibilityHidden(true)
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
            let availableCardHeight = cardHeight
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
                        if !compact { Text("LocalClip").font(.system(size: 16, weight: .bold, design: .rounded)) }
                    }
                    // 全部/收藏固定可见，类型与分类紧随其后，避免重复历史入口，by AI.Coding。
                    HStack(spacing: 5) { filter("剪贴板", nil); favoritesTab }.fixedSize()
                    categoryNavigation
                    HistorySearchInput(model: model, input: model.queryState, focus: model.focusRequest).frame(width: compact ? 160 : 240, height: 30)
                    Button { model.showingFilters.toggle() } label: { toolbarGlyph(filter: true) }.buttonStyle(.plain).accessibilityLabel("筛选").popover(isPresented: $model.showingFilters) { FilterEditor(model: model) }
                    Button { model.setCaptureEnabled(!model.settings.captureEnabled) } label: { toolbarGlyph(filter: false) }.buttonStyle(.plain).accessibilityLabel(model.settings.captureEnabled ? "暂停采集" : "恢复采集").help(model.settings.captureEnabled ? "暂停采集" : "恢复采集")
                    Menu { Button(model.settings.hideContents ? "显示内容" : "隐藏内容") { model.updateSettings { $0.hideContents.toggle() } }; Button("筛选…") { model.showingFilters.toggle() }; Button("撤销删除 · ⌘Z") { model.undoDeletion() }; Button("设置…") { model.openSettings?() }; Button("清空普通历史", role: .destructive) { model.change(.clearOrdinary) }; Divider(); Button("退出 LocalClip") { model.quitApplication?() }.keyboardShortcut("q", modifiers: .command) }
                        label: { Image(systemName: "ellipsis.circle").font(.system(size: 20, weight: .light)) }.menuStyle(.borderlessButton).fixedSize()
                    Button { model.closePanel?() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(.primary.opacity(0.06), in: Circle()) }.buttonStyle(.plain).help("关闭 · Escape")
                }.padding(.horizontal, 24).frame(height: toolbarHeight)
                if filterHeight > 0 { FilterStrip(model: model) }
                HistoryStrip(model: model, list: model.listState, cardHeight: cardHeight,
                    availableCardHeight: availableCardHeight, categoryID: model.categoryID, categories: model.categories,
                    target: model.target, draggedIDs: model.draggedIDs, hideContents: model.settings.hideContents, focusRequest: model.focusRequest, renamingID: model.renamingID)
                Divider().opacity(0.5)
                HStack(spacing: 12) {
                    Circle().fill(!model.settings.captureEnabled ? Color.gray : model.capture.capacityBlocked ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.message.isEmpty ? model.status : model.message).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .help(model.ignoreDescription)
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
                .onChange(of: model.favorites) { _, _ in model.searchChanged() }
                .onChange(of: model.categoryID) { _, _ in model.searchChanged() }
                .onChange(of: model.categoryFilters) { _, _ in model.searchChanged() }
                .onChange(of: model.sourceFilter) { _, _ in model.searchChanged() }
                .onChange(of: model.dateFilterEnabled) { _, _ in model.searchChanged() }
                .onChange(of: model.dateFrom) { _, _ in if model.dateFilterEnabled { model.searchChanged() } }
                .onChange(of: model.dateUntil) { _, _ in if model.dateFilterEnabled { model.searchChanged() } }
                .onChange(of: model.kind) { _, _ in model.searchChanged() }
                .onChange(of: model.showingDetail) { _, _ in model.detailVisibilityChanged() }
                .onChange(of: model.showingCategoryEditor) { _, _ in model.panelInteractionChanged?() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// 类型与分类共享工具栏剩余宽度；溢出只滚动这段，主入口与搜索保持可见，by AI.Coding。
    private var categoryNavigation: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(ClipKind.allCases, id: \.self) { filter(Self.kindName($0), $0) }
                        if !model.categories.isEmpty { Divider().frame(height: 16).padding(.horizontal, 5) }
                        ForEach(model.categories) { categoryTab($0).id($0.id) }
                        Button { model.editCategory() } label: {
                            Image(systemName: "plus").font(.system(size: 20, weight: .regular)).frame(width: 34, height: 32)
                        }.buttonStyle(.plain).help("新建分类").accessibilityLabel("新建分类")
                            .popover(isPresented: $model.showingCategoryEditor, arrowEdge: .top) { CategoryEditor(model: model) }
                    // 标签从收藏右侧依次排列，剩余空间不能把分类推到第二行，by AI.Coding。
                    }.fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { categoryContentWidth = $0 }
                        .frame(minWidth: geometry.size.width, minHeight: 32, alignment: .leading)
                }.scrollIndicators(.hidden)
                    .onChange(of: model.categoryID) { _, id in
                        if let id, categoryContentWidth > geometry.size.width { proxy.scrollTo(id, anchor: .center) }
                    }
                    // 溢出时尾部渐隐并提供全部分类菜单，被截断的标签仍可发现和直达，by AI.Coding。
                    .overlay(alignment: .trailing) {
                        if categoryContentWidth > geometry.size.width + 1 {
                            HStack(spacing: 0) {
                                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                                Menu {
                                    ForEach(model.categories) { category in
                                        Button(category.name) { model.selectCategories([category.id]); proxy.scrollTo(category.id, anchor: .center) }
                                    }
                                } label: { Image(systemName: "chevron.down.circle").font(.system(size: 15)) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .padding(.leading, 2).background(Color(nsColor: .windowBackgroundColor))
                                    .help("全部分类").accessibilityLabel("全部分类")
                            }.allowsHitTesting(true)
                        }
                    }
            }
        }.frame(height: 32)
    }
    /// 收藏独立于类型与分类；全部是唯一的完整历史入口，by AI.Coding。
    private var favoritesTab: some View {
        Button { model.categoryID = nil; model.categoryFilters = []; model.kind = nil; model.favorites = true } label: { Label("收藏", systemImage: "star").font(.system(size: 13, weight: model.favorites ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(model.favorites ? Color.primary : Color.secondary).background(model.favorites ? Color.primary.opacity(0.08) : Color.clear, in: Capsule()) }.buttonStyle(.plain)
    }
    /// 类型入口退出自定义分类；全部按钮不会在分类页面伪装成已选中，by AI.Coding。
    private func filter(_ title: String, _ kind: ClipKind?) -> some View {
        let selected = model.kind == kind && model.activeCategories.isEmpty && !model.favorites
        return Button { model.selectKind(kind) } label: {
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(Color.primary).background(selected ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
        }.buttonStyle(.plain)
    }
    /// 标签直接注册原生拖放目标，接收卡片拖动并保留点击与右键管理。
    private func categoryTab(_ category: ClipCategory) -> some View {
        CategoryDropTarget(category: category, selected: model.activeCategories.contains(category.id), model: model)
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
        SearchField(text: $input.literal, focus: focus, onChange: model.searchChanged,
            onNavigate: model.navigate, onEnter: { model.focusResults?() }, onEscape: { model.closePanel?() }, onDelete: model.deleteSelected)
    }
}
private struct HistoryStrip: View {
    let model: HistoryViewModel
    @ObservedObject var list: HistoryListState
    let cardHeight: CGFloat
    let availableCardHeight: CGFloat
    let categoryID: String?
    let categories: [ClipCategory]
    let target: TargetToken?
    let draggedIDs: Set<ClipID>
    let hideContents: Bool
    let focusRequest: UUID
    let renamingID: ClipID?
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollWheelState = HistoryScrollWheel.State()
    var body: some View {
        ZStack {
            if model.items.isEmpty {
                HistoryEmptyState(input: model.queryState, categoryID: categoryID, loading: list.snapshot.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, index: index, selected: model.selectedIDs.contains(item.id), dragging: draggedIDs.contains(item.id), editing: renamingID == item.id, hidden: hideContents, height: cardHeight, categoryID: categoryID, categories: categories, target: target, model: model).equatable().id(item.id)
                            }
                            if model.hasMore {
                                Button(action: model.loadMore) {
                                    VStack(spacing: 10) {
                                        if model.loading { ProgressView() } else { Image(systemName: "arrow.right").font(.title2) }
                                        Text(model.loading ? "正在读取…" : "更多历史")
                                    }.frame(width: 130, height: cardHeight)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 24).padding(.vertical, 10)
                            .background(OverlayScrollerStyle())
                    }.scrollIndicators(.visible)
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: HistoryScrollMetrics.self) { geometry in
                            HistoryScrollMetrics(offset: max(0, geometry.contentOffset.x), maximum: max(0, geometry.contentSize.width - geometry.containerSize.width), viewport: geometry.containerSize.width)
                        } action: { _, metrics in scrollWheelState.update(metrics); model.historyScrolled(offset: metrics.offset) }
                        .background(HistoryScrollWheel(state: scrollWheelState) { x in scrollPosition.scrollTo(x: x) })
                        .onChange(of: model.selectedID) { _, id in
                            if let id, let index = model.items.firstIndex(where: { $0.id == id }), scrollWheelState.needsReveal(index: index, cardWidth: cardHeight) {
                                proxy.scrollTo(id)
                            }
                        }
                        .onChange(of: model.scrollRestoration) { _, restore in
                            if let restore { scrollPosition.scrollTo(x: restore.offset) }
                        }
                }
            }
        }.frame(maxWidth: .infinity).frame(height: availableCardHeight + 20).clipped().blur(radius: hideContents ? 16 : 0).allowsHitTesting(!hideContents)
        .background {
            #if DEBUG
            if GUIAcceptanceProbe.configuration != nil {
                GUIRenderWitness(displayCycle: model.focusRequest, query: model.query, generation: model.guiQueryGeneration, first: model.items.first?.preview, firstID: model.items.first?.id, firstImage: model.items.first?.kind == .image, ready: model.items.first?.kind != .image || GUIAcceptanceProbe.imageReadyIDs.contains(model.items.first?.id ?? ""), loading: model.historyBusy).frame(width: 1, height: 1)
            }
            #else
            EmptyView()
            #endif
        }
        .onChange(of: list.snapshot.selectedID) { _, _ in if model.showingDetail { model.showingDetail = false } }
    }
}
/// 搜索词只让空结果提示订阅，避免每个输入字符重建整条卡片列表，by AI.Coding。
private struct HistoryEmptyState: View {
    @ObservedObject var input: HistoryQueryState
    let categoryID: String?
    let loading: Bool
    var body: some View {
        let emptyQuery = input.literal.isEmpty
        VStack(spacing: 12) {
            Image(systemName: emptyQuery ? "square.on.square" : "magnifyingglass").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(loading ? "正在读取历史…" : emptyQuery ? categoryID == nil ? "下一次复制，就从这里开始" : "这个分类还没有记录" : "没有匹配的历史").font(.system(size: 18, weight: .semibold))
            Text(emptyQuery ? categoryID == nil ? "文字、链接、图片、富文本和文件引用，只保存在这台 Mac。" : "选择“剪贴板”，把记录拖到这个分类标签。" : "中文短词、代码符号和链接片段，均按字面查找。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
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
                    Button { if let selected { model.change(.favorites(model.orderedSelection, !selected.isFavorite)) } } label: { Image(systemName: selected?.isFavorite == true ? "star.fill" : "star").foregroundStyle(selected?.isFavorite == true ? Color.orange : Color.secondary).frame(width: 18) }.buttonStyle(.plain).help("收藏/取消收藏")
                }
                Button { model.showingDetail.toggle() } label: { if compact { Image(systemName: "arrow.up.left.and.arrow.down.right") } else { Label("详情", systemImage: "arrow.up.left.and.arrow.down.right") } }.buttonStyle(.plain)
                    .accessibilityLabel("详情").help("详情")
                    .popover(isPresented: $model.showingDetail, arrowEdge: .top) { ClipInspector(model: model).frame(width: 590, height: 520) }
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
            .foregroundStyle(.white).background(Color(red: 0.23, green: 0.43, blue: 0.94), in: Capsule())
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
                ForEach(["34C759","8E8E93","FFCC00","FF3B30","007AFF","AF52DE"], id: \.self) { hex in
                    Button { model.categoryColor = hex } label: { Circle().fill(Color(nsColor: RichContent.colorValue(hex))).frame(width:20,height:20).overlay(Circle().strokeBorder(model.categoryColor == hex ? Color.primary : .clear, lineWidth:2).padding(-3)) }.buttonStyle(.plain)
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
    @State private var headerRect: CGRect = .zero
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let height: Double
    let categoryID: String?
    let categories: [ClipCategory]
    let target: TargetToken?
    let model: HistoryViewModel
    @State private var characterCount: Int?
    @State private var thumbnail: NSImage?
    @State private var isOnscreen = false
    @State private var detectedLanguage: String?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.index == rhs.index && lhs.selected == rhs.selected && lhs.dragging == rhs.dragging && lhs.editing == rhs.editing && lhs.hidden == rhs.hidden && lhs.height == rhs.height
            && lhs.categoryID == rhs.categoryID && lhs.categories == rhs.categories && lhs.target == rhs.target
    }
    private var code: Bool { item.kind == .text && detectedLanguage != nil }
    private var tint: Color { switch item.kind {
        case .text: Color(red: 0, green: 0.48, blue: 1)
        case .url: Color(red: 0.24, green: 0.50, blue: 0.88)
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
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
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
                            .font(.system(size: 9, weight: .medium)).opacity(0.84).lineLimit(1)

                    }
                }
                Spacer(minLength: 2)
                if item.isFavorite && !tiny { Image(systemName: "star.fill").font(.system(size: 11)) }
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white)
                    if let appIcon { Image(nsImage: appIcon).resizable().scaledToFit().padding(2) }
                    else { Image(systemName: symbol).font(.system(size: tiny ? 11 : 15, weight: .medium)).foregroundStyle(tint) }
                }.frame(width: iconSize, height: iconSize).help(sourceDescription)
            }.foregroundStyle(.white).padding(.leading, tiny ? 8 : 14).padding(.trailing, tiny ? 6 : 10)
                .frame(height: headerHeight).background(tint)
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
            Text(characterCount.map { "\($0) 个字符" } ?? (item.kind == .file ? "文件引用" : "复制\(item.copyCount)次"))
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                .frame(height: footerHeight)
        }.frame(width: height, height: height).background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(selected ? Color(red: 0, green: 0.48, blue: 1) : Color.primary.opacity(0.07), lineWidth: selected ? 3 : 0.7))
            .shadow(color: .black.opacity(0.09), radius: 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .coordinateSpace(name: item.id)
    }
    private var interactiveCard: some View {
        cardBody
            // 原生桥必须有明确卡片尺寸，否则透明NSView会占满滚动视口并误认其他卡片，by AI.Coding。
            .background(HistoryDragBridge(model: model, id: item.id, headerRect: headerRect).frame(width: height, height: height))
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
            .accessibilityLabel(hidden ? "\(item.title ?? HistoryView.kindName(item.kind))，\(item.source.name)，内容已隐藏" : "\(item.title ?? HistoryView.kindName(item.kind))，\(item.source.name)，\(item.preview)").accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
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
                Button(item.isFavorite ? "取消收藏" : "收藏") { model.change(.favorites(model.selectedIDs.contains(item.id) ? model.orderedSelection : [item.id], !item.isFavorite)) }
                Menu("加入分类") {
                    ForEach(model.categories) { category in Button(category.name) { model.setCategory(item.id, categoryID: category.id, included: true) } }
                    Divider(); Button("新建分类…") { model.editCategory() }
                }
                if let categoryID { Button("从当前分类移除") { model.setCategory(item.id, categoryID: categoryID, included: false) } }
                Button("在历史中定位 · ⌘G") { model.select(item.id); model.jumpToHistory() }
                Menu("在分类中定位") { ForEach(categories) { category in Button(category.name) { model.select(item.id); model.jumpToHistory(category: category.id) } } }
                if categoryID != nil { Button("向前移动") { model.select(item.id); model.moveSelected(-1) }; Button("向后移动") { model.select(item.id); model.moveSelected(1) } }
                Button("预览 · Space") { model.select(item.id); model.quickLook() }
                Button("打开 · ⌘O") { model.select(item.id); model.openSelected() }
                if item.kind == .file { Button("在Finder中显示") { model.select(item.id); model.openSelected(reveal: true) }; Button("打开方式…") { model.select(item.id); model.openSelected(withApplication: true) } }
                Divider(); Button("删除", role: .destructive) { model.change(.delete(model.selectedIDs.contains(item.id) ? model.orderedSelection : [item.id])) }
            }
    }
    var body: some View {
        menuCard
            // LazyHStack可能提前创建邻近卡片；正文/图片任务只在真实可见时运行，离屏释放解码图，by AI.Coding。
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isOnscreen = visible
                if !visible { model.cancelRename(id: item.id); thumbnail = nil; Task { await model.derived.cancel(id: item.id) } }
            }
            .task(id: isOnscreen) {
                guard isOnscreen else { return }
                // 只为实际出现的文字卡片统计全文，计数缓存不随选中状态重算。
                if [.text, .url, .richText].contains(item.kind) {
                    let count = try? await model.store.textCharacterCount(id: item.id, at: SystemClock().now())
                    guard !Task.isCancelled, model.contains(item.id),
                          (try? await model.store.metadata(id: item.id, at: SystemClock().now())) != nil else { return }
                    guard !Task.isCancelled, model.contains(item.id) else { return }
                    characterCount = count
                }
                guard item.kind == .image || item.kind == .mixed else { return }
                let result = await model.derived.thumbnail(id: item.id)
                guard !Task.isCancelled, model.contains(item.id) else { return }
                do { _ = try await model.store.metadata(id: item.id, at: SystemClock().now()) } catch { return }
                guard !Task.isCancelled, model.contains(item.id) else { return }
                if case .image(let data) = result {
                    thumbnail = NSImage(data: data)
                    #if DEBUG
                    if thumbnail != nil { GUIAcceptanceProbe.imageReadyIDs.insert(item.id) }
                    #endif
                }
            }.onDisappear { model.cancelRename(id: item.id); thumbnail = nil; characterCount = nil; Task { await model.derived.cancel(id: item.id) } }
    }
    @ViewBuilder private var cardContent: some View {
        if tiny && item.kind == .file {
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
            ZStack { Rectangle().fill(tint.opacity(0.06)); if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(tiny ? 2 : 9) }
                else if tiny { Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(tint) }
                else { VStack(spacing: 9) { Image(systemName: "photo").font(.system(size: 40, weight: .ultraLight)); Text("图片内容").font(.system(size: 12)); Text("原始格式保留 · 按需预览").font(.system(size: 10)) }.foregroundStyle(tint.opacity(0.65)).frame(maxWidth: .infinity, maxHeight: .infinity) } }
        } else if tiny && item.kind == .url {
            Text(URL(string: item.preview)?.host ?? item.context).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 6).padding(.top, 3)
        } else if item.kind == .url {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: "link").font(.system(size: 22, weight: .light)).foregroundStyle(tint); Text(URL(string: item.preview)?.host ?? "链接").font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1); Text(item.context).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4); Spacer(minLength: 0) }.padding(14)
        } else {
            // 卡片正文自动高亮代码，普通内容保持原有排版，by AI.Coding。
            SyntaxText(text: item.context, size: tiny ? 10 : height < 200 ? 9.5 : height < 210 ? 13 : 15, spacing: tiny ? 0 : 3, onLanguage: { detectedLanguage = $0 })
                .lineSpacing(tiny ? 0 : 3).frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, tiny || height < 200 ? 6 : 14).padding(.top, tiny ? 3 : 10).padding(.bottom, tiny ? 0 : 4)
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
private struct ClipInspector: View {
    @ObservedObject var model: HistoryViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let detail = model.detail {
                HStack { Text(detail.summary.title ?? HistoryView.kindName(detail.summary.kind)).font(.title2.bold()); Spacer(); Text(detail.summary.source.name).foregroundStyle(.secondary) }
                Text(detail.summary.source.basis == "frontmost" ? "来源依据：复制时前台应用推断" : detail.summary.source.basis == "declared" ? "来源依据：应用声明" : "来源依据：未知")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    if let image = model.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230).clipShape(RoundedRectangle(cornerRadius: 10)) }
                    if !model.previewMessage.isEmpty { Text(model.previewMessage).font(.caption).foregroundStyle(.secondary) }
                    if let rich = model.richPreview { SyntaxDetailPreview(content: rich).frame(height: 220) }
                } }.frame(maxHeight: .infinity)
                Divider()
                Text("\(detail.payload.items.count) 项 · \(HistoryViewModel.bytes(detail.payload.byteCount)) · 复制\(detail.summary.copyCount)次\n\(Date(timeIntervalSince1970: Double(detail.summary.lastCopiedAt)/1000).formatted())").font(.caption).foregroundStyle(.secondary)
                Text(detail.payload.items.flatMap { $0.representations.map(\.type) }.sorted().joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if detail.summary.kind == .file { Text("保存的是文件引用，未备份文件本体；移动或删除原件后请重新复制。Finder中双击会复制副本到当前实际文件夹，同名冲突会停止，不覆盖已有文件。").font(.caption).foregroundStyle(.secondary) }
                if detail.payload.items.contains(where: { !Set($0.declaredTypes).subtracting(SupportedType.all).isEmpty }) { Text("仅保留支持格式，附加私有格式未保存").font(.caption).foregroundStyle(.secondary) }
                HStack { Button("原格式复制") { model.perform(.original, action: .copy) }; Button("纯文本复制") { model.perform(.plainText, action: .copy) }.disabled(detail.payload.plainText == nil); Spacer(); Button("删除", role: .destructive) { model.change(.delete([detail.summary.id])) } }
            } else if model.detailLoading { ProgressView("正在读取完整内容…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView("内容已变化", systemImage: "doc.text.magnifyingglass", description: Text("请选择仍存在的历史条目。")) }
        }.padding(24)
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
private struct FilterEditor: View {
    @ObservedObject var model: HistoryViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("联合筛选").font(.headline)
            Picker("来源", selection: Binding(get: { model.sourceFilter ?? "*" }, set: { model.sourceFilter = $0 == "*" ? nil : $0 })) {
                Text("全部来源").tag("*")
                ForEach(Array(model.sourceSuggestions.enumerated()), id: \.offset) { _, source in Text(source.name).tag(source.bundleID ?? "") }
            }
            Toggle("限定复制日期", isOn: $model.dateFilterEnabled)
            HStack { DatePicker("从", selection: $model.dateFrom, displayedComponents: .date); DatePicker("至", selection: $model.dateUntil, displayedComponents: .date) }.disabled(!model.dateFilterEnabled)
            Text("日期按本机日历；类型与自定义分类互斥，来源和日期作用于当前范围。").font(.caption).foregroundStyle(.secondary)
            ForEach(model.categories) { category in Toggle(category.name, isOn: Binding(get: { model.activeCategories.contains(category.id) }, set: { included in var values = model.activeCategories; if included { values.insert(category.id) } else { values.remove(category.id) }; model.selectCategories(values) })) }
            HStack { Button("清除筛选") { model.sourceFilter = nil; model.dateFilterEnabled = false; model.categoryFilters = []; model.categoryID = nil; model.kind = nil }; Spacer(); Button("完成") { model.showingFilters = false; model.focusResults?() } }
        }.padding(18).frame(width: 420)
    }
}
