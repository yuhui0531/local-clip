// 更新会话补偿清理：全部使用临时目录与合成应用，不触碰真实安装、缓存或历史，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipUpdateKit
@testable import LocalClipMac

struct UpdateJanitorTests {
    /// 隔离根：Applications / Application Support / Caches/Updates 与外部哨兵。
    struct Fixture {
        let root: URL
        let locations: UpdateLocations
        let target: URL
        let sentinel: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("janitor-" + UUID().uuidString).resolvingSymlinksInPath()
            locations = UpdateLocations(support: root.appendingPathComponent("Application Support"), updatesCache: root.appendingPathComponent("Caches/Updates"), lockDirectory: root, storeLockIdentity: "janitor-test")
            target = root.appendingPathComponent("Applications/LocalClip.app")
            sentinel = root.appendingPathComponent("outside/sentinel")
            for url in [locations.updatesCache, locations.backups, locations.data, sentinel.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try Data("keep".utf8).write(to: sentinel)
            try Data("history".utf8).write(to: locations.data.appendingPathComponent("history"))
        }
        func cleanUp() {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if let all = FileManager.default.enumerator(atPath: root.path) {
                for case let path as String in all { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(path).path) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        static func app(_ url: URL, build: Int) throws {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": UpdatePackage.bundleIdentifier, "CFBundleVersion": String(build)]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        /// 一个完整会话的产物：工作区候选、数据快照与下载目录。
        func session(phase: UpdatePhase, installed: Int, candidate: Int?, finished: Date? = nil, result: String? = nil) throws -> UpdateSessionRecord {
            let id = ".LocalClip-update-" + UUID().uuidString
            try? FileManager.default.removeItem(at: target)
            try Self.app(target, build: installed)
            let workspace = target.deletingLastPathComponent().appendingPathComponent(id)
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent("candidate"), withIntermediateDirectories: true)
            if let candidate { try Self.app(workspace.appendingPathComponent("candidate/LocalClip.app"), build: candidate) }
            let backup = locations.backups.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: backup.appendingPathComponent("data"), withIntermediateDirectories: true)
            try Data("snapshot".utf8).write(to: backup.appendingPathComponent("data/history"))
            let download = locations.updatesCache.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1024).write(to: download.appendingPathComponent("LocalClip-v1.zip"))
            var record = UpdateSessionRecord(id: id, sourceBuild: 100, targetBuild: 101, target: target, download: download, phase: phase, now: finished ?? Date())
            record.result = result; record.finishedAt = finished
            try UpdateSessionStore.save(record, in: locations)
            return record
        }
        func workspace(_ record: UpdateSessionRecord) -> URL { target.deletingLastPathComponent().appendingPathComponent(record.id) }
        func backup(_ record: UpdateSessionRecord) -> URL { locations.backups.appendingPathComponent(record.id) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func record(_ id: String) -> UpdateSessionRecord? { UpdateSessionStore.load(locations).first { $0.id == id } }
        /// 外部哨兵、已安装应用与主数据在任何清理后都必须保持。
        func assertUserDataIntact() throws {
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
            #expect(try String(contentsOf: locations.data.appendingPathComponent("history"), encoding: .utf8) == "history")
            #expect(exists(target))
        }
    }

    /// 替换前中断（取消/超时/准备失败/被杀）：候选、半成品快照与无用下载被回收，原应用和数据不变。
    @Test(arguments: [UpdatePhase.preparing, .ready, .snapshotting, .abortedBeforeSwap])
    func preSwapSessionsReclaimCandidates(phase: UpdatePhase) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let record = try fixture.session(phase: phase, installed: 100, candidate: 101)
        let report = UpdateJanitor.run(fixture.locations)
        #expect(!fixture.exists(fixture.workspace(record)) && !fixture.exists(fixture.backup(record)))
        #expect(!fixture.exists(URL(fileURLWithPath: record.download!)))
        let updated = try #require(fixture.record(record.id))
        #expect(updated.phase == .abortedBeforeSwap && updated.trash.isEmpty && updated.result != nil)
        #expect(report.failures.isEmpty)
        try fixture.assertUserDataIntact()
        #expect(UpdateJanitor.appBuild(fixture.target) == 100)
    }

