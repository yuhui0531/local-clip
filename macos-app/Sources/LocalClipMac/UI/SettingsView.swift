// 配置界面：持久化完成后展示生效，系统权限由用户操作，by AI.Coding。
import AppKit
import SwiftUI
import Carbon
import LocalClipCore
public struct SettingsView: View {
    @ObservedObject var model: HistoryViewModel
    let login: LoginItemService
    @State private var retention = "30"
    @State private var quota = "500"
    @State private var recording = false
    @State private var monitor: Any?
    @State private var loginStatus = ""
    @State private var permitted = false
    public init(model: HistoryViewModel, login: LoginItemService) { self.model = model; self.login = login }
    /// 外观入口置顶；失焦与Esc由窗口管理，录制期间Esc只取消录制，by AI.Coding。
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("LocalClip 设置").font(.title2.bold())
                GroupBox("外观与布局") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("外观", selection: Binding(get: { model.settings.appearance }, set: { value in model.updateSettings { $0.appearance = value } })) {
                            Text("跟随系统").tag(AppAppearance.system)
                            Text("浅色").tag(AppAppearance.light)
                            Text("深色").tag(AppAppearance.dark)
                        }.pickerStyle(.segmented)
                        Toggle("紧凑布局", isOn: Binding(get: { model.settings.compactLayout }, set: { value in model.updateSettings { $0.compactLayout = value } }))
                        Text("外观同时应用于历史面板和设置。紧凑布局缩短工具栏和操作区；窄屏自动使用紧凑布局。按 Esc 或切换到其他窗口可关闭设置。").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("采集与操作") {
                    VStack(alignment: .leading, spacing: 12) {
                        // 开关传递绝对用户意图，不能由启动时的新配置反转，by AI.Coding。
                        Toggle("记录新的剪贴板变化", isOn: Binding(get: { model.settings.captureEnabled }, set: { value in model.setCaptureEnabled(value) }))
                        Text("启动后自动监听新复制内容；手动暂停只作用于本次运行，定时暂停按期限保留。").font(.caption).foregroundStyle(.secondary)
                        Picker("Enter 默认操作", selection: Binding(get: { model.settings.defaultAction }, set: { value in model.updateSettings { $0.defaultAction = value } })) {
                            Text("直接粘贴（默认）").tag(PasteAction.directPaste); Text("仅复制").tag(PasteAction.copy)
                        }
                        Toggle("复制或粘贴后移到最前", isOn: Binding(get: { model.settings.moveUsedToFront }, set: { value in model.updateSettings { $0.moveUsedToFront = value } }))
                        Picker("默认输出格式", selection: Binding(get: { model.settings.defaultFormat }, set: { value in model.updateSettings { $0.defaultFormat = value } })) { Text("原格式").tag(OutputFormat.original); Text("纯文本").tag(OutputFormat.plainText) }
                        HStack { Button("暂停15分钟") { model.updateSettings { $0.pauseUntil = SystemClock().now() + 15 * 60_000 } }; Button("暂停1小时") { model.updateSettings { $0.pauseUntil = SystemClock().now() + 60 * 60_000 } }; Button("取消定时暂停") { model.updateSettings { $0.pauseUntil = nil } } }
                        if let deadline = model.settings.pauseUntil, deadline > SystemClock().now() { Text("暂停至 " + Date(timeIntervalSince1970: Double(deadline)/1000).formatted()).font(.caption) }
                        Toggle("代码文件智能粘贴", isOn: Binding(get: { model.settings.smartCodeFilePaste }, set: { value in model.updateSettings { $0.smartCodeFilePaste = value } }))
                        Text("默认关闭。开启后，确认是文本编辑目标时粘贴代码文件正文；Finder、未知目标或读取失败仍保留原文件。代码片段语法高亮始终启用。多文件按顺序用换行分隔；每文件最多4MiB，合计8MiB。").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.settings.smartPasteEditorBundleIDs.sorted(), id: \.self) { id in
                            HStack { Text(id); Spacer(); Button("移除") { model.updateSettings { $0.smartPasteEditorBundleIDs.remove(id) } } }
                        }
                        Button("选择可识别的编辑器应用…", action: chooseSmartPasteEditor)
                        Text("仅将所选应用未暴露文本控件的AXWindow视为编辑器。所选应用的窗口（包括其中未被识别为终端的终端面板）可能收到文件正文；终端应用及已标记的终端上下文仍被排除。默认没有应用获准。").font(.caption).foregroundStyle(.secondary)
                        Toggle("记录时播放提示音", isOn: Binding(get: { model.settings.captureSounds }, set: { value in model.updateSettings { $0.captureSounds = value } }))
                        Toggle("显示菜单栏图标", isOn: Binding(get: { model.settings.showMenuIcon }, set: { value in model.updateSettings { $0.showMenuIcon = value } }))
                        Picker("数字1–9快捷粘贴修饰键", selection: Binding(get: { model.settings.quickModifiers }, set: { value in model.updateSettings { $0.quickModifiers = value } })) { Text("⌘").tag(UInt32(256)); Text("⌥").tag(UInt32(2048)); Text("⌃").tag(UInt32(4096)); Text("⌘⇧").tag(UInt32(768)) }
                        Picker("分类切换／新建修饰键", selection: Binding(get: { model.settings.boardModifiers }, set: { value in model.updateSettings { $0.boardModifiers = value } })) { Text("⌘⇧ + ← / → / N").tag(UInt32(768)); Text("⌘⌥ + ← / → / N").tag(UInt32(2304)); Text("⌃⌥ + ← / → / N").tag(UInt32(6144)) }
                        Text("⌘C复制所选，⇧Return直接粘贴纯文本；Return按默认动作。搜索框Return或Tab先进入结果。隐藏菜单栏图标要求快捷键可用。").font(.caption).foregroundStyle(.secondary)
                        Text("直接粘贴需要辅助功能权限，仅恢复目标应用，不能保证原输入框或光标位置。没有权限仍可复制后手动粘贴。").font(.caption).foregroundStyle(.secondary)
                        HStack { Text(permitted ? "辅助功能：已授予" : "辅助功能：未授予"); Button("打开权限设置", action: MacApplicationClient.openAccessibilitySettings) }
                        HStack { Text("全局快捷键：\(HotKeyService.label(model.settings.shortcut))"); Spacer(); Button(recording ? "按下新的快捷键（Esc取消）" : "更改快捷键", action: recordShortcut) }
                        HStack { Text(loginStatus); Spacer(); Button("开启登录启动") { loginChange(true) }; Button("关闭") { loginChange(false) } }
                        Button("查看系统登录项") { login.openSettings() }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("隐私与应用排除") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("来源优先使用应用声明，缺失时显示复制时前台应用及其图标。前台推断与未知来源不参与应用排除；需要停止记录时请暂停采集。").font(.callout)
                        Text("排除仅按 org.nspasteboard.source 声明的 bundleID 匹配。前台推断可能误判后台写入，来源依据可在卡片提示和详情查看。敏感/临时标记在正文读取前整次过滤，不能识别所有密码。").font(.caption).foregroundStyle(.secondary)
                        Toggle("排除应用位于前台时暂停采集", isOn: Binding(get: { model.settings.pauseWhenExcludedFrontmost }, set: { value in model.updateSettings { $0.pauseWhenExcludedFrontmost = value } }))
                        Text("该选项默认关闭。开启后，排除应用处于前台的整个区间都不采集，包括来源未知或后台写入；退出区间不补采。它不代表知道所有剪贴板写入进程。").font(.caption).foregroundStyle(.secondary)
                        Toggle("隐藏／模糊历史内容", isOn: Binding(get: { model.settings.hideContents }, set: { value in model.updateSettings { $0.hideContents = value } }))
                        Toggle("限制系统窗口共享读取", isOn: Binding(get: { model.settings.excludeFromSharing }, set: { value in model.updateSettings { $0.excludeFromSharing = value } }))
                        Text("共享限制使用公开NSWindow属性；不能保证所有屏幕共享、ScreenCaptureKit或第三方录屏方式隐藏本窗口。需要可靠遮蔽时请手动隐藏内容或关闭面板；本应用不申请录屏权限或监看共享状态。").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.settings.excludedBundleIDs.sorted(), id: \.self) { id in
                            HStack { Text(id); Spacer(); Button("移除") { model.updateSettings { $0.excludedBundleIDs.remove(id) } } }
                        }
                        Button("选择要排除的应用…", action: chooseApplication)
                        Text("新增排除不会自动删除已有历史；移除排除不会补采过去内容。数据保存在本机，未宣称加密，不上传剪贴板内容。").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("存储与清理") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let usage = model.usage {
                            Text("实际总占用 \(HistoryViewModel.bytes(usage.measuredTotal)) / \(HistoryViewModel.bytes(model.settings.quotaBytes))").font(.headline)
                            Text("保护载荷 \(HistoryViewModel.bytes(usage.favoritePayload)) · 普通载荷 \(HistoryViewModel.bytes(usage.normalPayload))\n公共页/索引/缩略图 \(HistoryViewModel.bytes(usage.common)) · 待回收 \(HistoryViewModel.bytes(usage.pending))").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("永不过期（仍有容量限制）") { model.change(.retention(0)) }
                        HStack { Text("保留天数"); TextField("1–365", text: $retention).frame(width: 80); Button("应用") { if let days = Int(retention) { model.change(.retention(days)) } else { model.message = "保留天数需为1–365" } }; Text(model.settings.retentionDays == 0 ? "当前永不过期" : "当前\(model.settings.retentionDays)天").foregroundStyle(.secondary) }
                        HStack { Text("容量 MiB"); TextField("100–4096", text: $quota).frame(width: 80); Button("应用") { if let value = Int64(quota), (100...4096).contains(value) { model.change(.quota(value * MiB)) } else { model.message = "容量需为100–4096MiB" } }; Text("1MiB=1,048,576字节").font(.caption).foregroundStyle(.secondary) }
                        Text("期限按最近有效用户复制起算；浏览和自身恢复不续期。收藏或任一自定义分类的记录不参与期限和自动淘汰，但计入容量。无法容纳新内容时保留旧历史，跳过新增。降低设置需预览确认。").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("清理已到期内容") { Task { await model.maintenance() } }; Button("清空普通历史", role: .destructive) { model.change(.clearOrdinary) } }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("面板与诊断") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("面板高度"); Slider(value: Binding(get: { model.actualPanelHeight }, set: { value in model.resizePanel?(value, false) }), in: 280...520, step: 10, onEditingChanged: { editing in if !editing { model.resizePanel?(model.actualPanelHeight, true) } }); Text("\(Int(model.actualPanelHeight)) pt").monospacedDigit() }
                        Toggle("启用本机阶段计时日志", isOn: Binding(get: { model.settings.timingEnabled }, set: { value in model.updateSettings { $0.timingEnabled = value } }))
                        Text("只记录阶段、条数和毫秒，不含正文、文件路径、URL或搜索词；性能仍需您实测。数据目录：LocalClip-LocalEdition。全新数据模型，不兼容或迁移旧库。").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("支持文本、URL、RTF、简单HTML、PNG/TIFF/JPEG和文件引用；每次32项、表示数据50MiB。文件不备份本体，原件删除后无法恢复。Finder中双击文件复制到当前文件夹。RTFD、云同步、OCR、AI不在此版本。").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 640, minHeight: 600)
        .onExitCommand {
            if recording { stopRecording() }
            else { (NSApp.keyWindow as? SettingsWindow)?.cancelOperation(nil) }
        }
        .onAppear { model.settingsVisibilityChanged(true); model.actualPanelHeight = max(280, model.settings.panelHeight); retention = String(model.settings.retentionDays); quota = String(model.settings.quotaBytes / MiB); loginStatus = login.message; permitted = MacApplicationClient().permitted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginStatus = login.message; permitted = MacApplicationClient().permitted }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            // 窗口保留用于再次打开；关闭时立即停止录制，不依赖SwiftUI销毁视图。
            if notification.object is SettingsWindow { model.settingsVisibilityChanged(false); stopRecording() }
        }
        .onDisappear { model.settingsVisibilityChanged(false); stopRecording() }
    }
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
        do { try login.setEnabled(enabled); loginStatus = login.message }
        catch { loginStatus = "请求失败：\(login.message)" }
    }
}
