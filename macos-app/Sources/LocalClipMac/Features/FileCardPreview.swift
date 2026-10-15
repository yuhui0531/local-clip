// 历史文件卡片按内容生成预览，不以文件后缀或截断路径决定能否展示，by AI.Coding。
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum FileCardPreview: Sendable {
    case image(Data), text(String), unavailable

    /// 图片优先按真实内容解码，文本保留原有开头/代码预览，其余交给文档缩略图。
    static func render(fileAt url: URL) async -> Self {
        let local = await Task.detached(priority: .utility) { localPreview(url) }.value
        guard !Task.isCancelled else { return .unavailable }
        if let local { return local }
        return await documentPreview(url)
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
        if let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) {
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
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 800, height: 800), scale: 1, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation, representation.type == .thumbnail, let data = png(representation.cgImage) else {
                    continuation.resume(returning: .unavailable); return
                }
                continuation.resume(returning: .image(data))
            }
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
