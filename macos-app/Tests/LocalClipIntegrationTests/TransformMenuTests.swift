// 两列转换菜单的静态布局、键盘选择和提交语义；不展示窗口、不触碰系统剪贴板，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct TransformMenuTests {
    /// 全部转换逐行左到右且只出现一次；奇数末行保留单项，禁用项不改变位置，by AI.Coding。
    @Test func twoColumnsKeepAllOptionsInOrder() {
        let menu = TransformMenuController(available: [.uppercase], reason: nil, allowsCopyOnly: true) { _, _ in }
        #expect(menu.rows.flatMap { $0 } == TextTransform.allCases)
        #expect(menu.rows.count == 13)
        #expect(menu.rows.dropLast().allSatisfy { $0.count == 2 })
        #expect(menu.rows.first == [.markdownCodeBlock, .dedent])
        #expect(menu.rows.last == [.colorToHex])
        #expect(menu.window == nil)
    }

    /// 仅用几何计算核对小屏、负坐标副屏和屏幕边缘；菜单完整留在可用区域，by AI.Coding。
    @Test func menuStaysOnItsScreen() {
        for screen in [NSRect(x: 0, y: 24, width: 1440, height: 876), NSRect(x: -1280, y: -200, width: 1280, height: 400)] {
            for point in [screen.origin, NSPoint(x: screen.maxX, y: screen.maxY), NSPoint(x: screen.midX, y: screen.midY)] {
                let frame = TransformMenuController.frame(at: point, visibleFrame: screen, rowCount: 13, hasReason: true)
                #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
                #expect(frame.width == 500)
                #expect(frame.height <= screen.height - 16)
            }
        }
    }

    /// 隐藏的父子窗口只验证归属与按键路由，不orderFront、不激活任何应用，by AI.Coding。
    @Test func menuWindowKeepsHistoryOwnershipAndOwnKeyboard() {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let history = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let menu = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        history.addChildWindow(menu, ordered: .above)
        defer { history.removeChildWindow(menu) }
        #expect(!history.isVisible && !menu.isVisible)
        #expect(AppDelegate.ownsHistoryWindow(menu, panel: history, settings: nil, feedback: nil,
            showingDetail: false, showingCategoryEditor: false, showingFilters: false))
        #expect(!AppDelegate.routesHistoryShortcuts(menu, panel: history, confirming: false, hasModal: false))
    }

    /// 初始高亮与上下同列保持固定顺序；Tab仍能遍历全部可用项，by AI.Coding。
    @Test func keyboardNavigationSkipsUnavailableOptions() {
        let menu = TransformMenuController(available: [.markdownCodeBlock, .stripLineNumbers, .formatJSON], reason: nil, allowsCopyOnly: true) { _, _ in }
        #expect(menu.highlighted == .markdownCodeBlock)
        menu.move(keyCode: 125); #expect(menu.highlighted == .stripLineNumbers)
        menu.move(keyCode: 124); #expect(menu.highlighted == .formatJSON)
        menu.move(keyCode: 124); #expect(menu.highlighted == .formatJSON)
        menu.move(keyCode: 48); #expect(menu.highlighted == .markdownCodeBlock)
        menu.move(keyCode: 48, backwards: true); #expect(menu.highlighted == .formatJSON)
        menu.move(keyCode: 123); #expect(menu.highlighted == .stripLineNumbers)
        menu.move(keyCode: 126); #expect(menu.highlighted == .markdownCodeBlock)
    }

    /// 禁用项及Escape取消不能提交；关闭多次也只发出一次dismiss，by AI.Coding。
    @Test func disabledChoicesAndEscapeDoNotDispatch() throws {
        var choices = 0, dismissals = 0
        let menu = TransformMenuController(available: [], reason: "所选内容不含文本，无法转换", allowsCopyOnly: true) { _, _ in choices += 1 }
        menu.onDismiss = { dismissals += 1 }
        menu.choose(.uppercase, modifiers: [.option]); menu.move(keyCode: 125)
        #expect(choices == 0); #expect(menu.highlighted == nil); #expect(dismissals == 0)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(menu.handleKey(escape))
        menu.close(); menu.choose(.uppercase, modifiers: [])
        #expect(choices == 0); #expect(dismissals == 1)
    }

    /// 提交以当前事件的⌥为准，默认复制模式不引入另一种动作；同菜单最多提交一次，by AI.Coding。
    @Test(arguments: [false, true]) func choiceReadsCurrentModifiers(allowsCopyOnly: Bool) {
        for option in [false, true] {
            var choices: [(TextTransform, Bool)] = []
            let menu = TransformMenuController(available: [.uppercase], reason: nil, allowsCopyOnly: allowsCopyOnly) { choices.append(($0, $1)) }
            menu.optionHeld = !option
            menu.choose(.uppercase, modifiers: option ? [.option] : [])
            menu.choose(.uppercase, modifiers: [])
            #expect(choices.count == 1)
            #expect(choices.first?.0 == .uppercase)
            #expect(choices.first?.1 == (allowsCopyOnly && option))
        }
    }

    /// 相邻列同行不可用时直接到最近可用项，仍保留双列固定位置及回程。
    @Test func horizontalNavigationFindsNearestEnabledRow() {
        let menu = TransformMenuController(available: [.markdownCodeBlock, .formatJSON], reason: nil, allowsCopyOnly: true) { _, _ in }
        #expect(menu.highlighted == .markdownCodeBlock)
        menu.move(keyCode: 124); #expect(menu.highlighted == .formatJSON)
        menu.move(keyCode: 123); #expect(menu.highlighted == .markdownCodeBlock)
    }
}
