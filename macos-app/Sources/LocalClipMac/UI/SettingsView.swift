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
public struct SettingsView: View {
    @ObservedObject var model: HistoryViewModel
    let login: LoginItemService
    @State private var section: SettingsSection = .general
    @State private var retention = "30"
    @State private var quota = "500"
    @State private var recording = false
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
    /// 原生分组表单：按“通用 / 记录 / 粘贴 / 隐私 / 存储 / 高级”组织，说明放入分组脚注；失焦与Esc由窗口管理，录制期间Esc只取消录制，by AI.Coding。
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
                        Picker("外观", selection: Binding(get: { model.settings.appearance }, set: { value in model.updateSettings { $0.appearance = value } })) {
                            Text("跟随系统").tag(AppAppearance.system)
                            Text("浅色").tag(AppAppearance.light)
                            Text("深色").tag(AppAppearance.dark)
                        }.pickerStyle(.segmented)
                        Toggle("紧凑布局", isOn: Binding(get: { model.settings.compactLayout }, set: { value in model.updateSettings { $0.compactLayout = value } }))
                        Toggle("显示菜单栏图标", isOn: Binding(get: { model.settings.showMenuIcon }, set: { value in model.updateSettings { $0.showMenuIcon = value } }))
                        LabeledContent("全局快捷键") {
                            Button(recording ? "按下新的快捷键…" : HotKeyService.label(model.settings.shortcut), action: recordShortcut)
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
                                if let release = updates.available { Button("查看版本 \(release.version)…") { NSWorkspace.shared.open(release.page) } }
                            case .failed, .idle:
                                Button(updates.checking ? "正在检查…" : "检查更新") { Task { await updates.check(manual: true) } }.disabled(updates.checking)
                            }
                        }
                        if case let .failed(message) = updates.phase { Text(message).foregroundStyle(.red).font(.caption) }
                        if case .manualOnly = updates.phase { Text("此版本尚未提供签名更新包，请从发布页手动安装。").settingsFootnote() }
                        if let result = updates.manualResult { Text(result).foregroundStyle(.secondary).font(.caption) }
                        if login.status == .requiresApproval || loginStatus.hasPrefix("请求失败") {
                            LabeledContent(loginStatus) { Button("打开登录项…") { login.openSettings() } }.foregroundStyle(.secondary)
                        }
                    } header: { Text("外观与启动") } footer: {
                        Text("自动检查每天最多一次；新版本会自动下载并验签，仅点击“安装并重启”后更新，普通退出不会安装。更新前保留旧应用及历史、设置快照，不发送剪贴板内容。当前使用临时签名，更新后 macOS 可能要求重新授予辅助功能权限。").settingsFootnote()
                    }
                }
                if section == .general {
                    Section {
                        // 开关传递绝对用户意图，不能由启动时的新配置反转，by AI.Coding。
                        Toggle("记录新的剪贴板变化", isOn: Binding(get: { model.settings.captureEnabled }, set: { value in model.setCaptureEnabled(value) }))
                        LabeledContent("定时暂停") {
                            if let deadline = model.settings.pauseUntil, deadline > SystemClock().now() {
                                Text("至 " + Date(timeIntervalSince1970: Double(deadline)/1000).formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                                Button("取消") { model.updateSettings { $0.pauseUntil = nil } }
                            } else {
                                Menu("暂停…") {
                                    Button("15 分钟") { model.updateSettings { $0.pauseUntil = SystemClock().now() + 15 * 60_000 } }
                                    Button("1 小时") { model.updateSettings { $0.pauseUntil = SystemClock().now() + 60 * 60_000 } }
                                }.fixedSize()
                            }
                        }
                        Toggle("记录时播放提示音", isOn: Binding(get: { model.settings.captureSounds }, set: { value in model.updateSettings { $0.captureSounds = value } }))
                    } header: { Text("记录") } footer: {
                        Text("启动后自动监听新复制内容；手动暂停只作用于本次运行，定时暂停按期限保留。").settingsFootnote()
                    }
                }
                if section == .paste {
                    Section {
                        Picker("Return 默认操作", selection: Binding(get: { model.settings.defaultAction }, set: { value in model.updateSettings { $0.defaultAction = value } })) {
                            Text("直接粘贴").tag(PasteAction.directPaste); Text("仅复制").tag(PasteAction.copy)
                        }
                        Picker("默认输出格式", selection: Binding(get: { model.settings.defaultFormat }, set: { value in model.updateSettings { $0.defaultFormat = value } })) { Text("原格式").tag(OutputFormat.original); Text("纯文本").tag(OutputFormat.plainText) }
                        Toggle("复制或粘贴后移到最前", isOn: Binding(get: { model.settings.moveUsedToFront }, set: { value in model.updateSettings { $0.moveUsedToFront = value } }))
                        Picker("数字 1–9 快捷粘贴", selection: Binding(get: { model.settings.quickModifiers }, set: { value in model.updateSettings { $0.quickModifiers = value } })) { Text("⌘ + 数字").tag(UInt32(256)); Text("⌥ + 数字").tag(UInt32(2048)); Text("⌃ + 数字").tag(UInt32(4096)); Text("⌘⇧ + 数字").tag(UInt32(768)) }
                        Picker("切换／新建分类", selection: Binding(get: { model.settings.boardModifiers }, set: { value in model.updateSettings { $0.boardModifiers = value } })) { Text("⌘⇧ + ← / → / N").tag(UInt32(768)); Text("⌘⌥ + ← / → / N").tag(UInt32(2304)); Text("⌃⌥ + ← / → / N").tag(UInt32(6144)) }
                        LabeledContent("辅助功能权限") {
                            Label(permitted ? "已授予" : "未授予", systemImage: permitted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(permitted ? Color.green : Color.orange)
                            if !permitted { Button("开启…") { AccessibilityGuide.shared.show(skipIntro: true) } }
                        }
                    } header: { Text("粘贴方式") } footer: {
                        Text("⌘C 复制所选，⇧Return 直接粘贴纯文本；搜索框 Return 或 Tab 先进入结果。直接粘贴需要辅助功能权限，仅恢复目标应用，不能保证原输入框或光标位置；没有权限仍可复制后手动粘贴。").settingsFootnote()
                    }
                }
                if section == .paste {
                    Section {
                        Toggle("代码文件智能粘贴", isOn: Binding(get: { model.settings.smartCodeFilePaste }, set: { value in model.updateSettings { $0.smartCodeFilePaste = value } }))
                        ForEach(model.settings.smartPasteEditorBundleIDs.sorted(), id: \.self) { id in
                            BundleRow(id: id) { model.updateSettings { $0.smartPasteEditorBundleIDs.remove(id) } }
                        }
                        Button("添加可识别的编辑器应用…", action: chooseSmartPasteEditor)
                    } header: { Text("代码") } footer: {
                        Text("默认关闭。开启后，确认是文本编辑目标时粘贴代码文件正文；Finder、未知目标或读取失败仍保留原文件。代码片段语法高亮始终启用。多文件按顺序用换行分隔；每文件最多4MiB，合计8MiB。仅将所选应用未暴露文本控件的AXWindow视为编辑器；所选应用的窗口（包括其中未被识别为终端的终端面板）可能收到文件正文，终端应用及已标记的终端上下文仍被排除。默认没有应用获准。").settingsFootnote()
                    }
                }
                if section == .privacy {
                    Section {
                        Toggle("隐藏历史内容", isOn: Binding(get: { model.settings.hideContents }, set: { value in model.updateSettings { $0.hideContents = value } }))
                        Toggle("限制系统窗口共享读取", isOn: Binding(get: { model.settings.excludeFromSharing }, set: { value in model.updateSettings { $0.excludeFromSharing = value } }))
                        Toggle("排除应用位于前台时暂停记录", isOn: Binding(get: { model.settings.pauseWhenExcludedFrontmost }, set: { value in model.updateSettings { $0.pauseWhenExcludedFrontmost = value } }))
                        ForEach(model.settings.excludedBundleIDs.sorted(), id: \.self) { id in
                            BundleRow(id: id) { model.updateSettings { $0.excludedBundleIDs.remove(id) } }
                        }
                        Button("添加要排除的应用…", action: chooseApplication)
                    } footer: {
                        Text("排除仅按 org.nspasteboard.source 声明的 bundleID 匹配；前台推断与未知来源不参与应用排除，需要停止记录时请暂停。开启“前台时暂停”后，排除应用处于前台的整个区间都不记录，退出区间不补采。敏感/临时标记在正文读取前整次过滤，不能识别所有密码。共享限制使用公开 NSWindow 属性，不能保证所有录屏方式隐藏本窗口。新增排除不会删除已有历史；数据保存在本机，未宣称加密，不上传剪贴板内容。").settingsFootnote()
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
                            Button("永不过期") { model.change(.retention(0)) }.help("永不过期（仍有容量限制）")
                        }
                        LabeledContent("容量上限（MiB）") {
                            TextField("100–4096", text: $quota).labelsHidden().frame(width: 70).multilineTextAlignment(.trailing).onSubmit(applyQuota)
                            Button("应用", action: applyQuota).disabled(quota == String(model.settings.quotaBytes / MiB))
                        }
                        HStack {
                            Button("清理已到期内容") { Task { await model.maintenance() } }
                            Spacer()
                            Button("清空普通历史…", role: .destructive) { model.change(.clearOrdinary) }
                        }
                    } footer: {
                        Text("期限按最近有效用户复制起算；浏览和自身恢复不续期。收藏或任一自定义分类的记录不参与期限和自动淘汰，但计入容量。无法容纳新内容时保留旧历史，跳过新增。降低设置需预览确认。1MiB = 1,048,576 字节。").settingsFootnote()
                    }
                }
                if section == .advanced {
                    Section {
                        LabeledContent("面板高度") {
                            // 手动取整到10pt，避免带step的原生滑块画出密集刻度。
                            Slider(value: Binding(get: { model.actualPanelHeight }, set: { value in model.resizePanel?((value / 10).rounded() * 10, false) }), in: 280...520, onEditingChanged: { editing in if !editing { model.resizePanel?(model.actualPanelHeight, true) } }).frame(width: 220)
                            Text("\(Int(model.actualPanelHeight)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                        }
                        Toggle("启用本机阶段计时日志", isOn: Binding(get: { model.settings.timingEnabled }, set: { value in model.updateSettings { $0.timingEnabled = value } }))
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("计时日志只记录阶段、条数和毫秒，不含正文、文件路径、URL或搜索词。数据目录：LocalClip-LocalEdition。全新数据模型，不兼容或迁移旧库。")
                            Text("支持文本、URL、RTF、简单HTML、PNG/TIFF/JPEG和文件引用；每次32项、表示数据50MiB。文件不备份本体，原件删除后无法恢复。Finder中双击文件复制到当前文件夹。RTFD、云同步、OCR、AI不在此版本。")
                        }.settingsFootnote()
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).id(section)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in formHeight = height }
                // 表单占据头部与底栏之间的剩余空间；窗口动画期间头部钉在顶部、底栏钉在底部，只有表单区伸缩，by AI.Coding。
                .frame(maxHeight: .infinity)
        }
        // 操作反馈固定在底部，不随长表单滚走。
        .safeAreaInset(edge: .bottom) {
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
        .onChange(of: section) { _, _ in stopRecording() }
        .onChange(of: model.settings.retentionDays) { _, value in retention = String(value) }
        .onChange(of: model.settings.quotaBytes) { _, value in quota = String(value / MiB) }
        .onExitCommand {
            if recording { stopRecording() }
            else { (NSApp.keyWindow as? SettingsWindow)?.cancelOperation(nil) }
        }
        .onAppear { model.settingsVisibilityChanged(true); model.actualPanelHeight = max(280, model.settings.panelHeight); retention = String(model.settings.retentionDays); quota = String(model.settings.quotaBytes / MiB); refreshLogin(); permitted = MacApplicationClient().permitted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLogin(); permitted = MacApplicationClient().permitted }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            // 窗口保留用于再次打开；关闭时立即停止录制，不依赖SwiftUI销毁视图。
            if notification.object is SettingsWindow { model.settingsVisibilityChanged(false); stopRecording(); feedback = "" }
        }
        .onDisappear { model.settingsVisibilityChanged(false); stopRecording() }
    }
    private var windowHeight: CGFloat { headerHeight + min(max(formHeight, 160), 600) + footerHeight }
    private func applyRetention() { if let days = Int(retention), (1...365).contains(days) { model.change(.retention(days)) } else { model.message = "保留天数需为1–365" } }
    private func applyQuota() { if let value = Int64(quota), (100...4096).contains(value) { model.change(.quota(value * MiB)) } else { model.message = "容量需为100–4096MiB" } }
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
    private func recordShortcut() {
        stopRecording(); recording = true
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { model.message = "快捷键需包含 Command、Option 或 Control"; return nil }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stopRecording(); model.updateSettings { $0.shortcut = shortcut }; return nil
        }
    }
    /// 窗口关闭和录制完成都移除监听。
    private func stopRecording() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false }
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
                Text(section.rawValue).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }.frame(width: 64, height: 50)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(Color.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
