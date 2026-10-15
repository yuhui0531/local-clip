// 与 GUI 的 SingleInstanceService 使用同一 POSIX 锁，快照/恢复期间禁止并发写库，by AI.Coding。
import Foundation
import CryptoKit
import Darwin

public final class UpdateStoreLock {
    private let identity: String
    private let directory: URL
    private var descriptor: Int32 = -1
    /// T-02：生产与 GUI 共用系统临时目录中的固定锁；测试传入隔离根，随根目录一并回收。
    public init(identity: String = UpdatePackage.bundleIdentifier, directory: URL = FileManager.default.temporaryDirectory) { self.identity = identity; self.directory = directory }
    /// 仅在旧进程退出或新进程停止后调用；其他实例持锁时拒绝修改应用和数据。
    public func acquire() throws {
        guard descriptor < 0 else { return }
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("localclip-\(getuid())-\(digest).lock")
        let fd = url.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw UpdateFailure.invalid("无法获取更新存储锁") }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET); lock.l_start = 0; lock.l_len = 0
        guard fcntl(fd, F_SETLK, &lock) == 0 else { Darwin.close(fd); throw UpdateFailure.invalid("另一个 LocalClip 实例仍在使用历史数据，更新已停止") }
        descriptor = fd
    }
    /// 启动 GUI 前释放锁，由 GUI 自己接管；锁文件 inode 永不删除。
    public func release() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
