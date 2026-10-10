// 串行存储上下文内的 SQLite RAII 包装，by AI.Coding。
import Foundation
import CSQLite
enum SQLValue { case text(String), integer(Int64), blob(Data), null }
final class SQLiteConnection {
    private var handle: OpaquePointer?
    let url: URL
    /// 打开后先只读检查版本，避免旧程序修改高版本库。
    init(_ url: URL, readonly: Bool = false) throws {
        self.url = url
        let flags = readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil; throw StoreError.ioFailure
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { if let handle { sqlite3_close(handle) } }
    /// 关闭所有语句后方可原子替换。
    func close() throws {
        if let handle { guard sqlite3_close(handle) == SQLITE_OK else { throw StoreError.ioFailure }; self.handle = nil }
    }
    /// 查询不输出 SQL 或正文，错误仅用类别表示。
    private func check(_ result: Int32) throws {
        if result == SQLITE_FULL { throw StoreError.diskFull }
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else { throw StoreError.ioFailure }
    }
    /// 固定 SQL 的批量执行，用户输入只能通过绑定参数。
    func exec(_ sql: String) throws { try check(sqlite3_exec(handle, sql, nil, nil, nil)) }
    /// 语句生命周期完全限制在闭包内，不暴露给 UI。
    private func statement<T>(_ sql: String, _ values: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil))
        guard let stmt else { throw StoreError.ioFailure }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): try check(text.withCString { sqlite3_bind_text(stmt, index, $0, Int32(text.utf8.count), transient) })
            case .integer(let number): try check(sqlite3_bind_int64(stmt, index, number))
            case .blob(let data):
                if data.isEmpty { try check(sqlite3_bind_zeroblob(stmt, index, 0)) }
                else { try check(data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }) }
            case .null: try check(sqlite3_bind_null(stmt, index))
            }
        }
        return try body(stmt)
    }
    /// 所有动态载荷参数绑定，不拼接正文。
    func run(_ sql: String, _ values: [SQLValue] = []) throws { try statement(sql, values) { try check(sqlite3_step($0)) } }
    /// 读取轻量行；调用方选择是否包含 BLOB。
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try statement(sql, values) { stmt in
            var rows: [[String: SQLValue]] = []
            while true {
                let code = sqlite3_step(stmt); try check(code)
                if code == SQLITE_DONE { break }
                var row: [String: SQLValue] = [:]
                for column in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, column))
                    switch sqlite3_column_type(stmt, column) {
                    case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, column))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(stmt, column))
                        row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, column)!, count: count))
                    case SQLITE_TEXT:
                        let count = Int(sqlite3_column_bytes(stmt, column))
                        row[name] = .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(stmt, column), count: count), as: UTF8.self))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }
    /// 标量结果用于 schema 与 pragma 验证。
    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 { try rows(sql, values).first?.values.first?.int ?? 0 }
    /// 标量文本用于完整性检查。
    func scalarText(_ sql: String, _ values: [SQLValue] = []) throws -> String { try rows(sql, values).first?.values.first?.text ?? "" }
    /// 配置必须读回验证，不假设未知 pragma 会报错。
    func configure() throws {
        try exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE; PRAGMA mmap_size=201326592")
        guard try scalarInt("PRAGMA foreign_keys") == 1, try scalarInt("PRAGMA synchronous") == 2,
              try scalarText("PRAGMA journal_mode") == "delete" else { throw StoreError.ioFailure }
    }
    /// 在线备份产生一致快照，禁止拷贝正在写入的原始文件。
    func backup(to other: SQLiteConnection) throws {
        guard let backup = sqlite3_backup_init(other.handle, "main", handle, "main") else { throw StoreError.ioFailure }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        try check(result); try check(finished)
    }
}
extension SQLValue {
    var text: String { if case .text(let v) = self { return v }; return "" }
    var int: Int64 { if case .integer(let v) = self { return v }; return 0 }
    var data: Data { if case .blob(let v) = self { return v }; return Data() }
}
extension Dictionary where Key == String, Value == SQLValue {
    func text(_ key: String) -> String { self[key]?.text ?? "" }
    func int(_ key: String) -> Int64 { self[key]?.int ?? 0 }
    func data(_ key: String) -> Data { self[key]?.data ?? Data() }
}
