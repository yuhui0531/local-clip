// ImageIO 下采样，预览失败不损失原始数据，by AI.Coding。
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LocalClipCore
public enum ThumbnailResult: Sendable { case image(Data), unavailable, tooManyPixels }
public enum ThumbnailRenderer {
    /// 按原顺序尝试图片表示；某一格式损坏不遮蔽其它有效格式，超过40MP仍不解码。
    public static func render(_ payload: ClipboardPayload) -> ThumbnailResult {
        var exceededPixelLimit = false
        for representation in payload.items.flatMap(\.representations) where [SupportedType.png, SupportedType.tiff, SupportedType.jpeg].contains(representation.type) {
            switch render(representation.data) {
            case .image(let data): return .image(data)
            case .tooManyPixels: exceededPixelLimit = true
            case .unavailable: continue
            }
        }
        return exceededPixelLimit ? .tooManyPixels : .unavailable
    }
    /// 图片文件引用直接从磁盘下采样；文件随时可能变更或删除，结果不入库，by AI.Coding。
    public static func render(fileAt url: URL) -> ThumbnailResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .unavailable }
        return render(source)
    }
    private static func render(_ data: Data) -> ThumbnailResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .unavailable }
        return render(source)
    }
    /// 只派生第一帧的有界缩略图，不修改原始图片或多页TIFF。
    private static func render(_ source: CGImageSource) -> ThumbnailResult {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return .unavailable }
        guard width.int64Value > 0, height.int64Value > 0, width.int64Value <= 40_000_000 / height.int64Value else { return .tooManyPixels }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 800,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .unavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return .unavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return .unavailable }
        return .image(output as Data)
    }
}
/// 文本文件引用只读开头一段作卡片预览；按内容判断而非扩展名，非UTF-8或含NUL视为不可预览，卡片退回文件样式，by AI.Coding。
public enum TextFilePreview {
    /// 扩展名的系统类型会被第三方应用改写，.tsx/.vue等也没有系统类型；这里只排除图片与RTF，其余交给read按内容判断。
    public static func isCandidate(_ path: String) -> Bool {
        !ClipboardPayload.isImageFile(path) && !["rtf", "rtfd"].contains((path as NSString).pathExtension.lowercased())
    }
    public static func read(_ url: URL, limit: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty, !data.contains(0) else { return nil }
        // 只有读满上限时截断处才可能切开多字节字符，最多回退3字节再按UTF-8校验。
        for trim in 0...(data.count == limit ? min(3, data.count - 1) : 0) {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) { return text }
        }
        return nil
    }
}
public actor DerivedContentService {
    private let store: HistoryStore
    private let clock: any ClipClock
    private var requests: [ClipID: (UUID, Task<ThumbnailResult, Never>)] = [:]
    /// 派生读取与调用方共用时钟；不改变缩略图缓存和持久化行为，by AI.Coding。
    public init(store: HistoryStore, clock: any ClipClock = SystemClock()) { self.store = store; self.clock = clock }
    /// 相同可见项目共享正在生成的任务；不缓存失效 UI 图片。
    public func thumbnail(id: ClipID) async -> ThumbnailResult {
        if let existing = requests[id] { return await existing.1.value }
        let generation = UUID()
        let task = Task<ThumbnailResult, Never> {
            do {
                if let cached = try await store.thumbnail(id: id, at: clock.now()) { return .image(cached) }
                try Task.checkCancellation()
                let detail = try await store.detail(id: id, at: clock.now())
                let result = await Task.detached(priority: .utility) { ThumbnailRenderer.render(detail.payload) }.value
                if Task.isCancelled { return .unavailable }
                // 提交前复查存在和版本，不能把已删内容恢复成派生行。
                if case .image(let data) = result { _ = try await store.cacheThumbnail(id: id, revision: detail.revision, data: data) }
                // 生成后仅复查可见性，避免再读取/哈希一遍大图的全部原始表示。
                _ = try await store.metadata(id: id, at: clock.now())
                return result
            } catch { return .unavailable }
        }
        requests[id] = (generation, task)
        let value = await task.value
        if requests[id]?.0 == generation { requests[id] = nil }
        // 离屏卡片的取消是异步发出的，可能晚于同一卡片重新可见后的新请求；调用方自身未取消时重新生成，不把别人的取消显示成失败，by AI.Coding。
        if case .unavailable = value, task.isCancelled, !Task.isCancelled { return await thumbnail(id: id) }
        return value
    }
    /// 不可见/删除时取消派生；提交端仍有独立版本验证。
    public func cancel(id: ClipID) { requests[id]?.1.cancel(); requests[id] = nil }
}