    /// 交换已发生但状态仍是 swapping/未决，或阶段与磁盘证据矛盾：全部恢复材料保留，多次补偿仍保留。
    @Test func undecidedSessionsKeepRecoveryMaterials() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let swapped = try fixture.session(phase: .swapping, installed: 101, candidate: 100)
        let contradiction = try fixture.session(phase: .snapshotting, installed: 101, candidate: 100)
        let pending = try fixture.session(phase: .awaitingReceipt, installed: 101, candidate: 100)
        let rescue = try fixture.session(phase: .rescueRequired, installed: 101, candidate: 100)
        let rollingBack = try fixture.session(phase: .rollingBack, installed: 100, candidate: 101)
        for _ in 0..<3 { _ = UpdateJanitor.run(fixture.locations) }
        for record in [swapped, contradiction, pending, rescue, rollingBack] {
            #expect(fixture.exists(fixture.workspace(record)), "\(record.phase)")
            #expect(fixture.exists(fixture.backup(record).appendingPathComponent("data/history")))
            #expect(fixture.exists(URL(fileURLWithPath: record.download!)))
        }
        try fixture.assertUserDataIntact()
    }

    /// 成功：换下的旧应用与下载回收，只保留最近一份普通成功快照；回滚快照、救援与未知材料不受影响。
    @Test func successfulSessionsKeepLatestSnapshotOnly() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let older = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, finished: Date(timeIntervalSinceNow: -7200), result: "更新成功；数据快照：old")
        let rolledBack = try fixture.session(phase: .rolledBack, installed: 100, candidate: 101, finished: Date(timeIntervalSinceNow: -3600), result: "更新失败：回滚")
        let newer = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, finished: Date(), result: "更新成功；数据快照：new")
        let unknown = fixture.locations.backups.appendingPathComponent(".LocalClip-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown.appendingPathComponent("data"), withIntermediateDirectories: true)
        _ = UpdateJanitor.run(fixture.locations)
        #expect(!fixture.exists(fixture.backup(older)) && fixture.exists(fixture.backup(newer)))
        #expect(!fixture.exists(fixture.workspace(older)) && !fixture.exists(fixture.workspace(newer)))
        #expect(!fixture.exists(fixture.workspace(rolledBack)), "完整回滚后失败新版候选可回收")
        #expect(fixture.exists(fixture.backup(rolledBack).appendingPathComponent("data/history")), "回滚快照可能含唯一新世代写入")
        #expect(fixture.exists(unknown))
        for record in [older, newer, rolledBack] { #expect(!fixture.exists(URL(fileURLWithPath: record.download!))) }
        // 最新结果记录保留供展示；成功结论不被清理改写。
        #expect(fixture.record(newer.id)?.phase == .succeeded && fixture.record(newer.id)?.result == "更新成功；数据快照：new")
        #expect(UpdateSessionStore.latestResult(fixture.locations)?.id == newer.id)
        #expect(fixture.record(older.id) == nil, "无残留的旧终态记录被回收")
        try fixture.assertUserDataIntact()
    }

    /// F-03：删除中途失败后快照已离开原名、标记也可能消失；登记的待删除对象在权限恢复后继续回收。
    @Test func partialDeletionIsRetriedWithoutMarker() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let older = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, finished: Date(timeIntervalSinceNow: -60), result: "更新成功；数据快照：old")
        _ = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, finished: Date(), result: "更新成功；数据快照：new")
        let locked = fixture.backup(older).appendingPathComponent("data/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let first = UpdateJanitor.run(fixture.locations)
        #expect(!first.failures.isEmpty)
        let pending = try #require(fixture.record(older.id))
        #expect(pending.trash.count == 1 && pending.phase == .succeeded)
        #expect(!fixture.exists(fixture.backup(older)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: URL(fileURLWithPath: pending.trash[0]).appendingPathComponent("data/locked").path)
        let second = UpdateJanitor.run(fixture.locations)
        #expect(second.failures.isEmpty)
        #expect(!fixture.exists(URL(fileURLWithPath: pending.trash[0])))
        try fixture.assertUserDataIntact()
    }

    /// 会话锁被其他进程持有或辅助程序仍从下载目录运行：本轮不碰。
    @Test func activeSessionsAreSkipped() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let locked = try fixture.session(phase: .ready, installed: 100, candidate: 101)
        let running = try fixture.session(phase: .ready, installed: 100, candidate: 101)
        let lockFile = fixture.locations.sessions.appendingPathComponent(locked.id + ".lock").path
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,os,sys,time\nf=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT)\nfcntl.lockf(f,fcntl.LOCK_EX)\nopen(sys.argv[1]+'.held','w').close()\ntime.sleep(30)", lockFile]
        let helper = Process()
        let download = URL(fileURLWithPath: running.download!)
        // 复制的系统二进制会被平台启动约束立即杀死（137），必须编译一个非平台可执行文件冒充辅助程序。
        let source = fixture.root.appendingPathComponent("sleeper.c")
        try Data("#include <unistd.h>\nint main(void){sleep(30);return 0;}\n".utf8).write(to: source)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc"); compiler.arguments = ["-o", download.appendingPathComponent("LocalClipUpdater").path, source.path]
        try compiler.run(); compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        helper.executableURL = download.appendingPathComponent("LocalClipUpdater")
        try holder.run(); try helper.run()
        defer { holder.terminate(); helper.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: lockFile + ".held") && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        // 夹具自检：假辅助程序确实存活且可被识别，否则下面的断言没有意义。
        try #require(helper.isRunning && UpdateJanitor.helperRunning(in: download))
        let report = UpdateJanitor.run(fixture.locations)
        #expect(Set(report.skippedActive).isSuperset(of: [locked.id, running.id]))
        for record in [locked, running] { #expect(fixture.exists(fixture.workspace(record)) && fixture.exists(fixture.backup(record))) }
        holder.terminate(); helper.terminate(); holder.waitUntilExit(); helper.waitUntilExit()
        _ = UpdateJanitor.run(fixture.locations)
        for record in [locked, running] { #expect(!fixture.exists(fixture.workspace(record))) }
    }

    /// F-02：旧辅助程序成功结果（两代格式）迁移后回收旧应用与下载；静默期内、无结果、活跃或越界对象保留。
    @Test func legacySessionsAreMigratedConservatively() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let fm = FileManager.default
        try Fixture.app(fixture.target, build: 102)
        func legacy(_ format: (URL, URL) -> String, age: TimeInterval, request: Bool = true) throws -> (URL, URL, URL) {
            let id = ".LocalClip-update-" + UUID().uuidString
            let workspace = fixture.target.deletingLastPathComponent().appendingPathComponent(id)
            try Fixture.app(workspace.appendingPathComponent("candidate/LocalClip.app"), build: 100)
            let backup = fixture.locations.backups.appendingPathComponent(id)
            try fm.createDirectory(at: backup.appendingPathComponent("data"), withIntermediateDirectories: true)
            let download = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: download, withIntermediateDirectories: true)
            if request { try JSONEncoder().encode(InstallRequest(target: fixture.target, downloadDirectory: download, parentPID: 999_999, currentBuild: 100)).write(to: download.appendingPathComponent("request.json")) }
            let result = download.appendingPathComponent("result.txt")
            try Data(format(workspace, backup).utf8).write(to: result)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: result.path)
            return (workspace, backup, download)
        }
        let v27 = try legacy({ "更新成功；旧应用：\($0.path)/candidate/LocalClip.app；数据快照：\($1.path)" }, age: 7200)
        let v34 = try legacy({ "更新成功；数据快照：\($1.path)" }, age: 3600)
        let fresh = try legacy({ "更新成功；数据快照：\($1.path)" }, age: 5)
        let failed = try legacy({ _, _ in "更新失败：新版本未能完成启动" }, age: 3600)
        let mismatch = try legacy({ _, b in "更新成功；旧应用：/elsewhere/.LocalClip-update-X/candidate/LocalClip.app；数据快照：\(b.path)" }, age: 3600)
        let noResult = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: noResult, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: noResult.appendingPathComponent("request.json"))
        let orphan = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
        let ready = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
        for url in [orphan, ready] { try fm.createDirectory(at: url, withIntermediateDirectories: true); try Data("zip".utf8).write(to: url.appendingPathComponent("LocalClip-v1.zip")) }
        let escape = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: escape, withDestinationURL: fixture.sentinel.deletingLastPathComponent())
        _ = UpdateJanitor.run(fixture.locations, excludedDownloads: [ready.path])
        // 两代成功格式：旧应用与下载回收；较早快照让位于最近一份。
        #expect(!fm.fileExists(atPath: v27.0.path) && !fm.fileExists(atPath: v27.2.path))
        #expect(!fm.fileExists(atPath: v34.0.path) && !fm.fileExists(atPath: v34.2.path))
        #expect(!fm.fileExists(atPath: v27.1.path) && fm.fileExists(atPath: v34.1.path))
        // 静默期内的结果可能仍由旧辅助程序收尾，完全不碰。
        #expect(fm.fileExists(atPath: fresh.0.path) && fm.fileExists(atPath: fresh.1.path) && fm.fileExists(atPath: fresh.2.path))
        // 旧失败结果无法证明工作区/快照状态：只回收下载，工作区与快照保留。
        #expect(!fm.fileExists(atPath: failed.2.path) && fm.fileExists(atPath: failed.0.path) && fm.fileExists(atPath: failed.1.path))
        #expect(fm.fileExists(atPath: mismatch.0.path) && fm.fileExists(atPath: mismatch.1.path))
        #expect(fm.fileExists(atPath: noResult.path) && !fm.fileExists(atPath: orphan.path) && fm.fileExists(atPath: ready.path))
        #expect(fm.fileExists(atPath: escape.path) && fm.fileExists(atPath: fixture.sentinel.path))
        // 迁移后的结果独立于下载目录仍可读取。
        #expect(UpdateSessionStore.load(fixture.locations).contains { $0.id == v34.1.lastPathComponent && $0.result?.hasPrefix("更新成功") == true })
        #expect(UpdateJanitor.appBuild(fixture.target) == 102)
    }

    /// F-04：默认成功快照保留 7 天；到期后不依赖下一次更新即可淘汰；回滚/救援快照不套用；nil 期限可关闭按时间删除。
    @Test func snapshotExpiryUsesSevenDayDefault() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let finished = Date(timeIntervalSince1970: 1_000_000)
        let success = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, finished: finished, result: "更新成功")
        let rolledBack = try fixture.session(phase: .rolledBack, installed: 100, candidate: 101, finished: finished, result: "更新失败")
        let rescue = try fixture.session(phase: .rescueRequired, installed: 100, candidate: 101, finished: finished, result: "更新失败：自动恢复失败")
        let later = finished.addingTimeInterval(30 * 86_400)
        #expect(UpdateSnapshotPolicy.standard.maximumAge == TimeInterval(7 * 86_400))
        _ = UpdateJanitor.run(fixture.locations, policy: UpdateSnapshotPolicy(maximumAge: nil), now: later)
        #expect(fixture.exists(fixture.backup(success)), "nil 期限不按时间删除")
        _ = UpdateJanitor.run(fixture.locations, now: finished.addingTimeInterval(-86_400))
        #expect(fixture.exists(fixture.backup(success)), "时钟回拨不提前到期")
        _ = UpdateJanitor.run(fixture.locations, now: finished.addingTimeInterval(7 * 86_400 - 60))
        #expect(fixture.exists(fixture.backup(success)), "未满 7 天保留")
        _ = UpdateJanitor.run(fixture.locations, now: finished.addingTimeInterval(7 * 86_400 + 60))
        #expect(!fixture.exists(fixture.backup(success)), "满 7 天后默认策略淘汰，即使是最近一份")
        #expect(fixture.exists(fixture.backup(rolledBack)) && fixture.exists(fixture.backup(rescue)) && fixture.exists(fixture.workspace(rescue)))
        #expect(fixture.record(success.id)?.phase == .succeeded)
    }

    /// 连续 10 轮混合更新后，可删除垃圾不随轮次增长；回滚快照按设计保留并单独计数。
    @Test func repeatedMixedSessionsDoNotAccumulateGarbage() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        var rollbacks = 0
        for round in 0..<10 {
            switch round % 3 {
            case 0: _ = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, finished: Date(timeIntervalSinceNow: Double(round)), result: "更新成功")
            case 1: _ = try fixture.session(phase: .rolledBack, installed: 100, candidate: 101, finished: Date(), result: "更新失败"); rollbacks += 1
            default: _ = try fixture.session(phase: .preparing, installed: 100, candidate: 101)
            }
            _ = UpdateJanitor.run(fixture.locations)
        }
        let fm = FileManager.default
        let workspaces = try fm.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path).filter { $0.hasPrefix(".LocalClip-") }
        let downloads = try fm.contentsOfDirectory(atPath: fixture.locations.updatesCache.path)
        let snapshots = try fm.contentsOfDirectory(atPath: fixture.locations.backups.path)
        let records = UpdateSessionStore.load(fixture.locations)
        let successSnapshots = records.filter { $0.phase == .succeeded && fm.fileExists(atPath: fixture.backup($0).path) }
        #expect(workspaces.isEmpty && downloads.isEmpty)
        #expect(successSnapshots.count <= 1)
        #expect(snapshots.count == rollbacks + successSnapshots.count)
        #expect(records.count <= rollbacks + 2)
    }

    /// F-05/F-06：结果来自持久记录，下载缓存被删除后仍可读；未出结论不显示；看过后以“上次更新”呈现。
    @MainActor @Test func resultIsReadFromRecordAndConsumed() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = try fixture.session(phase: .awaitingReceipt, installed: 101, candidate: 100)
        let checker = UpdateChecker(defaults: defaults, locations: fixture.locations)
        #expect(checker.manualResult == nil, "辅助程序尚未写出结论时不能显示为失败")
        var record = pending; record.phase = .succeeded; record.result = "更新成功；数据快照：/fixture"; record.finishedAt = Date(); record.updatedAt = Date()
        try UpdateSessionStore.save(record, in: fixture.locations)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: pending.download!))
        checker.refreshResult()
        #expect(checker.manualResult == "更新已完成；本次更新前的数据快照已保留；数据快照：/fixture")
        checker.markResultSeen()
        #expect(checker.manualResult == "上次更新：更新已完成；本次更新前的数据快照已保留；数据快照：/fixture")
        let reopened = UpdateChecker(defaults: defaults, locations: fixture.locations)
        #expect(reopened.manualResult == "上次更新：更新已完成；本次更新前的数据快照已保留；数据快照：/fixture")
        // 辅助程序收尾只更新告警文字，时间戳不变；已读会话也必须展示晚到的告警。
        record.result = "更新成功；部分临时文件未清理：workspace；数据快照：/fixture"
        try UpdateSessionStore.save(record, in: fixture.locations)
        checker.refreshResult()
        #expect(checker.manualResult == "上次更新：更新已完成；本次更新前的数据快照已保留；部分临时文件未清理：workspace；数据快照：/fixture")
    }

    /// 枚举后辅助程序刚结束：拿锁必须读取新终态，保留结果和待删除登记；已删除记录不复活。
    @Test func lockedSessionReloadsLatestTerminalState() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let stale = try fixture.session(phase: .awaitingReceipt, installed: 101, candidate: 100)
        var latest = stale
        latest.phase = .succeeded; latest.result = "更新成功"
        latest.updatedAt = Date(timeIntervalSince1970: 1_000_000); latest.finishedAt = latest.updatedAt
        let trash = fixture.locations.backups.appendingPathComponent(".LocalClip-trash-\(latest.id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        latest.trash = [trash.path]
        try UpdateSessionStore.save(latest, in: fixture.locations)
        var locks: [String: UpdateSessionLock] = [:], report = UpdateJanitorReport()
        defer { locks.values.forEach { $0.release() } }
        var loaded = try #require(UpdateJanitor.lockedRecord(stale.id, fixture.locations, ownSessionID: nil, locks: &locks, report: &report))
        #expect(loaded == latest)
        UpdateJanitor.process(&loaded, fixture.locations, report: &report)
        #expect(fixture.record(stale.id)?.phase == .succeeded && fixture.record(stale.id)?.result == "更新成功")
        #expect(!fixture.exists(trash))
        locks.values.forEach { $0.release() }; locks.removeAll()
        try FileManager.default.removeItem(at: UpdateSessionStore.url(stale.id, fixture.locations))
        #expect(UpdateJanitor.lockedRecord(stale.id, fixture.locations, ownSessionID: nil, locks: &locks, report: &report) == nil)
        try fixture.assertUserDataIntact()
    }

    /// 维护先开始时，手动检查等待清理结束，之后新建的下载目录仍在且可进入就绪态。
    @MainActor @Test(.timeLimit(.minutes(1))) func manualCheckWaitsForMaintenance() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = UpdateMaintenanceGate()
        defer { Task { await gate.release() } }
        let download = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
        var fetched = false, prepared = false
        let checker = UpdateChecker(defaults: defaults, fetch: { request in
            fetched = true
            let base = "https://github.com/yuhui0531/local-clip/releases/"
            let assets = ["update.json", "update.sig", "LocalClip-v999.0.0.zip"].map { ["name": $0, "browser_download_url": base + "download/v999.0.0/" + $0] }
            let json: [String: Any] = ["tag_name": "v999.0.0", "html_url": base + "tag/v999.0.0", "assets": assets]
            return (try JSONSerialization.data(withJSONObject: json), try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, prepare: { _, _ in
            prepared = true
            try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
            try Data("verified fixture".utf8).write(to: download.appendingPathComponent("archive.zip"))
            return DownloadedUpdate(directory: download, manifest: UpdateManifest(version: "999.0.0", build: 999, minimumSystemVersion: "15.0", architectures: ["arm64"], archive: "LocalClip-v999.0.0.zip", size: 1, sha256: String(repeating: "0", count: 64)))
        }, locations: fixture.locations, cleanup: { locations, excluded in
            await gate.pause()
            _ = UpdateJanitor.run(locations, excludedDownloads: excluded)
        })
        let maintenance = Task { await checker.maintain() }
        // 满负载时MainActor调度很慢，用确定性信号代替共享deadline轮询；超时由timeLimit兜底。
        await gate.waitForEntry()
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        // check在首次挂起前同步置checking，信号回到测试时它已在等待维护。
        let check = Task { signalStarted.finish(); await checker.check(manual: true) }
        for await _ in started {}
        #expect(!fetched && !prepared && checker.checking)
        await checker.maintain()
        #expect(!fetched && !prepared && checker.checking)
        #expect(await gate.entries == 1)
        await gate.release(); await maintenance.value; await check.value
        #expect(fetched && prepared && checker.phase == .ready)
        #expect(fixture.exists(download.appendingPathComponent("archive.zip")))
    }

    /// 检查先开始时，等待版本响应也属于受保护区，不能只在 downloading 阶段跳过维护。
    @MainActor @Test func maintenanceSkipsPendingReleaseFetch() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetchGate = UpdateMaintenanceGate(), cleanupGate = UpdateMaintenanceGate()
        defer { Task { await fetchGate.release() } }
        let checker = UpdateChecker(defaults: defaults, fetch: { _ in
            await fetchGate.pause()
            throw URLError(.notConnectedToInternet)
        }, locations: fixture.locations, cleanup: { _, _ in await cleanupGate.noteEntry() })
        let check = Task { await checker.check(manual: true) }
        let deadline = ContinuousClock.now + .seconds(3)
        while await !fetchGate.entered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(await fetchGate.entered)
        await checker.maintain()
        #expect(await !cleanupGate.entered)
        await fetchGate.release(); await check.value
        await checker.maintain()
        #expect(await cleanupGate.entered)
    }

    /// 设置页也显示手动检查状态；读过该状态不能覆盖成旧安装结果或误标旧结果已读。
    @MainActor @Test func markingCheckStatusPreservesManualResult() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        _ = try fixture.session(phase: .succeeded, installed: 101, candidate: 100, result: "更新成功")
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) }, locations: fixture.locations)
        await checker.check(manual: true)
        #expect(checker.manualResult == "检查失败，请稍后重试")
        checker.markResultSeen()
        #expect(checker.manualResult == "检查失败，请稍后重试")
        #expect(defaults.string(forKey: "lastSeenUpdateResult") == nil)
    }

    /// T-01：真实主程序回执函数与辅助程序同源校验；隔离根内可写，根外与非 /private/tmp 根拒绝。
    @MainActor @Test func debugReceiptUsesSharedIsolation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/localclip-ack-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("Caches/Updates/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let receipt = session.appendingPathComponent("startup-ok")
        let env = ["LOCALCLIP_UPDATER_TEST_ROOT": root.path]
        #if !DEBUG
        // Release 必须忽略隔离环境：回执不在生产缓存内，拒绝且不写文件。
        #expect(!UpdateInstaller.acknowledgeStartup(arguments: ["app", "--localclip-update-receipt", receipt.path], environment: env, build: "101"))
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        #expect(try UpdateLocations.current(environment: env).support == UpdateLocations.production.support)
        #else
        #expect(UpdateInstaller.acknowledgeStartup(arguments: ["app", "--localclip-update-receipt", receipt.path], environment: env, build: "101"))
        #expect(try String(contentsOf: receipt, encoding: .utf8) == "101")
        let outside = root.appendingPathComponent("startup-ok")
        #expect(!UpdateInstaller.acknowledgeStartup(arguments: ["app", "--localclip-update-receipt", outside.path], environment: env, build: "101"))
        #expect(!UpdateInstaller.acknowledgeStartup(arguments: ["app", "--localclip-update-receipt", receipt.path], environment: ["LOCALCLIP_UPDATER_TEST_ROOT": FileManager.default.homeDirectoryForCurrentUser.path], build: "101"))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        // T-02：隔离锁位于测试根，生产锁目录不新增文件。
        let locations = try UpdateLocations.current(environment: env)
        #expect(locations.lockDirectory.path == root.resolvingSymlinksInPath().path)
        let lock = UpdateStoreLock(identity: locations.storeLockIdentity, directory: locations.lockDirectory)
        try lock.acquire(); lock.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".lock") })
        #endif
    }
}

private actor UpdateMaintenanceGate {
    private(set) var entered = false
    private(set) var entries = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func noteEntry() { entered = true; resumeEntryWaiters() }
    func pause() async {
        entered = true; entries += 1; resumeEntryWaiters()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    private func resumeEntryWaiters() { entryWaiters.forEach { $0.resume() }; entryWaiters = [] }
    func release() { continuation?.resume(); continuation = nil }
}
