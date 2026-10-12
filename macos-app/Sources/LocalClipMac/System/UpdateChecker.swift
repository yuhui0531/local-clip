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

    /// 自动检查每天最多一次；关闭开关后不联网。
    public func checkIfDue(enabled: Bool) {
        guard enabled, !checking,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Self.lastCheckKey) > 86_400 else { return }
        Task { await check(manual: false) }
    }

    public func check(manual: Bool) async {
        guard !checking else { return }
        checking = true; manualResult = nil
        defer { checking = false }
        var request = URLRequest(url: Self.api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // 只信任GitHub自身的发布页链接，响应中的其他地址一律不打开。
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
                  page.scheme == "https", page.host == "github.com" else { throw URLError(.badServerResponse) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            available = AppVersion.isNewer(tag, than: Self.currentVersion) ? Release(version: AppVersion.marketing(tag), page: page) : nil
            if manual && available == nil { manualResult = "已是最新版本" }
        } catch {
            if manual { manualResult = "检查失败，请稍后重试" }
        }
        onChange?()
    }
}
