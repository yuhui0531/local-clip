// 启动恢复文案为纯映射；窗口和访达操作由桌面验收覆盖，by AI.Coding。
import Foundation
import Testing
import LocalClipCore
@testable import LocalClipMac

struct StorageOpenFailureTests {
    @Test func modalResponsesRequireExplicitExitAndBoundRetries() {
        #expect(AppDelegate.storagePromptAction(response: 1000, consecutiveUnexpected: 0) == .retry)
        #expect(AppDelegate.storagePromptAction(response: 1001, consecutiveUnexpected: 0) == .revealDirectory)
        #expect(AppDelegate.storagePromptAction(response: 1002, consecutiveUnexpected: 0) == .quit)
        #expect(AppDelegate.storagePromptAction(response: -1000, consecutiveUnexpected: 0) == .showAgain)
        #expect(AppDelegate.storagePromptAction(response: -1001, consecutiveUnexpected: 1) == .showAgain)
        #expect(AppDelegate.storagePromptAction(response: -1000, consecutiveUnexpected: 2) == .stopShowing)
    }

    @Test func messagesDescribeWhatTheUserCanCheck() {
        #expect(AppDelegate.storageOpenFailureMessage(StoreError.incompatibleSchema).contains("版本"))
        #expect(AppDelegate.storageOpenFailureMessage(StoreError.corruptPayload).contains("完整性"))
        #expect(AppDelegate.storageOpenFailureMessage(StoreError.diskFull).contains("空间不足"))
        #expect(AppDelegate.storageOpenFailureMessage(StoreError.ioFailure).contains("无法读写"))
        #expect(AppDelegate.storageOpenFailureMessage(CocoaError(.fileReadNoPermission)).contains("访问权限"))
    }
}
