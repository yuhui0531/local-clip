// 登录启动只响应用户操作，显示实际系统状态，by AI.Coding。
import Foundation
import ServiceManagement
@MainActor public final class LoginItemService {
    public init() {}
    public var status: SMAppService.Status { SMAppService.mainApp.status }
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
