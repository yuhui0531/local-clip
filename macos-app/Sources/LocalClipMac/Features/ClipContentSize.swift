// N-01：图片/文件记录的字节大小展示；只读元数据（单个本地图片文件另读头部取像素），不读正文、不下载云端内容、不改原文件，by AI.Coding。
import Darwin
import Foundation
import LocalClipCore

/// 图片像素尺寸（已按EXIF方向校正），by AI.Coding。
struct PixelSize: Equatable, Sendable {
    let width, height: Int
    var label: String { "\(width) × \(height)" }
}

enum ClipContentSize: Equatable, Sendable {
    case loading
    /// 已保存的主图片表示字节数（采集时内容，不随外部变化）。
    case stored(bytes: Int64, items: Int, pixels: PixelSize? = nil)
    /// 文件引用的查询时逻辑大小；目录与不可访问项单独计数，不递归。
    case files(known: Int64, count: Int, unknown: Int, folders: Int, pixels: PixelSize? = nil)
    case unknown

    /// 后台调用：每个引用一次 stat（与既有文件预览相同的链接跟随规则）；目录不递归、不读内容。
    static func measure(_ urls: [URL]) -> ClipContentSize {
        guard !urls.isEmpty else { return .unknown }
        var known: Int64 = 0, unknown = 0, folders = 0, dataless = false
        for url in urls {
            var info = stat()
            let found = url.isFileURL && url.resolvingSymlinksInPath().withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &info) == 0 } ?? false
            }
            guard found else { unknown += 1; continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                dataless = dataless || info.st_flags & UInt32(SF_DATALESS) != 0
                let (sum, overflow) = known.addingReportingOverflow(Int64(info.st_size))
                if info.st_size < 0 || overflow { unknown += 1 } else { known = sum }
            case S_IFDIR: folders += 1
            default: unknown += 1
            }
        }
        // 单个可读图片文件只读头部取像素，不解码；未下载的云端占位文件跳过，避免触发下载，by AI.Coding。
        let pixels = urls.count == 1 && unknown == 0 && folders == 0 && !dataless && ClipboardPayload.isImageFile(urls[0].path) ? ThumbnailRenderer.pixelSize(fileAt: urls[0]) : nil
        return .files(known: known, count: urls.count, unknown: unknown, folders: folders, pixels: pixels)
    }
    /// 单张图片或单个图片文件的像素尺寸；多张/多文件不给，by AI.Coding。
    var pixels: PixelSize? {
        switch self {
        case let .stored(_, 1, pixels): return pixels
        case let .files(_, 1, 0, 0, pixels): return pixels
        default: return nil
        }
    }
    /// 详情与辅助功能用：有像素时为“W × H · 大小”。
    var label: String? {
        guard let size = bytesLabel else { return nil }
        return pixels.map { "\($0.label) · \(size)" } ?? size
    }

    /// 次级元信息文字（不含像素）；loading 不占位，未知明确写出，已知 0 仍显示数字。
    var bytesLabel: String? {
        switch self {
        case .loading: return nil
        case .unknown: return "大小未知"
        case let .stored(bytes, items, _):
            return items > 1 ? "\(items) 张 · 合计 \(HistoryViewModel.bytes(bytes))" : HistoryViewModel.bytes(bytes)
        case let .files(known, count, unknown, folders, _):
            let measured = count - unknown - folders
            if count == 1 { return folders == 1 ? "文件夹 · 大小未知" : unknown == 1 ? "大小未知" : HistoryViewModel.bytes(known) }
            if measured == count { return "\(count) 项 · 合计 \(HistoryViewModel.bytes(known))" }
            if measured == 0 { return "\(count) 项 · 大小未知" }
            return "\(count) 项 · 部分未知（已知 \(HistoryViewModel.bytes(known))）"
        }
    }

    /// 说明计量口径：图片为保存内容，文件为查询时大小，目录不含内部文件。
    var detail: String? {
        switch self {
        case .stored: return "已保存图片内容的大小" + pixelNote
        case .files(_, _, _, let folders, _): return folders > 0 ? "文件当前大小（读取时查询，文件夹不统计内部文件）" : "文件当前大小（读取时查询）" + pixelNote
        case .unknown: return "无法读取大小，原文件可能已移动、删除或无访问权限"
        case .loading: return nil
        }
    }
    private var pixelNote: String { pixels == nil ? "" : "，像素尺寸为原图" }
}
