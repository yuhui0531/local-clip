// 解码缩略图的有界LRU：成本按像素估算，避免压缩图片很小但解码后常驻巨大内存，by AI.Coding。
import AppKit

@MainActor final class ThumbnailMemoryCache {
    private struct Entry { let image: NSImage; let bytes: Int }
    let byteLimit: Int
    private(set) var byteCount = 0
    private var entries: [NSString: Entry] = [:]
    private var order: [NSString] = []

    /// 保留原来的数量上限，同时让像素成本严格受预算限制。
    init(byteLimit: Int = 16 * 1024 * 1024) { self.byteLimit = max(0, byteLimit) }

    /// 命中仅更新LRU，不额外解码，也不改变图片对象身份。
    func object(forKey key: NSString) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry.image
    }

    /// 同时计算编码字节和解码像素，过大项仍可显示，只是不进入共享缓存。
    func setObject(_ image: NSImage, forKey key: NSString, encodedBytes: Int = 0) {
        remove(key)
        let pixels = image.representations.reduce(0) { total, rep in
            let row = max(rep.pixelsWide * 4, (rep as? NSBitmapImageRep)?.bytesPerRow ?? 0)
            return total + row * rep.pixelsHigh
        }
        let cost = max(1, pixels) + max(0, encodedBytes)
        guard cost <= byteLimit else { return }
        while byteCount + cost > byteLimit || entries.count >= 120, let oldest = order.first { remove(oldest) }
        entries[key] = Entry(image: image, bytes: cost); order.append(key); byteCount += cost
    }

    /// 隐藏后只保留最后一屏，重开不需要重复解码；不销毁界面或更改历史数据。
    func retainOnly(_ ids: Set<String>) {
        for key in order where !ids.contains(key as String) { remove(key) }
    }

    /// 外部文件引用版本变化时只清除对应预览，by AI.Coding。
    func removeObject(forKey key: NSString) { remove(key) }

    /// 替换、淘汰共用计费出口。
    private func remove(_ key: NSString) {
        if let entry = entries.removeValue(forKey: key) { byteCount -= entry.bytes }
        order.removeAll { $0 == key }
    }
}
