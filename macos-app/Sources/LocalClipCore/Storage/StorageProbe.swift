// 仅 Debug 可用的合成子进程崩溃探针，by AI.Coding。
#if DEBUG
import Foundation
import Darwin
public enum StorageProbe {
    private struct KillAt: StorageFaultInjector {
        let point: FaultPoint
        /// 真正 SIGKILL 验证磁盘恢复，不用抛错冒充崩溃。
        func check(_ point: FaultPoint) throws {
            if point == self.point {
                guard kill(getpid(), SIGKILL) == 0 else { throw StoreError.ioFailure }
                // 多线程进程的信号投递可能晚于kill返回，停在断点，绝不继续到rename。
                while true { Darwin.pause() }
            }
        }
    }
    /// 独立数据目录与固定 fixture，不能进入正式 UI 或 Release。
    public static func run(root: URL, point: String) throws {
        let setup = try CommitStrategy(root: root)
        try setup.initialize { db in try db.exec("CREATE TABLE fixture(id INTEGER PRIMARY KEY, data BLOB); INSERT INTO fixture VALUES(1,randomblob(4194304))") }
        guard let point = FaultPoint(rawValue: point) else { throw StoreError.invalidSettings }
        let crashing = try CommitStrategy(root: root, faults: KillAt(point: point))
        // 大事务配合小页缓存强制脏页溢写进原库，提交前被杀必须真正依赖热日志回滚，by AI.Coding。
        try crashing.commit(quota: 64 * MiB) { db in try db.exec("PRAGMA mmap_size=0; PRAGMA cache_size=16; PRAGMA cache_spill=16; DELETE FROM fixture; INSERT INTO fixture VALUES(2,randomblob(16777216))") }
    }
    /// 生产历史模型包含收藏、普通条目、共享引用及需要淘汰的新内容。
    public static func runHistory(root: URL, point: String) async throws {
        var settings = SettingsSnapshot(); settings.quotaBytes = MiB
        let store = try HistoryStore(location: root, initialSettings: settings)
        let now = SystemClock().now()
        func input(_ byte: UInt8, _ count: Int) -> ClipboardSnapshot { .init(payload: .init([.init([.init(SupportedType.png, Data(repeating: byte, count: count))])])) }
        guard case .inserted(let favorite) = try await store.ingest(input(1,180_000), at: now) else { throw StoreError.ioFailure }
        let preview = try await store.preview(.favorite(favorite,true)); _ = try await store.apply(preview.token)
        _ = try await store.ingest(input(2,70_000), at: now + 1)
        // 根据当前schema的真实磁盘占用限定fixture，不沿用旧schema的固定页开销，by AI.Coding。
        settings = try await store.settings(); settings.quotaBytes = try await store.usage().measuredTotal + 64 * 1024
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try db.configure(); try Schema.writeSettings(db, settings); try db.close()
        let bytes = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        try Data(ContentFingerprint.hash(bytes).utf8).write(to: root.appendingPathComponent("before.sha256"))
        guard let point = FaultPoint(rawValue: point) else { throw StoreError.invalidSettings }
        let failing = try HistoryStore(location: root, faults: KillAt(point: point))
        _ = try await failing.ingest(input(3,110_000), at: now + 2)
    }
}
#endif
