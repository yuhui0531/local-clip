// 历史管理三栏：侧栏范围、分页表格、检查器；只复制不直接粘贴，by AI.Coding。
import AppKit
import SwiftUI
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
                ManagerInspector(model: model, history: history).inspectorColumnWidth(min: 280, ideal: 320, max: 440)
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
        // 隐藏内容时放弃选择并关闭编辑器，不在遮罩下保留可操作对象，by AI.Coding。
        .onChange(of: history.canDisplayContents) { _, visible in if !visible { model.clearSelection(); model.editor = nil } }
        .sheet(isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.editor = nil } })) {
            if let editor = model.editor {
                ClipContentEditor(state: editor, save: model.saveEdit, cancel: model.cancelEdit, discard: { model.editor = nil })
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
    @State private var creating = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
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
                    Label { Text(category.name) } icon: { CategoryDot(category: category, size: 9) }
                        .tag(HistoryManagerModel.Scope.category(category.id))
                }
                if creating {
                    TextField("分类名称", text: $draft).focused($draftFocused)
                        .onSubmit(commit).onExitCommand { creating = false; draft = "" }
                        .onChange(of: draftFocused) { _, focused in if !focused && creating { commit() } }
                }
            } header: {
                HStack {
                    Text("分类"); Spacer()
                    Button { creating = true; draft = ""; draftFocused = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("新建分类").accessibilityLabel("新建分类")
                }
            }
        }
        .listStyle(.sidebar)
    }
    private func commit() {
        let name = draft
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { creating = false; return }
        Task { if await model.createCategory(name) { creating = false; draft = "" } else { draftFocused = true } }
    }
}

