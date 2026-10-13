// 显式安装入口先等待辅助进程预检，辅助进程未就绪绝不退出当前应用，by AI.Coding。
import AppKit
import LocalClipUpdateKit

@MainActor enum UpdateInstaller {
    static let lastAttemptKey = "lastUpdateAttemptDirectory"

    /// 下载目录保留安装结果；辅助程序副本不随应用原子交换而失效。
    static func begin(_ update: DownloadedUpdate) async throws {
        let fm = FileManager.default, bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", try bundle.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw UpdateFailure.invalid("请先将 LocalClip 安装到可写的应用程序目录") }
        _ = try UpdatePackage.authenticate(directory: update.directory, installedApp: bundle, currentBuild: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0)
        let source = bundle.appendingPathComponent("Contents/Helpers/LocalClipUpdater")
        let helper = update.directory.appendingPathComponent("LocalClipUpdater")
        for name in ["LocalClipUpdater", "installer-ready", "startup-ok", "result.txt"] {
            let file = update.directory.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
        try fm.copyItem(at: source, to: helper)
        _ = try UpdatePackage.runTool("/usr/bin/codesign", ["--verify", "--strict", helper.path])
        let request = InstallRequest(target: bundle, downloadDirectory: update.directory, parentPID: ProcessInfo.processInfo.processIdentifier, currentBuild: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0)
        let requestURL = update.directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let process = Process()
        process.executableURL = helper; process.arguments = [requestURL.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        UserDefaults.standard.set(update.directory.path, forKey: lastAttemptKey)
        let deadline = Date().addingTimeInterval(60)
        while !fm.fileExists(atPath: update.directory.appendingPathComponent("installer-ready").path) {
            guard process.isRunning, Date() < deadline else {
                if process.isRunning { process.terminate() }
                let reason = (try? String(contentsOf: update.directory.appendingPathComponent("result.txt"), encoding: .utf8)) ?? "安装准备失败，请检查磁盘空间和安装目录权限"
                throw UpdateFailure.invalid(reason)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.isRunning else { throw UpdateFailure.invalid("安装器提前退出") }
        NSApp.terminate(nil)
        // 终止被用户/系统取消时，仍存活的父进程不能留下等待安装的辅助程序。
        if process.isRunning { process.terminate() }
        throw UpdateFailure.invalid("应用退出已取消")
    }

    /// 完成存储恢复后才确认启动；限定自己的更新缓存，避免任意命令行路径写入。
    static func acknowledgeStartup() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--localclip-update-receipt"), args.indices.contains(flag + 1) else { return }
        let receipt = URL(fileURLWithPath: args[flag + 1]).standardizedFileURL
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.localclip.dev/Updates").resolvingSymlinksInPath().path + "/"
        guard receipt.lastPathComponent == "startup-ok", receipt.resolvingSymlinksInPath().path.hasPrefix(cache),
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        try? Data(build.utf8).write(to: receipt, options: .atomic)
    }
}
