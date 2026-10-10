// 目标身份、权限与粘贴事件的唯一系统边界，by AI.Coding。
import AppKit
// C SDK把只读使用的AX提示常量导入为共享变量；限定当前C接口的并发边界，实际调用仍限定主线程。
@preconcurrency import ApplicationServices
import OSLog
import LocalClipCore
@MainActor public final class MacApplicationClient: ApplicationClient {
    private var focusTarget: TargetToken?
    private var rememberedFocus: AXUIElement?
    private let logger = Logger(subsystem: "local.localclip.dev", category: "Paste")
    public private(set) var pasteFailureReason: String?
    public init() {}
    /// 只为智能文件转换分类，不收紧原生粘贴焦点检查；不读取输入框正文，by AI.Coding。
    public func pasteTargetKind(_ target: TargetToken) -> PasteTargetKind {
        guard isAlive(target) else { return .unknown }
        if target.bundleID == "com.apple.finder" { return .files }
        guard permitted, focusTarget == target, let rememberedFocus,
              let focused = focusedElement(in: target), CFEqual(focused, rememberedFocus),
              attribute(kAXEnabledAttribute, of: focused) as? Bool != false else { return .unknown }
        let role = attribute(kAXRoleAttribute, of: focused) as? String ?? ""
        let subrole = attribute(kAXSubroleAttribute, of: focused) as? String ?? ""
        let editable = attribute("AXEditable", of: focused) as? Bool
        var settable: DarwinBoolean = false
        if ["AXGroup", "AXDocument", "AXWebArea"].contains(role), editable == nil {
            _ = AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &settable)
        }
        return Self.classifyTextMetadata(role: role, subrole: subrole, editable: editable, selectedRangeSettable: settable.boolValue, bundleID: target.bundleID)
    }
    /// 文本角色与明确编辑能力是转换依据；安全文本、只读及未知画布都保持原文件，by AI.Coding。
    static func classifyTextMetadata(role: String, subrole: String, editable: Bool?, selectedRangeSettable: Bool, bundleID: String = "") -> PasteTargetKind {
        guard subrole != "AXSecureTextField", editable != false else { return .unknown }
        if ["AXTextArea", "AXTextField", "AXSearchField"].contains(role) { return .text }
        if ["AXGroup", "AXDocument", "AXWebArea"].contains(role), editable == true || selectedRangeSettable { return .text }
        // Zed的自绘编辑器当前只暴露窗口焦点。仅为该已知编辑器补足能力识别，
        // 仍要求原窗口身份、前台及权限；不把任意应用窗口或已识别的非文本控件当编辑器。
        if bundleID == "dev.zed.Zed", role == "AXWindow" { return .text }
        return .unknown
    }
    public var permitted: Bool { AXIsProcessTrusted() }
    /// 用户点击粘贴时只请求系统显示授权提示，不修改系统权限数据库。
    public func requestPastePermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        logger.notice("stage=permission_required")
    }
    /// 显示已记住的目标，便于用户确认恢复对象；过期身份不借用同 PID 的新进程名，by AI.Coding。
    public static func targetName(_ target: TargetToken?) -> String {
        guard let target, let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.bundleIdentifier == target.bundleID, app.launchDate?.timeIntervalSince1970 == target.launchedAt else { return "未指定有效目标" }
        return app.localizedName ?? target.bundleID
    }
    /// 面板打开前保存 PID + bundle + 启动身份，不依赖 PID 单独匹配。
    public func target() -> TargetToken? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundle = app.bundleIdentifier, let date = app.launchDate else { return nil }
        return .init(pid: app.processIdentifier, bundleID: bundle, launchedAt: date.timeIntervalSince1970)
    }
    /// PID 重用和已退出均拒绝。
    public func isAlive(_ target: TargetToken) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return false }
        return app.bundleIdentifier == target.bundleID && app.launchDate?.timeIntervalSince1970 == target.launchedAt
    }
    /// 发送前必须确认为记住的应用。
    public func isFrontmost(_ target: TargetToken) -> Bool { isAlive(target) && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid }
    /// 打开面板前只记住目标焦点身份，不读取控件内容；无授权时保留复制回退。
    public func rememberFocus(for target: TargetToken?) {
        focusTarget = target; rememberedFocus = nil; pasteFailureReason = nil
        guard let target, permitted, isFrontmost(target) else {
            reject(permitted ? "未记住目标焦点，请在目标应用重新打开历史" : "当前LocalClip尚未获得辅助功能权限")
            return
        }
        // 不在捕获焦点时切换Electron的辅助模式：实际VS Code会重建AX控件身份，
        // 使原焦点检查失效。直接读取当前已暴露的编辑控件元数据，保持目标状态不变。
        rememberedFocus = focusedElement(in: target)
        logger.notice("stage=remember_focus pid=\(target.pid) captured=\(self.rememberedFocus != nil)")
    }
    /// 核对原焦点即可；编辑器、文档、画布等由目标应用处理原生粘贴。
    public func isPasteFocusReady(_ target: TargetToken) -> Bool {
        guard focusTarget == target, let rememberedFocus else { return reject("未记住目标焦点，请在目标应用重新打开历史") }
        guard let focused = focusedElement(in: target), CFEqual(rememberedFocus, focused) else { return reject("原目标焦点尚未恢复或已经改变") }
        let enabled = attribute(kAXEnabledAttribute, of: focused) as? Bool
        // 原生粘贴不要求文本角色/AXIsEditable/AXValue setter；这些条件会误拒自绘编辑器及非文本目标。
        // 仍保留原控件身份和明确禁用状态检查，未知可选属性不当作禁用。
        guard enabled != false else { return reject("目标焦点控件已禁用") }
        pasteFailureReason = nil
        return true
    }
    /// 只恢复打开面板前保存的同一控件焦点，不设置正文，不按应用名称分支。
    public func restorePasteFocus(_ target: TargetToken) -> Bool {
        guard permitted, isFrontmost(target), focusTarget == target, let rememberedFocus else { return false }
        if isPasteFocusReady(target) { return true }
        var pid: pid_t = 0
        guard AXUIElementGetPid(rememberedFocus, &pid) == .success, pid == target.pid else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(rememberedFocus, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(rememberedFocus, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }
    /// 日志仅含固定原因与状态，无输入框内容、剪贴板正文、文件路径或URL。
    @discardableResult private func reject(_ reason: String) -> Bool {
        if pasteFailureReason != reason { logger.notice("stage=focus_rejected reason=\(reason, privacy: .public)") }
        pasteFailureReason = reason
        return false
    }
    /// 给无响应应用设置短超时，避免原生查询长时间卡住面板。
    private func focusedElement(in target: TargetToken) -> AXUIElement? {
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let value = attribute(kAXFocusedUIElementAttribute, of: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid else { return nil }
        return element
    }
    /// 统一读取身份/角色元数据，失败时不给未知目标发送输入。
    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    /// 最多一次激活，后续由协调层观察，不循环抢焦点。
    public func activate(_ target: TargetToken) -> Bool {
        guard isAlive(target), let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
        return app.activate(options: [])
    }
    /// 紧邻发送核对原焦点身份与前台，Command-V由目标应用处理格式和插入行为。
    /// AX检查可能耗时，必须在检查结束之后紧邻事件再次核对剪贴板收据。
    public func sendPaste(_ target: TargetToken, ifClipboardUnchanged stillValid: () -> Bool) -> Bool {
        guard permitted, isFrontmost(target), isPasteFocusReady(target),
              permitted, isFrontmost(target), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        guard stillValid(), permitted, isFrontmost(target) else { return false }
        // 向已核对的应用进程投递一次按键，避免全局HID路由仍指向刚关闭的面板。
        down.postToPid(target.pid); up.postToPid(target.pid)
        logger.notice("stage=command_sent pid=\(target.pid)")
        return true
    }
    /// 仅打开权限页面；授权由用户操作。
    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    #if DEBUG
    /// 隔离验收仅记录角色及能力，不读取第三方正文、路径或剪贴板内容，by AI.Coding。
    public func focusDiagnostic(_ target: TargetToken) -> [String: Any] {
        var result: [String: Any] = ["permitted": permitted, "bundleID": target.bundleID, "frontmost": isFrontmost(target), "remembered": rememberedFocus != nil, "kind": String(describing: pasteTargetKind(target))]
        if let focused = focusedElement(in: target) {
            result["role"] = attribute(kAXRoleAttribute, of: focused) as? String ?? ""
            result["subrole"] = attribute(kAXSubroleAttribute, of: focused) as? String ?? ""
            result["editable"] = attribute("AXEditable", of: focused) as? Bool
            result["sameFocus"] = rememberedFocus.map { CFEqual($0, focused) } ?? false
        }
        return result
    }
    #endif
}
