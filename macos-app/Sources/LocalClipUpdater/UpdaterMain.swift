// 独立、无提权安装器：只有显式启动才工作，退出应用本身不会触发安装，by AI.Coding。
import AppKit
import Darwin
import LocalClipUpdateKit

@main struct UpdaterMain {
    /// 请求文件由主程序创建；结论写入持久会话记录，下载目录 result.txt 仅为兼容旧读取方保留。
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
        var session: SessionTracker?
        do {
            let value = try JSONDecoder().decode(InstallRequest.self, from: Data(contentsOf: requestURL))
            request = value
            guard value.downloadDirectory.standardizedFileURL.path == root.standardizedFileURL.path else { throw UpdateFailure.invalid("安装请求的下载目录不匹配") }
            // Foundation 会把 /private/tmp 规范为 /tmp，不能用字符串相等判断符号链接。
            guard value.target.pathExtension == "app", try value.target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw UpdateFailure.invalid("安装目标不是独立应用目录") }
            guard value.parentPID > 1, kill(value.parentPID, 0) == 0 else { throw UpdateFailure.invalid("原应用进程不可访问：\(errno)") }
            // T-01：Debug 隔离根与主程序回执校验共用同一函数；Release 恒为生产路径。
            let locations = try UpdateLocations.current()
            #if DEBUG
            if let testRoot = ProcessInfo.processInfo.environment["LOCALCLIP_UPDATER_TEST_ROOT"] {
                let isolated = URL(fileURLWithPath: testRoot).resolvingSymlinksInPath().path + "/"
                guard value.target.resolvingSymlinksInPath().path.hasPrefix(isolated) else { throw UpdateFailure.invalid("测试目录未隔离") }
            }
            #endif
            // 下载目录必须是受信任缓存根的直接子目录，补偿清理才能按同一边界回收。
            guard locations.isDownloadDirectory(root) else { throw UpdateFailure.invalid("安装请求的下载目录不受信任") }
            let manifest = try UpdatePackage.authenticate(directory: root, installedApp: value.target, currentBuild: value.currentBuild)
            let id = ".LocalClip-update-" + UUID().uuidString
            let workspace = value.target.deletingLastPathComponent().appendingPathComponent(id, isDirectory: true)
            let backup = locations.backups.appendingPathComponent(id, isDirectory: true)
            // 先落盘会话并持有全程会话锁，再创建任何产物；进程被杀后由主程序按记录补偿。
            session = try SessionTracker(locations, UpdateSessionRecord(id: id, sourceBuild: value.currentBuild, targetBuild: manifest.build, target: value.target, download: root, phase: .preparing))
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            work = workspace
            let candidate = try UpdatePackage.extract(directory: root, manifest: manifest, destination: workspace.appendingPathComponent("candidate"))
            // 数据快照与原数据同卷，跨磁盘安装应用仍然能够原子恢复数据。
            storeLock = UpdateStoreLock(identity: locations.storeLockIdentity, directory: locations.lockDirectory)
            let operation = try UpdateTransaction(target: value.target, candidate: candidate, dataDirectory: locations.data, backupDirectory: backup)
            transaction = operation
            // 完成验签、解压和安装目录写入后才通知父程序可以安全退出。
            try session?.advance(.ready)
            try Data("ready".utf8).write(to: root.appendingPathComponent("installer-ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(45)
            while kill(value.parentPID, 0) == 0 {
                guard Date() < deadline else { throw UpdateFailure.invalid("应用未退出，更新已取消") }
                try await Task.sleep(for: .milliseconds(100))
            }
            oldProcessExited = true
            try session?.advance(.snapshotting)
            try storeLock?.acquire()
            try operation.prepare()
            // swapping 必须先于交换落盘：否则补偿清理会把含旧应用的工作区误当作替换前候选。
            try session?.advance(.swapping)
            try operation.replaceApp()
            try? session?.advance(.awaitingReceipt)
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
            let message = "更新成功；数据快照：\(backup.path)"
            try? Data(message.utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
            // F-03：成功终态先可靠落盘，再做任何破坏性清理；落盘失败只放弃清理，绝不回滚或改写结论。
            guard (try? session?.finish(.succeeded, result: message)) != nil else { return }
            // 兼容旧版辅助程序识别成功快照；新逻辑以会话记录为准，不依赖此标记。
            try? Data("startup-confirmed".utf8).write(to: backup.appendingPathComponent("update-succeeded"), options: .atomic)
            session?.cleanUp(keepDownload: false, download: root)
        } catch {
            var message = "更新失败：\(error.localizedDescription)"
            var phase = UpdatePhase.abortedBeforeSwap
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
                let swapped = transaction?.replaced == true
                if swapped { try? session?.advance(.rollingBack) }
                do {
                    try storeLock?.acquire()
                    try transaction?.rollback()
                    if swapped { phase = .rolledBack }
                    shouldRelaunchOld = oldProcessExited
                }
                catch { message += "；自动恢复失败，备份已保留：\(work?.path ?? "")"; phase = swapped ? .rescueRequired : .abortedBeforeSwap }
            } else if oldProcessExited {
                message += "；新进程未停止，未覆盖数据；旧应用和快照已保留"
                phase = .rescueRequired
            }
            try? Data(message.utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
            storeLock?.release()
            // F-01：只在确认的终态下回收；父进程仍在时它会读取 result.txt，下载目录留给主程序补偿回收。
            if (try? session?.finish(phase, result: message)) != nil, phase != .rescueRequired {
                session?.cleanUp(keepDownload: !oldProcessExited, download: root)
            }
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

/// 持有会话锁直到进程退出；每次阶段推进都原子写入记录。
@MainActor final class SessionTracker {
    let locations: UpdateLocations
    var record: UpdateSessionRecord
    private let lock: UpdateSessionLock
    init(_ locations: UpdateLocations, _ record: UpdateSessionRecord) throws {
        self.locations = locations; self.record = record
        lock = UpdateSessionLock(id: record.id, locations: locations)
        guard lock.tryAcquire() else { throw UpdateFailure.invalid("无法获得更新会话锁") }
        try UpdateSessionStore.save(record, in: locations)
    }
    func advance(_ phase: UpdatePhase) throws {
        record.phase = phase; record.updatedAt = Date()
        try UpdateSessionStore.save(record, in: locations)
    }
    func finish(_ phase: UpdatePhase, result: String) throws {
        record.result = result; record.finishedAt = Date()
        try advance(phase)
    }
    /// 清理只产生告警：本会话产物按终态回收，其余会话只参与成功快照保留；旧会话迁移只由主程序执行。
    func cleanUp(keepDownload: Bool, download: URL) {
        var report = UpdateJanitorReport()
        UpdateJanitor.process(&record, locations, keepDownload: keepDownload, report: &report)
        let others = UpdateJanitor.run(locations, excludedDownloads: [download.path], ownSessionID: record.id, migrate: false)
        let failures = report.failures + others.failures
        guard !failures.isEmpty, let result = record.result else { return }
        record.warnings = failures
        if record.phase == .succeeded, let range = result.range(of: "；数据快照：") {
            record.result = "更新成功；部分临时文件未清理：\(failures.joined(separator: "、"))" + result[range.lowerBound...]
        }
        try? UpdateSessionStore.save(record, in: locations)
    }
}
