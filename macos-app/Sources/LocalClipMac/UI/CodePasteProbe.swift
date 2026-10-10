// Debug隔离真实应用验收：只入库指定合成文件，不读取用户历史，by AI.Coding。
#if DEBUG
import AppKit
import LocalClipCore

@MainActor public enum CodePasteProbe {
    /// 延迟让测试者聚焦新建的空白文档；执行真正的系统客户端和粘贴协调器。
    public static func run(file: URL, report: URL, delay: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalClip-code-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = MacApplicationClient()
        try await Task.sleep(for: .seconds(delay))
        var output: [String: Any] = ["permitted": applications.permitted, "scope": "real ApplicationClient and PasteCoordinator; commandSent does not prove receipt"]
        if let target = applications.target(), applications.permitted,
           target.bundleID == ProcessInfo.processInfo.environment["LOCALCLIP_PROBE_TARGET"] {
            applications.rememberFocus(for: target)
            output["before"] = applications.focusDiagnostic(target)
            // 允许直接插入合成fixture；CaptureCoordinator从不start，因此不会读取系统剪贴板。
            var settings = SettingsSnapshot()
            settings.smartCodeFilePaste = ProcessInfo.processInfo.environment["LOCALCLIP_PROBE_SMART"] != "0"
            output["enabled"] = settings.smartCodeFilePaste
            let store = try HistoryStore(location: root, initialSettings: settings)
            let payload = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else { throw StoreError.notFound }
            // 本验收会写合成内容至系统剪贴板；采集器不启动，私有库无用户剪贴板记录。
            let board = MacPasteboardClient(access: NativePasteboardAccess(.general))
            let capture = CaptureCoordinator(board: board, store: store)
            let paste = PasteCoordinator(board: board, applications: applications, store: store, capture: capture)
            output["result"] = String(describing: await paste.perform(.init(ids: [id], action: .directPaste, target: target)))
            output["after"] = applications.focusDiagnostic(target)
        } else { output["blocked"] = "Accessibility permission or expected external foreground target unavailable" }
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: report)
    }
}
#endif
