// 更新检查只使用合成响应和独立偏好域，验证失败限频、手动重试和链接校验，by AI.Coding。
import Foundation
import Testing
import LocalClipUpdateKit
@testable import LocalClipMac

@MainActor struct UpdateCheckerTests {
    /// LC-F05：仅承诺数据快照，保留清理失败细节与原始回滚结果，by AI.Coding。
    @Test(arguments: ["更新成功；数据快照：/fixture/backup", "更新成功；部分临时文件未清理：workspace；数据快照：/fixture/backup", "更新失败：启动回执不匹配", "更新失败：自动恢复失败，备份已保留：/fixture/rescue"])
    func restoredUpdateResultMatchesRetainedMaterials(message: String) throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(message.utf8).write(to: root.appendingPathComponent("result.txt"))
        defaults.set(root.path, forKey: UpdateInstaller.lastAttemptKey)
        let checker = UpdateChecker(defaults: defaults)
        let result = try #require(checker.manualResult)
        if message.hasPrefix("更新成功") {
            #expect(result.hasPrefix("更新已完成；本次更新前的数据快照已保留"))
            #expect(!result.contains("旧版本"))
            #expect(result.contains("/fixture/backup"))
            if message.contains("部分临时文件") { #expect(result.contains("部分临时文件未清理：workspace")) }
        } else { #expect(result == message) }
    }

    /// 自动发现只准备更新；唯有显式点击才调用安装器，重复点击不会重复安装。
    @Test func automaticDownloadNeverInstallsWithoutExplicitClick() async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var prepared = 0, installed = 0
        let checker = UpdateChecker(defaults: defaults, fetch: Self.signedRelease, prepare: { _, _ in
            prepared += 1
            return Self.fakeDownload()
        }, install: { _ in installed += 1 })
        await checker.installAndRestart()
        #expect(installed == 0)
        await checker.check(manual: false)
        #expect(prepared == 1 && installed == 0 && checker.phase == .ready)
        checker.automaticUpdatesChanged(enabled: false)
        await Task.yield()
        #expect(installed == 0 && checker.phase == .ready)
        await checker.installAndRestart()
        await checker.installAndRestart()
        #expect(installed == 1)
    }

