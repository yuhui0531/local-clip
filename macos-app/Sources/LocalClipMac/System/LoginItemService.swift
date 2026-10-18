// 登录启动只响应用户操作，显示实际系统状态，by AI.Coding。
import Foundation
import ServiceManagement
@MainActor public final class LoginItemService {
    private let readStatus: () -> SMAppService.Status
    public init() { readStatus = { SMAppService.mainApp.status } }
    /// 只替换状态读取供隔离验证；注册/注销仍仅由用户操作，by AI.Coding。
    init(readStatus: @escaping () -> SMAppService.Status) { self.readStatus = readStatus }
    public var status: SMAppService.Status { readStatus() }
    public var message: String {
        switch status {
        case .enabled: "系统已启用登录启动"
        case .requiresApproval: "等待用户在系统设置中批准"
        case .notRegistered: "登录启动未注册（默认关闭）"
        case .notFound: "系统未找到该登录项"
        @unknown default: "系统状态未知"
        }
    }
    /// 返回调用后实际状态，注册返回不等于授权完成。
    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
    /// 用户主动进入系统登录项页面。
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
