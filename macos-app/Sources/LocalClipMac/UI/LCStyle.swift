// 视觉规范：字号、圆角、间距与卡片阴影的唯一来源，供历史面板、编辑、确认与设置复用，by AI.Coding。
import SwiftUI

enum LCStyle {
    /// 字号：caption 只用于角标与徽标；代码正文上限另见 codeMax。
    enum FontSize {
        static let caption: CGFloat = 10
        static let meta: CGFloat = 11
        static let body: CGFloat = 13
        static let title: CGFloat = 14
        static let heading: CGFloat = 15
        static let codeMax: CGFloat = 12.5
    }
    /// 圆角：pill 直接使用 Capsule。
    enum Radius {
        static let panel: CGFloat = 16
        static let card: CGFloat = 12
        static let control: CGFloat = 6
    }
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }
    /// 卡片阴影：默认与悬停两档。
    struct Shadow {
        let opacity: Double, radius: CGFloat, y: CGFloat
        static let card = Shadow(opacity: 0.08, radius: 4, y: 2)
        static let hover = Shadow(opacity: 0.14, radius: 8, y: 4)
    }
}
