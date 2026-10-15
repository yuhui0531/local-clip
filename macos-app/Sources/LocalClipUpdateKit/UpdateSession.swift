// 更新会话持久状态、全程会话锁与受边界约束的回收；只有正向证据才删除，by AI.Coding。
import Foundation
import Darwin

/// 更新相关的全部受信任根；Debug 隔离根与生产路径由同一函数决定，主程序与辅助程序共用。
public struct UpdateLocations: Sendable, Equatable {
    public let support: URL
    public let updatesCache: URL
    /// 存储锁目录：生产为系统临时目录（固定 inode 不删除），测试为隔离根。
    public let lockDirectory: URL
    public let storeLockIdentity: String
    public init(support: URL, updatesCache: URL, lockDirectory: URL = FileManager.default.temporaryDirectory, storeLockIdentity: String = UpdatePackage.bundleIdentifier) {
        self.support = support; self.updatesCache = updatesCache; self.lockDirectory = lockDirectory; self.storeLockIdentity = storeLockIdentity
    }
    public var sessions: URL { support.appendingPathComponent("LocalClip-UpdateSessions", isDirectory: true) }
    public var backups: URL { support.appendingPathComponent("LocalClip-UpdateBackups", isDirectory: true) }
    public var data: URL { support.appendingPathComponent("LocalClip-LocalEdition", isDirectory: true) }

    /// 下载会话目录必须是更新缓存根的直接子目录；按真实路径比较，不受 /private 前缀规范化影响。
    public func isDownloadDirectory(_ directory: URL) -> Bool {
        guard let parent = Self.realPath(directory.deletingLastPathComponent()), let cache = Self.realPath(updatesCache),
              let resolved = Self.realPath(directory) else { return false }
        return parent == cache && URL(fileURLWithPath: resolved).deletingLastPathComponent().path == cache
    }
    /// 启动回执只能写入某个下载会话目录中的 startup-ok（文件此时尚不存在，按父目录真实路径判断）。
    public func isTrustedReceipt(_ receipt: URL) -> Bool {
        receipt.lastPathComponent == "startup-ok" && isDownloadDirectory(receipt.deletingLastPathComponent())
    }
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static var production: UpdateLocations {
        let fm = FileManager.default
        return .init(support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                     updatesCache: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.localclip.dev/Updates", isDirectory: true))
    }

    /// T-01：仅 Debug 接受 /private/tmp 下的 LOCALCLIP_UPDATER_TEST_ROOT；Release 恒为生产路径。
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> UpdateLocations {
        #if DEBUG
        if let value = environment["LOCALCLIP_UPDATER_TEST_ROOT"] {
            let root = URL(fileURLWithPath: value).resolvingSymlinksInPath()
            let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path + "/"
            guard root.path.hasPrefix(temporary), root.path.count > temporary.count else { throw UpdateFailure.invalid("测试目录未隔离") }
            return .init(support: root.appendingPathComponent("Application Support", isDirectory: true),
                         updatesCache: root.appendingPathComponent("Caches/Updates", isDirectory: true),
                         lockDirectory: root, storeLockIdentity: "localclip-update-test-" + root.lastPathComponent)
        }
        #endif
        return .production
    }
}

/// 事务语义阶段；swapping 必须在交换前落盘，因此其余替换前阶段可证明应用未交换。
public enum UpdatePhase: String, Codable, Sendable {
    case preparing, ready, snapshotting, swapping, awaitingReceipt
    case succeeded, rollingBack, rolledBack, rescueRequired, abortedBeforeSwap
    /// 旧辅助程序留下的结果，无法证明安装工作区/快照状态，只回收下载缓存。
    case legacyUnknown
    var isPreSwap: Bool { [.preparing, .ready, .snapshotting, .abortedBeforeSwap].contains(self) }
    /// 辅助程序已给出最终结论，可以展示结果。
    public var isFinal: Bool { [.succeeded, .rolledBack, .rescueRequired, .abortedBeforeSwap, .legacyUnknown].contains(self) }
}

/// 结构化会话记录；路径只用于定位，删除前仍逐项核对根目录、层级与应用身份。
public struct UpdateSessionRecord: Codable, Sendable, Equatable {
    public var id: String
    public var sourceBuild: Int
    public var targetBuild: Int?
    public var target: String?
    public var download: String?
    public var phase: UpdatePhase
    public var result: String?
    public var warnings: [String]
    /// 已授权、已改名或待改名的删除对象；部分删除后依赖这里重试，不依赖快照内标记。
    public var trash: [String]
    public var legacy: Bool
    public var updatedAt: Date
    public var finishedAt: Date?
    public init(id: String, sourceBuild: Int, targetBuild: Int?, target: URL?, download: URL?, phase: UpdatePhase, legacy: Bool = false, now: Date = Date()) {
        self.id = id; self.sourceBuild = sourceBuild; self.targetBuild = targetBuild
        self.target = target?.path; self.download = download?.path; self.phase = phase
        result = nil; warnings = []; trash = []; self.legacy = legacy; updatedAt = now; finishedAt = nil
    }
    var workspace: URL? {
        guard UpdateSessionStore.isWorkspaceName(id), let target else { return nil }
        return URL(fileURLWithPath: target).deletingLastPathComponent().appendingPathComponent(id, isDirectory: true)
    }
    func backup(_ locations: UpdateLocations) -> URL? {
        UpdateSessionStore.isWorkspaceName(id) ? locations.backups.appendingPathComponent(id, isDirectory: true) : nil
    }
}

public enum UpdateSessionStore {
    private static let uuid = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
    static func isWorkspaceName(_ name: String) -> Bool { name.range(of: "^\\.LocalClip-update-\(uuid)$", options: .regularExpression) != nil }
    static func isDownloadName(_ name: String) -> Bool { name.range(of: "^\(uuid)$", options: .regularExpression) != nil }
    static func isRecordID(_ id: String) -> Bool { isWorkspaceName(id) || id.range(of: "^legacy-download-\(uuid)$", options: .regularExpression) != nil }

