// 历史管理三栏：侧栏范围、分页表格、检查器；只复制不直接粘贴，by AI.Coding。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LocalClipCore

struct HistoryManagerView: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    @State private var inspectorShown = true
    var body: some View {
        NavigationSplitView {
            ManagerSidebar(model: model, history: history).navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.selection.count > 1 || model.allMatching != nil { ManagerBatchBar(model: model, history: history) }
                else { ManagerFilterBar(model: model) }
                Divider()
                ManagerTable(model: model, history: history)
                Divider()
                ManagerPager(model: model)
            }
            .inspector(isPresented: $inspectorShown) {
                // 检查器不向窗口报最小尺寸：文件说明纵向固定，测最小尺寸时按极窄宽度排版会高过窗口，整页被居中上移、侧栏钻到标题栏下，by AI.Coding。
                ManagerInspector(model: model, history: history)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .inspectorColumnWidth(min: 300, ideal: 400, max: 640)
            }
        }
        .searchable(text: $model.literal, placement: .toolbar, prompt: "搜索历史")
        .navigationTitle("历史管理")
        .navigationSubtitle("\(model.total) 条记录")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { inspectorShown.toggle() } label: { Label("检查器", systemImage: "sidebar.trailing") }.help("显示或隐藏检查器")
            }
        }
        .overlay {
            if !history.canDisplayContents {
                ContentUnavailableView("内容已隐藏", systemImage: "eye.slash", description: Text("在历史面板“更多”中选择“显示内容”后可管理历史。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            }
        }
        // 提示条在隐藏遮罩之上，撤销入口始终可见，by AI.Coding。
        .overlay(alignment: .bottom) { ManagerToast(model: model) }
        // 隐藏内容时放弃选择，不在遮罩下保留可操作对象，by AI.Coding。
        .onChange(of: history.canDisplayContents) { _, visible in if !visible { model.clearSelection() } }
        // 内容隐藏时附页收起而草稿保留；只有内容可见时的关闭才放弃草稿，by AI.Coding。
        .sheet(isPresented: Binding(get: { model.editorPresented }, set: { if !$0, history.canDisplayContents { model.discardEdit() } })) {
            if let editor = model.editor {
                ClipContentEditor(state: editor, save: model.saveEdit, cancel: model.cancelEdit, discard: model.discardEdit)
                    .padding(ClipContentLayout.padding)
                    .frame(width: ClipContentLayout.size.width, height: ClipContentLayout.size.height)
                    .interactiveDismissDisabled()
                    .onExitCommand { if editor.confirmingDiscard { editor.confirmingDiscard = false } else { model.cancelEdit() } }
            }
        }
        .onAppear { model.start() }
    }
}

// MARK: 侧栏
private struct ManagerSidebar: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    @State private var dropTarget: String?
    var body: some View {
        List(selection: Binding(get: { model.scope }, set: { if let value = $0 { model.scope = value } })) {
            Section("资料库") {
                Label("全部历史", systemImage: "tray.full").tag(HistoryManagerModel.Scope.all)
                Label("收藏", systemImage: "star").tag(HistoryManagerModel.Scope.favorites)
            }
            Section("类型") {
                ForEach(ClipKind.allCases, id: \.self) { kind in
                    Label(HistoryView.kindName(kind), systemImage: HistoryView.kindSymbol(kind)).tag(HistoryManagerModel.Scope.kind(kind))
                }
            }
            Section {
                ForEach(history.categories) { category in
                    let tint = Color(nsColor: RichContent.colorValue(category.colorHex))
                    Label { Text(category.name) } icon: { CategoryDot(category: category, size: 9) }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .help("单击切换分类，双击重命名")
                        .accessibilityAction(named: Text("重命名")) { model.beginCategoryRename(category) }
                        .popover(isPresented: Binding(get: { model.categoryEditorShown && model.categoryBeingEdited?.id == category.id }, set: { if !$0, model.categoryBeingEdited?.id == category.id { model.categoryEditorShown = false } }), arrowEdge: .trailing) {
                            CategoryEditor(creating: false, name: $model.categoryName, color: $model.categoryColor,
                                           error: model.categoryError, saving: model.savingCategory,
                                           cancel: model.cancelCategoryRename, save: { Task { await model.saveCategoryRename() } })
                        }
                        // 拖入只加入分类，不切换浏览范围；悬停时按分类色高亮，与面板分类标签一致，by AI.Coding。
                        .background { if dropTarget == category.id { RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.18)).strokeBorder(tint, lineWidth: 1.5).padding(-3) } }
                        .dropDestination(for: ManagerDragToken.self) { items, _ in model.drop(items.map(\.value), into: category.id) }
                            isTargeted: { if $0 { dropTarget = category.id } else if dropTarget == category.id { dropTarget = nil } }
                        .tag(HistoryManagerModel.Scope.category(category.id))
                }
            } header: {
                HStack {
                    Text("分类"); Spacer()
                    NewCategoryButton(model: model, history: history)
                }
            }
        }
        .listStyle(.sidebar)
        // 行内点按手势会截走List的单击选择；双击与右键改用List原生入口，单击始终切换范围，by AI.Coding。
        .contextMenu(forSelectionType: HistoryManagerModel.Scope.self) { scopes in
            if case .category(let id) = scopes.first, let category = history.categories.first(where: { $0.id == id }) {
                Button("重命名…") { model.beginCategoryRename(category) }
                Button("删除分类…", role: .destructive) { model.deleteCategory(id) }
            }
        } primaryAction: { scopes in
            if case .category(let id) = scopes.first, let category = history.categories.first(where: { $0.id == id }) { model.beginCategoryRename(category) }
        }
        // 分类被删除（本窗口或底栏）后不停留在已不存在的范围，by AI.Coding。
        .onChange(of: history.categories) { _, categories in
            if case .category(let id) = model.scope, !categories.contains(where: { $0.id == id }) { model.scope = .all }
            // 正在改名的分类被删后释放草稿，否则其他分类的改名入口会被卡住。
            if let editing = model.categoryBeingEdited, !categories.contains(where: { $0.id == editing.id }) { model.cancelCategoryRename() }
        }
    }
}
/// 新建分类沿用面板的分类编辑弹窗：弹窗自带焦点与取消，不在侧栏列表里嵌输入框，by AI.Coding。
private struct NewCategoryButton: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    @State private var shown = false
    @State private var name = ""
    @State private var color = ""
    @State private var error = ""
    @State private var saving = false
    @State private var categoryDraftID = UUID()
    var body: some View {
        Button { name = ""; color = history.nextCategoryColor; error = ""; shown = true; registerCategoryDraft() } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless).help("新建分类").accessibilityLabel("新建分类")
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                CategoryEditor(creating: true, name: $name, color: $color, error: error, saving: saving, cancel: { shown = false; history.surfaceEdits.remove(categoryDraftID) }, save: save)
            }
    }
    /// 弹出层临时失焦不丢草稿，显式取消/保存才解除保护。
    private func registerCategoryDraft() {
        history.surfaceEdits.register(categoryDraftID, surface: .manager, draft: .init(title: "分类名称", dirty: { !name.isEmpty || saving }, save: saveBeforeLeaving, discard: { shown = false; name = "" }))
    }
    private func save() { Task { await saveBeforeLeaving() } }
    /// 切换等待真实结果；失败重新展示原草稿。
    @discardableResult private func saveBeforeLeaving() async -> Bool {
        guard !saving else { return false }
        saving = true; error = ""
        defer { saving = false }
        if let failure = await model.createCategory(name, color: color) { error = failure; shown = true; return false }
        shown = false; history.surfaceEdits.remove(categoryDraftID); return true
    }
}

