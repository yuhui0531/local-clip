// Paste 类横向底部卡片面板，真实数据驱动的原生界面，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
public struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var categoryContentWidth: CGFloat = 0
    @State private var resizingHeight: Double?
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollWheelState = HistoryScrollWheel.State()
    public init(model: HistoryViewModel) { self.model = model }
    public var body: some View {
        // 根布局只接受真实窗口视口；卡片最小内容尺寸不能反过来扩大托管视图。
        GeometryReader { viewport in
            let compact = viewport.size.width < 1000
            let dense = viewport.size.height < 300
            let toolbarHeight: CGFloat = dense ? 40 : 48
            let footerHeight: CGFloat = dense ? 36 : 44
            let filterHeight: CGFloat = model.sourceFilter != nil || model.dateFilterEnabled ? 22 : 0
            let availableCardHeight = max(1, viewport.size.height - 8 - toolbarHeight - 40 - filterHeight - footerHeight - 1 - 20)
            // 正方形宽高一起收缩，完整边界始终留在实际视口内。
            let cardHeight = min(260, availableCardHeight)
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
                    HStack(spacing: 5) { scope(compact ? "历史" : "剪贴板历史", "clock.arrow.circlepath", false); scope("收藏", "star", true) }
                    Spacer(minLength: 10)
                    SearchField(text: $model.query, focus: model.focusRequest, onChange: model.searchChanged,
                        onNavigate: model.navigate, onEnter: { model.focusResults?() }, onEscape: { model.closePanel?() }, onDelete: model.deleteSelected).frame(maxWidth: 310).frame(height: 30)
                    Button { model.showingFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 19)) }.buttonStyle(.plain).popover(isPresented: $model.showingFilters) { FilterEditor(model: model) }
                    Button { model.updateSettings { $0.captureEnabled.toggle() } } label: { Image(systemName: model.settings.captureEnabled ? "pause.circle" : "play.circle").font(.system(size: 20, weight: .light)) }.buttonStyle(.plain).help(model.settings.captureEnabled ? "暂停采集" : "恢复采集")
                    Menu { Button(model.settings.hideContents ? "显示内容" : "隐藏内容") { model.updateSettings { $0.hideContents.toggle() } }; Button("筛选…") { model.showingFilters.toggle() }; Button("撤销删除 · ⌘Z") { model.undoDeletion() }; Button("设置…") { model.openSettings?() }; Button("清空普通历史", role: .destructive) { model.change(.clearOrdinary) } }
                        label: { Image(systemName: "ellipsis.circle").font(.system(size: 20, weight: .light)) }.menuStyle(.borderlessButton).fixedSize()
                    Button { model.closePanel?() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(.primary.opacity(0.06), in: Circle()) }.buttonStyle(.plain).help("关闭 · Escape")
                }.padding(.horizontal, 24).frame(height: toolbarHeight)
                // 分类不足一屏时整组居中，溢出时整组滚动；＋始终紧随最后一个分类。
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 7) {
                                filter("全部", nil)
                                ForEach(ClipKind.allCases, id: \.self) { filter(Self.kindName($0), $0) }
                                if !model.categories.isEmpty { Divider().frame(height: 16).padding(.horizontal, 5) }
                                ForEach(model.categories) { categoryTab($0).id($0.id) }
                                Button { model.editCategory() } label: {
                                    Image(systemName: "plus").font(.system(size: 20, weight: .regular)).frame(width: 34, height: 32)
                                }.buttonStyle(.plain).help("新建分类").accessibilityLabel("新建分类")
                                    .popover(isPresented: $model.showingCategoryEditor, arrowEdge: .top) { CategoryEditor(model: model) }
                            // 固定标签本身的宽度，剩余空间只由外层居中框架分配。
                            }.fixedSize(horizontal: true, vertical: false)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { categoryContentWidth = $0 }
                                .frame(minWidth: geometry.size.width, minHeight: 32, alignment: .center)
                        }.scrollIndicators(.hidden)
                            .onChange(of: model.categoryID) { _, id in
                                if let id, categoryContentWidth > geometry.size.width { proxy.scrollTo(id, anchor: .center) }
                            }
                    }
                }.frame(height: 32).padding(.horizontal, 24).padding(.bottom, 8)
                if filterHeight > 0 { FilterStrip(model: model) }
                ZStack {
                    if model.items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: model.query.isEmpty ? "square.on.square" : "magnifyingglass").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                            Text(model.loading ? "正在读取历史…" : model.query.isEmpty ? model.categoryID == nil ? "下一次复制，就从这里开始" : "这个分类还没有记录" : "没有匹配的历史").font(.system(size: 18, weight: .semibold))
                            Text(model.query.isEmpty ? model.categoryID == nil ? "文字、链接、图片、富文本和文件引用，只保存在这台 Mac。" : "回到剪贴板历史，把记录拖到这个分类标签。" : "中文短词、代码符号和链接片段，均按字面查找。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 16) {
                                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                        ClipCard(item: item, index: index, selected: model.selectedIDs.contains(item.id), height: cardHeight, categoryID: model.categoryID, categories: model.categories, target: model.target, model: model).equatable().id(item.id)
                                            // LazyHStack接近页尾才预读，滚动不改变当前选择，也不一次加载全部历史。
                                            .onAppear { if index >= model.items.count - 6 { model.loadMore() } }
                                    }
                                    if model.hasMore {
                                        Button(action: model.loadMore) {
                                            VStack(spacing: 10) {
                                                if model.loading { ProgressView() } else { Image(systemName: "arrow.right").font(.title2) }
                                                Text(model.loading ? "正在读取…" : "更多历史")
                                            }.frame(width: 130, height: cardHeight)
                                        }.buttonStyle(.plain).onAppear { model.loadMore() }
                                    }
                                }.padding(.horizontal, 24).padding(.vertical, 10)
                            }.scrollIndicators(.visible)
                                .scrollPosition($scrollPosition)
                                .onScrollGeometryChange(for: HistoryScrollMetrics.self) { geometry in
                                    HistoryScrollMetrics(offset: max(0, geometry.contentOffset.x), maximum: max(0, geometry.contentSize.width - geometry.containerSize.width), viewport: geometry.containerSize.width)
                                } action: { _, metrics in scrollWheelState.update(metrics) }
                                .background(HistoryScrollWheel(state: scrollWheelState) { x in scrollPosition.scrollTo(x: x) })
                                .onChange(of: model.selectedID) { _, id in
                                    if let id, let index = model.items.firstIndex(where: { $0.id == id }), scrollWheelState.needsReveal(index: index, cardWidth: cardHeight) {
                                        proxy.scrollTo(id)
                                    }
                                }
                        }
                    }
                }.frame(maxWidth: .infinity).frame(height: availableCardHeight + 20).clipped().blur(radius: model.settings.hideContents ? 16 : 0).allowsHitTesting(!model.settings.hideContents)
                Divider().opacity(0.5)
                HStack(spacing: 12) {
                    Circle().fill(!model.settings.captureEnabled ? Color.gray : model.capture.capacityBlocked ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.message.isEmpty ? model.status : model.message).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .help(model.ignoreDescription)
                    ZStack { if model.loading { ProgressView().controlSize(.small) } }.frame(width: 14, height: 14)
                    Text("\(model.selectedIDs.count > 1 ? "已选\(model.selectedIDs.count) · " : "")\(model.items.count)\(model.hasMore ? "+" : "") 条")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    // 始终保留操作栏的位置，加载或切换选择只改启用状态，避免右侧整块出现/消失。
                    Group {
                        let selected = model.items.first(where: { $0.id == model.selectedID })
                        Menu {
                            ForEach(model.categories) { category in
                                let included = model.selectedMetadata?.summary.id == selected?.id && model.selectedMetadata?.categoryIDs.contains(category.id) == true
                                Button { if let selected { model.setCategory(selected.id, categoryID: category.id, included: !included) } } label: {
                                    if included { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
                                }
                            }
                            Divider(); Button("新建分类…") { model.editCategory() }
                        } label: { if compact { Image(systemName: "folder") } else { Label("分类", systemImage: "folder") } }
                            .menuStyle(.borderlessButton).fixedSize().disabled(selected == nil || model.selectedMetadata?.summary.id != selected?.id)
                        Button { if let selected { model.change(.favorites(model.orderedSelection, !selected.isFavorite)) } } label: { Image(systemName: selected?.isFavorite == true ? "star.fill" : "star").foregroundStyle(selected?.isFavorite == true ? Color.orange : Color.secondary).frame(width: 18) }.buttonStyle(.plain).help("收藏/取消收藏")
                        Button { model.showingDetail.toggle() } label: { if compact { Image(systemName: "arrow.up.left.and.arrow.down.right") } else { Label("详情", systemImage: "arrow.up.left.and.arrow.down.right") } }.buttonStyle(.plain)
                            .popover(isPresented: $model.showingDetail, arrowEdge: .top) { ClipInspector(model: model).frame(width: 590, height: 520) }
                        Divider().frame(height: 20)
                        // 窄屏保留所有动作，以图标缩短底栏，避免正文状态把右侧按钮推出视口。
                        Button { model.perform(.plainText, action: .copy) } label: {
                            if compact { Image(systemName: "textformat") } else { Text("纯文本复制") }
                        }.disabled(model.selectedMetadata?.hasTextRepresentations != true).buttonStyle(.plain).foregroundStyle(.secondary).help("纯文本复制")
                        // 明示面板记住的应用，避免把向后台窗口发送测试输入误认为已激活该应用。
                        Button { model.perform(action: .directPaste) } label: { if compact { Image(systemName: "arrow.turn.down.left") } else { Label("直接粘贴", systemImage: "arrow.turn.down.left") } }.buttonStyle(.plain)
                            .help("粘贴到：\(MacApplicationClient.targetName(model.target))；请确认目标输入位置")
                            .accessibilityLabel("直接粘贴到：\(MacApplicationClient.targetName(model.target))")
                        Button { model.perform(action: .copy) } label: { HStack(spacing: 12) { Text("复制").fontWeight(.semibold); Text("⌘C").font(.system(size: 10)).opacity(0.7) }.padding(.horizontal, 17).padding(.vertical, 7) }
                            .buttonStyle(.plain).foregroundStyle(.white).background(Color(red: 0.23, green: 0.43, blue: 0.94), in: Capsule()).keyboardShortcut("c", modifiers: .command)
                    }.disabled(model.selectedID == nil)
                }.padding(.horizontal, 24).frame(height: footerHeight)
            // 顶部保留圆角，底边与屏幕贴合，不留可拖动的悬浮窗口边距。
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .background { ZStack { HistoryBackdrop(); Color(nsColor: .windowBackgroundColor).opacity(0.76) } }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18).strokeBorder(.white.opacity(0.30), lineWidth: 1))
                .clipped()
                .onChange(of: model.favorites) { _, _ in model.searchChanged() }
                .onChange(of: model.categoryID) { _, _ in model.searchChanged() }
                .onChange(of: model.categoryFilters) { _, _ in model.searchChanged() }
                .onChange(of: model.sourceFilter) { _, _ in model.searchChanged() }
                .onChange(of: model.dateFilterEnabled) { _, _ in model.searchChanged() }
                .onChange(of: model.dateFrom) { _, _ in if model.dateFilterEnabled { model.searchChanged() } }
                .onChange(of: model.dateUntil) { _, _ in if model.dateFilterEnabled { model.searchChanged() } }
                .onChange(of: model.kind) { _, _ in model.searchChanged() }
                .onChange(of: model.selectedID) { _, _ in model.showingDetail = false }
                .onChange(of: model.showingDetail) { _, _ in model.detailVisibilityChanged() }
                .onChange(of: model.showingCategoryEditor) { _, _ in model.panelInteractionChanged?() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// 历史/收藏入口退出分类筛选，分类具有独立入口。
    private func scope(_ title: String, _ symbol: String, _ favorite: Bool) -> some View {
        Button { model.categoryID = nil; model.categoryFilters = []; model.kind = nil; model.favorites = favorite } label: { Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(model.activeCategories.isEmpty && model.favorites == favorite ? Color.primary : Color.secondary).background(model.activeCategories.isEmpty && model.favorites == favorite ? Color.primary.opacity(0.08) : Color.clear, in: Capsule()) }.buttonStyle(.plain)
    }
    /// 类型入口退出自定义分类；全部按钮不会在分类页面伪装成已选中。
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
    let height: Double
    let categoryID: String?
    let categories: [ClipCategory]
    let target: TargetToken?
    let model: HistoryViewModel
    @State private var characterCount: Int?
    @State private var thumbnail: NSImage?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.index == rhs.index && lhs.selected == rhs.selected && lhs.height == rhs.height
            && lhs.categoryID == rhs.categoryID && lhs.categories == rhs.categories && lhs.target == rhs.target
    }
    private var code: Bool { item.kind == .text && (item.preview.contains("->") || item.preview.contains("{") || item.preview.contains("foo_bar")) }
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
    private var cardRadius: Double { min(22, height * 0.12) }
    /// 展示身份与依据分开，前台推断不伪装成应用主动声明。
    private var sourceDescription: String {
        switch item.source.basis {
        case "frontmost": "来源：\(item.source.name)（复制时前台应用推断）"
        case "declared": "来源：\(item.source.name)（应用声明）"
        default: "来源未知"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: tiny ? 4 : 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryView.kindName(item.kind)).font(.system(size: tiny ? 10 : height < 150 ? 12 : 14, weight: .semibold)).lineLimit(1)
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
            .contentShape(RoundedRectangle(cornerRadius: 22))
            // 单/双击互斥识别，避免Button先消费点击导致必须再按回车。
            .gesture(TapGesture(count: 2).onEnded { model.doubleClick(item.id) }
                .exclusively(before: TapGesture(count: 1).onEnded { model.choose(item.id) }))
            .background(HistoryDragBridge(model: model, id: item.id))
            .help(item.kind == .file ? "双击复制到Finder当前目录或原应用" : "单击选择，双击粘贴到：\(MacApplicationClient.targetName(model.target))")
            .accessibilityLabel("\(HistoryView.kindName(item.kind))，\(item.source.name)，\(item.preview)").accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { model.select(item.id) }
            .accessibilityAction(named: Text("复制并粘贴")) { model.doubleClick(item.id) }
            .contextMenu {
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
            .task(id: item.id) {
                // 只为实际出现的文字卡片统计全文，计数缓存不随选中状态重算。
                if [.text, .url, .richText].contains(item.kind) {
                    let count = try? await model.store.textCharacterCount(id: item.id, at: SystemClock().now())
                    guard !Task.isCancelled, model.items.contains(where: { $0.id == item.id }),
                          (try? await model.store.metadata(id: item.id, at: SystemClock().now())) != nil else { return }
                    guard !Task.isCancelled, model.items.contains(where: { $0.id == item.id }) else { return }
                    characterCount = count
                }
                guard item.kind == .image || item.kind == .mixed else { return }
                let result = await model.derived.thumbnail(id: item.id)
                guard !Task.isCancelled, model.items.contains(where: { $0.id == item.id }) else { return }
                do { _ = try await model.store.metadata(id: item.id, at: SystemClock().now()) } catch { return }
                guard !Task.isCancelled, model.items.contains(where: { $0.id == item.id }) else { return }
                if case .image(let data) = result { thumbnail = NSImage(data: data) }
            }.onDisappear { thumbnail = nil; characterCount = nil; Task { await model.derived.cancel(id: item.id) } }
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
            SyntaxText(text: item.context, size: tiny ? 10 : height < 210 ? 13 : 15)
                .lineSpacing(tiny ? 0 : 3).frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, tiny ? 6 : 14).padding(.top, tiny ? 3 : 10).padding(.bottom, tiny ? 0 : 4)
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
                HStack { Text(HistoryView.kindName(detail.summary.kind)).font(.title2.bold()); Spacer(); Text(detail.summary.source.name).foregroundStyle(.secondary) }
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
