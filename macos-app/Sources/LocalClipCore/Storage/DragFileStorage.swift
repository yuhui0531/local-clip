// 同步请求时图片文件输出；actor入口和只读导出句柄复用原有空间/去重/回收规则，by AI.Coding。
import Foundation

enum DragFileStorage {
    /// 只在目标实际索取URL时写出独立的完整原始字节，不影响历史配额或原始表示。
    static func write(_ data: Data, root: URL, fileName: String) throws -> (url: URL, created: Bool) {
        guard data.count <= 50 * MiB else { throw StoreError.invalidSettings }
        return try write(VerifiedExportPayload(data), root: root, fileName: fileName)
    }
    static func write(_ payload: VerifiedExportPayload, root: URL, fileName: String) throws -> (url: URL, created: Bool) {
        let data = payload.data
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.hasPrefix("."),
              ["png", "tiff", "jpg"].contains(URL(fileURLWithPath: fileName).pathExtension), data.count <= 50 * MiB else { throw StoreError.invalidSettings }
        let folder = root.appendingPathComponent("DragFiles/" + payload.digest, isDirectory: true)
        let file = folder.appendingPathComponent(fileName)
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { return (file, false) }
        // LC-F02：不同名称必须独立写入；已接受文件可被外部原地编辑，不能共享inode或用它作新导出的数据源。
        // 同名旧路径继续复用且不覆盖；新路径仍以数据库校验后的原始字节进行空间预检和原子写入。
        let filesystem = try fm.attributesOfFileSystem(forPath: root.path)
        guard let free = filesystem[.systemFreeSize] as? NSNumber,
              free.int64Value > Int64(data.count) * 2 + 8 * MiB else { throw StoreError.diskFull }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return (file, true)
    }
    /// 仅清理本次新建路径，拒绝自有拖出目录以外的文件。
    static func remove(_ files: [URL], root: URL) throws {
        let fm = FileManager.default
        let root = root.appendingPathComponent("DragFiles").standardizedFileURL
        for file in files {
            let folder = file.deletingLastPathComponent().standardizedFileURL
            guard folder.deletingLastPathComponent().path == root.path,
                  folder.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path,
                  folder.lastPathComponent.count == 64,
                  folder.lastPathComponent.allSatisfy({ "0123456789abcdef".contains($0) }),
                  file.standardizedFileURL.deletingLastPathComponent().path == folder.path else { throw StoreError.invalidSettings }
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            if fm.fileExists(atPath: folder.path), try fm.contentsOfDirectory(atPath: folder.path).isEmpty { try fm.removeItem(at: folder) }
        }
    }
}