// MARK: 筛选与批量
private struct ManagerFilterBar: View {
    @ObservedObject var model: HistoryManagerModel
    var body: some View {
        HStack(spacing: 10) {
            PageCheckbox(model: model)
            Picker("时间", selection: $model.time) { ForEach(HistoryManagerModel.TimeRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("来源", selection: $model.source) {
                Text("全部来源").tag(String?.none)
                ForEach(Array(model.sources.enumerated()), id: \.offset) { _, source in Text(source.name).tag(String?.some(source.bundleID ?? "")) }
            }.labelsHidden().fixedSize()
            Picker("排序", selection: $model.sort) { ForEach(HistorySortOrder.allCases, id: \.self) { Text($0.title).tag($0) } }
                .labelsHidden().fixedSize()
            if model.hasFilters { Button("清除筛选", action: model.clearFilters).buttonStyle(.link) }
            Spacer()
        }.padding(.horizontal, 12).frame(height: 40)
    }
}
private struct ManagerBatchBar: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    var body: some View {
        let ids = model.targetIDs, all = model.selectAllID
        HStack(spacing: 10) {
            PageCheckbox(model: model)
            Text("已选择 \(ids.count) 条").font(.system(size: LCStyle.FontSize.body, weight: .semibold))
            if model.selectingAll { ProgressView().controlSize(.small); Text("正在选择全部…").foregroundStyle(.secondary) }
            else if model.allMatching == nil, model.total > ids.count { Button("选择全部 \(model.total) 条", action: model.selectAllMatching).buttonStyle(.link) }
            Spacer()
            // 收集完成前目标集合未定，写入按钮禁用，只保留取消，by AI.Coding。
            Group {
                Button("收藏") { model.setFavorite(ids, true, selectAll: all) }
                Menu("分类…") { CategoryItems(model: model, history: history, ids: ids, selectAll: all) }.fixedSize()
                Button("删除", role: .destructive) { model.delete(ids, selectAll: all) }
            }.disabled(model.selectingAll)
            Button("取消", action: model.clearSelection)
        }.padding(.horizontal, 12).frame(height: 40).background(Color.accentColor.opacity(0.08))
    }
}
/// 表头只能放文字，“选择本页全部”放在表格上方条的首位，与行勾选框对齐，by AI.Coding。
private struct PageCheckbox: View {
    @ObservedObject var model: HistoryManagerModel
    var body: some View {
        Toggle("选择本页全部", isOn: Binding(get: { model.pageChecked }, set: { model.setPageChecked($0) }))
            .toggleStyle(.checkbox).labelsHidden().help("选择本页全部").accessibilityLabel("选择本页全部")
            .disabled(model.rows.isEmpty || model.selectingAll)
    }
}
/// 勾选表示所选记录全部已在该分类，点按整体加入或移出。
private struct CategoryItems: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    let ids: [ClipID]
    var selectAll: UUID?
    var body: some View {
        ForEach(history.categories) { category in
            let included = !ids.isEmpty && ids.allSatisfy { model.categoryIDs(of: $0).contains(category.id) }
            Toggle(category.name, isOn: Binding(get: { included }, set: { model.setCategory(ids, category.id, $0, selectAll: selectAll) }))
        }
        if history.categories.isEmpty { Text("尚无分类，可在侧栏新建").foregroundStyle(.secondary) }
    }
}

