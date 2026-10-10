// 结果契约的行为检查，by AI.Coding。
import Testing
@testable import LocalClipCore
@Test func noDeliveredClaim() {
    #expect(PasteResult.commandSent.message == "已发送粘贴指令")
    #expect(PasteResult.copied != .commandSent)
}
