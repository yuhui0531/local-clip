// 更新检查只使用合成响应和独立偏好域，验证失败限频、手动重试和链接校验，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipMac

@MainActor struct UpdateCheckerTests {
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
        let deadline = ContinuousClock.now + .seconds(2)
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