// MARK: 表格
private struct ManagerTable: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    @State private var hovered: ClipID?
    @State private var order = [KeyPathComparator(\ClipSummary.lastCopiedAt, order: .reverse)]
    var body: some View {
        VStack(spacing: 0) {
            // 有内容时的刷新失败不能静默：保留旧内容并给出重试，by AI.Coding。
            if model.failed, !model.rows.isEmpty {
                HStack {
                    Label("刷新失败，显示的是上次结果", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Spacer()
                    Button("重试", action: model.retry)
                }.padding(.horizontal, 12).padding(.vertical, 6).background(Color.red.opacity(0.08))
            }
            table
        }
    }
    private var table: some View {
        Table(of: ClipSummary.self, selection: Binding(get: { model.selection }, set: { model.tableSelected($0, checkboxClick: Self.checkboxDoubleClick()) }), sortOrder: $order) {
            TableColumn("") { row in
                Toggle("", isOn: Binding(get: { model.isChecked(row.id) }, set: { model.setChecked(row.id, $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
            }.width(min: 22, ideal: 22, max: 22)
            // 名称是唯一伸缩列；类型图标并入名称，其余列窄而锁定。理想宽度之和不超过默认窗口（1180，检查器400）下的表格宽度，首次打开不溢出，by AI.Coding。
            TableColumn("名称") { row in NameCell(row: row, categories: history.categories, memberships: model.memberships[row.id] ?? [], showsContent: history.canDisplayContents, history: history) }
                .width(min: 220, ideal: 240)
            TableColumn("来源") { row in Text(row.source.name).foregroundStyle(.secondary).lineLimit(1) }.width(min: 88, ideal: 88, max: 88)
            TableColumn("最近复制", value: \.lastCopiedAt) { row in
                CopyAge(copiedAt: row.lastCopiedAt).foregroundStyle(.secondary)
                    .help(Date(timeIntervalSince1970: Double(row.lastCopiedAt) / 1000).formatted(date: .abbreviated, time: .standard))
            }.width(min: 84, ideal: 84, max: 84)
            TableColumn("") { row in
                let visible = hovered == row.id || model.selection.contains(row.id)
                HStack(spacing: 6) {
                    Button { model.beginEdit(row.id) } label: { Image(systemName: "pencil") }.help("编辑 · ⌘E").accessibilityLabel("编辑")
                        .disabled(![ClipKind.text, .url].contains(row.kind))
                    Button { model.delete([row.id]) } label: { Image(systemName: "trash") }.help("删除 · ⌫").accessibilityLabel("删除")
                }.buttonStyle(.borderless).opacity(visible ? 1 : 0)
                    .onHover { if $0 { hovered = row.id } else if hovered == row.id { hovered = nil } }
            }.width(min: 48, ideal: 48, max: 48)
        } rows: {
            // 行可拖到侧栏分类；载荷只是本窗口令牌，目标在拖动开始时按选择解析，by AI.Coding。
            ForEach(model.rows) { row in TableRow(row).draggable(ManagerDragToken(value: model.dragToken(for: row.id))) }
        }
        .onChange(of: order) { _, value in model.sort = value.first?.order == .forward ? .recentAsc : .recentDesc }
        .onChange(of: model.sort) { _, sort in
            if sort == .recentAsc || sort == .recentDesc { order = [KeyPathComparator(\ClipSummary.lastCopiedAt, order: sort == .recentAsc ? .forward : .reverse)] }
        }
        // 不设双击动作：双击会让间隔内连点两行勾选框被表格当成双击，改选该行并弹出编辑；编辑走 ⌘E、铅笔与右键，by AI.Coding。
        .contextMenu(forSelectionType: ClipID.self) { ids in
            // 右键已选记录时作用于完整目标（含跨页全选），不静默降级为本页，by AI.Coding。
            let clicked = model.rows.map(\.id).filter(ids.contains)
            let selected = !clicked.isEmpty && Set(clicked).isSubset(of: model.selection)
            ManagerRowMenu(model: model, history: history, ids: selected ? model.targetIDs : clicked, selectAll: selected ? model.selectAllID : nil)
        }
        .overlay {
            if model.rows.isEmpty {
                if model.loading { ProgressView() }
                else if !model.queryProblems.isEmpty {
                    ContentUnavailableView("条件未生效", systemImage: "exclamationmark.magnifyingglass", description: Text(model.queryProblems.joined(separator: "\n")))
                }
                else if model.failed { ContentUnavailableView { Label("读取失败", systemImage: "exclamationmark.triangle") } actions: { Button("重试", action: model.retry) } }
                else if !model.literal.isEmpty || model.hasFilters || model.scope != .all { ContentUnavailableView.search }
                else { ContentUnavailableView("暂无历史", systemImage: "tray") }
            }
        }
    }
}
extension ManagerTable {
    /// 当前事件是落在勾选列（第0列）上的连击：表格据此改选整行，勾选框收不到这次点击，by AI.Coding。
    static func checkboxDoubleClick() -> Bool {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1,
              let frame = event.window?.contentView?.superview, let hit = frame.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view as? NSTableView else { return false }
        return table.column(at: table.convert(event.locationInWindow, from: nil)) == 0
    }
}
private struct NameCell: View {
    let row: ClipSummary
    let categories: [ClipCategory]
    let memberships: Set<String>
    let showsContent: Bool
    let history: HistoryViewModel
    @State private var preview: RowPreview?
    var body: some View {
        HStack(spacing: 8) {
            RowPreviewTile(row: row, preview: showsContent ? preview : nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if row.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                    Text(title).lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        ForEach(categories.filter { memberships.contains($0.id) }) { category in
                            CategoryDot(category: category).help(category.name)
                        }
                    }
                }
                if showsContent, let snippet {
                    Text(snippet).font(preview?.text != nil ? .system(size: 11, design: .monospaced) : .system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
                }
            }
        }
        // 悬停显示较长的摘要预览，不读正文；内容隐藏时不提示，by AI.Coding。
        .help(showsContent ? (row.preview.isEmpty ? HistoryView.displayTitle(row) : row.preview) : "")
        .task(id: showsContent ? row.id + "|" + (row.contentFingerprint ?? "") : "") {
            guard showsContent else { preview = nil; return }
            preview = await RowPreview.load(row, history: history)
        }
    }
    private var title: String { Self.title(row) }
    /// 文件只显示文件名，完整路径留在悬停提示里；检查器名称占位同用，by AI.Coding。
    static func title(_ row: ClipSummary) -> String {
        guard row.kind == .file, row.title == nil, let first = row.preview.split(whereSeparator: \.isNewline).first else { return HistoryView.displayTitle(row) }
        return (String(first) as NSString).lastPathComponent
    }
    /// 文本/代码文件取开头几行；文字记录取首行之后的摘要；有标题时摘要是正文开头。
    private var snippet: String? {
        if let text = preview?.text { return Self.lines(text, dropFirst: false) }
        guard [.text, .url].contains(row.kind) else { return nil }
        return Self.lines(row.preview, dropFirst: row.title == nil)
    }
    private static func lines(_ text: String, dropFirst: Bool) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let value = (dropFirst ? Array(lines.dropFirst()) : lines).prefix(2).joined(separator: "\n")
        return value.isEmpty ? nil : value
    }
}
/// 名称列预览数据：图片与卡片共用缩略图服务和缓存；文件与卡片同用 FileCardPreview 按内容决定显示图像还是开头文字，by AI.Coding。
private struct RowPreview {
    var image: NSImage?
    var text: String?
    var icon: NSImage?
    @MainActor static func load(_ row: ClipSummary, history: HistoryViewModel) async -> RowPreview? {
        switch row.kind {
        case .image, .mixed:
            if let cached = history.thumbnails.object(forKey: row.id as NSString) { return .init(image: cached) }
            let result = await history.derived.thumbnail(id: row.id)
            guard !Task.isCancelled, let image = ThumbnailPreviewState(result).image else { return nil }
            if case .image(let data) = result { history.thumbnails.setObject(image, forKey: row.id as NSString, encodedBytes: data.count) }
            return .init(image: image)
        case .file:
            guard let url = try? await history.previewDetail(id: row.id).payload.fileURLs?.first, !Task.isCancelled else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            switch await FileCardPreview.render(fileAt: url) {
            case .image(let data): return .init(image: NSImage(data: data), icon: icon)
            case .text(let text): return .init(text: text, icon: icon)
            case .unavailable: return .init(icon: icon)
            }
        default: return nil
        }
    }
}
/// 固定 72×48，行高一致又看得清；图片按比例完整显示，加载前和不能预览时显示类型图标，by AI.Coding。
private struct RowPreviewTile: View {
    let row: ClipSummary
    let preview: RowPreview?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05))
            if let image = preview?.image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .padding(3)
            } else if let icon = preview?.icon {
                Image(nsImage: icon).resizable().scaledToFit().padding(8)
            } else {
                Image(systemName: HistoryView.kindSymbol(row.kind)).font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 48)
        .help(HistoryView.kindName(row.kind))
    }
}
private struct ManagerRowMenu: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    let ids: [ClipID]
    let selectAll: UUID?
    var body: some View {
        let rows = model.rows.filter { ids.contains($0.id) }
        let single = ids.count == 1 ? rows.first : nil
        if !ids.isEmpty {
            Button("复制") { model.copy(ids) }.keyboardShortcut("c")
            Button("纯文本复制") { model.copy(ids, plain: true) }
            // 与卡片一致提供显式入口，Space处理仍由窗口级键盘路由负责。
            if let single, single.kind == .image || single.kind == .file {
                Button("预览") { model.preview(single.id) }
            }
            Divider()
            Button("编辑…") { if let single { model.beginEdit(single.id) } }.keyboardShortcut("e")
                .disabled(single.map { ![ClipKind.text, .url].contains($0.kind) } ?? true)
            let favorite = model.allFavorite(ids)
            Button(favorite ? "取消收藏" : "收藏") { model.setFavorite(ids, !favorite, selectAll: selectAll) }.keyboardShortcut("d")
            Menu("分类") { CategoryItems(model: model, history: history, ids: ids, selectAll: selectAll) }
            Divider()
            Button("在历史面板中定位") { if let single { model.locate?(single.id) } }.keyboardShortcut("g").disabled(single == nil)
            Divider()
            Button("删除", role: .destructive) { model.delete(ids, selectAll: selectAll) }.keyboardShortcut(.delete, modifiers: [])
        }
    }
}

