// 单卷候选库提交；任何提交前失败不修改原库，by AI.Coding。
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
    private var validatedSource = false
    /// 启动/恢复完成全库与外键校验后，才允许已验证APFS源库的局部提交校验，by AI.Coding。
    func sourceDidValidate() { validatedSource = true }
    /// 创建专用布局；历史日志与待回收候选均纳入实际占用。
    init(root: URL, faults: any StorageFaultInjector = NoStorageFault()) throws {
        self.root = root; self.faults = faults
        databaseURL = root.appendingPathComponent("History/history.sqlite")
        staging = root.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }
    /// 首次初始化也在候选内完成，不能留下半份 schema。
    func initialize(_ body: (SQLiteConnection) throws -> Void) throws {
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try commit(quota: Int64.max, body)
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
    static func bytes(_ directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var enumerationError: Error?
        let keys:Set<URLResourceKey> = [.isRegularFileKey,.fileSizeKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey]
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw StoreError.ioFailure }
        var total: Int64 = 0
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
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
        return try Self.bytes(staging)
    }
    /// 候选变更 → 校验和物理计量 → fsync → rename，提交点只有一个。
    func commit(quota: Int64, allowOverQuota: Bool = false, estimatedGrowth: Int64 = 0, dryRun: Bool = false, finalize: ((SQLiteConnection, Int64) throws -> Void)? = nil, _ body: (SQLiteConnection) throws -> Void) throws {
        let oldSize = try Self.bytes(databaseURL.deletingLastPathComponent())
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let free = filesystem[.systemFreeSize] as? NSNumber,
              free.int64Value > oldSize * 3 + estimatedGrowth * 3 + 8 * MiB else { throw StoreError.diskFull }
        let operation = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
        let candidate = operation.appendingPathComponent("candidate.sqlite")
        var committed = false
        do {
            var cloned = false
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                // actor中原库无开放写事务；APFS克隆为独立COW文件，候选改动不影响原库。
                if Darwin.clonefile(databaseURL.path, candidate.path, 0) == 0 { cloned = true }
                else if errno != ENOTSUP && errno != EINVAL && errno != EXDEV {
                    if errno == ENOSPC { throw StoreError.diskFull }
                    throw StoreError.ioFailure
                }
            }
            let db = try SQLiteConnection(candidate)
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                if !cloned {
                    let old = try SQLiteConnection(databaseURL)
                    try old.configure(); try old.backup(to: db); try old.close()
                }
            } else { try db.exec("PRAGMA auto_vacuum=FULL") }
            try faults.check(.candidateCreated)
            // 不用全文件预读验证权限；候选读写权限失败仍在变更事务之前拒绝，by AI.Coding。
            guard Darwin.access(candidate.path, R_OK | W_OK) == 0 else { throw StoreError.ioFailure }
            try db.configure()
            guard try db.scalarInt("PRAGMA auto_vacuum") == 1 else { throw StoreError.ioFailure }
            try db.exec("BEGIN IMMEDIATE")
            do {
                try body(db)
                peakTemporaryBytes = max(peakTemporaryBytes, try Self.bytes(operation))
                try faults.check(.candidateWritten); try db.exec("COMMIT")
            }
            catch { try? db.exec("ROLLBACK"); throw error }
            if let finalize {
                let pending = try Self.bytes(staging) + Self.bytes(root.appendingPathComponent("Exports")) - Self.bytes(operation)
                try finalize(db, pending)
            }
            // 已验证源库的COW副本由SQLite约束校验变更页；不再为小写入读取全部正文。
            // 初始化、未验证源库和非APFS备份仍执行完整校验，by AI.Coding。
            if !cloned || !validatedSource {
                guard try db.scalarText("PRAGMA quick_check") == "ok", try db.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError.corruptPayload }
            }
            let identity: (Int64, String)?
            if try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='store_meta'") == 1 {
                identity = (try db.scalarInt("SELECT storeRevision FROM store_meta WHERE singletonID=1"), try db.scalarText("SELECT lastOperationID FROM store_meta WHERE singletonID=1"))
            } else { identity = nil }
            if try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='clips'") == 1 { lastCandidateClipCount = try db.scalarInt("SELECT COUNT(*) FROM clips") }
            try faults.check(.candidateValidated)
            peakTemporaryBytes = max(peakTemporaryBytes, try Self.bytes(operation))
            try db.close()
            let actual = try Self.bytes(operation)
            lastCandidateBytes = actual
            let pending = try Self.bytes(staging) + Self.bytes(root.appendingPathComponent("Exports")) - actual
            if !allowOverQuota && actual + pending > quota { throw StoreError.quotaExceeded }
            if dryRun {
                try FileManager.default.removeItem(at: operation)
                return
            }
            try syncFile(candidate)
            try faults.check(.beforeReplace)
            // rename 在同卷替换已有文件为原子操作，原库从未先删除。
            guard Darwin.rename(candidate.path, databaseURL.path) == 0 else { throw StoreError.ioFailure }
            committed = true
            try syncDirectory(databaseURL.deletingLastPathComponent())
            try faults.check(.afterReplace)
            try faults.check(.reopen)
            let verify = try SQLiteConnection(databaseURL)
            if let identity {
                guard try verify.scalarInt("SELECT storeRevision FROM store_meta WHERE singletonID=1") == identity.0,
                      try verify.scalarText("SELECT lastOperationID FROM store_meta WHERE singletonID=1") == identity.1 else { throw StoreError.postCommitUnavailable }
            } else {
                guard try verify.scalarText("PRAGMA quick_check") == "ok" else { throw StoreError.postCommitUnavailable }
            }
            try verify.close()
            do { try FileManager.default.removeItem(at: operation) } catch { /* 保留可计量的待回收目录。 */ }
        } catch {
            do { try FileManager.default.removeItem(at: operation) } catch { /* 删除失败计入容量。 */ }
            if committed { throw StoreError.postCommitUnavailable }
            throw error
        }
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