    /// 原子写入；目录 0700，记录不放在可被系统清空的 Caches。
    public static func save(_ record: UpdateSessionRecord, in locations: UpdateLocations) throws {
        guard isRecordID(record.id) else { throw UpdateFailure.invalid("更新会话标识无效") }
        try FileManager.default.createDirectory(at: locations.sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(record).write(to: url(record.id, locations), options: .atomic)
    }

    /// 无法解析的文件保留原样，不当作垃圾。
    public static func load(_ locations: UpdateLocations) -> [UpdateSessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: locations.sessions, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { load($0.deletingPathExtension().lastPathComponent, in: locations) }
    }

    static func load(_ id: String, in locations: UpdateLocations) -> UpdateSessionRecord? {
        guard isRecordID(id) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(UpdateSessionRecord.self, from: Data(contentsOf: url(id, locations))), record.id == id else { return nil }
        return record
    }

    static func url(_ id: String, _ locations: UpdateLocations) -> URL { locations.sessions.appendingPathComponent(id + ".json") }

    /// 最近一次已有最终结论的会话结果，供主程序展示；不依赖下载缓存目录。
    public static func latestResult(_ locations: UpdateLocations) -> (id: String, message: String, at: Date)? {
        load(locations).filter { $0.phase.isFinal && $0.result != nil }.max { $0.updatedAt < $1.updatedAt }
            .map { ($0.id, $0.result!, $0.updatedAt) }
    }
}

/// 覆盖辅助程序整个生命周期的会话锁；进程退出自动释放。旧辅助程序不认识此锁，另用进程与结果证据。
public final class UpdateSessionLock {
    private var descriptor: Int32 = -1
    let url: URL
    public init(id: String, locations: UpdateLocations) { url = locations.sessions.appendingPathComponent(id + ".lock") }
    /// 非阻塞尝试；被占用即返回 false，调用方跳过而不等待，避免与回执互等。
    public func tryAcquire() -> Bool {
        guard descriptor < 0 else { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = url.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { return false }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET); lock.l_start = 0; lock.l_len = 0
        guard fcntl(fd, F_SETLK, &lock) == 0 else { Darwin.close(fd); return false }
        descriptor = fd
        return true
    }
    public func release() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    /// 只在本进程持锁时删除：会话标识唯一，之后不会有进程再打开同一路径。
    func removeWhileHeld() { if descriptor >= 0 { unlink(url.path); release() } }
    deinit { release() }
}

/// 成功快照保留策略：最多保留最近 keepLatest 份，且成功满 maximumAge 后到期（产品确认 7 天，2026-10-15）；nil 表示不按时间删除。
/// 只作用于 succeeded 会话；回滚、救援快照永不按时间删除。
public struct UpdateSnapshotPolicy: Sendable, Equatable {
    public var maximumAge: TimeInterval?
    public var keepLatest: Int
    public init(maximumAge: TimeInterval? = nil, keepLatest: Int = 1) { self.maximumAge = maximumAge; self.keepLatest = max(1, keepLatest) }
    public static let standard = UpdateSnapshotPolicy(maximumAge: 7 * 86_400)
}

public struct UpdateJanitorReport: Sendable, Equatable {
    public var removed: [String] = []
    public var retained: [String] = []
    public var skippedActive: [String] = []
    public var failures: [String] = []
    public init() {}
}

/// 补偿清理器：主程序启动/维护与新辅助程序共用；单项失败不阻断其他项，所有删除均可重试。
public enum UpdateJanitor {
    /// excludedDownloads：就绪包、正在安装的包；ownSessionID：调用者已持有其锁的会话。
    /// migrate：只有主程序（知道自己的下载/就绪状态）才迁移旧会话与中断下载；辅助程序传 false。
    public static func run(_ locations: UpdateLocations, excludedDownloads: Set<String> = [], ownSessionID: String? = nil, migrate: Bool = true,
                           policy: UpdateSnapshotPolicy = .standard, now: Date = Date(), legacyQuietPeriod: TimeInterval = 120) -> UpdateJanitorReport {
        var report = UpdateJanitorReport()
        let excluded = Set(excludedDownloads.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        if migrate { migrateLegacy(locations, excluded: excluded, now: now, quiet: legacyQuietPeriod, report: &report) }
        adoptLegacyMarkers(locations, now: now)
        var records = UpdateSessionStore.load(locations)
        var locks: [String: UpdateSessionLock] = [:]
        defer { locks.values.forEach { $0.release() } }
        // 先拿到所有非活跃会话的锁，再整体判断快照保留；被占用的会话本轮完全不碰。
        records = records.compactMap { record in
            lockedRecord(record.id, locations, ownSessionID: ownSessionID, locks: &locks, report: &report)
        }
        // 调用者自己的会话已由其按当次结论处理，这里只参与快照保留与记录回收。
        for index in records.indices where records[index].id != ownSessionID {
            process(&records[index], locations, excluded: excluded, report: &report)
        }
        pruneSnapshots(&records, locations, policy: policy, now: now, report: &report)
        // 记录本身也有生命周期：无残留材料的终态记录只保留最新一条供结果展示。
        let newest = records.filter { $0.result != nil }.max { $0.updatedAt < $1.updatedAt }?.id
        for record in records where record.id != newest && record.id != ownSessionID && collectable(record, locations) {
            if (try? FileManager.default.removeItem(at: UpdateSessionStore.url(record.id, locations))) != nil { locks[record.id]?.removeWhileHeld() }
        }
        return report
    }

    /// 锁前枚举仅用于发现会话；拿锁后重读，避免辅助程序刚完成时用旧阶段覆盖其终态与待删除登记。
    static func lockedRecord(_ id: String, _ locations: UpdateLocations, ownSessionID: String?,
                             locks: inout [String: UpdateSessionLock], report: inout UpdateJanitorReport) -> UpdateSessionRecord? {
        if id == ownSessionID { return UpdateSessionStore.load(id, in: locations) }
        let lock = UpdateSessionLock(id: id, locations: locations)
        guard lock.tryAcquire() else { report.skippedActive.append(id); return nil }
        guard let record = UpdateSessionStore.load(id, in: locations) else { return nil }
        if let download = record.download, helperRunning(in: URL(fileURLWithPath: download)) { report.skippedActive.append(id); return nil }
        locks[id] = lock
        return record
    }

    /// 按阶段回收本会话产物；不确定、救援与未决会话不做破坏性操作。
    public static func process(_ record: inout UpdateSessionRecord, _ locations: UpdateLocations, excluded: Set<String> = [], keepDownload: Bool = false, report: inout UpdateJanitorReport) {
        purgeTrash(&record, locations, report: &report)
        let target = record.target.map { URL(fileURLWithPath: $0) }
        let installed = target.flatMap(appBuild)
        var phase = record.phase
        // 交换后未及落盘：按磁盘上的真实应用身份判定，证据矛盾时保持未决。
        if phase == .swapping, let workspace = record.workspace, let targetBuild = record.targetBuild {
            let candidate = appBuild(workspace.appendingPathComponent("candidate/LocalClip.app"))
            if installed == record.sourceBuild && candidate != record.sourceBuild { phase = .abortedBeforeSwap }
            else if installed == targetBuild && candidate == record.sourceBuild { phase = .awaitingReceipt }
        }
        let releaseDownload: Bool
        switch phase {
        case _ where phase.isPreSwap:
            // 原应用仍是源构建，或候选可证明就是新版包内容（不是换下的旧应用），否则不推定未替换。
            let candidateBuild = record.workspace.flatMap { appBuild($0.appendingPathComponent("candidate/LocalClip.app")) }
            guard installed == record.sourceBuild || candidateBuild != nil && candidateBuild == record.targetBuild else {
                retain(record, "原应用身份与替换前状态不符", &report); return
            }
            // 工作区身份不符（可能含旧应用）时，快照同样可能是回滚所需材料，一并保留。
            let workspaceGone = discardWorkspace(&record, expectedBuild: record.targetBuild, allowMissingApp: true, locations, report: &report)
            let backupGone = workspaceGone && discardBackup(&record, locations, report: &report)
            if workspaceGone && backupGone {
                if record.phase != .abortedBeforeSwap { record.phase = .abortedBeforeSwap; record.finishedAt = record.finishedAt ?? Date() }
                record.result = record.result ?? "更新未完成：安装器在替换应用前中断，原版本与历史未改变"
            }
            releaseDownload = workspaceGone
        case .succeeded:
            if let installed, installed > record.sourceBuild { _ = discardWorkspace(&record, expectedBuild: record.sourceBuild, allowMissingApp: false, locations, report: &report) }
            else if record.workspace.map(exists) == true { retain(record, "已安装应用不是更新后的版本", &report) }
            releaseDownload = true
        case .rolledBack:
            // 完整回滚后候选是换下的失败新版；身份必须是目标构建（构建号单调递增，不可能是旧应用）。
            _ = discardWorkspace(&record, expectedBuild: record.targetBuild, allowMissingApp: false, locations, report: &report)
            releaseDownload = true
        case .legacyUnknown:
            releaseDownload = true
        default:
            retain(record, "会话未决或需要救援，保留全部恢复材料", &report)
            releaseDownload = false
        }
        if releaseDownload, !keepDownload, let download = record.download {
            let url = URL(fileURLWithPath: download)
            if excluded.contains(url.resolvingSymlinksInPath().path) { record.download = nil }
            else if !helperRunning(in: url), UpdateSessionStore.isDownloadName(url.lastPathComponent),
                    discard(url, under: locations.updatesCache, &record, locations, report: &report) { record.download = nil }
        }
        try? UpdateSessionStore.save(record, in: locations)
    }

    /// 普通成功快照：保留最近 keepLatest 份，并按可注入时钟到期删除；时钟回拨时不会提前到期。
    static func pruneSnapshots(_ records: inout [UpdateSessionRecord], _ locations: UpdateLocations, policy: UpdateSnapshotPolicy, now: Date, report: inout UpdateJanitorReport) {
        let succeeded = records.indices.filter { records[$0].phase == .succeeded && records[$0].backup(locations).map(exists) == true }
            .sorted { (records[$0].finishedAt ?? records[$0].updatedAt) > (records[$1].finishedAt ?? records[$1].updatedAt) }
        for (rank, index) in succeeded.enumerated() {
            let finished = records[index].finishedAt ?? records[index].updatedAt
            let expired = policy.maximumAge.map { now.timeIntervalSince(finished) > $0 } ?? false
            guard rank >= policy.keepLatest || expired else { continue }
            if discardBackup(&records[index], locations, report: &report) { try? UpdateSessionStore.save(records[index], in: locations) }
        }
    }

    // MARK: - 旧会话迁移

    /// 旧辅助程序只在 Caches 留下 result.txt / request.json；仅当结论明确、进程不在且静默期已过才归类。
    static func migrateLegacy(_ locations: UpdateLocations, excluded: Set<String>, now: Date, quiet: TimeInterval, report: inout UpdateJanitorReport) {
        let fm = FileManager.default
        var known = Dictionary(UpdateSessionStore.load(locations).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let referenced = Set(known.values.compactMap { $0.download.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } })
        for directory in (try? fm.contentsOfDirectory(at: locations.updatesCache, includingPropertiesForKeys: nil)) ?? [] {
            let path = directory.resolvingSymlinksInPath().path
            guard UpdateSessionStore.isDownloadName(directory.lastPathComponent), isDirectory(directory),
                  !excluded.contains(path), !referenced.contains(path) else { continue }
            if helperRunning(in: directory) { report.skippedActive.append(directory.lastPathComponent); continue }
            let resultURL = directory.appendingPathComponent("result.txt")
            let hasRequest = fm.fileExists(atPath: directory.appendingPathComponent("request.json").path)
            guard let message = try? String(contentsOf: resultURL, encoding: .utf8) else {
                // 无安装请求也无结果：单实例下只能是本应用中断的下载，不是任何会话的材料。
                if !hasRequest {
                    var record = UpdateSessionRecord(id: "legacy-download-" + directory.lastPathComponent, sourceBuild: 0, targetBuild: nil, target: nil, download: directory, phase: .legacyUnknown, legacy: true, now: now)
                    record.finishedAt = now
                    if (try? UpdateSessionStore.save(record, in: locations)) != nil { report.retained.append(record.id + "：待回收中断下载") }
                } else { retain(directory.lastPathComponent, "旧安装请求没有结果，无法确认是否仍需恢复", &report) }
                continue
            }
            let modified = (try? resultURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) >= quiet else { report.skippedActive.append(directory.lastPathComponent); continue }
            let request = (try? Data(contentsOf: directory.appendingPathComponent("request.json"))).flatMap { try? JSONDecoder().decode(InstallRequest.self, from: $0) }
            var record: UpdateSessionRecord
            let existing = legacySnapshotName(message, locations).flatMap { known[$0] }
            if message.hasPrefix("更新成功"), let request, let snapshot = legacySnapshotName(message, locations), existing == nil || existing?.legacy == true && existing?.target == nil {
                // 7c0ff14 格式同时给出旧应用路径，必须与快照同名；ca874a9 起只给快照路径。
                if let old = legacyField(message, "旧应用："), URL(fileURLWithPath: old).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent != snapshot {
                    retain(directory.lastPathComponent, "旧结果中的应用与快照不一致", &report); continue
                }
                // 已由旧成功标记建档时补全关联证据，而不是另建一条记录。
                record = UpdateSessionRecord(id: snapshot, sourceBuild: request.currentBuild, targetBuild: nil, target: request.target, download: directory, phase: .succeeded, legacy: true, now: existing?.updatedAt ?? modified)
            } else {
                record = UpdateSessionRecord(id: "legacy-download-" + directory.lastPathComponent, sourceBuild: request?.currentBuild ?? 0, targetBuild: nil, target: nil, download: directory, phase: .legacyUnknown, legacy: true, now: modified)
            }
            record.result = message; record.finishedAt = existing?.finishedAt ?? modified
            if (try? UpdateSessionStore.save(record, in: locations)) == nil { report.failures.append(directory.lastPathComponent + "：无法保存迁移记录") }
            else { known[record.id] = record }
        }
    }

    /// 只看备份根，不涉及下载缓存，辅助程序也可执行（保持旧版“成功后淘汰带标记旧快照”的行为）。
    static func adoptLegacyMarkers(_ locations: UpdateLocations, now: Date) {
        let fm = FileManager.default
        let known = Set(UpdateSessionStore.load(locations).map(\.id))
        // 旧协议的成功标记：只作为“普通成功快照”的证据，归入保留策略，不再依赖目录内标记重试。
        for backup in (try? fm.contentsOfDirectory(at: locations.backups, includingPropertiesForKeys: nil)) ?? [] {
            let name = backup.lastPathComponent
            guard UpdateSessionStore.isWorkspaceName(name), !known.contains(name), isDirectory(backup) else { continue }
            let marker = backup.appendingPathComponent("update-succeeded")
            guard (try? String(contentsOf: marker, encoding: .utf8)) == "startup-confirmed" else { continue }
            let at = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            var record = UpdateSessionRecord(id: name, sourceBuild: 0, targetBuild: nil, target: nil, download: nil, phase: .succeeded, legacy: true, now: at)
            record.finishedAt = at
            try? UpdateSessionStore.save(record, in: locations)
        }
    }

    private static func legacyField(_ message: String, _ key: String) -> String? {
        guard let range = message.range(of: key) else { return nil }
        return String(message[range.upperBound...].prefix { $0 != "；" })
    }

    /// 快照路径必须是受信任备份根的直接子目录且名称符合会话格式。
    private static func legacySnapshotName(_ message: String, _ locations: UpdateLocations) -> String? {
        guard let path = legacyField(message, "数据快照：") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard UpdateSessionStore.isWorkspaceName(url.lastPathComponent),
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == locations.backups.resolvingSymlinksInPath().path else { return nil }
        return url.lastPathComponent
    }

    // MARK: - 删除原语

    /// 工作区只能包含 candidate/LocalClip.app，应用身份必须符合本阶段预期。
    private static func discardWorkspace(_ record: inout UpdateSessionRecord, expectedBuild: Int?, allowMissingApp: Bool, _ locations: UpdateLocations, report: inout UpdateJanitorReport) -> Bool {
        guard let workspace = record.workspace else { return true }
        guard exists(workspace) else { return true }
        let fm = FileManager.default
        let candidate = workspace.appendingPathComponent("candidate", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(atPath: workspace.path)) ?? ["?"]
        let inner = exists(candidate) ? ((try? fm.contentsOfDirectory(atPath: candidate.path)) ?? ["?"]) : []
        guard Set(entries).isSubset(of: ["candidate"]), Set(inner).isSubset(of: ["LocalClip.app"]) else {
            retain(record, "工作区含有未知内容", &report); return false
        }
        // 可读身份必须等于本阶段预期；替换前的半成品解压（无法读取身份）仅在原应用已核实时允许回收。
        let build = appBuild(candidate.appendingPathComponent("LocalClip.app"))
        guard build.map({ $0 == expectedBuild }) ?? allowMissingApp else { retain(record, "工作区应用身份不符", &report); return false }
        return discard(workspace, under: workspace.deletingLastPathComponent(), &record, locations, report: &report)
    }

    private static func discardBackup(_ record: inout UpdateSessionRecord, _ locations: UpdateLocations, report: inout UpdateJanitorReport) -> Bool {
        guard let backup = record.backup(locations), exists(backup) else { return true }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: backup.path)) ?? ["?"]
        guard Set(entries).isSubset(of: ["data", "update-succeeded"]) else { retain(record, "快照含有未知内容", &report); return false }
        return discard(backup, under: locations.backups, &record, locations, report: &report)
    }