// MARK: 筛选与批量
private struct ManagerFilterBar: View {
    @ObservedObject var model: HistoryManagerModel
    var body: some View {
        HStack(spacing: 10) {
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
        let ids = model.targetIDs
        HStack(spacing: 10) {
            Text("已选择 \(ids.count) 条").font(.system(size: LCStyle.FontSize.body, weight: .semibold))
            if model.selectingAll { ProgressView().controlSize(.small); Text("正在选择全部…").foregroundStyle(.secondary) }
            else if model.allMatching == nil, model.total > ids.count { Button("选择全部 \(model.total) 条", action: model.selectAllMatching).buttonStyle(.link) }
            Spacer()
            Button("收藏") { model.setFavorite(ids, true) }
            Menu("分类…") { CategoryItems(model: model, history: history, ids: ids) }.fixedSize()
            Button("删除", role: .destructive) { model.delete(ids) }
            Button("取消", action: model.clearSelection)
        }.padding(.horizontal, 12).frame(height: 40).background(Color.accentColor.opacity(0.08))
    }
}
/// 勾选表示所选记录全部已在该分类，点按整体加入或移出。
private struct CategoryItems: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    let ids: [ClipID]
    var body: some View {
        ForEach(history.categories) { category in
            let included = !ids.isEmpty && ids.allSatisfy { model.memberships[$0]?.contains(category.id) == true }
            Toggle(category.name, isOn: Binding(get: { included }, set: { model.setCategory(ids, category.id, $0) }))
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
        Table(model.rows, selection: $model.selection, sortOrder: $order) {
            TableColumn("") { row in
                Toggle("", isOn: Binding(get: { model.selection.contains(row.id) }, set: { on in if on { model.selection.insert(row.id) } else { model.selection.remove(row.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
            }.width(22)
            TableColumn("") { row in Image(systemName: HistoryView.kindSymbol(row.kind)).foregroundStyle(.secondary) }.width(22)
            TableColumn("名称") { row in NameCell(row: row, categories: history.categories, memberships: model.memberships[row.id] ?? []) }
            TableColumn("来源") { row in Text(row.source.name).foregroundStyle(.secondary).lineLimit(1) }.width(min: 70, ideal: 110, max: 180)
            TableColumn("最近复制", value: \.lastCopiedAt) { row in
                CopyAge(copiedAt: row.lastCopiedAt).foregroundStyle(.secondary)
                    .help(Date(timeIntervalSince1970: Double(row.lastCopiedAt) / 1000).formatted(date: .abbreviated, time: .standard))
            }.width(min: 70, ideal: 90, max: 130)
            TableColumn("") { row in
                let visible = hovered == row.id || model.selection.contains(row.id)
                HStack(spacing: 6) {
                    Button { model.beginEdit(row.id) } label: { Image(systemName: "pencil") }.help("编辑 · ⌘E").accessibilityLabel("编辑")
                        .disabled(![ClipKind.text, .url].contains(row.kind))
                    Button { model.delete([row.id]) } label: { Image(systemName: "trash") }.help("删除 · ⌫").accessibilityLabel("删除")
                }.buttonStyle(.borderless).opacity(visible ? 1 : 0)
                    .onHover { if $0 { hovered = row.id } else if hovered == row.id { hovered = nil } }
            }.width(48)
        }
        .onChange(of: order) { _, value in model.sort = value.first?.order == .forward ? .recentAsc : .recentDesc }
        .onChange(of: model.sort) { _, sort in
            if sort == .recentAsc || sort == .recentDesc { order = [KeyPathComparator(\ClipSummary.lastCopiedAt, order: sort == .recentAsc ? .forward : .reverse)] }
        }
        .contextMenu(forSelectionType: ClipID.self) { ids in
            ManagerRowMenu(model: model, history: history, ids: model.rows.map(\.id).filter(ids.contains))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { model.beginEdit(id) }
        }
        .overlay {
            if model.rows.isEmpty {
                if model.failed { ContentUnavailableView { Label("读取失败", systemImage: "exclamationmark.triangle") } actions: { Button("重试") { model.reload() } } }
                else if !model.literal.isEmpty || model.hasFilters || model.scope != .all { ContentUnavailableView.search }
                else { ContentUnavailableView("暂无历史", systemImage: "tray") }
            }
        }
    }
}
private struct NameCell: View {
    let row: ClipSummary
    let categories: [ClipCategory]
    let memberships: Set<String>
    var body: some View {
        HStack(spacing: 6) {
            if row.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
            Text(HistoryView.displayTitle(row)).lineLimit(1)
            if row.title != nil { Text(row.preview).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                ForEach(categories.filter { memberships.contains($0.id) }) { category in
                    CategoryDot(category: category).help(category.name)
                }
            }
        }
    }
}
private struct ManagerRowMenu: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    let ids: [ClipID]
    var body: some View {
        let rows = model.rows.filter { ids.contains($0.id) }
        let single = rows.count == 1 ? rows.first : nil
        if !rows.isEmpty {
            Button("复制") { model.copy(ids) }.keyboardShortcut("c")
            Button("纯文本复制") { model.copy(ids, plain: true) }
            Divider()
            Button("编辑…") { if let single { model.beginEdit(single.id) } }.keyboardShortcut("e")
                .disabled(single.map { ![ClipKind.text, .url].contains($0.kind) } ?? true)
            let favorite = rows.allSatisfy(\.isFavorite)
            Button(favorite ? "取消收藏" : "收藏") { model.setFavorite(ids, !favorite) }.keyboardShortcut("d")
            Menu("分类") { CategoryItems(model: model, history: history, ids: ids) }
            Divider()
            Button("在历史面板中定位") { if let single { model.locate?(single.id) } }.keyboardShortcut("g").disabled(single == nil)
            Divider()
            Button("删除", role: .destructive) { model.delete(ids) }.keyboardShortcut(.delete, modifiers: [])
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
            Spacer()
            Picker("每页", selection: $model.pageSize) { ForEach(HistoryManagerModel.pageSizes, id: \.self) { Text("\($0)").tag($0) } }.fixedSize()
            Button { model.go(toPage: model.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.page == 0).help("上一页 · Page Up")
            TextField("页码", text: $input).frame(width: 40).multilineTextAlignment(.center)
                .onSubmit { if let value = Int(input) { model.go(toPage: value - 1) }; input = "\(model.page + 1)" }
            Text("/ \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()
            Button { model.go(toPage: model.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.page + 1 >= model.pageCount).help("下一页 · Page Down")
        }
        .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 12).frame(height: 32)
        .onChange(of: model.page) { _, page in input = "\(page + 1)" }
    }
}

// MARK: 检查器
private struct ManagerInspector: View {
    @ObservedObject var model: HistoryManagerModel
    @ObservedObject var history: HistoryViewModel
    var body: some View {
        if model.selection.count > 1 || model.allMatching != nil {
            let names = model.rows.filter { model.selection.contains($0.id) }.map(HistoryView.displayTitle)
            VStack(alignment: .leading, spacing: 8) {
                Text("已选择 \(model.targetIDs.count) 条").font(.headline)
                List(Array(names.enumerated()), id: \.offset) { Text($0.element).lineLimit(1) }.listStyle(.plain)
            }.padding(12)
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
    @State private var name = ""
    var body: some View {
        let detail = content.detail
        let urls = row.kind == .file ? detail.payload.fileURLs ?? [] : []
        let hasOCR = row.kind == .image || row.kind == .mixed || urls.contains { ClipboardPayload.isImageFile($0.path) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField(row.preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? HistoryView.kindName(row.kind), text: $name)
                    .textFieldStyle(.plain).font(.system(size: LCStyle.FontSize.heading, weight: .semibold))
                    .onSubmit { if name != (row.title ?? "") { model.rename(row.id, name) } }
                Button { model.setFavorite([row.id], !row.isFavorite) } label: { Image(systemName: row.isFavorite ? "star.fill" : "star").foregroundStyle(row.isFavorite ? .yellow : .secondary) }
                    .buttonStyle(.borderless).help(row.isFavorite ? "取消收藏 · ⌘D" : "收藏 · ⌘D")
            }
            Text(HistoryView.sourceDescription(row.source))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ClipDetailPreview(detail: detail, image: content.image, text: content.richPreview, highlight: content.highlight, interactive: history.canDisplayContents)
            }.frame(maxHeight: .infinity)
            ManagerCategoryChips(model: model, history: history, row: row, included: detail.categoryIDs)
            ClipRecordInfo(detail: detail)
            HStack {
                if hasOCR { Button("复制图中文字") { history.copyImageText(id: row.id) } }
                if !urls.isEmpty { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(urls.filter { FileManager.default.fileExists(atPath: $0.path) }) } }
                if urls.isEmpty, let link = HistoryViewModel.openTargets(detail.payload).first { Button("打开链接") { NSWorkspace.shared.open(link) } }
                Spacer()
                Button("复制") { model.copy([row.id]) }.buttonStyle(.borderedProminent).help("复制 · ↩")
            }
        }
        .padding(12)
        .onAppear { name = row.title ?? "" }
        .onChange(of: row.title) { _, title in name = title ?? "" }
    }
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
private struct CategoryDot: View {
    let category: ClipCategory
    var size: CGFloat = 7
    var body: some View { Circle().fill(Color(nsColor: RichContent.colorValue(category.colorHex))).frame(width: size, height: size) }
}
