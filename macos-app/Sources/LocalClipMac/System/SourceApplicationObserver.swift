// 记录剪贴板变化时的前台应用上下文，仅作展示推断，不用于可靠排除，by AI.Coding。
import AppKit
import LocalClipCore

@MainActor public final class SourceApplicationObserver {
    private let changeCount: () -> Int
    private var sampledCount: Int
    private var sampledSource = SourceAttribution.unknown
    private var observer: NSObjectProtocol?
    /// 前台区间结束只用于推进暂停采集基线，不改变来源归因的可信度。
    public var onDeactivate: ((String?) -> Void)?
    private static let icons = NSCache<NSString, NSImage>()

    public init(changeCount: @escaping () -> Int) {
        self.changeCount = changeCount
        sampledCount = changeCount()
        // 旧应用停用时关联尚未轮询到的复制计数，降低复制后立刻切应用的归因竞态。
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // 只带入可发送的身份值；进程已退出也保留通知中的排除身份。
            let eventApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = eventApplication?.processIdentifier, bundleID = eventApplication?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                let application = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                self.onDeactivate?(bundleID)
                let count = self.changeCount()
                guard count != self.sampledCount else { return }
                self.sampledCount = count
                self.sampledSource = Self.attribution(application)
            }
        }
    }

    /// 只采集应用身份，不读取剪贴板正文；无法稳定关联时仍保留未知。
    public func source(for count: Int) -> SourceAttribution {
        guard count == changeCount() else { return .unknown }
        if sampledCount != count {
            sampledCount = count
            sampledSource = Self.attribution(NSWorkspace.shared.frontmostApplication)
        }
        return sampledSource
    }

    /// 退出时解除系统观察；不将LocalClip自身当作用户复制来源。
    public func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private static func attribution(_ application: NSRunningApplication?) -> SourceAttribution {
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let id = application.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return .unknown }
        if let icon = application.icon { icons.setObject(icon, forKey: id as NSString) }
        return .init(bundleID: id, name: application.localizedName ?? id, basis: "frontmost")
    }

    /// 缓存应用图标，运行中的未注册应用也能展示；不读用户剪贴板或其他应用历史。
    public static func icon(for id: String) -> NSImage? {
        if let cached = icons.object(forKey: id as NSString) { return cached }
        let icon: NSImage?
        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
           let runningIcon = application.icon { icon = runningIcon }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else { icon = nil }
        if let icon { icons.setObject(icon, forKey: id as NSString) }
        return icon
    }
}
