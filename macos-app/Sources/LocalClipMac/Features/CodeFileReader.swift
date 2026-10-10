// 有界、严格解码的代码文件读取；任何项目失败均保留整组原文件，by AI.Coding。
import Foundation
import Darwin

public enum CodeFileReadError: Error, Equatable, Sendable {
    case unsupported, unavailable, tooLarge, binaryOrEncoding, changed
}
public struct CodeFileContents: Sendable {
    public let text: String
    fileprivate let identities: [CodeFileReader.Identity]
    /// 文件读完后再次核对原路径，防止文本与已替换的文件引用不一致，by AI.Coding。
    public func isCurrent() -> Bool { identities.allSatisfy { $0.isCurrent() } }
}
public enum CodeFileReader {
    public static let perFileLimit = 4 * 1024 * 1024
    public static let totalLimit = 8 * 1024 * 1024
    public static let extensions: Set<String> = ["json", "jsonc", "java", "py", "pyw", "js", "mjs", "cjs", "jsx", "ts", "tsx", "yaml", "yml", "xml", "html", "htm", "css", "scss", "sass", "sh", "bash", "zsh", "swift", "c", "h", "cc", "cpp", "hpp", "cs", "go", "rs", "rb", "php", "sql", "toml", "md", "dockerfile"]
    struct Identity: Sendable, Equatable {
        let url: URL, device: UInt64, inode: UInt64, size: Int64, seconds: Int64, nanos: Int64
        init(url: URL, info: stat) {
            self.url = url; device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
            size = info.st_size; seconds = Int64(info.st_mtimespec.tv_sec); nanos = Int64(info.st_mtimespec.tv_nsec)
        }
        func isCurrent() -> Bool {
            var info = stat()
            return url.withUnsafeFileSystemRepresentation { path in
                guard let path, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
                return self == Identity(url: url, info: info)
            }
        }
    }
    /// 顺序与每份文本完全保留；多文件仅追加明确的换行分隔，不裁剪或格式化正文，by AI.Coding。
    public static func read(_ urls: [URL]) throws -> String { try snapshot(urls).text }
    public static func snapshot(_ urls: [URL]) throws -> CodeFileContents {
        guard !urls.isEmpty, urls.count <= 64 else { throw CodeFileReadError.unsupported }
        var texts: [String] = [], identities: [Identity] = [], total = 0
        for url in urls {
            guard url.isFileURL, [nil, "", "localhost"].contains(url.host), extensions.contains(url.pathExtension.lowercased()) || url.lastPathComponent.lowercased() == "dockerfile" else { throw CodeFileReadError.unsupported }
            let fd = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) } ?? -1 }
            guard fd >= 0 else { throw CodeFileReadError.unavailable }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw CodeFileReadError.unavailable }
            guard before.st_size >= 0, before.st_size <= perFileLimit, total + Int(before.st_size) <= totalLimit else { throw CodeFileReadError.tooLarge }
            let identity = Identity(url: url, info: before)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CodeFileReadError.unavailable }
                if count == 0 { break }
                guard data.count + count <= perFileLimit, total + data.count + count <= totalLimit else { throw CodeFileReadError.tooLarge }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(fd, &after) == 0, identity == Identity(url: url, info: after), Int64(data.count) == before.st_size, identity.isCurrent() else { throw CodeFileReadError.changed }
            texts.append(try decode(data)); identities.append(identity); total += data.count
        }
        let result = CodeFileContents(text: texts.joined(separator: "\n"), identities: identities)
        guard result.isCurrent() else { throw CodeFileReadError.changed }
        return result
    }
    /// 只接受严格UTF-8或显式BOM的UTF-16/32；回编码一致才接受，避免替换字符与二进制误判，by AI.Coding。
    private static func decode(_ input: Data) throws -> String {
        let bytes = [UInt8](input.prefix(4))
        var skip = 0; var encoding = String.Encoding.utf8
        if bytes.starts(with: [0x00,0x00,0xfe,0xff]) { skip = 4; encoding = .utf32BigEndian }
        else if bytes.starts(with: [0xff,0xfe,0x00,0x00]) { skip = 4; encoding = .utf32LittleEndian }
        else if bytes.starts(with: [0xef,0xbb,0xbf]) { skip = 3 }
        else if bytes.starts(with: [0xfe,0xff]) { skip = 2; encoding = .utf16BigEndian }
        else if bytes.starts(with: [0xff,0xfe]) { skip = 2; encoding = .utf16LittleEndian }
        let body = Data(input.dropFirst(skip))
        guard let text = String(data: body, encoding: encoding), text.data(using: encoding) == body,
              !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9,10,13].contains($0.value)) || $0.value == 127 }) else { throw CodeFileReadError.binaryOrEncoding }
        return text
    }
}
