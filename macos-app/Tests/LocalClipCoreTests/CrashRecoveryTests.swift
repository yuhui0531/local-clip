// 子进程断点必须使用 SIGKILL 再重开真实库，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct CrashRecoveryTests {
    /// 完整生产schema的六个真实进程终止断点，校验收藏、淘汰、BLOB与物理配额。
    @Test func AC02_AC25_AC26_productionHistoryTermination() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for point in FaultPoint.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let child = Process(); child.executableURL = ProcessInfo.processInfo.environment["LOCALCLIP_PROBE_BINARY"].map { URL(fileURLWithPath:$0) } ?? package.appendingPathComponent(".build/debug/LocalClip")
            child.arguments = ["--history-probe",root.path,point.rawValue]; try child.run(); child.waitUntilExit()
            #expect(child.terminationReason == .uncaughtSignal); #expect(child.terminationStatus == 9)
            let store = try HistoryStore(location: root); _ = try await store.recover()
            let committed = [FaultPoint.afterReplace,.reopen].contains(point)
            var contents: Set<UInt8> = []
            let page = try await store.search(.init()); #expect(page.items.count == 2)
            for item in page.items {
                let payload = try await store.loadPayload(id: item.id, at: SystemClock().now())
                let byte = payload.items[0].representations[0].data.first!; contents.insert(byte)
                #expect(item.isFavorite == (byte == 1))
            }
            #expect(contents == (committed ? Set([1,3]) : Set([1,2])))
            let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"),readonly:true)
            #expect(try db.scalarText("PRAGMA integrity_check") == "ok"); #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
            #expect(try db.scalarInt("SELECT COUNT(*) FROM blobs WHERE NOT EXISTS(SELECT 1 FROM representations WHERE blobDigest=blobs.digest)") == 0); try db.close()
            if !committed { #expect(ContentFingerprint.hash(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))) == String(decoding: try Data(contentsOf: root.appendingPathComponent("before.sha256")),as:UTF8.self)) }
            #expect(try await store.usage().measuredTotal <= 400_000)
            print("AC26 production SIGKILL \(point.rawValue) => bytes \(contents.sorted()) integrity/FK/hash/quota ok")
        }
    }
    /// T03/T17：每个断点只能出现完整旧态或提交后的完整新态。
    @Test func AC26_realProcessTermination() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["LOCALCLIP_PROBE_BINARY"].map { URL(fileURLWithPath:$0) } ?? package.appendingPathComponent(".build/debug/LocalClip")
        for point in FaultPoint.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let child = Process(); child.executableURL = binary
            child.arguments = ["--storage-probe", root.path, point.rawValue]
            try child.run(); child.waitUntilExit()
            #expect(child.terminationReason == .uncaughtSignal)
            #expect(child.terminationStatus == 9)
            let store = try CommitStrategy(root: root)
            let expected: Int64 = [FaultPoint.afterReplace, .reopen].contains(point) ? 2 : 1
            #expect(try store.read { try $0.scalarInt("SELECT id FROM fixture") } == expected)
            #expect(try store.read { try $0.scalarText("PRAGMA integrity_check") } == "ok")
            let pending = try store.recover(); #expect(pending == 0)
            print("AC26 SIGKILL \(point.rawValue) => complete id \(expected)")
        }
    }
}