// MARK: 分页
private struct ManagerPager: View {
    @ObservedObject var model: HistoryManagerModel
    @State private var input = "1"
    var body: some View {
        HStack(spacing: 8) {
            Text(model.rangeText).foregroundStyle(.secondary).monospacedDigit()
            if model.refreshing { ProgressView().controlSize(.mini) }
            Spacer()
            Picker("每页", selection: $model.pageSize) { ForEach(HistoryManagerModel.pageSizes, id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
            Button { model.go(toPage: model.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.page == 0).help("上一页 · Page Up")
            TextField("页码", text: $input).frame(width: 40).multilineTextAlignment(.center)
                .onSubmit { if let value = Int(input) { model.go(toPage: value - 1) }; input = "\(model.page + 1)" }
            Text("/ \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()
            Button { model.go(toPage: model.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.page + 1 >= model.pageCount).help("下一页 · Page Down")
        }
        .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 12).frame(height: 32)
        .disabled(model.loading)
        .onChange(of: model.page) { _, page in input = "\(page + 1)" }
    }
}

// MARK: 检查器
private struct ManagerInspector: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    var body: some View {
        if model.selectingAll {
            VStack(spacing: 8) { ProgressView(); Text("正在选择全部…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selection.count > 1 || model.allMatching != nil {
            ManagerSelectionSummary(summary: model.selectionSummary, categories: history.categories)
        } else if let row = model.selectedRow {
            if let content = model.detail, content.detail.summary.id == row.id { ManagerDetail(model: model, history: history, row: row, content: content).id(row.id) }
            else if model.detailFailed { ContentUnavailableView("内容读取失败", systemImage: "exclamationmark.triangle", description: Text("记录可能已删除或过期。")) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else {
            ContentUnavailableView("未选择记录", systemImage: "sidebar.trailing", description: Text("选择一条记录查看详情。"))
        }
    }
}
private struct ManagerDetail: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    let row: ClipSummary
    let content: ClipDetailContent
    @State private var draft = HistoryManagerModel.NameDraft(nil)
    @State private var draftID = UUID()
    /// 自动生成的名称同样是可读标题，占位提示与已保存名称均使用正文颜色，by AI.Coding。
    var body: some View {
        let detail = content.detail
        let urls = row.kind == .file ? detail.payload.fileURLs ?? [] : []
        let hasOCR = row.kind == .image || row.kind == .mixed || urls.contains { ClipboardPayload.isImageFile($0.path) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                // 未命名记录以预览作提示，显式指定颜色，避免系统将名称渲染成浅灰占位文字。
                TextField(NameCell.title(row), text: $draft.text, prompt: Text(NameCell.title(row)).foregroundStyle(.primary))
                    .textFieldStyle(.plain).font(.system(size: LCStyle.FontSize.heading, weight: .semibold))
                    .foregroundStyle(.primary)
                    .onSubmit {
                        guard let name = draft.submit(current: row.title) else { return }
                        Task { await model.rename(row.id, name); draft.finished(name) }
                    }
                Button { model.setFavorite([row.id], !row.isFavorite) } label: { Image(systemName: row.isFavorite ? "star.fill" : "star").foregroundStyle(row.isFavorite ? .yellow : .secondary) }
                    .buttonStyle(.borderless).help(row.isFavorite ? "取消收藏 · ⌘D" : "收藏 · ⌘D")
            }
            // 记录信息常显为一行，格式与来源依据放悬停提示；说明文字直接显示，by AI.Coding。
            Text(ClipRecordInfo.line(detail)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help("\(HistoryView.sourceDescription(row.source))\n\(detail.payload.items.count) 项 · 格式：\(ClipRecordInfo.formats(detail))")
            ClipRecordInfo.Notes(detail: detail)
            // 预览占满名称、来源行与底部分类、按钮之外的高度，长文在区内滚动，by AI.Coding。
            ClipDetailPreview(detail: detail, image: content.image, text: content.richPreview, highlight: content.highlight, interactive: history.canDisplayContents, fills: true)
                .frame(maxHeight: .infinity, alignment: .top)
            ManagerCategoryChips(model: model, history: history, row: row, included: detail.categoryIDs)
            HStack {
                if row.kind == .image || row.kind == .file {
                    Button("预览") { model.preview(row.id) }.help("空格预览，再按空格或Esc关闭")
                }
                if hasOCR { Button("复制图中文字") { history.copyImageText(id: row.id) } }
                if !urls.isEmpty { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(urls.filter { FileManager.default.fileExists(atPath: $0.path) }) } }
                if urls.isEmpty, let link = HistoryViewModel.openTargets(detail.payload).first { Button("打开链接") { NSWorkspace.shared.open(link) } }
                Spacer()
                Button("复制") { model.copy([row.id]) }.buttonStyle(.borderedProminent).help("复制 · ↩")
            }
        }
        .padding(12)
        .onAppear { draft = .init(row.title); registerDraft() }
        .onChange(of: row.title) { old, title in draft.titleChanged(from: old, to: title); registerDraft() }
        .onDisappear { history.surfaceEdits.remove(draftID) }
    }
    /// 草稿仍由输入框持有，仅登记切换时的校验、保存和放弃操作。
    private func registerDraft() {
        history.surfaceEdits.register(draftID, surface: .manager, draft: .init(title: "名称修改", dirty: {
            draft.text != (row.title ?? "") || !draft.pending.isEmpty
        }, save: {
            guard draft.pending.isEmpty else { return false }
            guard let name = draft.submit(current: row.title) else { return true }
            let saved = await model.rename(row.id, name); draft.finished(name); return saved
        }, discard: { draft = .init(row.title) }))
    }
}
/// 多选只显示汇总；数量在批量栏，不在此重复，逐条名称见表格勾选行，by AI.Coding。
private struct ManagerSelectionSummary: View {
    let summary: HistoryManagerModel.SelectionSummary
    let categories: [ClipCategory]
    var body: some View {
        let used = categories.filter { summary.categories[$0.id] != nil }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("类型")
                Text(ClipKind.allCases.compactMap { kind in summary.kinds[kind].map { "\(HistoryView.kindName(kind)) \($0)" } }.joined(separator: " · "))
            }
            GridRow { label("已收藏"); Text("\(summary.favorites) 条") }
            if !used.isEmpty {
                GridRow {
                    label("分类")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(used) { category in
                            HStack(spacing: 6) { CategoryDot(category: category); Text(category.name).lineLimit(1); Text("\(summary.categories[category.id] ?? 0) 条").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if let earliest = summary.earliest, let latest = summary.latest {
                GridRow { label("复制时间"); Text(earliest == latest ? ClipRecordInfo.time(latest) : "\(ClipRecordInfo.time(earliest)) – \(ClipRecordInfo.time(latest))") }
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func label(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing) }
}
private struct ManagerCategoryChips: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    let row: ClipSummary
    let included: Set<String>
    var body: some View {
        HStack(spacing: 6) {
            ForEach(history.categories.filter { included.contains($0.id) }) { category in
                HStack(spacing: 4) {
                    CategoryDot(category: category)
                    Text(category.name).lineLimit(1)
                    Button { model.setCategory([row.id], category.id, false) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.borderless).help("移出分类").accessibilityLabel("移出\(category.name)")
                }.font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.06), in: Capsule())
            }
            let others = history.categories.filter { !included.contains($0.id) }
            if !others.isEmpty {
                Menu("＋ 分类") { ForEach(others) { category in Button(category.name) { model.setCategory([row.id], category.id, true) } } }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
        }
    }
}
private struct ManagerToast: View {
    @ObservedObject var model: HistoryManagerModel
    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Text(toast.text).foregroundStyle(toast.failed ? Color.red : Color.primary)
                if toast.undo { Button("撤销") { model.undoDelete() }.buttonStyle(.link) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).shadow(radius: 6, y: 2)
            .padding(.bottom, 44).transition(.opacity).id(toast.id)
        }
    }
}
/// 管理窗口内部拖动载荷：沿用已声明的内部历史类型，只带令牌；其他应用与 Finder 不认该类型，by AI.Coding。
struct ManagerDragToken: Transferable {
    let value: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: UTType(exportedAs: HistoryViewModel.categoryDragType)) { Data($0.value.utf8) }
            importing: { ManagerDragToken(value: String(decoding: $0, as: UTF8.self)) }
    }
}
private struct CategoryDot: View {
    let category: ClipCategory
    var size: CGFloat = 7
    var body: some View { Circle().fill(Color(nsColor: RichContent.colorValue(category.colorHex))).frame(width: size, height: size) }
}
