// 更新签名工具：私钥仅写入受限文件或从 CI 环境读取，输出不包含私钥，by AI.Coding。
import Foundation
import CryptoKit
import LocalClipUpdateKit

@main struct UpdateToolMain {
    /// keygen 生成独立发布密钥；manifest 根据最终 ZIP 生成签名元数据。
    static func main() throws {
        let args = CommandLine.arguments
        #if DEBUG
        // 仅 Debug：对隔离根执行与主程序相同的补偿清理，供安装器脚本验证；Release 不包含此命令，by AI.Coding。
        if args.count >= 2 && args[1] == "janitor" {
            let environment = ProcessInfo.processInfo.environment
            guard environment["LOCALCLIP_UPDATER_TEST_ROOT"] != nil else { throw UpdateFailure.invalid("janitor 仅用于隔离测试根") }
            let report = UpdateJanitor.run(try UpdateLocations.current(), excludedDownloads: Set(args.dropFirst(2)),
                                           legacyQuietPeriod: environment["LOCALCLIP_JANITOR_QUIET"].flatMap(Double.init) ?? 120)
            print("removed=\(report.removed.count) retained=\(report.retained.count) active=\(report.skippedActive.count) failures=\(report.failures.joined(separator: ","))")
            return
        }
        #endif
        if args.count == 3 && args[1] == "keygen" {
            let file = URL(fileURLWithPath: args[2]), fm = FileManager.default
            guard !fm.fileExists(atPath: file.path) else { throw UpdateFailure.invalid("私钥已存在，不覆盖") }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = Curve25519.Signing.PrivateKey()
            guard fm.createFile(atPath: file.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600]) else { throw UpdateFailure.invalid("无法保存私钥") }
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        guard args.count == 5, args[1] == "manifest",
              let encoded = ProcessInfo.processInfo.environment["LOCALCLIP_UPDATE_PRIVATE_KEY"],
              let secret = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateFailure.invalid("用法：keygen <私钥路径> 或 manifest <app> <zip> <输出目录>；签名需要 LOCALCLIP_UPDATE_PRIVATE_KEY")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        let app = URL(fileURLWithPath: args[2]), archive = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
        let info = try UpdatePackage.readInfo(app)
        guard let version = info["CFBundleShortVersionString"] as? String,
              let build = (info["CFBundleVersion"] as? String).flatMap(Int.init),
              let minimum = info["LSMinimumSystemVersion"] as? String,
              info[UpdatePackage.publicKeyProperty] as? String == key.publicKey.rawRepresentation.base64EncodedString() else { throw UpdateFailure.invalid("发布私钥与应用内公钥不匹配") }
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        let archs = try UpdatePackage.runTool("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/LocalClip").path]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let manifest = UpdateManifest(version: version, build: build, minimumSystemVersion: minimum, architectures: archs, archive: archive.lastPathComponent, size: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try UpdatePackage.validateBundle(app, manifest: manifest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = try encoder.encode(manifest), signature = try key.signature(for: json)
        _ = try UpdateManifest.authenticate(json, signature: signature, publicKey: key.publicKey.rawRepresentation)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try json.write(to: output.appendingPathComponent("update.json"), options: .atomic)
        try signature.write(to: output.appendingPathComponent("update.sig"), options: .atomic)
        print("Signed update metadata for \(version) (\(build))")
    }
}
