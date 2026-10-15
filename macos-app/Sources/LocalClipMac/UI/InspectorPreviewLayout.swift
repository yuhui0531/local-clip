// 详情预览的同步高度计算有固定输入上限，全文仍交给可滚动的原生文本视图，by AI.Coding。
import AppKit

enum InspectorPreviewLayout {
    /// 短文保持紧凑；超过2048个UTF-16单元直接使用最大视口，避免反复排版完整长文。
    static func height(for content: NSAttributedString) -> CGFloat {
        guard content.length <= 2_048 else { return 200 }
        // 同时限制测量输入和目标高度，不能在无界全文测量后才裁剪结果。
        let measured = content.boundingRect(with: CGSize(width: 444, height: 180),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(200, max(52, ceil(measured) + 20))
    }
}
