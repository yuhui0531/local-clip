// 历史文件卡片按内容生成预览，不以文件后缀或截断路径决定能否展示，by AI.Coding。
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum FileCardPreview: Sendable {
    case image(Data), text(String), unavailable

    /// 图片优先按真实内容解码，文本保留原有开头/代码预览，其余交给文档缩略图。
    static func render(fileAt url: URL, document: @Sendable (URL) async -> Self = documentPreview) async -> Self {
        let local = await Task.detached(priority: .utility) { localPreview(url) }.value
        guard !Task.isCancelled else { return .unavailable }
        if let local {
            // SVG 优先显示图形；系统不能生成缩略图时保留已有源码预览。
            if case .text = local, url.pathExtension.lowercased() == "svg" {
                let graphic = await document(url)
                guard !Task.isCancelled else { return .unavailable }
                if case .image = graphic { return graphic }
            }
            return local
        }
        return await document(url)
    }

    /// 只读原件；40MP限制不能通过文档回退绕过，PDF即使全为ASCII也应展示页面。
    private static func localPreview(_ url: URL) -> Self? {
        guard FileReferencePreviewVersion.read([url]) != nil else { return .unavailable }
        switch ThumbnailRenderer.render(fileAt: url) {
        case .image(let data): return .image(data)
        case .tooManyPixels: return .unavailable
        case .unavailable: break
        }
        // CoreGraphics按内容识别PDF，包含没有后缀的文件，输出有界首页缩略图。
        if let document = CGPDFDocument(url as CFURL) {
            // 锁定或无首页的 PDF 不作为文本显示，也不生成空白成功预览。
            guard document.isUnlocked, let page = document.page(at: 1) else { return .unavailable }
            let bounds = page.getBoxRect(.cropBox)
            guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return .unavailable }
            let scale = min(1, 800 / max(bounds.width, bounds.height))
            let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .unavailable }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            return context.makeImage().flatMap(png).map(Self.image) ?? .unavailable
        }
        if TextFilePreview.isCandidate(url.path), let text = TextFilePreview.read(url) { return .text(text) }
        return nil
    }

    /// Office、RTF等常见文档使用系统提供的内容缩略图；不把通用文件图标当成预览。
    private static func documentPreview(_ url: URL) async -> Self {
        let request = ThumbnailRequest(value: QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 800, height: 800), scale: 1, representationTypes: .thumbnail))
        let completion = PreviewCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation) else { return }
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request.value) { representation, _ in
                    let result = representation.flatMap { $0.type == .thumbnail ? png($0.cgImage) : nil }.map(Self.image) ?? .unavailable
                    completion.finish(result)
                }
                // 覆盖取消发生在安装 continuation 与提交系统请求之间的窗口。
                if completion.isCancelled { QLThumbnailGenerator.shared.cancel(request.value) }
            }
        } onCancel: {
            completion.cancel()
            QLThumbnailGenerator.shared.cancel(request.value)
        }
    }

    /// 后台统一编码为PNG后才交给主线程，沿用既有解码位图预算缓存。
    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// 取消与系统回调竞争时仅完成一次；锁内只交换状态，锁外恢复等待者，by AI.Coding。
final class PreviewCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FileCardPreview, Never>?
    private var completed = false
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    /// 取消可能先于 continuation 安装，届时直接完成，禁止再提交系统请求。
    func install(_ value: CheckedContinuation<FileCardPreview, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !completed else { return false }
            continuation = value; return true
        }
        if !accepted { value.resume(returning: .unavailable) }
        return accepted
    }
    /// 成功、失败与取消共用一次性出口；迟到的系统结果不会复活旧预览。
    func finish(_ value: FileCardPreview, cancelling: Bool = false) {
        let pending = lock.withLock { () -> CheckedContinuation<FileCardPreview, Never>? in
            if cancelling { cancelled = true }
            guard !completed else { return nil }
            completed = true
            let pending = continuation; continuation = nil
            return pending
        }
        pending?.resume(returning: value)
    }
    /// 取消立即释放等待任务，不依赖系统稍后是否回调。
    func cancel() { finish(.unavailable, cancelling: true) }
}

/// 请求在创建后不再修改；生成与取消只传递同一身份给系统，不跨线程读写请求属性，by AI.Coding。
private struct ThumbnailRequest: @unchecked Sendable { let value: QLThumbnailGenerator.Request }
