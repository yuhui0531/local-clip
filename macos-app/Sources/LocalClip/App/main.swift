// AppKit 进程入口，by AI.Coding。
import AppKit
import LocalClipMac
import LocalClipCore
#if DEBUG
// 仅隔离验收包提供此标记；用户为授权而双击测试包时，不启动真实剪贴板采集或打开正式数据库。
if CommandLine.arguments.count == 1, let resources = Bundle.main.resourceURL,
   FileManager.default.fileExists(atPath: resources.appendingPathComponent("IsolatedCodeProbe").path) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.run(); exit(0)
}
if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--real-code-paste" {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await CodePasteProbe.run(file: URL(fileURLWithPath: CommandLine.arguments[2]), report: URL(fileURLWithPath: CommandLine.arguments[3]), delay: Double(CommandLine.arguments[4]) ?? 5); exit(0) }
        catch { print("isolated-code-paste-failed: \(error)"); exit(3) }
    }
    application.run(); exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--system-check" {
    _ = NSApplication.shared
    let first = HotKeyService(), second = HotKeyService()
    let shortcut = Shortcut(keyCode:79,modifiers:6400)
    let registered=first.register(shortcut), conflict=second.register(shortcut)
    first.stop(); let afterRelease=second.register(shortcut); second.stop()
    let report:[String:Any] = ["accessibilityPermitted":MacApplicationClient().permitted,"loginStatus":LoginItemService().message,"hotkeyInitialRegistration":registered,"duplicateRegistration":conflict,"registrationAfterRelease":afterRelease,"scope":"actual system API; invocation and user enable/disable not tested"]
    do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2])); exit(0) } catch { exit(3) }
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--prepare-test-store" {
    do {
        var settings = SettingsSnapshot(); settings.captureEnabled = false
        _ = try HistoryStore(location: URL(fileURLWithPath: CommandLine.arguments[2]), initialSettings: settings, extractor: ContentDecoder.extract)
        print("isolated test store initialized paused"); exit(0)
    } catch { exit(3) }
}
if CommandLine.arguments.count == 4 && ["--render-ui", "--interaction-ui", "--render-code-detail"].contains(CommandLine.arguments[1]) {
    let application = NSApplication.shared
    Task { @MainActor in
        do { try await VisualProbe.render(at: URL(fileURLWithPath: CommandLine.arguments[2]), dark: CommandLine.arguments[3] == "dark", width: Double(ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_WIDTH"] ?? "1400") ?? 1400, height: Double(ProcessInfo.processInfo.environment["LOCALCLIP_VISUAL_HEIGHT"] ?? "400") ?? 400, keepOpen: CommandLine.arguments[1] == "--interaction-ui", codeDetail: CommandLine.arguments[1] == "--render-code-detail"); if CommandLine.arguments[1] != "--interaction-ui" { exit(0) } }
        catch { print("visual-render-failed: \(error)"); exit(3) }
    }
    application.run()
    exit(0)
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--storage-probe" {
    do { try StorageProbe.run(root: URL(fileURLWithPath: CommandLine.arguments[2]), point: CommandLine.arguments[3]) }
    catch { exit(3) }
    exit(0)
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--history-probe" {
    Task {
        do { try await StorageProbe.runHistory(root: URL(fileURLWithPath: CommandLine.arguments[2]), point: CommandLine.arguments[3]); exit(0) }
        catch { exit(3) }
    }
    dispatchMain()
}
#endif
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
