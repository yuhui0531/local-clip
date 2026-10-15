// 显式安装入口先等待辅助进程预检，辅助进程未就绪绝不退出当前应用，by AI.Coding。
import AppKit
import LocalClipUpdateKit

/// 用户取消退出且已确认辅助程序退出：替换从未发生，下载包可直接恢复为就绪状态，by AI.Coding。
struct UpdateQuitCancelled: Error, LocalizedError {
    var errorDescription: String? { "应用退出已取消" }
}

@MainActor enum UpdateInstaller {
    static let lastAttemptKey = "lastUpdateAttemptDirectory"
    private static let attemptFiles = ["LocalClipUpdater", "installer-ready", "startup-ok", "result.txt"]

    /// 下载目录保留安装结果；辅助程序副本不随应用原子交换而失效。
    static func begin(_ update: DownloadedUpdate) async throws {
        let fm = FileManager.default, bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", try bundle.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw UpdateFailure.invalid("请先将 LocalClip 安装到可写的应用程序目录") }
        _ = try UpdatePackage.authenticate(directory: update.directory, installedApp: bundle, currentBuild: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0)
        let source = bundle.appendingPathComponent("Contents/Helpers/LocalClipUpdater")
        let helper = update.directory.appendingPathComponent("LocalClipUpdater")
        for name in attemptFiles {
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
                if process.isRunning { process.terminate(); _ = await exited(process) }
                let reason = (try? String(contentsOf: update.directory.appendingPathComponent("result.txt"), encoding: .utf8)) ?? "安装准备失败，请检查磁盘空间和安装目录权限"
                throw UpdateFailure.invalid(reason)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.isRunning else { throw UpdateFailure.invalid("安装器提前退出") }
        NSApp.terminate(nil)
        // 终止被用户/系统取消时，仍存活的父进程不能留下等待安装的辅助程序。
        if process.isRunning { process.terminate() }
        // F-01：发送信号不等于已退出；确认退出后父进程仍在，可证明替换未发生，才把包恢复为就绪。
        guard await exited(process) else { throw UpdateFailure.invalid("应用退出已取消；安装器仍在退出，稍后自动回收") }
        for name in attemptFiles + ["request.json"] {
            try? fm.removeItem(at: update.directory.appendingPathComponent(name))
        }
        throw UpdateQuitCancelled()
    }

    /// 异步等待而不阻塞主线程；超时返回 false，由后续补偿在会话锁释放后处理。
    private static func exited(_ process: Process, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return !process.isRunning
    }

    /// 完成存储恢复后才确认启动；限定自己的更新缓存，避免任意命令行路径写入。
    /// T-01：可信根与辅助程序同源（UpdateLocations.current），Debug 隔离根可用，Release 恒为生产缓存。
    @discardableResult
    static func acknowledgeStartup(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment,
                                   build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) -> Bool {
        guard let flag = arguments.firstIndex(of: "--localclip-update-receipt"), arguments.indices.contains(flag + 1),
              let locations = try? UpdateLocations.current(environment: environment) else { return false }
        let receipt = URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL
        guard locations.isTrustedReceipt(receipt), let build else { return false }
        return (try? Data(build.utf8).write(to: receipt, options: .atomic)) != nil
    }
}
