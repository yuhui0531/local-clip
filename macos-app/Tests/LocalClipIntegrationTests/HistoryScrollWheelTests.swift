// 滚轮方向、边界与连续输入的纯状态回归，不产生桌面交互，by AI.Coding。
import Testing
@testable import LocalClipMac

@MainActor struct HistoryScrollWheelTests {
    /// 普通滚轮两种轴向使用相同的步长和累积位置，避免动画尚未完成时丢失输入，by AI.Coding。
    @Test func discreteAxesAccumulateBeforeRendering() {
        let state = HistoryScrollWheel.State()
        state.update(.init(offset: 300, maximum: 1000, viewport: 400))
        #expect(state.targetOffset(horizontal: -2, vertical: 0, precise: false) == 372)
        #expect(state.targetOffset(horizontal: 0, vertical: -2, precise: false) == 444)
        #expect(state.targetOffset(horizontal: 1, vertical: 0, precise: false) == 408)
    }

    /// 触控板横向手势交还系统惯性，纵向映射逐像素跟手，不放大增量，by AI.Coding。
    @Test func preciseHorizontalStaysNative() {
        let state = HistoryScrollWheel.State()
        state.update(.init(offset: 300, maximum: 1000, viewport: 400))
        #expect(state.targetOffset(horizontal: -2, vertical: 0, precise: false) == 372)
        #expect(state.targetOffset(horizontal: -5, vertical: 1, precise: true) == nil)
        #expect(state.targetOffset(horizontal: 1, vertical: -5, precise: true) == 305)
    }

    /// 边界与内容尺寸变化以最新几何为准，不沿用过期动画目标，by AI.Coding。
    @Test func clampsAndResetsWhenContentShrinks() {
        let state = HistoryScrollWheel.State()
        state.update(.init(offset: 30, maximum: 100, viewport: 400))
        #expect(state.targetOffset(horizontal: 2, vertical: 0, precise: false) == 0)
        #expect(state.targetOffset(horizontal: -10, vertical: 0, precise: false) == 100)
        state.update(.init(offset: 20, maximum: 40, viewport: 400))
        #expect(state.targetOffset(horizontal: 0, vertical: -0.25, precise: false) == 29)
    }

    /// 无效或静止输入不消费事件，也不污染后续有效滚动目标，by AI.Coding。
    @Test func invalidInputDoesNotPoisonTarget() {
        let state = HistoryScrollWheel.State()
        state.update(.init(offset: 300, maximum: 1000, viewport: 400))
        #expect(state.targetOffset(horizontal: .nan, vertical: 1, precise: false) == nil)
        #expect(state.targetOffset(horizontal: 0, vertical: .infinity, precise: true) == nil)
        #expect(state.targetOffset(horizontal: 0, vertical: 0, precise: false) == nil)
        #expect(state.targetOffset(horizontal: 0, vertical: -1, precise: false) == 336)
    }
}