    /// 同父目录改名为带会话标识的待删除对象并先登记，再删除；身份变化或越界即跳过。
    static func discard(_ url: URL, under root: URL, _ record: inout UpdateSessionRecord, _ locations: UpdateLocations, report: inout UpdateJanitorReport) -> Bool {
        var before = stat()
        guard lstat(url.path, &before) == 0 else { return errno == ENOENT }
        let kind = before.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG,
              let parent = realPath(url.deletingLastPathComponent()), let trusted = realPath(root), parent == trusted else {
            retain(record, "越界或符号链接：\(url.lastPathComponent)", &report); return false
        }
        let trash = URL(fileURLWithPath: parent).appendingPathComponent(".LocalClip-trash-\(record.id)-\(UUID().uuidString)")
        record.trash.append(trash.path)
        guard (try? UpdateSessionStore.save(record, in: locations)) != nil else {
            record.trash.removeLast(); report.failures.append(url.lastPathComponent + "：无法登记删除"); return false
        }
        guard renamex_np(url.path, trash.path, UInt32(RENAME_EXCL)) == 0 else {
            let missing = errno == ENOENT
            record.trash.removeLast(); try? UpdateSessionStore.save(record, in: locations)
            if !missing { report.failures.append(url.lastPathComponent) }
            return missing
        }
        var after = stat()
        guard lstat(trash.path, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
            // 检查后对象被替换：不删除改名后的未知对象，也不再登记。
            record.trash.removeAll { $0 == trash.path }; try? UpdateSessionStore.save(record, in: locations)
            retain(record, "删除前对象已变化：\(url.lastPathComponent)", &report); return false
        }
        report.removed.append(url.lastPathComponent)
        purgeTrash(&record, locations, report: &report)
        return true
    }

