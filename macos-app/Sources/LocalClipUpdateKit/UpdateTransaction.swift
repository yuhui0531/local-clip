// 同卷原子交换应用与数据快照；每个失败分支都保留恢复材料，by AI.Coding。
import Foundation
import Darwin

public final class UpdateTransaction {
    public let target: URL
    public let candidate: URL
    public let dataDirectory: URL?
    public let dataBackup: URL
    private let backupDirectory: URL
    private var prepared = false
    private var replaced = false
    private var hadData = false

    /// 候选应用必须与安装目录同卷；真实辅助进程使用安装目录旁的私有工作目录。
    public init(target: URL, candidate: URL, dataDirectory: URL?, backupDirectory: URL) throws {
        self.target = target; self.candidate = candidate; self.dataDirectory = dataDirectory
        self.backupDirectory = backupDirectory; dataBackup = backupDirectory.appendingPathComponent("data")
        guard target.standardizedFileURL != candidate.standardizedFileURL else { throw UpdateFailure.invalid("更新目录无效") }
    }

    /// 旧进程退出后创建一致快照；任何复制或磁盘空间错误均发生在替换应用之前。
    public func prepare() throws {
        let fm = FileManager.default
        guard !prepared, !fm.fileExists(atPath: backupDirectory.path) else { throw UpdateFailure.invalid("备份目录已存在") }
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let dataDirectory, fm.fileExists(atPath: dataDirectory.path) {
            // 数据符号链接不能形成指向原文件的“假快照”；拒绝此布局并保留旧应用。
            var paths = [dataDirectory]
            if let entries = fm.enumerator(at: dataDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                paths.append(contentsOf: entries.compactMap { $0 as? URL })
            }
            guard try paths.allSatisfy({ try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false }) else { throw UpdateFailure.invalid("历史目录包含符号链接，未执行更新") }
            try fm.copyItem(at: dataDirectory, to: dataBackup)
            hadData = true
        }
        prepared = true
    }

    /// RENAME_SWAP 不暴露“旧程序已删、新程序未到位”的中间状态；旧程序保留在 candidate。
    public func replaceApp() throws {
        guard prepared, !replaced else { throw UpdateFailure.invalid("更新准备未完成") }
        try Self.exchange(target, candidate)
        replaced = true
    }

    /// 仅在新进程确认停止后调用；交换而非删除，让新旧数据均可恢复。
    public func rollback() throws {
        guard replaced else { return }
        if let dataDirectory {
            let fm = FileManager.default
            if hadData {
                if fm.fileExists(atPath: dataDirectory.path) { try Self.exchange(dataDirectory, dataBackup) }
                else { try fm.moveItem(at: dataBackup, to: dataDirectory) }
            } else if fm.fileExists(atPath: dataDirectory.path) {
                try fm.moveItem(at: dataDirectory, to: dataBackup)
            }
        }
        try Self.exchange(target, candidate)
        replaced = false
    }

    /// 不支持原子交换或跨卷时直接失败，不退化成先删除再复制。
    private static func exchange(_ left: URL, _ right: URL) throws {
        let result = left.path.withCString { a in right.path.withCString { b in renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP)) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
