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

    // MARK: 卡片头部来源色：按bundleID提取图标主色并校正到白字对比度≥4.5:1，只计算一次，by AI.Coding。
    private static var headerColors: [String: NSColor] = [:]
    /// 图标整体近灰（含单色图标）时使用的中性深灰。
    static let neutralHeader = NSColor(srgbRed: 0x5A / 255.0, green: 0x5F / 255.0, blue: 0x6B / 255.0, alpha: 1)
    /// 有来源图标时返回校正后的头部色；无图标返回nil，由调用方回退到类型色。
    public static func headerColor(for id: String) -> NSColor? {
        if let cached = headerColors[id] { return cached }
        guard let icon = icon(for: id) else { return nil }
        let color = readableHeader(dominantColor(icon) ?? neutralHeader)
        headerColors[id] = color
        return color
    }
    /// 回退类型色同样校正并缓存，深浅色模式共用。
    static func headerColor(fallback key: String, base: NSColor) -> NSColor {
        if let cached = headerColors["kind:" + key] { return cached }
        let color = readableHeader(base); headerColors["kind:" + key] = color
        return color
    }
    /// 绘制到8×8位图，饱和度加权平均，排除饱和度<0.15的近灰像素；全为灰时返回nil。
    static func dominantColor(_ image: NSImage) -> NSColor? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        NSGraphicsContext.restoreGraphicsState()
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for x in 0..<8 { for y in 0..<8 {
            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.5 else { continue }
            let saturation = pixel.saturationComponent
            guard saturation >= 0.15 else { continue }
            red += pixel.redComponent * saturation; green += pixel.greenComponent * saturation; blue += pixel.blueComponent * saturation; weight += saturation
        } }
        guard weight > 0 else { return nil }
        return NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
    }
    /// 保持色相，饱和度上限0.85，逐步降低亮度直到白字对比度≥4.5:1。
    static func readableHeader(_ color: NSColor) -> NSColor {
        guard let value = color.usingColorSpace(.sRGB) else { return neutralHeader }
        let hue = value.hueComponent, saturation = min(value.saturationComponent, 0.85)
        var brightness = value.brightnessComponent
        var result = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        while whiteContrast(result) < 4.5 && brightness > 0 {
            brightness = max(0, brightness - 0.02)
            result = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        }
        return result
    }
    /// WCAG相对亮度下白字与背景的对比度。
    static func whiteContrast(_ color: NSColor) -> Double {
        guard let value = color.usingColorSpace(.sRGB) else { return 1 }
        func linear(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent) + 0.0722 * linear(value.blueComponent)
        return 1.05 / (luminance + 0.05)
    }
}
