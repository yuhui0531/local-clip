// Finder当前窗口定位与不覆盖原件的文件复制，by AI.Coding。
import AppKit
import Darwin
import LocalClipCore

public struct FinderDestination: Equatable, Sendable {
    public let windowID: Int32
    public let directory: URL
}

@MainActor public final class FinderFileService {
    /// 构造时不访问Finder，不提前触发授权。
    public init() {}
    /// 仅在用户执行文件操作后查询Finder；虚拟目录、无窗口和拒绝授权均不猜目录。
    public func destination() -> Result<FinderDestination, FinderLookupError> {
        let source = """
        with timeout of 3 seconds
            tell application id "com.apple.finder"
                if not frontmost then error "Finder is not frontmost" number -2701
                if (count of Finder windows) is 0 then error "No Finder window" number -2702
                set currentWindow to front Finder window
                if not visible of currentWindow then error "No visible Finder window" number -2702
                set currentFolder to (target of currentWindow) as alias
                return {id of currentWindow, POSIX path of currentFolder}
            end tell
        end timeout
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.unavailable) }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let path = result.atIndex(2)?.stringValue, path.hasPrefix("/"),
              let window = result.atIndex(1), window.int32Value > 0 else {
            let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            return .failure(code == -1743 ? .permission : .unavailable)
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .failure(.unavailable) }
        return .success(.init(windowID: window.int32Value, directory: directory))
    }
}

public enum FinderLookupError: Error, Sendable {
    case permission, unavailable
    public var message: String {
        switch self {
        case .permission: "请允许LocalClip自动化控制Finder，或在Finder中手动粘贴"
        case .unavailable: "请打开Finder的实际文件夹后重试；最近使用、搜索等虚拟位置不可作为目标"
        }
    }
}

public struct FileCopyReport: Sendable {
    public var copied: Int
    public var total: Int
    public var directoryName: String
    public var failure: String?
    public var message: String {
        if let failure { return "已复制\(copied)/\(total)项到“\(directoryName)”；\(failure)" }
        return "已复制\(copied)项文件到“\(directoryName)”"
    }
}

public enum FileObjectCopier {
    /// 在后台复制文件/目录；每项完整落到临时目录后才发布，不覆盖同名对象。
    public static func copy(_ sources: [URL], to directory: URL) -> FileCopyReport {
        let manager = FileManager.default
        var report = FileCopyReport(copied: 0, total: sources.count, directoryName: directory.lastPathComponent, failure: nil)
        let destination = directory.resolvingSymlinksInPath().standardizedFileURL
        let staging = destination.appendingPathComponent(".localclip-copy-\(UUID().uuidString)", isDirectory: true)
        var stagingCreated = false
        do {
            // 所有引用先检查；不在源目录内部建临时文件夹，避免递归复制自身。
            var names = Set<String>()
            for source in sources {
                guard names.insert(source.lastPathComponent.lowercased()).inserted, !exists(destination.appendingPathComponent(source.lastPathComponent), manager: manager) else { report.failure = "存在同名对象，未复制；请先处理冲突"; return report }
                let attributes = try manager.attributesOfItem(atPath: source.path)
                let origin = source.resolvingSymlinksInPath().standardizedFileURL
                if attributes[.type] as? FileAttributeType == .typeDirectory,
                   destination.pathComponents.starts(with: origin.pathComponents) {
                    report.failure = "目标位于源文件夹内部，请选择其他目录"
                    return report
                }
            }
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            stagingCreated = true
            for (index, source) in sources.enumerated() {
                let staged = staging.appendingPathComponent(String(index))
                try manager.copyItem(at: source, to: staged)
                let isFolder = (try manager.attributesOfItem(atPath: staged.path)[.type] as? FileAttributeType) == .typeDirectory
                let target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: isFolder)
                // 同卷独占rename在内核拒绝同名目标，避免检查之后并发出现文件被覆盖。
                guard Darwin.renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                report.copied += 1
            }
        } catch {
            let code = (error as NSError).code
            report.failure = code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError
                ? "原文件已移动或删除，未完成项目请重新复制"
                : "文件复制未完成，请检查访问权限、磁盘空间或同名冲突"
        }
        // 只回收本次创建的临时副本，不回滚已交付文件或触碰原件。
        if stagingCreated {
            do { try manager.removeItem(at: staging) }
            catch { report.failure = (report.failure.map { $0 + "；" } ?? "") + "本次临时副本未回收" }
        }
        return report
    }

    /// 包括失效符号链接在内的已有目录项都不能覆盖。
    private static func exists(_ url: URL, manager: FileManager) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)) != nil
    }
}
