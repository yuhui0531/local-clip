// 面板焦点意图与菜单身份独立于窗口服务器，供真实事件和无窗口回归共用，by AI.Coding。
import Foundation

@MainActor struct HistoryPanelFocusState {
    private(set) var externalInteractionPending = false
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var lastInteractionTime: TimeInterval = 0
    var isTrackingMenu: Bool { !trackingMenus.isEmpty }

    /// 外部点击或激活要求关闭；自动恢复key不会清除此意图，by AI.Coding。
    mutating func externalInteraction(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard time >= lastInteractionTime else { return }
        lastInteractionTime = time; externalInteractionPending = true
    }
    /// 只有真实的面板输入才覆盖之前的离开意图，by AI.Coding。
    @discardableResult mutating func ownedInteraction(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard time >= lastInteractionTime else { return false }
        lastInteractionTime = time; externalInteractionPending = false
        return true
    }
    /// 同一菜单重复开始通知不累加，子菜单分别保留身份，by AI.Coding。
    mutating func menuBegan(_ identity: ObjectIdentifier) { trackingMenus.insert(identity) }
    /// 无关或重复结束通知不能提前解除仍在使用的菜单保护，by AI.Coding。
    mutating func menuEnded(_ identity: ObjectIdentifier) { trackingMenus.remove(identity) }
    /// 关闭面板后不保留上一轮交互的菜单或离开意图，by AI.Coding。
    mutating func reset() {
        externalInteractionPending = false; trackingMenus.removeAll(); lastInteractionTime = 0
    }

    /// 拖动与确认先完成，普通key转移保留自有弹窗与菜单，by AI.Coding。
    func shouldDismiss(panelIsKey: Bool, ownsKeyWindow: Bool, dragging: Bool,
                       confirming: Bool, hasModal: Bool) -> Bool {
        guard !dragging, !confirming, !hasModal else { return false }
        // 外部点击已经离开菜单交互；过期菜单通知不能永久拦住关闭，by AI.Coding。
        if externalInteractionPending { return true }
        return !panelIsKey && !ownsKeyWindow && !isTrackingMenu
    }
}
