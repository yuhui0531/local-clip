// schema 安全边界与持久化约束，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct SchemaTests {
    /// 高版本先只读拒绝，文件哈希保持。
    @Test func E08_highVersionRefusesWithoutMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        try strategy.initialize { try $0.exec("PRAGMA user_version=99; CREATE TABLE future(value TEXT)") }
        let bytes = try Data(contentsOf: strategy.databaseURL)
        #expect(throws: StoreError.incompatibleSchema) { _ = try HistoryStore(location: root) }
        #expect(try Data(contentsOf: strategy.databaseURL) == bytes)
    }
    /// 非 SQLite 文件应报告损坏，并保留全部原始字节，by AI.Coding。
    @Test func unreadableDatabaseHeaderIsReportedAsCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let strategy = try CommitStrategy(root: root)
        let bytes = Data(repeating: 0x58, count: 4096)
        try bytes.write(to: strategy.databaseURL)
        #expect(throws: StoreError.corruptPayload) { _ = try HistoryStore(location: root) }
        #expect(try Data(contentsOf: strategy.databaseURL) == bytes)
    }

    /// 首次恢复失败也会消耗打开时的校验结果，by AI.Coding。
    @Test func failedFirstRecoveryDoesNotSkipValidationOnRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.exec("PRAGMA user_version=99")
        await #expect(throws: StoreError.corruptPayload) { try await store.recover() }
        try db.exec("PRAGMA user_version=6; PRAGMA foreign_keys=OFF; INSERT INTO items VALUES('missing',0,'[]')")
        await #expect(throws: StoreError.corruptPayload) { try await store.recover() }
        await #expect(throws: StoreError.postCommitUnavailable) { try await store.search(.init()) }
        try db.exec("DELETE FROM items")
        _ = try await store.recover()
        #expect(try await store.search(.init()).items.isEmpty)
    }

    @Test func firstRecoveryRevalidatesDatabaseChangedSinceOpening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try HistoryStore(location: root)
        let store = try HistoryStore(location: root)
        let events = await store.events()
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.exec("PRAGMA foreign_keys=OFF; INSERT INTO items VALUES('missing',0,'[]')")
        try db.close()
        await #expect(throws: StoreError.corruptPayload) { try await store.recover() }
        let unavailable = await store.unavailable
        try #require(unavailable)
        let notified = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                if case .unavailable(.corruptPayload)? = await iterator.next() { return true }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(notified)
        await #expect(throws: StoreError.postCommitUnavailable) { try await store.search(.init()) }
    }

    /// 初次 schema 故障不能把半份库发布。
    @Test func AC15_schemaFailurePreservesNoPublishedDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: StoreError.diskFull) { _ = try HistoryStore(location: root, faults: ThrowAt(point: .candidateWritten)) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("History/history.sqlite").path))
    }
    /// 外键和内容长度约束不可绕过。
    @Test func schemaConstraints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try HistoryStore(location: root)
        let strategy = try CommitStrategy(root: root)
        #expect(throws: StoreError.ioFailure) { try strategy.read { try $0.exec("INSERT INTO items VALUES('missing',0,'[]')") } }
        #expect(throws: StoreError.ioFailure) { try strategy.read { try $0.exec("INSERT INTO blobs VALUES('bad',10,zeroblob(2))") } }
    }
}
