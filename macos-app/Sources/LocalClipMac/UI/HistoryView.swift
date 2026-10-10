// Paste 类横向底部卡片面板，真实数据驱动的原生界面，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore
public struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var compact = false
    @State private var resizingHeight: Double?
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollWheelState = HistoryScrollWheel.State()
    private var dense: Bool { model.actualPanelHeight < 300 }
    private var cardHeight: Double { max(64, model.actualPanelHeight - (dense ? 135 : 155)) }
    public init(model: HistoryViewModel) { self.model = model }
    public var body: some View {
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
                Button { model.showingFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 19)) }.buttonStyle(.plain).popover(isPresented: Binding(get: { dense && model.showingFilters }, set: { model.showingFilters = $0 })) { FilterEditor(model: model) }
                Button { model.updateSettings { $0.captureEnabled.toggle() } } label: { Image(systemName: model.settings.captureEnabled ? "pause.circle" : "play.circle").font(.system(size: 20, weight: .light)) }.buttonStyle(.plain).help(model.settings.captureEnabled ? "暂停采集" : "恢复采集")
                Menu { Button(model.settings.hideContents ? "显示内容" : "隐藏内容") { model.updateSettings { $0.hideContents.toggle() } }; Button("筛选…") { model.showingFilters.toggle() }; Button("撤销删除 · ⌘Z") { model.undoDeletion() }; Button("设置…") { model.openSettings?() }; Button("清空普通历史", role: .destructive) { model.change(.clearOrdinary) } }
                    label: { Image(systemName: "ellipsis.circle").font(.system(size: 20, weight: .light)) }.menuStyle(.borderlessButton).fixedSize()
                Button { model.closePanel?() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(.primary.opacity(0.06), in: Circle()) }.buttonStyle(.plain).help("关闭 · Escape")
            }.padding(.horizontal, 24).padding(.top, dense ? 4 : 10).padding(.bottom, dense ? 4 : 8)
            // 类型和自定义分类共享一行；溢出横向滚动，新建入口始终可见。
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        filter("全部", nil)
                        ForEach(ClipKind.allCases, id: \.self) { filter(Self.kindName($0), $0) }
                        if !model.categories.isEmpty { Divider().frame(height: 16).padding(.horizontal, 5) }
                        ForEach(model.categories) { categoryTab($0) }
                    }
                }.scrollIndicators(.hidden).frame(height: dense ? 28 : 32)
                Button { model.editCategory() } label: {
                    Image(systemName: "plus").font(.system(size: 19, weight: .regular)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("新建分类").accessibilityLabel("新建分类")
                    .popover(isPresented: $model.showingCategoryEditor, arrowEdge: .top) { CategoryEditor(model: model) }
                ZStack { if model.loading { ProgressView().controlSize(.small) } }.frame(width: 16, height: 16)
                Text("\(model.selectedIDs.count > 1 ? "已选\(model.selectedIDs.count) · " : "")\(model.items.count)\(model.hasMore ? "+" : "") 条").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
            }.padding(.horizontal, 24).padding(.bottom, dense ? 3 : 6)
            if !dense { FilterStrip(model: model) }
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
                            }.padding(.horizontal, 24).padding(.top, 5).padding(.bottom, 12)
                        }.scrollIndicators(.visible)
                            .scrollPosition($scrollPosition)
                            .onScrollGeometryChange(for: HistoryScrollMetrics.self) { geometry in
                                HistoryScrollMetrics(offset: max(0, geometry.contentOffset.x), maximum: max(0, geometry.contentSize.width - geometry.containerSize.width), viewport: geometry.containerSize.width)
                            } action: { _, metrics in scrollWheelState.update(metrics) }
                            .background(HistoryScrollWheel(state: scrollWheelState) { x in scrollPosition.scrollTo(x: x) })
                            .onChange(of: model.selectedID) { _, id in
                                if let id, let index = model.items.firstIndex(where: { $0.id == id }), scrollWheelState.needsReveal(index: index) {
                                    proxy.scrollTo(id)
                                }
                            }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).blur(radius: model.settings.hideContents ? 16 : 0).allowsHitTesting(!model.settings.hideContents)
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Circle().fill(!model.settings.captureEnabled ? Color.gray : model.capture.capacityBlocked ? Color.orange : Color.green).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.message.isEmpty ? model.status : model.message).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if !model.ignoreDescription.isEmpty { Text(model.ignoreDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
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
                    } label: { Label("分类", systemImage: "folder") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(selected == nil || model.selectedMetadata?.summary.id != selected?.id)
                    Button { if let selected { model.change(.favorites(model.orderedSelection, !selected.isFavorite)) } } label: { Image(systemName: selected?.isFavorite == true ? "star.fill" : "star").foregroundStyle(selected?.isFavorite == true ? Color.orange : Color.secondary).frame(width: 18) }.buttonStyle(.plain).help("收藏/取消收藏")
                    Button { model.showingDetail.toggle() } label: { Label("详情", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain)
                        .popover(isPresented: $model.showingDetail, arrowEdge: .top) { ClipInspector(model: model).frame(width: 590, height: 520) }
                    Divider().frame(height: 20)
                    Button("纯文本复制") { model.perform(.plainText, action: .copy) }.disabled(model.selectedMetadata?.hasTextRepresentations != true).buttonStyle(.plain).foregroundStyle(.secondary)
                    // 明示面板记住的应用，避免把向后台窗口发送测试输入误认为已激活该应用。
                    Button { model.perform(action: .directPaste) } label: { Label("直接粘贴", systemImage: "arrow.turn.down.left") }.buttonStyle(.plain)
                        .help("粘贴到：\(MacApplicationClient.targetName(model.target))；请确认目标输入位置")
                        .accessibilityLabel("直接粘贴到：\(MacApplicationClient.targetName(model.target))")
                    Button { model.perform(action: .copy) } label: { HStack(spacing: 12) { Text("复制").fontWeight(.semibold); Text("⌘C").font(.system(size: 10)).opacity(0.7) }.padding(.horizontal, 17).padding(.vertical, 7) }
                        .buttonStyle(.plain).foregroundStyle(.white).background(Color(red: 0.23, green: 0.43, blue: 0.94), in: Capsule()).keyboardShortcut("c", modifiers: .command)
                }.disabled(model.selectedID == nil)
            }.padding(.horizontal, 24).padding(.vertical, dense ? 4 : 8)
        // 顶部保留圆角，底边与屏幕贴合，不留可拖动的悬浮窗口边距。
        }.background(HistoryBackdrop()).clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18).strokeBorder(.white.opacity(0.30), lineWidth: 1))
            .frame(minWidth: 680, minHeight: 220)
            .onGeometryChange(for: Bool.self) { $0.size.width < 900 } action: { compact = $0 }
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
    }
    /// 历史/收藏入口退出分类筛选，分类具有独立入口。
    private func scope(_ title: String, _ symbol: String, _ favorite: Bool) -> some View {
        Button { model.categoryID = nil; model.categoryFilters = []; model.kind = nil; model.favorites = favorite } label: { Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(model.categoryID == nil && model.favorites == favorite ? Color.primary : Color.secondary).background(model.categoryID == nil && model.favorites == favorite ? Color.primary.opacity(0.08) : Color.clear, in: Capsule()) }.buttonStyle(.plain)
    }
    /// 内容类型筛选延续字面搜索契约。
    private func filter(_ title: String, _ kind: ClipKind?) -> some View {
        let selected = model.kind == kind
        return Button { model.kind = kind } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(Color.primary).background(selected ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
        }.buttonStyle(.plain)
    }
    private func categoryTab(_ category: ClipCategory) -> some View {
        CategoryTab(category: category, selected: model.activeCategories.contains(category.id), tint: Color(nsColor: RichContent.colorValue(category.colorHex)),
            onSelect: { model.toggleCategory(category.id) }, onRename: { model.editCategory(category) },
            onDelete: { model.change(.deleteCategory(category.id)) }, onMove: { model.moveCategory(category, delta: $0) },
            onDrop: { model.dropIntoCategory($0, categoryID: category.id) })
    }
    /// 类型名称与新增文件筛选保持一致。
    public static func kindName(_ kind: ClipKind) -> String { switch kind { case .text: "文本"; case .url: "链接"; case .richText: "富文本"; case .image: "图片"; case .file: "文件"; case .mixed: "混合" } }
}
private struct CategoryTab: View {
    let category: ClipCategory
    let selected: Bool
    let tint: Color
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var targeted = false
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle().fill(tint).overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)).frame(width: 11, height: 11)
                Text(category.name).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }.font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6).foregroundStyle(Color.primary)
                .background(targeted ? tint.opacity(0.18) : selected ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(targeted ? tint : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).contextMenu { Button("名称与颜色…", action: onRename); Button("向左移动") { onMove(-1) }; Button("向右移动") { onMove(1) }; Divider(); Button("删除分类…", role: .destructive, action: onDelete) }
            .onDrop(of: [HistoryViewModel.categoryDragType], isTargeted: $targeted, perform: onDrop)
            .help(targeted ? "松开即可加入“\(category.name)”" : "把历史卡片拖到这里加入分类；右键重命名")
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
    let height: Double
    let categoryID: String?
    let categories: [ClipCategory]
    let target: TargetToken?
    let model: HistoryViewModel
    @State private var hovered = false
    @State private var thumbnail: NSImage?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.index == rhs.index && lhs.selected == rhs.selected && lhs.height == rhs.height
            && lhs.categoryID == rhs.categoryID && lhs.categories == rhs.categories && lhs.target == rhs.target
    }
    private var code: Bool { item.kind == .text && (item.preview.contains("->") || item.preview.contains("{") || item.preview.contains("foo_bar")) }
    private var tint: Color { switch item.kind {
        case .text: code ? Color(red: 0.28, green: 0.34, blue: 0.48) : Color(red: 0.87, green: 0.39, blue: 0.30)
        case .url: Color(red: 0.24, green: 0.50, blue: 0.88)
        case .richText: Color(red: 0.66, green: 0.39, blue: 0.62)
        case .image: Color(red: 0.24, green: 0.62, blue: 0.55)
        case .file: Color(red: 0.35, green: 0.49, blue: 0.70)
        case .mixed: Color(red: 0.73, green: 0.53, blue: 0.25) } }
    private var appIcon: NSImage? {
        guard let id = item.source.bundleID else { return nil }
        return SourceApplicationObserver.icon(for: id)
    }
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
                HStack(spacing: 9) {
                    if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 29, height: 29) }
                    else { Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28).background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 6)) }
                    VStack(alignment: .leading, spacing: 3) { Text(item.source.bundleID == nil ? "未知来源" : item.source.name).font(.system(size: 12, weight: .semibold)).lineLimit(1); Text(HistoryView.kindName(item.kind)).font(.system(size: 9, weight: .medium)).opacity(0.74) }.help(sourceDescription)
                    Spacer(); if item.isFavorite { Image(systemName: "star.fill").font(.system(size: 11)) }
                }.foregroundStyle(.white).padding(.horizontal, 14).frame(height: height < 130 ? 30 : 44).background(tint.gradient)
                cardContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                HStack { Text(Date(timeIntervalSince1970: Double(item.lastCopiedAt)/1000), style: .relative); Spacer(); if selected { Text("已选中").fontWeight(.medium).foregroundStyle(tint) } else { Text("\(index + 1)").monospacedDigit() } }.font(.system(size: 10)).foregroundStyle(Color.secondary).padding(.horizontal, 14).frame(height: 24).background(Color(nsColor: .controlBackgroundColor))
            }.frame(width: 250, height: height).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? tint : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 0.7))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // 单/双击互斥识别，避免Button先消费点击导致必须再按回车。
            .gesture(TapGesture(count: 2).onEnded { model.doubleClick(item.id) }
                .exclusively(before: TapGesture(count: 1).onEnded { model.choose(item.id) }))
            .background(HistoryDragBridge(model: model, id: item.id))
            .onHover { hovered = $0 }
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
                guard item.kind == .image || item.kind == .mixed else { return }
                let result = await model.derived.thumbnail(id: item.id)
                guard !Task.isCancelled, model.items.contains(where: { $0.id == item.id }) else { return }
                do { _ = try await model.store.metadata(id: item.id, at: SystemClock().now()) } catch { return }
                guard !Task.isCancelled, model.items.contains(where: { $0.id == item.id }) else { return }
                if case .image(let data) = result { thumbnail = NSImage(data: data) }
            }.onDisappear { thumbnail = nil; Task { await model.derived.cancel(id: item.id) } }
    }
    @ViewBuilder private var cardContent: some View {
        if item.kind == .file {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 24, weight: .light)).foregroundStyle(tint)
                let paths = item.preview.split(separator: "\n")
                Text(paths.map { (String($0) as NSString).lastPathComponent }.joined(separator: "\n"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(item.context).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text("文件引用 · 双击复制").font(.system(size: 10)).foregroundStyle(tint)
            }.padding(12)
        } else if item.kind == .image || item.kind == .mixed {
            ZStack { Rectangle().fill(tint.opacity(0.06)); if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(9) }
                else { VStack(spacing: 9) { Image(systemName: "photo").font(.system(size: 40, weight: .ultraLight)); Text("图片内容").font(.system(size: 12)); Text("原始格式保留 · 按需预览").font(.system(size: 10)) }.foregroundStyle(tint.opacity(0.65)).frame(maxWidth: .infinity, maxHeight: .infinity) } }
        } else if item.kind == .url {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: "link").font(.system(size: 22, weight: .light)).foregroundStyle(tint); Text(URL(string: item.preview)?.host ?? "链接").font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1); Text(item.context).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4); Spacer(minLength: 0) }.padding(14)
        } else if code {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) { Circle().fill(.red.opacity(0.65)).frame(width: 6,height: 6); Circle().fill(.yellow.opacity(0.65)).frame(width: 6,height: 6); Circle().fill(.green.opacity(0.65)).frame(width: 6,height: 6); Spacer(); Text("TEXT").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.35)) }
                Text(item.context).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(red: 0.76, green: 0.86, blue: 0.94)).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading); Spacer(minLength: 0)
            }.padding(14).background(Color(red: 0.13, green: 0.17, blue: 0.24))
        } else {
            VStack(alignment: .leading, spacing: 8) { if item.kind == .richText { Text("Aa").font(.system(size: 22, weight: .medium, design: .serif)).foregroundStyle(tint.opacity(0.8)) }; Text(item.context).font(.system(size: item.kind == .richText ? 13 : 14, design: item.kind == .richText ? .serif : .default)).lineSpacing(3).lineLimit(item.kind == .richText ? 4 : 5).frame(maxWidth: .infinity, alignment: .leading); Spacer(minLength: 0) }.padding(14)
        }
    }
    private var symbol: String { switch item.kind { case .text: code ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"; case .url: "link"; case .richText: "textformat"; case .image: "photo"; case .file: "doc.on.doc"; case .mixed: "square.stack" } }
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
                    if let rich = model.richPreview { RichTextPreview(content: rich).frame(height: 220) }
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
            Button { model.showingFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 16)) }.buttonStyle(.plain).help("来源与日期筛选 · ⌘F")
                .popover(isPresented: $model.showingFilters) { FilterEditor(model: model) }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if let source = model.sourceFilter { chip(source.isEmpty ? "未知来源" : model.sourceSuggestions.first(where: { $0.bundleID == source })?.name ?? source) { model.sourceFilter = nil } }
                    if model.dateFilterEnabled { chip("日期区间") { model.dateFilterEnabled = false } }
                    ForEach(model.categories.filter { model.activeCategories.contains($0.id) }) { category in chip(category.name) { model.categoryFilters = model.activeCategories.subtracting([category.id]); model.categoryID = model.categoryFilters.count == 1 ? model.categoryFilters.first : nil } }
                    if model.sourceFilter == nil && !model.dateFilterEnabled && model.activeCategories.isEmpty { Text("⌘点击多选 · ⇧点击范围 · 拖出内容或拖入分类").font(.system(size: 10)).foregroundStyle(.tertiary) }
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
            Text("日期按本机日历；分类取并集，类型、来源和日期取交集。").font(.caption).foregroundStyle(.secondary)
            ForEach(model.categories) { category in Toggle(category.name, isOn: Binding(get: { model.activeCategories.contains(category.id) }, set: { included in var values = model.activeCategories; if included { values.insert(category.id) } else { values.remove(category.id) }; model.categoryFilters = values; model.categoryID = values.count == 1 ? values.first : nil })) }
            HStack { Button("清除筛选") { model.sourceFilter = nil; model.dateFilterEnabled = false; model.categoryFilters = []; model.categoryID = nil; model.kind = nil }; Spacer(); Button("完成") { model.showingFilters = false; model.focusResults?() } }
        }.padding(18).frame(width: 420)
    }
}
