// 配置界面：持久化完成后展示生效，系统权限由用户操作，by AI.Coding。
import AppKit
import SwiftUI
import Carbon
import LocalClipCore
/// 页面只切换展示分组，所有设置继续使用原有持久化入口，by AI.Coding。
enum SettingsSection: String, CaseIterable {
    case general = "通用", paste = "粘贴", privacy = "隐私", storage = "存储", advanced = "高级"
    var symbol: String {
        switch self { case .general: "gearshape"; case .paste: "clipboard"; case .privacy: "hand.raised"; case .storage: "internaldrive"; case .advanced: "slider.horizontal.3" }
    }
}
/// 分组表单在传统滚动条模式下仍使用 AppKit 滚动条，隐藏它但保留滚动，by AI.Coding。
private struct SettingsScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    /// 只作用于当前表单的滚动视图，系统偏好改变时重新应用，by AI.Coding。
    @MainActor final class Probe: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(preferenceChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        @objc private func preferenceChanged() { DispatchQueue.main.async { [weak self] in self?.apply() } }
        func apply() {
            guard let scroll = enclosingScrollView else { return }
            // SwiftUI 会重新启用滚动条；使用悬浮样式避免占位，并隐藏原生指示器。
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            scroll.autohidesScrollers = true
            scroll.verticalScroller?.alphaValue = 0
        }
    }
}
public struct SettingsView: View {
    @ObservedObject var model: HistoryViewModel
    let login: LoginItemService
    @State private var section: SettingsSection = .general
    var sectionChanged: (SettingsSection) -> Void = { _ in }
    @State private var draftID = UUID()
    @State private var retention = "30"
    @State private var quota = "500"
    @State private var recording = false
    @State private var recordingQueue = false
    @State private var confirmingDragFiles = false
    @State private var monitor: Any?
    @State private var loginStatus = ""
    @State private var loginEnabled = false
    @State private var permitted = false
    @ObservedObject private var updates = UpdateChecker.shared
    // 底栏只显示设置窗口在前台时产生的反馈；面板粘贴、采集等全局消息不进入设置，by AI.Coding。
    @State private var feedback = ""
    // 窗口高度跟随当前分组内容，过长分组才滚动，避免短分组下方大片留白，by AI.Coding。
    @State private var formHeight: CGFloat = 360
    // 头部与底栏固定高度单独测量，窗口目标高度=头部+表单+底栏，by AI.Coding。
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    public init(model: HistoryViewModel, login: LoginItemService) { self.model = model; self.login = login }
    /// 内容自然高度变化时调整承载窗口；默认交给设置窗口，调试渲染可替换。
    var fitWindow: (CGFloat) -> Void = { height in NSApp.windows.lazy.compactMap { $0 as? SettingsWindow }.first?.fitContent(height: height) }
    init(model: HistoryViewModel, login: LoginItemService, section: SettingsSection, fitWindow: @escaping (CGFloat) -> Void) {
        self.init(model: model, login: login); _section = State(initialValue: section); self.fitWindow = fitWindow
    }
    /// 原生分组表单：按“通用 / 粘贴 / 隐私 / 存储 / 高级”组织，说明放入分组脚注；失焦与Esc由窗口管理，录制期间Esc只取消录制，by AI.Coding。
    public var body: some View {
        VStack(spacing: 0) {
            // macOS设置窗口惯用的图标标签栏，与下方表单同一底色，by AI.Coding。
            HStack(spacing: 4) {
                ForEach(SettingsSection.allCases, id: \.self) { value in SettingsTab(section: value, selected: section == value) { section = value } }
            }.padding(.top, 10).padding(.bottom, 8).frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { Divider() }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Form {
                if section == .general {
                    Section {
                        Picker("外观", selection: setting(\.appearance)) {
                            Text("跟随系统").tag(AppAppearance.system)
                            Text("浅色").tag(AppAppearance.light)
                            Text("深色").tag(AppAppearance.dark)
                        }.pickerStyle(.segmented).background(SettingsScrollerHider())
                        Toggle("紧凑布局", isOn: setting(\.compactLayout))
                        Toggle("显示菜单栏图标", isOn: setting(\.showMenuIcon))
                        LabeledContent("全局快捷键") {
                            Button(recording && !recordingQueue ? "按下新的快捷键…" : HotKeyService.label(model.settings.shortcut)) { recordShortcut() }
                                .help(recording ? "按 Esc 取消" : "点按后按下新的快捷键")
                        }
                        // 登录启动显示系统真实状态，开关只在用户点击时请求注册。
                        Toggle("登录时启动", isOn: Binding(get: { loginEnabled }, set: { loginChange($0) }))
                        // 沿用原偏好控制后台检查和下载，关闭时立即取消未完成的后台下载，by AI.Coding。
                        Toggle("自动检查并下载更新", isOn: Binding(get: { model.settings.autoCheckUpdates }, set: { value in
                            model.updateSettings { $0.autoCheckUpdates = value }
                            updates.automaticUpdatesChanged(enabled: value)
                        }))
                        LabeledContent("当前版本 \(UpdateChecker.currentVersion)") {
                            switch updates.phase {
                            case .downloading:
                                HStack { ProgressView().controlSize(.small); Text("正在下载更新…") }
                            case .ready:
                                Button("安装并重启") { Task { await updates.installAndRestart() } }.buttonStyle(.borderedProminent)
                            case .installing:
                                HStack { ProgressView().controlSize(.small); Text("正在准备安装…") }
                            case .manualOnly:
                                HStack {
                                    if let release = updates.available { Button("查看版本 \(release.version)…") { NSWorkspace.shared.open(release.page) } }
                                    // 资产稍后补齐时可立即重查，仍由用户显式选择安装。
                                    Button(updates.checking ? "正在检查…" : "重新检查") { Task { await updates.check(manual: true) } }.disabled(updates.checking)
                                }
                            case .failed, .idle:
                                Button(updates.checking ? "正在检查…" : "检查更新") { Task { await updates.check(manual: true) } }.disabled(updates.checking)
                            }
                        }
                        if case let .failed(message) = updates.phase { Text(message).foregroundStyle(.red).font(.caption) }
                        if case .manualOnly = updates.phase { Text("此版本尚未提供签名更新包，请从发布页手动安装。").settingsFootnote() }
                        if let result = updates.manualResult { Text(result).foregroundStyle(.secondary).font(.caption).onAppear { updates.markResultSeen() } }
                        if login.status == .requiresApproval || loginStatus.hasPrefix("请求失败") {
                            LabeledContent(loginStatus) { Button("打开登录项…") { login.openSettings() } }.foregroundStyle(.secondary)
                        }
                    } header: { Text("外观与启动") } footer: {
                        Text("自动检查每天最多一次；新版本会自动下载并验签，仅点击“安装并重启”后更新，普通退出不会安装。更新前保留旧应用及历史、设置快照，不发送剪贴板内容。当前使用临时签名，更新后 macOS 可能要求重新授予辅助功能权限。").settingsFootnote()
                    }
                    Section {
                        // 开关传递绝对用户意图，不能由启动时的新配置反转，by AI.Coding。
                        Toggle("监控剪贴板变化", isOn: Binding(get: { model.settings.captureEnabled }, set: { value in model.setCaptureEnabled(value) }))
                        LabeledContent("定时停止监控") {
                            if let deadline = model.settings.pauseUntil, deadline > SystemClock().now() {
                                Text("至 " + Date(timeIntervalSince1970: Double(deadline)/1000).formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                                Button("取消") { model.updateSettings { $0.pauseUntil = nil } }
                            } else {
                                Menu("停止…") {
                                    Button("15 分钟") { model.updateSettings { $0.pauseUntil = SystemClock().now() + 15 * 60_000 } }
                                    Button("1 小时") { model.updateSettings { $0.pauseUntil = SystemClock().now() + 60 * 60_000 } }
                                }.fixedSize()
                            }
                        }
                        Toggle("复制新内容时播放提示音", isOn: setting(\.captureSounds))
                    } header: { Text("监控") } footer: {
                        Text("启动后自动监控新复制内容；手动停止只作用于本次运行，定时停止按期限保留。").settingsFootnote()
                    }
                }
                if section == .paste {
                    Section {
                        Picker("Return 默认操作", selection: setting(\.defaultAction)) {
                            Text("直接粘贴").tag(PasteAction.directPaste); Text("仅复制").tag(PasteAction.copy)
                        }.background(SettingsScrollerHider())
                        Picker("默认输出格式", selection: setting(\.defaultFormat)) { Text("原格式").tag(OutputFormat.original); Text("纯文本").tag(OutputFormat.plainText) }
                        Toggle("复制或粘贴后移到最前", isOn: setting(\.moveUsedToFront)).help("开启后，用过的记录排到历史第一位")
                        Picker("数字 1–9 快捷粘贴", selection: setting(\.quickModifiers)) { Text("⌘ + 数字").tag(UInt32(256)); Text("⌥ + 数字").tag(UInt32(2048)); Text("⌃ + 数字").tag(UInt32(4096)); Text("⌘⇧ + 数字").tag(UInt32(768)) }
                        Picker("切换／新建分类", selection: setting(\.boardModifiers)) { Text("⌘⇧ + ← / → / N").tag(UInt32(768)); Text("⌘⌥ + ← / → / N").tag(UInt32(2304)); Text("⌃⌥ + ← / → / N").tag(UInt32(6144)) }
                        // 只在粘贴队列进行中注册，平时不占用该组合键，by AI.Coding。
                        LabeledContent("粘贴队列下一项") {
                            Button(recording && recordingQueue ? "按下新的快捷键…" : HotKeyService.label(model.settings.queueShortcut)) { recordShortcut(queue: true) }
                                .help(recording && recordingQueue ? "按 Esc 取消" : "多选后右键“加入粘贴队列”，每按一次粘贴下一项")
                        }
                        LabeledContent("辅助功能权限") {
                            Label(permitted ? "已授予" : "未授予", systemImage: permitted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(permitted ? Color.green : Color.orange)
                            if !permitted { Button("开启…") { AccessibilityGuide.shared.show(skipIntro: true) } }
                        }
                    } header: { Text("粘贴方式") } footer: {
                        Text("结果中按 Return 执行上面的默认操作，⇧Return 直接粘贴纯文本。直接粘贴需要辅助功能权限，仅恢复目标应用，不能保证原输入框或光标位置；没有权限仍可复制后手动粘贴。").settingsFootnote()
                        settingsLimits("搜索中 ↑/↓ 选择并进入结果，Return 先进入结果；结果中 ⌘C 复制所选。搜索中也可用 ⌘I/E/T/O/G/R 操作所选记录；Tab/Shift-Tab 切换控件焦点。")
                    }
                    Section {
                        Toggle("代码文件智能粘贴", isOn: setting(\.smartCodeFilePaste))
                        ForEach(model.settings.smartPasteEditorBundleIDs.sorted(), id: \.self) { id in
                            BundleRow(id: id) { model.updateSettings { $0.smartPasteEditorBundleIDs.remove(id) } }
                        }
                        Button("添加可识别的编辑器应用…", action: chooseSmartPasteEditor)
                    } header: { Text("代码") } footer: {
                        Text("开启后，粘贴到列表中的编辑器时插入代码文件正文；Finder、未知目标或读取失败仍粘贴原文件。默认关闭，默认没有应用获准。").settingsFootnote()
                        settingsLimits("确认是文本编辑目标时才粘贴正文。拖出代码文件时提供正文，拖到编辑器插入代码，拖到Finder仍复制原文件。代码片段语法高亮始终启用。多文件按顺序用换行分隔；每文件最多4MiB，合计8MiB。仅将所选应用未暴露文本控件的AXWindow视为编辑器；所选应用的窗口（包括其中未被识别为终端的终端面板）可能收到文件正文，终端应用及已标记的终端上下文仍被排除。")
                    }
                }
                if section == .privacy {
                    Section {
                        Toggle("隐藏历史内容", isOn: setting(\.hideContents)).help("开启后面板、预览与队列浮窗不显示正文；复制与粘贴照常").background(SettingsScrollerHider())
                        Toggle("限制系统窗口共享读取", isOn: setting(\.excludeFromSharing)).help("开启后截图、录屏与共享通常看不到 LocalClip 的窗口")
                        Toggle("排除应用位于前台时停止监控", isOn: setting(\.pauseWhenExcludedFrontmost)).help("开启后，排除列表中的应用在前台期间复制的内容都不记录")
                        // 保留声明来源契约，将普通应用的排除前提放在列表旁，by AI.Coding。
                        if !model.settings.excludedBundleIDs.isEmpty && !model.settings.pauseWhenExcludedFrontmost {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("多数应用不声明剪贴板来源。要停止记录所选应用，请开启“排除应用位于前台时停止监控”。", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                                Button("开启前台时停止监控") { model.updateSettings { $0.pauseWhenExcludedFrontmost = true } }
                            }
                        }
                        ForEach(model.settings.excludedBundleIDs.sorted(), id: \.self) { id in
                            BundleRow(id: id) { model.updateSettings { $0.excludedBundleIDs.remove(id) } }
                        }
                        Button("添加要排除的应用…", action: chooseApplication)
                    } footer: {
                        Text("排除只对声明来源的应用生效；要停止记录某个应用，请开启“前台时停止监控”。新增排除不会删除已有历史；数据保存在本机，未宣称加密，不上传剪贴板内容。").settingsFootnote()
                        settingsLimits("排除仅按 org.nspasteboard.source 声明的 bundleID 匹配；前台推断与未知来源不参与应用排除，需要停止记录时请停止监控。开启“前台时停止监控”后，排除应用处于前台的整个区间都不记录，退出区间不补采。敏感/临时标记在正文读取前整次过滤，不能识别所有密码。共享限制使用公开 NSWindow 属性，不能保证所有录屏方式隐藏本窗口。")
                    }
                    // A2：图片文字搜索默认关闭；识别在本机进行，识别文字保存用于搜索，可独立清除，by AI.Coding。
                    Section {
                        Toggle("图片文字搜索", isOn: Binding(get: { model.settings.imageTextSearchSince != nil }, set: { model.setImageTextSearch($0) }))
                            .disabled(!model.imageTextSearchAvailable)
                        HStack {
                            if model.imageTextIndexing { Button("停止索引") { model.stopImageTextIndexing() } }
                            else {
                                Button("为已有图片建立索引") { model.indexExistingImages() }
                                    .disabled(model.settings.imageTextSearchSince == nil || model.settings.hideContents)
                            }
                            Spacer()
                            Button("清除图片文字索引") { model.clearImageTextIndex() }.disabled(!model.imageTextSearchAvailable)
                        }
                        if !model.imageTextSearchAvailable { Text("图片文字索引暂不可用，下次启动时会重试；历史不受影响").font(.caption).foregroundStyle(.secondary) }
                        else if let status = model.imageTextStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                    } footer: {
                        Text("开启后，本机用系统文字识别读取之后复制的图片，识别出的文字保存在本机历史库中用于搜索，不上传。已有图片需点“为已有图片建立索引”，可随时停止、下次继续。关闭后不再识别、不再按图片文字命中；索引保留以便再次开启，可单独清除，开启状态下清除后只为之后复制的图片自动识别。“复制图中文字”不受此开关影响。").settingsFootnote()
                        settingsLimits("目前只识别历史中保存的图片数据，不读取文件引用、PDF 或多页文档；开启“隐藏历史内容”时停止识别，取消隐藏后自动继续识别新图片，已有图片需再点一次建立索引。识别索引计入容量，空间不足时停止索引，不为此删除历史；新内容需要空间时会先清空图片文字索引。")
                    }
                }
                if section == .storage {
                    Section {
                        if let usage = model.usage {
                            LabeledContent("已用空间") {
                                Text("\(HistoryViewModel.bytes(usage.measuredTotal)) / \(HistoryViewModel.bytes(model.settings.quotaBytes))").monospacedDigit()
                            }
                            ProgressView(value: min(1, Double(usage.measuredTotal) / Double(max(1, model.settings.quotaBytes))))
                            Text("保护载荷 \(HistoryViewModel.bytes(usage.favoritePayload)) · 普通载荷 \(HistoryViewModel.bytes(usage.normalPayload)) · 公共页/索引/缩略图 \(HistoryViewModel.bytes(usage.common)) · 待回收 \(HistoryViewModel.bytes(usage.pending))").font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("保留天数") {
                            Text(model.settings.retentionDays == 0 ? "当前永不过期" : "当前 \(model.settings.retentionDays) 天").foregroundStyle(.secondary)
                            TextField("1–365", text: $retention).labelsHidden().frame(width: 70).multilineTextAlignment(.trailing).onSubmit(applyRetention)
                            Button("应用", action: applyRetention).disabled(retention == String(model.settings.retentionDays))
                            Button("永不过期") { model.change(.retention(0), fromSettings: true) }.help("永不过期（仍有容量限制）")
                        }.background(SettingsScrollerHider())
                        LabeledContent("容量上限（MiB）") {
                            TextField("100–4096", text: $quota).labelsHidden().frame(width: 70).multilineTextAlignment(.trailing).onSubmit(applyQuota)
                            Button("应用", action: applyQuota).disabled(quota == String(model.settings.quotaBytes / MiB))
                        }
                        LabeledContent("拖出图片文件") {
                            Text(model.dragFilesBytes.map(HistoryViewModel.bytes) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                            Button("清理…") { confirmingDragFiles = true }.disabled((model.dragFilesBytes ?? 0) == 0)
                        }
                        .alert("清理拖出图片文件？", isPresented: $confirmingDragFiles) {
                            Button("清理", role: .destructive) { model.clearDragFiles() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("历史记录不受影响。只引用这些文件路径（未复制图片）的文档，例如Typora未设置复制图片时，将无法再显示对应图片。")
                        }
                        HStack {
                            Button("清理已到期内容") { Task { await model.maintenance() } }
                            Spacer()
                            Button("清空普通历史…", role: .destructive) { model.change(.clearOrdinary, fromSettings: true) }
                        }
                    } footer: {
                        Text("收藏或加入自定义分类的记录不会因期限或自动淘汰被删除，但计入容量；容量满时保留旧历史、跳过新增。降低设置前会预览确认。").settingsFootnote()
                        settingsLimits("拖出图片文件是拖进编辑器时提供的图片副本，长期保留以免文档图片失效，不计入容量，仅可手动清理。期限按最近有效用户复制起算；浏览和自身恢复不续期。1MiB = 1,048,576 字节。")
                    }
                }
                if section == .advanced {
                    Section {
                        LabeledContent("面板高度") {
                            // 手动取整到10pt，避免带step的原生滑块画出密集刻度。
                            Slider(value: Binding(get: { model.actualPanelHeight }, set: { value in model.resizePanel?((value / 10).rounded() * 10, false) }), in: 280...520, onEditingChanged: { editing in if !editing { model.resizePanel?(model.actualPanelHeight, true) } }).frame(width: 220)
                            Text("\(Int(model.actualPanelHeight)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                        }.background(SettingsScrollerHider())
                        Toggle("启用本机阶段计时日志", isOn: setting(\.timingEnabled))
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("计时日志只记录阶段、条数和毫秒，不含正文、文件路径、URL或搜索词。数据目录：LocalClip-LocalEdition。全新数据模型，不兼容或迁移旧库。")
                            Text("支持文本、URL、RTF、简单HTML、PNG/TIFF/JPEG和文件引用；每次32项、表示数据50MiB。文件不备份本体，原件删除后无法恢复。Finder中双击文件复制到当前文件夹。RTFD、云同步、AI不在此版本。")
                        }.settingsFootnote()
                    }
                }
            // 隐藏设置页滚动条，内容超出屏幕时仍可滚动查看，by AI.Coding。
            }.formStyle(.grouped).scrollContentBackground(.hidden).scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical).id(section)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in formHeight = height }
                // 表单占据头部与底栏之间的剩余空间；窗口动画期间头部钉在顶部、底栏钉在底部，只有表单区伸缩，by AI.Coding。
                .frame(maxHeight: .infinity)
        }
        // 操作反馈固定在底部，不随长表单滚走。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 固定反馈区避免保存提示出现时挤动表单，by AI.Coding。
            VStack(spacing: 0) {
                Divider()
                Label(feedback.isEmpty ? "常规设置自动保存；存储限制需点按“应用”" : feedback, systemImage: feedback.isEmpty ? "checkmark.circle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    .padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading).frame(height: 38)
            }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .onChange(of: model.message) { _, message in if message.isEmpty || NSApp.keyWindow is SettingsWindow { feedback = message } }
        .frame(width: 620)
        // 不再按整页自然高度撑开：内容高于窗口时宿主会居中溢出，导致切换分组时头部上跳再回落，by AI.Coding。
        .onChange(of: windowHeight, initial: true) { _, height in if headerHeight > 0, footerHeight > 0 { fitWindow(height) } }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: section) { _, value in stopRecording(); sectionChanged(value) }
        .onChange(of: model.settings.retentionDays) { _, value in retention = String(value) }
        .onChange(of: model.settings.quotaBytes) { _, value in quota = String(value / MiB) }
        .onExitCommand {
            if recording { stopRecording() }
            else { (NSApp.keyWindow as? SettingsWindow)?.cancelOperation(nil) }
        }
        .onAppear { model.settingsVisibilityChanged(true); model.actualPanelHeight = max(280, model.settings.panelHeight); retention = String(model.settings.retentionDays); quota = String(model.settings.quotaBytes / MiB); refreshLogin(); permitted = MacApplicationClient().permitted; registerStorageDraft() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLogin(); permitted = MacApplicationClient().permitted }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // 复用设置窗口重开时应用可能一直激活；仅刷新系统登录项，不覆盖未应用草稿或改动权限。
            if notification.object is SettingsWindow { refreshLogin() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            // 窗口保留用于再次打开；关闭时立即停止录制，不依赖SwiftUI销毁视图。
            if notification.object is SettingsWindow { model.settingsVisibilityChanged(false); stopRecording(); feedback = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            // 切出设置停止录制，但保留页面和未应用输入，by AI.Coding。
            if notification.object is SettingsWindow { stopRecording() }
        }
        .onDisappear { model.settingsVisibilityChanged(false); stopRecording(); model.surfaceEdits.remove(draftID) }
    }
    /// 手动应用的存储限制也受草稿保护；保留原有可能删除记录的二次确认。
    private func registerStorageDraft() {
        model.surfaceEdits.register(draftID, surface: .settings, draft: .init(title: "存储设置", dirty: {
            retention != String(model.settings.retentionDays) || quota != String(model.settings.quotaBytes / MiB)
        }, save: {
            let changeRetention = retention != String(model.settings.retentionDays)
            let changeQuota = quota != String(model.settings.quotaBytes / MiB)
            guard !changeRetention || Int(retention).map({ (1...365).contains($0) }) == true else { feedback = "保留天数需为1–365"; return false }
            guard !changeQuota || Int64(quota).map({ (100...4096).contains($0) }) == true else { feedback = "容量需为100–4096MiB"; return false }
            if changeRetention, let days = Int(retention) {
                let ok = await withCheckedContinuation { continuation in model.change(.retention(days), fromSettings: true) { continuation.resume(returning: $0) } }
                guard ok else { return false }
            }
            if changeQuota, let value = Int64(quota) {
                return await withCheckedContinuation { continuation in model.change(.quota(value * MiB), fromSettings: true) { continuation.resume(returning: $0) } }
            }
            return true
        }, discard: { retention = String(model.settings.retentionDays); quota = String(model.settings.quotaBytes / MiB) }))
    }
    /// 普通偏好直接读写快照字段，保存仍走updateSettings。
    private func setting<Value>(_ key: WritableKeyPath<SettingsSnapshot, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.updateSettings { $0[keyPath: key] = value } })
    }
    // 按表单与固定区域的实际高度定尺寸，屏幕不足时由窗口限制并保留滚动。
    private var windowHeight: CGFloat { headerHeight + max(formHeight, 160) + footerHeight }
    private func applyRetention() { if let days = Int(retention), (1...365).contains(days) { model.change(.retention(days), fromSettings: true) } else { feedback = "保留天数需为1–365"; model.message = feedback } }
    private func applyQuota() { if let value = Int64(quota), (100...4096).contains(value) { model.change(.quota(value * MiB), fromSettings: true) } else { feedback = "容量需为100–4096MiB"; model.message = feedback } }
    /// 应用选择器读取 bundleID，不将名称作为唯一键。
    private func chooseApplication() {
        guard let bundle = chooseBundleID(title: "选择要排除的应用") else { return }
        model.updateSettings { $0.excludedBundleIDs.insert(bundle) }
    }
    /// 使用相同的应用选择器，仅把明确选中的 bundleID加入智能粘贴白名单。
    private func chooseSmartPasteEditor() {
        guard let bundle = chooseBundleID(title: "选择可识别的编辑器应用") else { return }
        model.updateSettings { $0.smartPasteEditorBundleIDs.insert(bundle) }
    }
    private func chooseBundleID(title: String) -> String? {
        let picker = NSOpenPanel(); picker.title = title; picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowedContentTypes = [.application]
        guard picker.runModal() == .OK, let url = picker.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
    /// 只捕获本设置窗口内用户主动录制的一次按键。
    private func recordShortcut(queue: Bool = false) {
        // 再次点击当前录制按钮取消；切换另一个按钮仍可直接开始录制。
        if recording && recordingQueue == queue { stopRecording(); return }
        stopRecording(); recording = true; recordingQueue = queue
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { feedback = "快捷键需包含 Command、Option 或 Control"; model.message = feedback; return nil }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            let queue = recordingQueue
            // 重复冲突也直接展示本次反馈，且不先注册覆盖另一个快捷键。
            if shortcut == (queue ? model.settings.shortcut : model.settings.queueShortcut) {
                feedback = "面板与队列快捷键不能相同"; model.message = feedback; stopRecording(); return nil
            }
            stopRecording(); model.updateSettings { if queue { $0.queueShortcut = shortcut } else { $0.shortcut = shortcut } }; return nil
        }
    }
    /// 窗口关闭和录制完成都移除监听。
    private func stopRecording() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false; recordingQueue = false }
    /// 只在用户点击时请求注册，不把 API 返回当作系统授权完成。
    private func loginChange(_ enabled: Bool) {
        do { try login.setEnabled(enabled); refreshLogin() }
        catch { refreshLogin(); loginStatus = "请求失败：\(login.message)" }
    }
    /// 系统登录项状态不可观察，出现、激活和切换后显式读取，by AI.Coding。
    private func refreshLogin() { loginStatus = login.message; loginEnabled = login.status == .enabled || login.status == .requiresApproval }
}

/// 应用列表行：显示本地应用图标与名称，bundleID作为次要信息，by AI.Coding。
private struct BundleRow: View {
    let id: String
    let remove: () -> Void
    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id)
                if url != nil { Text(id).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("移除", action: remove)
        }
    }
}
/// 技术细节默认折叠，影响判断的说明仍就地可见，by AI.Coding。
@MainActor @ViewBuilder func settingsLimits(_ text: String) -> some View {
    DisclosureGroup("了解限制") { Text(text).settingsFootnote().padding(.top, 2) }.font(.caption).foregroundStyle(.secondary)
}
extension View {
    func settingsFootnote() -> some View {
        font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 设置顶部标签：图标在上、名称在下，选中为强调色与浅色底，带悬停反馈，by AI.Coding。
private struct SettingsTab: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: section.symbol).font(.system(size: 18, weight: .regular)).frame(height: 22)
                Text(section.rawValue).font(.system(size: LCStyle.FontSize.meta, weight: selected ? .semibold : .regular))
            }.frame(width: 64, height: 50)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(Color.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
