// 只读取GitHub公开的最新Release版本号，不发送任何剪贴板内容；不自动下载或安装，by AI.Coding。
import AppKit
import LocalClipCore

@MainActor public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()
    public struct Release: Equatable { public let version: String; public let page: URL }
    @Published public private(set) var available: Release?
    @Published public private(set) var checking = false
    /// 仅手动检查时给出结果；自动检查失败保持静默。
    @Published public private(set) var manualResult: String?
    /// 发现或失去新版本时刷新菜单栏菜单。
    public var onChange: (() -> Void)?
    private static let api = URL(string: "https://api.github.com/repos/yuhui0531/local-clip/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"
    public static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    /// 测试注入私有偏好与传输，生产仍使用系统会话，避免测试访问网络或用户设置，by AI.Coding。
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults; self.now = now; self.fetch = fetch
    }

    private var isDue: Bool {
        defaults.object(forKey: Self.lastCheckKey) == nil || now().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) > 86_400
    }

    /// 自动检查每天最多一次；关闭开关后不联网。
    public func checkIfDue(enabled: Bool) {
        guard enabled, !checking, isDue else { return }
        Task {
            // 同一轮多个入口排队时，第二个任务不能重复发起已经完成的检查。
            guard isDue else { return }
            await check(manual: false)
        }
    }

    public func check(manual: Bool) async {
        guard !checking else { return }
        checking = true; manualResult = nil
        // 按尝试而非成功限频；离线或服务错误不能让每分钟维护都重试，手动检查仍可立即重试。
        defaults.set(now().timeIntervalSince1970, forKey: Self.lastCheckKey)
        defer { checking = false }
        var request = URLRequest(url: Self.api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetch(request)
            // 只信任GitHub自身的发布页链接，响应中的其他地址一律不打开。
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
                  page.scheme == "https", page.host == "github.com" else { throw URLError(.badServerResponse) }
            available = AppVersion.isNewer(tag, than: Self.currentVersion) ? Release(version: AppVersion.marketing(tag), page: page) : nil
            if manual && available == nil { manualResult = "已是最新版本" }
        } catch {
            if manual { manualResult = "检查失败，请稍后重试" }
        }
        onChange?()
    }
}
