// 图片文字识别：系统Vision本地识别原图，不联网、不入库；只在用户点击时运行，可取消，by AI.Coding。
import AppKit
import ImageIO
import Vision
import LocalClipCore

public enum ImageTextRecognizer {
    /// 与缩略图解码同一上限，超大原图不解码。
    static let pixelLimit = 40_000_000
    public struct Failure: Error, Equatable { public let message: String }
    /// 尝试所有原始表示与图片文件引用；识别结果按Vision阅读顺序逐行连接。
    public static func recognize(_ payload: ClipboardPayload) async throws -> [String] {
        let image = try decode(payload)
        let box = RequestBox()
        try await withTaskCancellationHandler {
            try await Task.detached { try VNImageRequestHandler(cgImage: image.image, orientation: image.orientation).perform([box.request]) }.value
        } onCancel: { box.request.cancel() }
        try Task.checkCancellation()
        let lines = (box.request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw Failure(message: "未识别到文字") }
        return lines
    }
    /// 逐项优先真实图片文件，再尝试内嵌表示；损坏或超限候选不遮蔽后续有效图，禁用ImageIO全局缓存，by AI.Coding。
    static func decode(_ payload: ClipboardPayload) throws -> (image: CGImage, orientation: CGImagePropertyOrientation) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        var found = false, exceeded = false
        func image(_ source: CGImageSource?) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
            guard let source,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
            guard width <= pixelLimit / height else { exceeded = true; return nil }
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
            // 原图像素不旋转，交由 Vision 按同一帧的 EXIF 方向识别（包含镜像方向）。
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
            return (decoded, orientation)
        }
        for item in payload.items {
            // LC-F03/F04：混合记录也枚举每项合法文件URL，文件图标不能抢占实际图片；不改变fileURLs的全文件契约。
            if let url = item.fileURL, ClipboardPayload.isImageFile(url.path) {
                found = true
                if let value = image(CGImageSourceCreateWithURL(url as CFURL, options)) { return value }
            }
            for type in [SupportedType.png, SupportedType.tiff, SupportedType.jpeg] {
                for representation in item.representations where representation.type == type {
                    found = true
                    if let value = image(CGImageSourceCreateWithData(representation.data as CFData, options)) { return value }
                }
            }
        }
        throw Failure(message: exceeded ? "图片超过 4000 万像素，无法识别" : found ? "图片无法解码" : "所选内容不含图片")
    }
    /// VNRequest不是Sendable；只在后台perform后于同一任务读取结果。
    private final class RequestBox: @unchecked Sendable {
        let request: VNRecognizeTextRequest = {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            return request
        }()
    }
}
