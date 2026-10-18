// 更新包只在私有目录解压，所有安装前校验可由主进程和辅助进程重复执行，by AI.Coding。
import Foundation

public struct InstallRequest: Codable, Sendable {
    public let target: URL
    public let downloadDirectory: URL
    public let parentPID: Int32
    public let currentBuild: Int
    public init(target: URL, downloadDirectory: URL, parentPID: Int32, currentBuild: Int) {
        self.target = target; self.downloadDirectory = downloadDirectory; self.parentPID = parentPID; self.currentBuild = currentBuild
    }
}

public enum UpdatePackage {
    public static let bundleIdentifier = "local.localclip.dev"
    public static let publicKeyProperty = "LocalClipUpdatePublicKey"

    /// 使用固定的应用公钥重新验签，辅助进程不信任由调用方传入的密钥。
    public static func authenticate(directory: URL, installedApp: URL, currentBuild: Int) throws -> UpdateManifest {
        let info = try readInfo(installedApp)
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              (info["CFBundleVersion"] as? String).flatMap(Int.init) == currentBuild,
              let encodedKey = info[publicKeyProperty] as? String, let key = Data(base64Encoded: encodedKey) else {
            throw UpdateFailure.invalid("当前应用已改变或尚未配置更新公钥，请重新启动后检查")
        }
        let manifest = try UpdateManifest.authenticate(Data(contentsOf: directory.appendingPathComponent("update.json")), signature: Data(contentsOf: directory.appendingPathComponent("update.sig")), publicKey: key)
        try manifest.checkCompatibility(currentBuild: currentBuild)
        try manifest.verifyArchive(at: directory.appendingPathComponent(manifest.archive))
        return manifest
    }

    /// 所有条目必须位于唯一应用目录内；验签在解压之前完成。
    public static func extract(directory: URL, manifest: UpdateManifest, destination: URL) throws -> URL {
        let archive = directory.appendingPathComponent(manifest.archive)
        try manifest.verifyArchive(at: archive)
        let entries = try runTool("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            return parts.first == "LocalClip.app" && !parts.contains("..") && !entry.contains("\\")
        }) else { throw UpdateFailure.invalid("更新包目录结构无效") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try runTool("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
        let app = destination.appendingPathComponent("LocalClip.app")
        try validateBundle(app, manifest: manifest)
        return app
    }

    /// 保持 bundle ID、版本、架构和最低系统版本一致，允许有效的 ad-hoc 签名。
    public static func validateBundle(_ app: URL, manifest: UpdateManifest) throws {
        let info = try readInfo(app)
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == "LocalClip",
              info["CFBundleShortVersionString"] as? String == manifest.version,
              (info["CFBundleVersion"] as? String).flatMap(Int.init) == manifest.build,
              info["LSMinimumSystemVersion"] as? String == manifest.minimumSystemVersion else { throw UpdateFailure.invalid("更新应用身份或版本不匹配") }
        guard let resolvedRoot = UpdateLocations.realPath(app) else { throw UpdateFailure.invalid("无法读取更新应用") }
        let root = resolvedRoot + "/"
        guard let iterator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { throw UpdateFailure.invalid("无法读取更新应用") }
        for case let url as URL in iterator {
            // realpath 失败（含悬空/循环链接）也拒绝；合法内部 Framework 链接仍可通过。
            guard let resolved = UpdateLocations.realPath(url), resolved.hasPrefix(root) else { throw UpdateFailure.invalid("更新应用包含外部链接") }
        }
        _ = try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let archs = try runTool("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/LocalClip").path]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard Set(archs) == Set(manifest.architectures) else { throw UpdateFailure.invalid("更新应用架构不匹配") }
    }

    /// 直接读取 plist，避免 Bundle 对同一路径元数据缓存导致版本判断失真。
    public static func readInfo(_ app: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { throw UpdateFailure.invalid("应用信息无效") }
        return value
    }

    /// 固定程序路径和参数数组，不通过 shell 拼接用户路径；边读取边等待避免管道死锁。
    @discardableResult public static func runTool(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.invalid("更新校验失败：\(URL(fileURLWithPath: executable).lastPathComponent)") }
        return String(decoding: bytes, as: UTF8.self)
    }
}
