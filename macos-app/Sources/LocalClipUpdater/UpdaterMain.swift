// 独立、无提权安装器：只有显式启动才工作，退出应用本身不会触发安装，by AI.Coding。
import AppKit
import Darwin
import LocalClipUpdateKit

@main struct UpdaterMain {
    /// 请求文件由主程序创建；所有结果留在下载目录供重启后的设置界面读取。
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else { return }
        let requestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = requestURL.deletingLastPathComponent()
        var oldProcessExited = false
        var request: InstallRequest?
        var transaction: UpdateTransaction?
        var running: NSRunningApplication?
        var work: URL?
        var storeLock: UpdateStoreLock?
        do {
            let value = try JSONDecoder().decode(InstallRequest.self, from: Data(contentsOf: requestURL))
            request = value
            guard value.downloadDirectory.standardizedFileURL.path == root.standardizedFileURL.path else { throw UpdateFailure.invalid("安装请求的下载目录不匹配") }
            // Foundation 会把 /private/tmp 规范为 /tmp，不能用字符串相等判断符号链接。
            guard value.target.pathExtension == "app", try value.target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw UpdateFailure.invalid("安装目标不是独立应用目录") }
            guard value.parentPID > 1, kill(value.parentPID, 0) == 0 else { throw UpdateFailure.invalid("原应用进程不可访问：\(errno)") }
            let manifest = try UpdatePackage.authenticate(directory: root, installedApp: value.target, currentBuild: value.currentBuild)
            let parent = value.target.deletingLastPathComponent()
            let workspace = parent.appendingPathComponent(".LocalClip-update-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            work = workspace
            let candidate = try UpdatePackage.extract(directory: root, manifest: manifest, destination: workspace.appendingPathComponent("candidate"))
            // 数据快照与原数据同卷，跨磁盘安装应用仍然能够原子恢复数据。
            var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var lockIdentity = UpdatePackage.bundleIdentifier
            #if DEBUG
            // 仅 Debug 辅助程序支持临时目录端到端验收；Release 完全忽略测试环境变量。
            if let testRoot = ProcessInfo.processInfo.environment["LOCALCLIP_UPDATER_TEST_ROOT"] {
                let isolated = URL(fileURLWithPath: testRoot).resolvingSymlinksInPath()
                let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path + "/"
                guard isolated.path.hasPrefix(temporaryRoot),
                      value.target.resolvingSymlinksInPath().path.hasPrefix(isolated.path + "/"), root.resolvingSymlinksInPath().path.hasPrefix(isolated.path + "/") else {
                    throw UpdateFailure.invalid("测试目录未隔离")
                }
                support = isolated.appendingPathComponent("Application Support")
                lockIdentity = "localclip-update-test-" + isolated.lastPathComponent
            }
            #endif
            let data = support.appendingPathComponent("LocalClip-LocalEdition", isDirectory: true)
            storeLock = UpdateStoreLock(identity: lockIdentity)
            let backup = support.appendingPathComponent("LocalClip-UpdateBackups/" + workspace.lastPathComponent, isDirectory: true)
            let operation = try UpdateTransaction(target: value.target, candidate: candidate, dataDirectory: data, backupDirectory: backup)
            transaction = operation
            // 完成验签、解压和安装目录写入后才通知父程序可以安全退出。
            try Data("ready".utf8).write(to: root.appendingPathComponent("installer-ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(45)
            while kill(value.parentPID, 0) == 0 {
                guard Date() < deadline else { throw UpdateFailure.invalid("应用未退出，更新已取消") }
                try await Task.sleep(for: .milliseconds(100))
            }
            oldProcessExited = true
            try storeLock?.acquire()
            try operation.prepare()
            try operation.replaceApp()
            storeLock?.release()
            let receipt = root.appendingPathComponent("startup-ok")
            running = try await launch(value.target, arguments: ["--localclip-update-receipt", receipt.path])
            let startupDeadline = Date().addingTimeInterval(45)
            while !FileManager.default.fileExists(atPath: receipt.path) {
                guard let app = running, !app.isTerminated, Date() < startupDeadline else { throw UpdateFailure.invalid("新版本未能完成启动") }
                try await Task.sleep(for: .milliseconds(100))
            }
            // 回执必须携带本次预期构建号，单纯启动进程不算更新成功。
            guard try String(contentsOf: receipt, encoding: .utf8) == String(manifest.build) else { throw UpdateFailure.invalid("新版本启动回执不匹配") }
            try Data("更新成功；旧应用：\(candidate.path)；数据快照：\(backup.path)".utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
        } catch {
            var message = "更新失败：\(error.localizedDescription)"
            // 新进程必须真正停止后才恢复快照，禁止与其数据库写入并发。
            if let app = running, !app.isTerminated {
                app.terminate()
                let deadline = Date().addingTimeInterval(5)
                while !app.isTerminated && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                if !app.isTerminated { app.forceTerminate() }
                let forceDeadline = Date().addingTimeInterval(5)
                while !app.isTerminated && Date() < forceDeadline { try? await Task.sleep(for: .milliseconds(100)) }
            }
            var shouldRelaunchOld = false
            if oldProcessExited && (running == nil || running?.isTerminated == true) {
                do {
                    try storeLock?.acquire()
                    try transaction?.rollback()
                    shouldRelaunchOld = oldProcessExited
                }
                catch { message += "；自动恢复失败，备份已保留：\(work?.path ?? "")" }
            } else if oldProcessExited {
                message += "；新进程未停止，未覆盖数据；旧应用和快照已保留"
            }
            try? Data(message.utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
            storeLock?.release()
            // 先写失败结果再启动旧版，使其第一次读取状态就能提示恢复情况。
            if shouldRelaunchOld, let target = request?.target { _ = try? await launch(target, arguments: []) }
        }
    }

    /// LaunchServices 完成回调只证明进程启动，业务就绪由独立回执确认。
    @MainActor private static func launch(_ app: URL, arguments: [String]) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments; configuration.createsNewApplicationInstance = true
        configuration.activates = false
        return try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
