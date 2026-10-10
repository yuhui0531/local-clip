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
