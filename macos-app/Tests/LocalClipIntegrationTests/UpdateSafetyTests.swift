// 更新验签、原子替换和故障恢复使用临时目录，不访问用户数据，by AI.Coding。
import Foundation
import CryptoKit
import Testing
@testable import LocalClipUpdateKit

struct UpdateSafetyTests {
    /// 签名覆盖完整元数据，归档的任何修改都必须拒绝。
    @Test func signedManifestAndArchiveRejectTampering() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("archive".utf8)
        let manifest = UpdateManifest(version: "1.0.0", build: 100, minimumSystemVersion: "15.0", architectures: ["arm64"], archive: "LocalClip-v1.0.0.zip", size: payload.count, sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let bytes = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: bytes)
        #expect(try UpdateManifest.authenticate(bytes, signature: signature, publicKey: key.publicKey.rawRepresentation) == manifest)
        #expect(throws: (any Error).self) { try UpdateManifest.authenticate(bytes + Data([0]), signature: signature, publicKey: key.publicKey.rawRepresentation) }
        #expect(throws: (any Error).self) { try UpdateManifest.authenticate(bytes, signature: signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("payload.zip")
        try payload.write(to: archive)
        try manifest.verifyArchive(at: archive)
        try Data("changed".utf8).write(to: archive)
        #expect(throws: (any Error).self) { try manifest.verifyArchive(at: archive) }
    }

    /// 新程序失败后必须同时恢复旧程序与旧数据，并保留失败版本产生的数据。
    @Test func atomicRollbackPreservesBothGenerations() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("LocalClip.app")
        let staged = root.appendingPathComponent("candidate.app")
        let data = root.appendingPathComponent("history")
        for url in [app, staged, data] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("old-app".utf8).write(to: app.appendingPathComponent("version"))
        try Data("new-app".utf8).write(to: staged.appendingPathComponent("version"))
        try Data("history-and-settings".utf8).write(to: data.appendingPathComponent("database"))
        let transaction = try UpdateTransaction(target: app, candidate: staged, dataDirectory: data, backupDirectory: root.appendingPathComponent("backup"))
        try transaction.prepare()
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "old-app")
        try transaction.replaceApp()
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "new-app")
        try Data("new-data".utf8).write(to: data.appendingPathComponent("database"))
        try transaction.rollback()
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "old-app")
        #expect(try String(contentsOf: data.appendingPathComponent("database"), encoding: .utf8) == "history-and-settings")
        #expect(try String(contentsOf: transaction.dataBackup.appendingPathComponent("database"), encoding: .utf8) == "new-data")
    }

    /// 快照失败不能触碰旧程序；不存在旧数据时也不创建空历史覆盖用户数据。
    @Test func failedPreparationDoesNotReplaceApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("LocalClip.app")
        let candidate = root.appendingPathComponent("new.app")
        for url in [app, candidate] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let transaction = try UpdateTransaction(target: app, candidate: candidate, dataDirectory: nil, backupDirectory: blocked)
        #expect(throws: (any Error).self) { try transaction.prepare() }
        #expect(throws: (any Error).self) { try transaction.replaceApp() }
        #expect(fm.fileExists(atPath: app.path) && fm.fileExists(atPath: candidate.path))
    }

    /// 不允许符号链接把快照重新指向可变原文件。
    @Test func symlinkDataIsRejectedBeforeReplacement() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), app = root.appendingPathComponent("app"), candidate = root.appendingPathComponent("new")
        for url in [data, app, candidate] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("original".utf8).write(to: root.appendingPathComponent("outside"))
        try fm.createSymbolicLink(at: data.appendingPathComponent("database"), withDestinationURL: root.appendingPathComponent("outside"))
        let transaction = try UpdateTransaction(target: app, candidate: candidate, dataDirectory: data, backupDirectory: root.appendingPathComponent("backup"))
        #expect(throws: (any Error).self) { try transaction.prepare() }
        #expect(throws: (any Error).self) { try transaction.replaceApp() }
        #expect(try String(contentsOf: root.appendingPathComponent("outside"), encoding: .utf8) == "original")
    }

    /// 新版本不得向不兼容系统、CPU 或旧构建回退。
    @Test func compatibilityRejectsWrongSystemArchitectureAndDowngrade() throws {
        let incompatible = UpdateManifest(version: "1.0", build: 1, minimumSystemVersion: "999.0", architectures: ["unsupported"], archive: "LocalClip-v1.0.zip", size: 1, sha256: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try incompatible.checkCompatibility(currentBuild: 2) }
    }
}
