// 原库事务提交；任何提交前失败由SQLite回滚日志恢复完整旧态，by AI.Coding。
import Foundation
import Darwin
final class CommitStrategy {
    let root: URL
    let databaseURL: URL
    let staging: URL
    let faults: any StorageFaultInjector
    private(set) var peakTemporaryBytes: Int64 = 0
    private(set) var lastCandidateClipCount: Int64 = 0
    private(set) var lastCandidateBytes: Int64 = 0
    /// 创建专用布局；历史日志与待回收候选均纳入实际占用。
    init(root: URL, faults: any StorageFaultInjector = NoStorageFault()) throws {
        self.root = root; self.faults = faults
        databaseURL = root.appendingPathComponent("History/history.sqlite")
        staging = root.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }
    /// 首次初始化在独立候选内完成并rename发布，不能留下半份 schema。
    func initialize(_ body: (SQLiteConnection) throws -> Void) throws {
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try create(body)
    }
    /// 每次访问一个连接，actor 调用期间没有 await。
    func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let db = try SQLiteConnection(databaseURL)
        try db.configure()
        let result = try body(db)
        try db.close()
        return result
    }
    /// 实际文件长度，包括目录下 SQLite 日志、派生和垃圾，不假装失败为零。
    static func bytes(_ directory: URL, countHardLinksOnce: Bool = false) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var enumerationError: Error?
        let keys:Set<URLResourceKey> = [.isRegularFileKey,.fileSizeKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey]
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw StoreError.ioFailure }
        var total: Int64 = 0
        var fileIdentities = Set<String>()
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                // 仅拖出目录按硬链接身份去重；历史/配额计量沿用原规则，by AI.Coding。
                if countHardLinksOnce {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw StoreError.ioFailure }
                    if !fileIdentities.insert("\(device.uint64Value):\(inode.uint64Value)").inserted { continue }
                }
                guard let size = values.fileSize, let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { throw StoreError.ioFailure }
                total += Int64(max(size,allocated))
            }
        }
        if enumerationError != nil { throw StoreError.ioFailure }
        return total
    }
    /// 非活跃 staging 都是待回收，不通过重命名避开配额。
    func measuredBytes() throws -> Int64 { try Self.bytes(databaseURL.deletingLastPathComponent()) + Self.bytes(staging) + Self.bytes(root.appendingPathComponent("Exports")) }
    /// 清理失败的 staging 留存并在 usage 计量。
    func recover() throws -> Int64 {
        for file in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            do { try FileManager.default.removeItem(at: file) } catch { /* 无法回收时仍纳入容量，不能报已释放。 */ }
        }
        try discardStaleJournal()
        return try Self.bytes(staging)
    }
    /// 崩溃于页写入前会留下非热日志：取得排他锁时SQLite先回滚任何热日志，
    /// 之后仍存在的日志不含需要恢复的数据，删除以免虚占容量，by AI.Coding。
    private func discardStaleJournal() throws {
        let journal = URL(fileURLWithPath: databaseURL.path + "-journal")
        guard FileManager.default.fileExists(atPath: databaseURL.path), FileManager.default.fileExists(atPath: journal.path) else { return }
        let db = try SQLiteConnection(databaseURL)
        try db.exec("BEGIN EXCLUSIVE; ROLLBACK")
        try db.close()
        if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
    }
    /// 原库上的单一SQLite事务：回滚日志保证中断只留下完整旧态，COMMIT是唯一提交点。
    /// 配额按事务内实际页数检查，超额回滚；dryRun执行同样变更后回滚，不改原库，by AI.Coding。
    /// 旧协议每次写入都克隆并替换整库，耗时随库大小线性增长，因此改为原地事务。
    func commit(quota: Int64, allowOverQuota: Bool = false, estimatedGrowth: Int64 = 0, dryRun: Bool = false, finalize: ((SQLiteConnection, Int64) throws -> Void)? = nil, _ body: (SQLiteConnection) throws -> Void) throws {
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        // 回滚日志只保存被改页的原像；按增量三倍预留，不再需要整库副本空间。
        guard let free = filesystem[.systemFreeSize] as? NSNumber,
              free.int64Value > estimatedGrowth * 3 + 8 * MiB else { throw StoreError.diskFull }
        let pending = try Self.bytes(staging) + Self.bytes(root.appendingPathComponent("Exports"))
        let db = try SQLiteConnection(databaseURL)
        defer { try? db.close() }
        try db.configure()
        // macOS的fsync不刷写盘缓存；保持原协议F_FULLFSYNC级别的持久性。
        try db.exec("PRAGMA fullfsync=ON")
        try db.exec("BEGIN IMMEDIATE")
        var committed = false
        do {
            try faults.check(.candidateCreated)
            try body(db)
            try finalize?(db, pending)
            try faults.check(.candidateWritten)
            let used = try Self.pageBytes(db)
            peakTemporaryBytes = max(peakTemporaryBytes, used)
            if try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='clips'") == 1 { lastCandidateClipCount = try db.scalarInt("SELECT COUNT(*) FROM clips") }
            lastCandidateBytes = used
            if !allowOverQuota && used + pending > quota { throw StoreError.quotaExceeded }
            try faults.check(.candidateValidated)
            if dryRun { try db.exec("ROLLBACK"); return }
            try faults.check(.beforeReplace)
            try db.exec("COMMIT")
            committed = true
            try faults.check(.afterReplace)
            try faults.check(.reopen)
        } catch {
            if committed { throw StoreError.postCommitUnavailable }
            try? db.exec("ROLLBACK")
            throw error
        }
    }
    /// 事务内实际占用：FULL autovacuum在提交时截断空闲页，故按非空闲页计算。
    static func pageBytes(_ db: SQLiteConnection) throws -> Int64 {
        try (db.scalarInt("PRAGMA page_count") - db.scalarInt("PRAGMA freelist_count")) * db.scalarInt("PRAGMA page_size")
    }
    /// 新库在staging完整建成、校验、同步后一次rename发布。
    private func create(_ body: (SQLiteConnection) throws -> Void) throws {
        let operation = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: operation) } catch { /* 删除失败计入容量。 */ } }
        let candidate = operation.appendingPathComponent("candidate.sqlite")
        let db = try SQLiteConnection(candidate)
        defer { try? db.close() }
        try db.exec("PRAGMA auto_vacuum=FULL")
        try db.configure()
        try faults.check(.candidateCreated)
        try db.exec("BEGIN IMMEDIATE")
        do { try body(db); try faults.check(.candidateWritten); try db.exec("COMMIT") }
        catch { try? db.exec("ROLLBACK"); throw error }
        guard try db.scalarText("PRAGMA quick_check") == "ok", try db.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError.corruptPayload }
        try faults.check(.candidateValidated)
        try db.close()
        try syncFile(candidate)
        try faults.check(.beforeReplace)
        guard Darwin.rename(candidate.path, databaseURL.path) == 0 else { throw StoreError.ioFailure }
        try syncDirectory(databaseURL.deletingLastPathComponent())
    }
    /// 候选内容同步到磁盘，失败属于提交前失败。
    private func syncFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StoreError.ioFailure }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StoreError.ioFailure }
        // macOS 完整同步请求失败时仍保有 fsync 的保证，不伪造硬件能力。
        if fcntl(descriptor, F_FULLFSYNC) != 0 && errno != ENOTSUP && errno != EINVAL { throw StoreError.ioFailure }
    }
    /// 同步目录使替换提交具备重启可恢复性。
    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StoreError.postCommitUnavailable }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StoreError.postCommitUnavailable }
    }
}
