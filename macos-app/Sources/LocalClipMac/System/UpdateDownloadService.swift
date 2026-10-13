// 下载只进入私有缓存；关闭应用不会自动安装，by AI.Coding。
import Foundation
import LocalClipUpdateKit

struct UpdateAssets: Equatable, Sendable {
    let manifest: URL
    let signature: URL
    let archive: URL
}

struct DownloadedUpdate: Sendable {
    let directory: URL
    let manifest: UpdateManifest
}

enum UpdateDownloadService {
    /// 重启后重新验签及校验归档；缓存被清理或替换时不恢复可安装状态。
    static func restore(directory: URL) async throws -> DownloadedUpdate {
        let bundle = Bundle.main.bundleURL
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.localclip.dev/Updates").resolvingSymlinksInPath().path + "/"
        guard directory.resolvingSymlinksInPath().path.hasPrefix(cache) else { throw UpdateFailure.invalid("更新缓存目录无效") }
        return try await Task.detached {
            let manifest = try UpdatePackage.authenticate(directory: directory, installedApp: bundle, currentBuild: currentBuild)
            return DownloadedUpdate(directory: directory, manifest: manifest)
        }.value
    }

    /// 固定仓库路径，拒绝 API 返回的外站或其他仓库资产。
    static func assets(from json: [String: Any], tag: String, version: String) -> UpdateAssets? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        let prefix = "/yuhui0531/local-clip/releases/download/\(tag)/"
        func asset(_ name: String) -> URL? {
            let matches = assets.filter { $0["name"] as? String == name }
            guard matches.count == 1, let raw = matches[0]["browser_download_url"] as? String, let url = URL(string: raw),
                  url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
                  url.port == nil, url.path == prefix + name, url.query == nil, url.fragment == nil else { return nil }
            return url
        }
        guard let manifest = asset("update.json"), let signature = asset("update.sig"), let archive = asset("LocalClip-v\(version).zip") else { return nil }
        return UpdateAssets(manifest: manifest, signature: signature, archive: archive)
    }

    /// 先验证小型清单，再下载有尺寸上限的 ZIP；失败只清理本次缓存。
    static func prepare(_ assets: UpdateAssets, version: String, bundle: URL = Bundle.main.bundleURL) async throws -> DownloadedUpdate {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.localclip.dev/Updates/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let manifestURL = try await download(assets.manifest, into: root.appendingPathComponent("update.json"), limit: 65_536)
            let signatureURL = try await download(assets.signature, into: root.appendingPathComponent("update.sig"), limit: 64)
            let info = try UpdatePackage.readInfo(bundle)
            guard let keyText = info[UpdatePackage.publicKeyProperty] as? String, let key = Data(base64Encoded: keyText) else { throw UpdateFailure.invalid("此应用尚未配置更新签名公钥") }
            let manifest = try UpdateManifest.authenticate(Data(contentsOf: manifestURL), signature: Data(contentsOf: signatureURL), publicKey: key)
            guard manifest.version == version, assets.archive.lastPathComponent == manifest.archive else { throw UpdateFailure.invalid("发布版本与签名清单不符") }
            try manifest.checkCompatibility(currentBuild: (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0)
            let archive = try await download(assets.archive, into: root.appendingPathComponent(manifest.archive), limit: manifest.size)
            try Task.checkCancellation()
            try manifest.verifyArchive(at: archive)
            return DownloadedUpdate(directory: root, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// 会话不携带 Cookie，重定向限定为 GitHub HTTPS 资产域名，超限立即取消。
    private static func download(_ url: URL, into destination: URL, limit: Int) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let guardrail = DownloadGuard(limit: Int64(limit))
        let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: guardrail)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = response.url, DownloadGuard.allowed(finalURL),
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= limit else { throw UpdateFailure.invalid("更新下载响应无效或超过大小限制") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

private final class DownloadGuard: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    /// GitHub 的资产 CDN 采用临时签名 URL，不允许降级到 HTTP 或任意域名。
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    /// 重定向响应本身不能扩大下载来源。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }
    /// 实际字节数和服务端声明都不能超过签名清单约定。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    /// async download API 接管临时文件，这里不移动它。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
