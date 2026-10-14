// 文件引用预览的轻量版本；不改变历史引用，不复制文件正文，by AI.Coding。
import Foundation
import Darwin

struct FileReferencePreviewVersion: Equatable, Sendable {
    let references: [URL]
    let files: [CodeFileReader.Identity]
    let changes: [Int64]

    /// 必须在后台调用：慢卷stat和权限检查不阻塞主线程；链接按既有预览规则跟随目标。
    static func read(_ urls: [URL]) -> Self? {
        guard !urls.isEmpty else { return nil }
        var files: [CodeFileReader.Identity] = [], changes: [Int64] = []
        for url in urls {
            guard url.isFileURL else { return nil }
            let resolved = url.resolvingSymlinksInPath()
            var info = stat()
            let readable = resolved.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, R_OK) == 0
            }
            guard readable else { return nil }
            files.append(.init(url: resolved, info: info))
            changes.append(Int64(info.st_ctimespec.tv_sec)); changes.append(Int64(info.st_ctimespec.tv_nsec))
        }
        return .init(references: urls, files: files, changes: changes)
    }

    /// 读取完成再查一次，避免把更新前的正文缓存为更新后的身份。
    func isCurrent() -> Bool { Self.read(references) == self }
}
