// T03 使用真实文件验证失败保留与物理配额，by AI.Coding。
import Foundation
import Darwin
import Testing
@testable import LocalClipCore
struct ThrowAt: StorageFaultInjector {
    let point: FaultPoint
    /// 在生产提交断点注入 ENOSPC 等价错误。
    func check(_ point: FaultPoint) throws { if point == self.point { throw StoreError.diskFull } }
}
struct StorageFeasibilityTests {
    /// 真实候选读取权限失败覆盖预读分支；不通过抛出模拟错误代替系统失败，by AI.Coding。
    @Test func AC15_AC26_prefetchAccessFailureKeepsOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        try strategy.initialize { db in
            try db.exec("CREATE TABLE fixture(id INTEGER PRIMARY KEY,data BLOB); INSERT INTO fixture VALUES(1,zeroblob(41943040))")
        }
        let before = try Data(contentsOf: strategy.databaseURL)
        let bytes = try strategy.measuredBytes()
        let failing = try CommitStrategy(root: root, faults: DenyCandidateRead(staging: strategy.staging))
        var bodyCalled = false
        #expect(throws: StoreError.ioFailure) {
            try failing.commit(quota: 100 * MiB) { db in
                bodyCalled = true
                try db.exec("DELETE FROM fixture")
            }
        }
        #expect(!bodyCalled)
        #expect(try Data(contentsOf: strategy.databaseURL) == before)
        #expect(try strategy.measuredBytes() == bytes)
        #expect(try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM fixture") } == 1)
        #expect(try strategy.read { try $0.scalarText("PRAGMA integrity_check") } == "ok")
        print("AC15 prefetch actual EACCES; old bytes=\(bytes); original unchanged; candidate cleaned")
    }
    /// 共享载荷删除普通引用不删除收藏所需的 BLOB。
    @Test func AC25_sharedBlobAndJournalBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        try strategy.initialize { db in
            try db.exec("CREATE TABLE blobs(id INTEGER PRIMARY KEY,data BLOB); CREATE TABLE refs(id INTEGER PRIMARY KEY,favorite INTEGER,blobID INTEGER REFERENCES blobs(id)); INSERT INTO blobs VALUES(1,zeroblob(2097152)); INSERT INTO refs VALUES(1,1,1),(2,0,1)")
        }
        let before = try strategy.measuredBytes()
        try strategy.commit(quota: 4 * MiB) { db in
            try db.exec("DELETE FROM refs WHERE favorite=0; DELETE FROM blobs WHERE NOT EXISTS(SELECT 1 FROM refs WHERE blobID=blobs.id)")
        }
        #expect(try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM blobs") } == 1)
        #expect(try strategy.read { try $0.scalarInt("SELECT SUM(length(data)) FROM blobs") } == 2 * MiB)
        print("AC25 shared raw=2097152 physical before=\(before) after=\(try strategy.measuredBytes()) peak candidate+journal=\(strategy.peakTemporaryBytes)")
    }
    /// 合成库位于独立目录，拒绝不会触碰已提交内容。
    @Test func AC15_AC26_candidateFailureKeepsOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        try strategy.initialize { db in try db.exec("CREATE TABLE fixture(id INTEGER PRIMARY KEY, favorite INTEGER, data BLOB)") }
        try strategy.commit(quota: 10 * MiB) { db in try db.run("INSERT INTO fixture VALUES(1,1,?)", [.blob(Data(repeating: 7, count: 100_000))]) }
        let old = try Data(contentsOf: strategy.databaseURL)
        for point in [FaultPoint.candidateCreated, .candidateWritten, .candidateValidated, .beforeReplace] {
            let failing = try CommitStrategy(root: root, faults: ThrowAt(point: point))
            #expect(throws: StoreError.diskFull) {
                try failing.commit(quota: 10 * MiB) { db in
                    try db.exec("DELETE FROM fixture")
                    try db.run("INSERT INTO fixture VALUES(2,0,?)", [.blob(Data(repeating: 9, count: 200_000))])
                }
            }
            #expect(try Data(contentsOf: strategy.databaseURL) == old)
            #expect(try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM fixture WHERE id=1") } == 1)
        }
    }
    /// 实际大库对应 490MiB 不可释放 +5MiB 普通 +20MiB新增的不等式。
    @Test func AC17_real500MiBQuotaRefusesWithoutDeleting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        try strategy.initialize { db in
            try db.exec("CREATE TABLE fixture(id INTEGER PRIMARY KEY, favorite INTEGER, data BLOB)")
            try db.exec("INSERT INTO fixture VALUES(1,1,zeroblob(513802240)); INSERT INTO fixture VALUES(2,0,zeroblob(5242880))")
        }
        let before = try strategy.measuredBytes()
        #expect(before > 495 * MiB && before < 500 * MiB)
        #expect(throws: StoreError.quotaExceeded) {
            try strategy.commit(quota: 500 * MiB) { db in
                try db.exec("DELETE FROM fixture WHERE favorite=0")
                try db.exec("INSERT INTO fixture VALUES(3,0,zeroblob(20971520))")
            }
        }
        #expect(try strategy.measuredBytes() == before)
        #expect(try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM fixture") } == 2)
        print("AC17 actual old bytes=\(before); favorite raw=\(490 * MiB); new raw=\(20 * MiB); quota=\(500 * MiB)")
    }
    /// 成功提交后重开只得到完整新态，FULL autovacuum 实际缩小文件。
    @Test func AC25_replacementAndPhysicalReclaim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        try strategy.initialize { db in try db.exec("CREATE TABLE fixture(id INTEGER PRIMARY KEY, data BLOB); INSERT INTO fixture VALUES(1,zeroblob(2097152))") }
        let before = try strategy.measuredBytes()
        try strategy.commit(quota: MiB) { db in try db.exec("DELETE FROM fixture; INSERT INTO fixture VALUES(2,zeroblob(1024))") }
        #expect(try strategy.measuredBytes() < before)
        #expect(try strategy.read { try $0.scalarInt("SELECT id FROM fixture") } == 2)
        #expect(try strategy.read { try $0.scalarText("PRAGMA integrity_check") } == "ok")
    }
}

private struct DenyCandidateRead: StorageFaultInjector {
    let staging: URL
    /// 只撤销专用临时候选的读权限；实际失败由生产预读 open 返回，by AI.Coding。
    func check(_ point: FaultPoint) throws {
        guard point == .candidateCreated else { return }
        guard let files = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil),
              let candidate = (files.allObjects as? [URL])?.first(where: { $0.lastPathComponent == "candidate.sqlite" }) else { throw StoreError.invalidSettings }
        guard (try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) >= 32 * MiB else { throw StoreError.invalidSettings }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: candidate.path)
        let descriptor = Darwin.open(candidate.path, O_RDONLY)
        let actualError = errno
        if descriptor >= 0 { Darwin.close(descriptor) }
        guard descriptor < 0 && actualError == EACCES else { throw StoreError.invalidSettings }
    }
}
