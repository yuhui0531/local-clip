// 图片卡片明确区分加载、成功、失败及尺寸限制，原始表示始终由存储层保留，by AI.Coding。
import AppKit
import SwiftUI

enum ThumbnailPreviewState {
    case loading, ready(NSImage), failed, tooLarge

    /// 生成器或平台图像解码失败均结束加载，不让卡片永久显示等待状态。
    init(_ result: ThumbnailResult) {
        switch result {
        case .image(let data): self = NSImage(data: data).map(Self.ready) ?? .failed
        case .unavailable: self = .failed
        case .tooManyPixels: self = .tooLarge
        }
    }
    var image: NSImage? { if case .ready(let image) = self { image } else { nil } }
    var label: String {
        switch self {
        case .loading: "正在加载预览"
        case .ready: "图片预览"
        case .failed: "无法生成预览"
        case .tooLarge: "图片尺寸过大"
        }
    }
}

/// 复用卡片原有色彩与尺寸；紧凑布局也通过辅助功能与悬停提示说明状态。
struct ThumbnailPreview: View {
    let state: ThumbnailPreviewState
    let tint: Color
    let compact: Bool

    var body: some View {
        ZStack {
            // 透明图片衬中性底色，不随类型色偏色，by AI.Coding。
            Rectangle().fill(state.image != nil ? Color.primary.opacity(0.05) : tint.opacity(0.06))
            switch state {
            case .ready(let image):
                Image(nsImage: image).resizable().scaledToFit().padding(compact ? 2 : 4)
                    .accessibilityLabel(state.label)
            case .loading:
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    if !compact { Text(state.label).font(.system(size: 12)) }
                }.foregroundStyle(.secondary).accessibilityElement(children: .ignore).accessibilityLabel(state.label)
            case .failed, .tooLarge:
                VStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: compact ? 14 : 28, weight: .light))
                    if !compact {
                        Text(state.label).font(.system(size: 12))
                        Text("原始数据已保留").font(.system(size: 10))
                    }
                }.foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityElement(children: .ignore).accessibilityLabel(state.label + "，原始数据已保留")
            }
        }.help(state.label)
    }
}
