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
    /// 只派生第一帧的有界缩略图，不修改原始图片或多页TIFF。
    private static func render(_ data: Data) -> ThumbnailResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
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
public actor DerivedContentService {
    private let store: HistoryStore
    private var requests: [ClipID: (UUID, Task<ThumbnailResult, Never>)] = [:]
    public init(store: HistoryStore) { self.store = store }
    /// 相同可见项目共享正在生成的任务；不缓存失效 UI 图片。
    public func thumbnail(id: ClipID) async -> ThumbnailResult {
        if let existing = requests[id] { return await existing.1.value }
        let generation = UUID()
        let task = Task<ThumbnailResult, Never> {
            do {
                if let cached = try await store.thumbnail(id: id, at: SystemClock().now()) { return .image(cached) }
                try Task.checkCancellation()
                let detail = try await store.detail(id: id, at: SystemClock().now())
                let result = await Task.detached(priority: .utility) { ThumbnailRenderer.render(detail.payload) }.value
                if Task.isCancelled { return .unavailable }
                // 提交前复查存在和版本，不能把已删内容恢复成派生行。
                if case .image(let data) = result { _ = try await store.cacheThumbnail(id: id, revision: detail.revision, data: data) }
                // 生成后仅复查可见性，避免再读取/哈希一遍大图的全部原始表示。
                _ = try await store.metadata(id: id, at: SystemClock().now())
                return result
            } catch { return .unavailable }
        }
        requests[id] = (generation, task)
        let value = await task.value
        if requests[id]?.0 == generation { requests[id] = nil }
        return value
    }
    /// 不可见/删除时取消派生；提交端仍有独立版本验证。
    public func cancel(id: ClipID) { requests[id]?.1.cancel(); requests[id] = nil }
}
