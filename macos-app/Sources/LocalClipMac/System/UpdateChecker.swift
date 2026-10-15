// 自动检查并下载已验签更新；仅用户点击后启动独立安装器，by AI.Coding。
import AppKit
import LocalClipCore
import LocalClipUpdateKit

@MainActor public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker(locations: try? UpdateLocations.current())
    public struct Release: Equatable { public let version: String; public let page: URL }
    @Published public private(set) var available: Release?
    @Published public private(set) var checking = false
    /// 仅手动检查时给出结果；自动检查失败保持静默。
    @Published public private(set) var manualResult: String?
    public enum Phase: Equatable { case idle, downloading, ready, installing, failed(String), manualOnly }
    @Published public private(set) var phase: Phase = .idle
    /// 发现或失去新版本时刷新菜单栏菜单。
    public var onChange: (() -> Void)?
    private static let api = URL(string: "https://api.github.com/repos/yuhui0531/local-clip/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"
    private static let readyKey = "downloadedUpdateDirectory"
    private static let seenResultKey = "lastSeenUpdateResult"
    public static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private let prepareUpdate: (UpdateAssets, String) async throws -> DownloadedUpdate
    private let installUpdate: (DownloadedUpdate) async throws -> Void
    private var downloadTask: Task<DownloadedUpdate, Error>?
    private var staged: DownloadedUpdate?
    private var backgroundDownload = false
    private var automaticEnabled = true
    /// nil 时不读写更新会话（测试默认），生产与隔离验收显式提供。
    private let locations: UpdateLocations?
    private var resultKey: String?
    private var resultPresentation: String?
    private let cleanup: @Sendable (UpdateLocations, Set<String>) async -> Void
    private var maintenanceTask: Task<Void, Never>?

    /// 测试注入私有偏好与传输，生产仍使用系统会话，避免测试访问网络或用户设置，by AI.Coding。
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         prepare: @escaping (UpdateAssets, String) async throws -> DownloadedUpdate = { try await UpdateDownloadService.prepare($0, version: $1) },
         restore: @escaping (URL) async throws -> DownloadedUpdate = { try await UpdateDownloadService.restore(directory: $0) },
         install: @escaping (DownloadedUpdate) async throws -> Void = { try await UpdateInstaller.begin($0) },
         locations: UpdateLocations? = nil,
         cleanup: @escaping @Sendable (UpdateLocations, Set<String>) async -> Void = { locations, excluded in
             _ = await Task.detached(priority: .utility) { UpdateJanitor.run(locations, excludedDownloads: excluded) }.value
         }) {
        self.defaults = defaults; self.now = now; self.fetch = fetch
        self.prepareUpdate = prepare; self.installUpdate = install; self.locations = locations
        self.cleanup = cleanup
        refreshResult()
        if let path = defaults.string(forKey: Self.readyKey) {
            checking = true
            Task {
                defer { checking = false; onChange?() }
                do {
                    let update = try await restore(URL(fileURLWithPath: path))
                    staged = update; phase = .ready
                    available = Release(version: update.manifest.version, page: URL(string: "https://github.com/yuhui0531/local-clip/releases")!)
                } catch {
                    defaults.removeObject(forKey: Self.readyKey)
                    defaults.removeObject(forKey: Self.lastCheckKey)
                }
            }
        }
    }

    private var isDue: Bool {
        defaults.object(forKey: Self.lastCheckKey) == nil || now().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) > 86_400
    }

    /// 自动检查每天最多一次；关闭开关后不联网。
    public func checkIfDue(enabled: Bool) {
        automaticEnabled = enabled
        guard enabled, !checking, staged == nil, phase != .installing, isDue else { return }
        Task {
            // 同一轮多个入口排队时，第二个任务不能重复发起已经完成的检查。
            guard automaticEnabled, isDue else { return }
            await check(manual: false)
        }
    }

    /// found在确认有签名更新包、开始下载前回调，让手动入口不必等下载完成即可告知用户。
    public func check(manual: Bool, found: ((Release) -> Void)? = nil) async {
        guard !checking, staged == nil, phase != .installing else { return }
        // 等待期间也占用 checking，阻止上一轮维护完成后又启动下一轮维护。
        checking = true
        defer { checking = false; onChange?() }
        // 等待维护结束再开始版本请求；保留手动请求，避免新下载被误当作中断下载回收。
        if let maintenanceTask { await maintenanceTask.value }
        manualResult = nil
        // 按尝试而非成功限频；离线或服务错误不能让每分钟维护都重试，手动检查仍可立即重试。
        defaults.set(now().timeIntervalSince1970, forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetch(request)
            // 只信任GitHub自身的发布页链接，响应中的其他地址一律不打开。
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
                  page.scheme == "https", page.host == "github.com", page.user == nil, page.password == nil,
                  page.path.hasPrefix("/yuhui0531/local-clip/releases/") else { throw URLError(.badServerResponse) }
            available = AppVersion.isNewer(tag, than: Self.currentVersion) ? Release(version: AppVersion.marketing(tag), page: page) : nil
            phase = .idle
            if let release = available {
                // 用户可能在版本请求尚未返回时关闭开关，此时也不能开始下载。
                guard manual || automaticEnabled else { return }
                guard let assets = UpdateDownloadService.assets(from: json, tag: tag, version: release.version) else {
                    phase = .manualOnly
                    return
                }
                phase = .downloading; backgroundDownload = !manual; onChange?()
                found?(release)
                let task = Task { try await prepareUpdate(assets, release.version) }
                downloadTask = task
                do {
                    let result = try await task.value
                    if task.isCancelled {
                        try? FileManager.default.removeItem(at: result.directory)
                        phase = .idle
                    } else {
                        staged = result; phase = .ready
                        defaults.set(result.directory.path, forKey: Self.readyKey)
                    }
                } catch {
                    phase = task.isCancelled ? .idle : .failed("下载失败：\(error.localizedDescription)；原版本未改变")
                }
                downloadTask = nil; backgroundDownload = false
            } else if manual { manualResult = "已是最新版本" }
        } catch {
            if manual { manualResult = "检查失败，请稍后重试" }
        }
    }

    /// 关闭自动检查时取消后台下载；已经下载的包仍需点击才安装。
    public func automaticUpdatesChanged(enabled: Bool) {
        automaticEnabled = enabled
        if !enabled && backgroundDownload { downloadTask?.cancel() }
        if enabled { checkIfDue(enabled: true) }
    }

    /// 唯一安装入口；下载完成、普通退出或重复点击均不能绕过此状态门控。
    public func installAndRestart() async {
        guard phase == .ready, let staged else { return }
        defaults.removeObject(forKey: Self.readyKey)
        phase = .installing; onChange?()
        do { try await installUpdate(staged) }
        catch is UpdateQuitCancelled {
            // 已确认辅助程序退出且未替换：复用同一已验签包，不重新下载。
            phase = .ready; defaults.set(staged.directory.path, forKey: Self.readyKey)
            await maintain()
        }
        catch { phase = .failed("安装失败：\(error.localizedDescription)；旧版本与恢复材料已保留"); self.staged = nil }
        onChange?()
    }

    /// F-06：结果来自持久会话记录（或旧版下载目录），辅助程序晚于启动写入时由刷新补上；未出结论不显示。
    public func refreshResult() {
        var best = locations.flatMap(UpdateSessionStore.latestResult)
        if let path = defaults.string(forKey: UpdateInstaller.lastAttemptKey),
           let message = try? String(contentsOfFile: path + "/result.txt", encoding: .utf8) {
            let at = (try? URL(fileURLWithPath: path + "/result.txt").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            // 新辅助程序先写兼容文件再写记录；只有明显更新的旧格式结果才覆盖记录。
            if best.map({ at > $0.at.addingTimeInterval(2) }) ?? true { best = ("legacy:" + path, message, at) }
        }
        guard let best else { return }
        let key = best.id + "@" + String(Int(best.at.timeIntervalSince1970))
        // LC-F05：成功后旧应用工作区已清理，只承诺数据快照；保留清理异常和快照路径，失败/回滚结果原样展示。
        let text = best.message.hasPrefix("更新成功")
            ? "更新已完成；本次更新前的数据快照已保留" + best.message.dropFirst("更新成功".count)
            : best.message
        // 已看过的结果仍可查看，但以“上次更新”呈现，不再当作新结果。
        let presentation = defaults.string(forKey: Self.seenResultKey) == key ? "上次更新：" + text : text
        // 同一终态可能晚到清理告警，已读状态也会变化，不能仅按会话时间戳去重。
        guard key != resultKey || presentation != resultPresentation else { return }
        resultKey = key; resultPresentation = presentation
        manualResult = presentation
        onChange?()
    }

    /// 设置页展示后标记为已读；不删除结果。
    public func markResultSeen() {
        // 手动检查的状态也使用同一文本位置，不能把它当成旧会话结果并覆盖。
        if let resultKey, manualResult == resultPresentation {
            defaults.set(resultKey, forKey: Self.seenResultKey); refreshResult()
        }
    }

    /// 新版本回执后调用：立即补偿一次，并在辅助程序收尾期间有限次刷新结果，不忙轮询。
    public func startupFinished() {
        Task {
            await maintain()
            for delay in [1, 3, 10, 30] {
                try? await Task.sleep(for: .seconds(delay))
                refreshResult()
            }
            await maintain()
        }
    }

    /// F-01/F-02：非阻塞补偿清理；下载/安装期间不运行，就绪包与当前包始终排除；活跃会话由会话锁跳过。
    public func maintain() async {
        guard let locations, maintenanceTask == nil, !checking, phase != .downloading, phase != .installing, downloadTask == nil else { return }
        let excluded = Set([defaults.string(forKey: Self.readyKey), staged?.directory.path].compactMap { $0 })
        let task = Task { await cleanup(locations, excluded) }
        maintenanceTask = task
        await task.value
        maintenanceTask = nil
        refreshResult()
    }
}
