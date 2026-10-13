// 图片文字识别：系统Vision本地识别原图，不联网、不入库；只在用户点击时运行，可取消，by AI.Coding。
import AppKit
import ImageIO
import Vision
import LocalClipCore

public enum ImageTextRecognizer {
    /// 与缩略图解码同一上限，超大原图不解码。
    static let pixelLimit = 40_000_000
    public struct Failure: Error, Equatable { public let message: String }
    /// 按原始表示优先级取第一张图；识别结果按Vision阅读顺序逐行连接。
    public static func recognize(_ payload: ClipboardPayload) async throws -> [String] {
        guard let data = [SupportedType.png, SupportedType.tiff, SupportedType.jpeg].lazy.compactMap({ type in
            payload.items.lazy.compactMap { $0.representations.first { $0.type == type }?.data }.first }).first else { throw Failure(message: "所选内容不含图片") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure(message: "图片无法解码") }
        guard width > 0, height > 0, width <= pixelLimit / height else { throw Failure(message: "图片超过 4000 万像素，无法识别") }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "图片无法解码") }
        let box = RequestBox()
        try await withTaskCancellationHandler {
            try await Task.detached { try VNImageRequestHandler(cgImage: image).perform([box.request]) }.value
        } onCancel: { box.request.cancel() }
        try Task.checkCancellation()
        let lines = (box.request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw Failure(message: "未识别到文字") }
        return lines
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