    /// 重试已登记的待删除对象；只认本会话前缀且位于受信任父目录，不跟随符号链接。
    static func purgeTrash(_ record: inout UpdateSessionRecord, _ locations: UpdateLocations, report: inout UpdateJanitorReport) {
        guard !record.trash.isEmpty else { return }
        let roots = Set([locations.backups, locations.updatesCache, record.workspace?.deletingLastPathComponent()].compactMap { $0.flatMap(realPath) })
        record.trash = record.trash.filter { path in
            let url = URL(fileURLWithPath: path)
            guard url.lastPathComponent.hasPrefix(".LocalClip-trash-\(record.id)-"), let parent = realPath(url.deletingLastPathComponent()), roots.contains(parent) else { return false }
            var info = stat()
            guard lstat(path, &info) == 0 else { return errno != ENOENT }
            guard info.st_mode & S_IFMT != S_IFLNK else { return false }
            do { try FileManager.default.removeItem(at: url); return false }
            catch { report.failures.append(url.lastPathComponent); return true }
        }
        try? UpdateSessionStore.save(record, in: locations)
    }

    private static func collectable(_ record: UpdateSessionRecord, _ locations: UpdateLocations) -> Bool {
        record.phase.isFinal && record.trash.isEmpty && record.download.map { exists(URL(fileURLWithPath: $0)) } != true
            && record.workspace.map(exists) != true && record.backup(locations).map(exists) != true
    }

