// 使用独立 Ed25519 发布密钥验证更新，不依赖 Apple Developer ID，by AI.Coding。
import Foundation
import CryptoKit

public enum UpdateFailure: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let architectures: [String]
    public let archive: String
    public let size: Int
    public let sha256: String
    public static let maximumArchiveSize = 256 * 1024 * 1024

    /// 发布工具和测试使用相同的元数据结构。
    public init(version: String, build: Int, minimumSystemVersion: String, architectures: [String], archive: String, size: Int, sha256: String) {
        self.version = version; self.build = build; self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures; self.archive = archive; self.size = size; self.sha256 = sha256
    }

    /// 先验签再解析，未受信任的发布内容不能进入解压或执行路径。
    public static func authenticate(_ bytes: Data, signature: Data, publicKey: Data) throws -> Self {
        guard bytes.count <= 65_536, signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: bytes) else {
            throw UpdateFailure.invalid("更新签名验证失败，原版本未改变")
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard !value.version.isEmpty, value.version.allSatisfy({ $0.isNumber || $0 == "." }), value.build > 0,
              value.archive == "LocalClip-v\(value.version).zip", value.size > 0, value.size <= maximumArchiveSize,
              value.sha256.count == 64, value.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              !value.architectures.isEmpty else { throw UpdateFailure.invalid("更新元数据无效") }
        return value
    }

    /// 流式计算哈希，拒绝截断、替换或大小不符的压缩包。
    public func verifyArchive(at url: URL) throws {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { throw UpdateFailure.invalid("更新包大小不符") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw UpdateFailure.invalid("更新包校验失败") }
    }

    /// 在下载前检查系统与 CPU，构建号必须单调递增。
    public func checkCompatibility(currentBuild: Int) throws {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let pieces = minimumSystemVersion.split(separator: ".").compactMap { Int($0) }
        guard !pieces.isEmpty, pieces.count <= 3, pieces.count == minimumSystemVersion.split(separator: ".").count,
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: pieces[0], minorVersion: pieces.count > 1 ? pieces[1] : 0, patchVersion: pieces.count > 2 ? pieces[2] : 0)),
              architectures.contains(arch), build > currentBuild else { throw UpdateFailure.invalid("更新版本不兼容当前系统，或构建号未递增") }
    }
}
