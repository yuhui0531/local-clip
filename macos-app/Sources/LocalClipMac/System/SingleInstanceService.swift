// 新实例接替旧实例；历史数据库/采集/快捷键仅在获得进程锁后启动，by AI.Coding。
import AppKit
import CryptoKit
import Darwin

@MainActor public final class SingleInstanceService {
    public enum StartupError: Error {
        case superseded, identityUnavailable, lockUnavailable, previousInstanceBusy
        public var message: String {
            switch self {
            case .superseded: "已有更新的LocalClip实例正在启动"
            case .identityUnavailable: "无法确认当前启动身份，未启用新实例"
            case .lockUnavailable: "无法获得LocalClip实例锁，未启用采集或存储"
            case .previousInstanceBusy: "旧LocalClip尚未退出，新实例未启用。请退出旧实例后重新打开。"
            }
        }
    }
    private var descriptor: Int32 = -1

    public init() {}

    /// 所有GUI包副本按同一bundle ID接替；Debug命令行探针不进入此流程。
    public func takeOver() async throws {
        let current = NSRunningApplication.current
        guard let launchedAt = current.launchDate else { throw StartupError.identityUnavailable }
        let identifier = Bundle.main.bundleIdentifier ?? "local.localclip.dev"
        let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("localclip-\(getuid())-\(digest).lock")
        descriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw StartupError.lockUnavailable }
        // 不删除锁文件；同一inode上的POSIX记录锁在进程退出时释放，不能在退出回调中过早解锁。
        let deadline = ContinuousClock.now + .seconds(6)
        var requested: [pid_t: NSRunningApplication] = [:]
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let peers = NSWorkspace.shared.runningApplications.filter {
                    $0.processIdentifier != current.processIdentifier && $0.bundleIdentifier == identifier && !$0.isTerminated
                }
                // 并发启动时较晚启动者胜出；相同时间用PID确定顺序，避免相互请求退出。
                if peers.contains(where: { peer in
                    guard let date = peer.launchDate else { return false }
                    return date > launchedAt || (date == launchedAt && peer.processIdentifier > current.processIdentifier)
                }) { throw StartupError.superseded }
                for peer in peers {
                    guard let date = peer.launchDate,
                          date < launchedAt || (date == launchedAt && peer.processIdentifier < current.processIdentifier),
                          requested[peer.processIdentifier] == nil else { continue }
                    requested[peer.processIdentifier] = peer
                    _ = peer.terminate()
                }
                // 不把terminate()返回或从列表消失当作退出完成，仍等已请求的进程真正终止。
                if peers.isEmpty && requested.values.allSatisfy({ $0.isTerminated }) {
                    var lock = flock()
                    lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
                    lock.l_start = 0; lock.l_len = 0
                    if fcntl(descriptor, F_SETLK, &lock) == 0 { return }
                    guard errno == EACCES || errno == EAGAIN else { throw StartupError.lockUnavailable }
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw StartupError.previousInstanceBusy
        } catch {
            Darwin.close(descriptor); descriptor = -1
            throw error
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
