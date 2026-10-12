// 结果契约的行为检查，by AI.Coding。
import Testing
@testable import LocalClipCore
@Test func noDeliveredClaim() {
    #expect(PasteResult.commandSent.message == "已发送粘贴指令")
    #expect(PasteResult.copied != .commandSent)
}

// 发布标签与当前版本号按数字分段比较，by AI.Coding。
@Test func appVersionComparison() {
    #expect(AppVersion.isNewer("v0.3.18", than: "0.3.17"))
    #expect(AppVersion.isNewer("v0.10.0", than: "0.9.9"))
    #expect(AppVersion.isNewer("1.0", than: "0.99.99"))
    #expect(!AppVersion.isNewer("v0.3.17", than: "0.3.17"))
    #expect(!AppVersion.isNewer("0.3.17.0", than: "0.3.17"))
    #expect(!AppVersion.isNewer("v0.3.16", than: "0.3.17"))
    // 实际发布标签带构建号后缀。
    #expect(AppVersion.isNewer("v0.3.18-40", than: "0.3.17"))
    #expect(!AppVersion.isNewer("v0.3.17-39", than: "0.3.17"))
    #expect(AppVersion.marketing("v0.3.16-38") == "0.3.16")
    #expect(SettingsSnapshot().autoCheckUpdates)
}