    // MARK: - 证据

    /// 其他进程正从该下载目录运行辅助程序即视为活跃（调用者自身除外）；无法枚举时保守视为活跃。
    public static func helperRunning(in directory: URL) -> Bool {
        guard let resolved = realPath(directory) else { return false }
        let expected = URL(fileURLWithPath: resolved).appendingPathComponent("LocalClipUpdater").path
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0, count < pids.count else { return true }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let current = getpid()
        for pid in pids.prefix(count) where pid > 0 && pid != current {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
               buffer.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == expected { return true }
        }
        return false
    }

    static func appBuild(_ app: URL) -> Int? {
        guard let info = try? UpdatePackage.readInfo(app), info["CFBundleIdentifier"] as? String == UpdatePackage.bundleIdentifier else { return nil }
        return (info["CFBundleVersion"] as? String).flatMap(Int.init)
    }
    static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private static func isDirectory(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR }
    private static func realPath(_ url: URL) -> String? { UpdateLocations.realPath(url) }
    private static func retain(_ record: UpdateSessionRecord, _ reason: String, _ report: inout UpdateJanitorReport) { retain(record.id, reason, &report) }
    private static func retain(_ id: String, _ reason: String, _ report: inout UpdateJanitorReport) { report.retained.append(id + "：" + reason) }
}