    /// 损坏包、磁盘错误或安装预检失败都不能隐式退出应用，且允许重试。
    @Test func failuresAreVisibleAndRetryable() async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts = 0, installs = 0
        let checker = UpdateChecker(defaults: defaults, fetch: Self.signedRelease, prepare: { _, _ in
            attempts += 1
            if attempts == 1 { throw UpdateFailure.invalid("损坏包") }
            return Self.fakeDownload()
        }, install: { _ in installs += 1; throw UpdateFailure.invalid("目录只读") })
        await checker.check(manual: true)
        guard case .failed = checker.phase else { Issue.record("下载失败应展示错误"); return }
        await checker.installAndRestart()
        #expect(installs == 0)
        await checker.check(manual: true)
        #expect(checker.phase == .ready)
        await checker.installAndRestart()
        guard case .failed = checker.phase else { Issue.record("安装失败应展示错误"); return }
        await checker.check(manual: true)
        #expect(attempts == 3 && checker.phase == .ready && installs == 1)
    }

    /// 关闭开关取消正在下载的任务，不允许晚到回调变成可安装状态。
    @Test func disablingBackgroundDownloadsCancelsWork() async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, fetch: Self.signedRelease, prepare: { _, _ in
            try await Task.sleep(for: .seconds(10))
            return Self.fakeDownload()
        }, install: { _ in Issue.record("取消下载不能安装") })
        let check = Task { await checker.check(manual: false) }
        while checker.phase != .downloading { await Task.yield() }
        checker.automaticUpdatesChanged(enabled: false)
        await check.value
        #expect(checker.phase == .idle && !checker.checking)
    }

    /// 普通退出不安装；再次启动只恢复已验签的缓存，关闭后台开关仍可手动安装。
    @Test func verifiedDownloadSurvivesRestartWithoutInstalling() async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let download = Self.fakeDownload()
        let first = UpdateChecker(defaults: defaults, fetch: Self.signedRelease, prepare: { _, _ in download }, install: { _ in Issue.record("不应安装") })
        await first.check(manual: false)
        var restored = 0
        let reopened = UpdateChecker(defaults: defaults, fetch: { _ in Issue.record("恢复缓存不访问网络"); throw URLError(.cancelled) }, restore: { directory in
            #expect(directory.path == download.directory.path)
            restored += 1
            return download
        }, install: { _ in Issue.record("重启不应安装") })
        reopened.checkIfDue(enabled: false)
        while reopened.checking { await Task.yield() }
        #expect(restored == 1 && reopened.phase == .ready)
    }

    /// 等待版本响应期间关闭开关，晚到的响应也不能发起后台下载。
    @Test func disablingWhileCheckingPreventsDownload() async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        let checker = UpdateChecker(defaults: defaults, fetch: { request in
            await withCheckedContinuation { continuation = $0 }
            return try await Self.signedRelease(request)
        }, prepare: { _, _ in Issue.record("关闭后不应下载"); return Self.fakeDownload() })
        let work = Task { await checker.check(manual: false) }
        while continuation == nil { await Task.yield() }
        checker.automaticUpdatesChanged(enabled: false)
        continuation?.resume()
        await work.value
        #expect(checker.phase == .idle)
    }

    /// 资产必须来自指定仓库和版本，不信任其他 GitHub 仓库或重复资产。
    @Test func assetURLsArePinnedToRelease() throws {
        let tag = "v999.0.0", version = "999.0.0"
        let names = ["update.json", "update.sig", "LocalClip-v999.0.0.zip"]
        let assets = names.map { ["name": $0, "browser_download_url": "https://github.com/yuhui0531/local-clip/releases/download/\(tag)/\($0)"] }
        #expect(UpdateDownloadService.assets(from: ["assets": assets], tag: tag, version: version) != nil)
        #expect(UpdateDownloadService.assets(from: ["assets": assets + [assets[0]]], tag: tag, version: version) == nil)
        var unsafe = assets
        unsafe[0]["browser_download_url"] = "https://github.com/attacker/local-clip/releases/download/\(tag)/update.json"
        #expect(UpdateDownloadService.assets(from: ["assets": unsafe], tag: tag, version: version) == nil)
    }

    /// 使用完整仓库资产响应，测试绝不访问 GitHub。
    private static func signedRelease(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let base = "https://github.com/yuhui0531/local-clip/releases/"
        let assets = ["update.json", "update.sig", "LocalClip-v999.0.0.zip"].map { ["name": $0, "browser_download_url": base + "download/v999.0.0/" + $0] }
        let json: [String: Any] = ["tag_name": "v999.0.0", "html_url": base + "tag/v999.0.0", "assets": assets]
        return (try JSONSerialization.data(withJSONObject: json), try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }

    /// 虚拟准备结果仅供状态机使用，不触碰实际安装路径。
    private static func fakeDownload() -> DownloadedUpdate {
        DownloadedUpdate(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), manifest: UpdateManifest(version: "999.0.0", build: 999, minimumSystemVersion: "15.0", architectures: ["arm64"], archive: "LocalClip-v999.0.0.zip", size: 1, sha256: String(repeating: "0", count: 64)))
    }

    /// 离线也按天限频；关闭自动检查不发请求，手动操作可重试，重新实例化保留限频。
    @Test func failedAttemptsAreThrottledAndManualRetryRemainsAvailable() async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 100_000)
        var requests = 0
        let checker = UpdateChecker(defaults: defaults, now: { now }, fetch: { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        })
        checker.checkIfDue(enabled: false)
        await Task.yield()
        #expect(requests == 0)
        await checker.check(manual: false)
        #expect(requests == 1 && !checker.checking && checker.manualResult == nil)
        checker.checkIfDue(enabled: true)
        await Task.yield()
        #expect(requests == 1)
        await checker.check(manual: true)
        #expect(requests == 2 && checker.manualResult == "检查失败，请稍后重试")
        let reopened = UpdateChecker(defaults: defaults, now: { now }, fetch: { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        })
        reopened.checkIfDue(enabled: true)
        await Task.yield()
        #expect(requests == 2)
        now = now.addingTimeInterval(86_401)
        reopened.checkIfDue(enabled: true)
        reopened.checkIfDue(enabled: true)
        let deadline = ContinuousClock.now + .seconds(15)
        while requests < 3, ContinuousClock.now < deadline { await Task.yield() }
        await Task.yield()
        #expect(requests == 3 && !reopened.checking)
    }

    /// 合法发布仍可下载；错误状态或非GitHub地址不能进入可打开的新版本状态。
    @Test(arguments: ["release", "current", "http-error", "unsafe-link"])
    func releaseResponsesRemainValidated(scenario: String) async throws {
        let suite = "LocalClip.UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, fetch: { request in
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            let page = scenario == "unsafe-link" ? "https://example.invalid/download" : "https://github.com/yuhui0531/local-clip/releases/tag/v999.0.0"
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": scenario == "current" ? "v0.0.0" : "v999.0.0", "html_url": page])
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: scenario == "http-error" ? 503 : 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        })
        await checker.check(manual: true)
        #expect(!checker.checking)
        if scenario == "release" {
            #expect(checker.available?.version == "999.0.0")
            #expect(checker.manualResult == nil)
        } else {
            #expect(checker.available == nil)
            #expect(checker.manualResult == (scenario == "current" ? "已是最新版本" : "检查失败，请稍后重试"))
        }
    }
}
