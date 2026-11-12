// 缓存文件副本随历史持久化，原引用失效时按需生成可交给目标应用的文件，by AI.Coding。
import Darwin
import Foundation

enum CachedFileCopy {
    /// 仅采集缓存和临时目录中的普通文件，排除历史库自身及指向其他目录的符号链接。
    static func capture(_ url: URL, limit: Int, storeRoot: URL) -> Data? {
        let file = url.standardizedFileURL
        let resolved = file.resolvingSymlinksInPath()
        let manager = FileManager.default
        let caches = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let roots = [caches, manager.temporaryDirectory, URL(fileURLWithPath: "/private/tmp")]
            .map { $0.resolvingSymlinksInPath().path + "/" }
        // macOS 的 /var 与 /tmp 可经系统链接到 /private，检查源父目录和最终路径。
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        guard roots.contains(where: { parent.hasPrefix($0) && resolved.path.hasPrefix($0) }),
              !resolved.path.hasPrefix(storeRoot.resolvingSymlinksInPath().path + "/") else { return nil }

        // 非阻塞打开并校验文件描述符，避免缓存被替换为链接或管道时跟随链接或卡住采集。
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { return nil }

        // 最多读取原大小加一个字节，文件在采集中增长时也不会超过预算。
        let size = Int(info.st_size)
        do {
            let data = try handle.read(upToCount: size + 1) ?? Data()
            return data.count == size ? data : nil
        } catch { return nil }
    }

    /// 只在原引用不可读时查找副本；旧记录没有副本时仍返回原引用。
    static func restoreIfNeeded(_ original: URL, db: SQLiteConnection, id: ClipID, index: Int, root: URL) throws -> URL? {
        guard !FileManager.default.isReadableFile(atPath: original.path),
              let payload = try read(db, id: id, index: index) else { return nil }
        return try DragFileStorage.write(payload, root: root, fileName: original.lastPathComponent, isFileCopy: true).url
    }

    /// 导出前验证副本的长度及摘要，避免返回损坏的字节。
    static func read(_ db: SQLiteConnection, id: ClipID, index: Int) throws -> VerifiedExportPayload? {
        guard let row = try db.rows("SELECT digest,byteCount,payload FROM file_copies WHERE clipID=? AND itemIndex=?",
                                    [.text(id), .integer(Int64(index))]).first else { return nil }
        return try VerifiedExportPayload(row.data("payload"), expectedDigest: row.text("digest"), expectedByteCount: row.int("byteCount"))
    }
}
