# 评审任务：LocalClip UX 优化（U-01～U-19）独立代码评审

你是独立评审员，不了解作者的思路，也没有看过作者的自检结论。只依据方案和代码本身做判断。**只读评审，不改代码、不提交。**

## 范围
- 仓库：`/Users/ronny/VscodeProjects/rea`，代码在 `macos-app/`。这是 Swift Package，用 SwiftUI 加 AppKit。
- 评审对象：提交区间 `dea4d44..88849dd`，共 12 个提交。查看方式：`git log --oneline dea4d44..88849dd`、`git diff dea4d44..88849dd -- macos-app`。
- 唯一依据：`macos-app/docs/ux-optimization-plan-20261019.md`（下文称"方案"）。方案里的行号对应 dea4d44，代码已经偏移，请按符号定位。不要参考其他对标报告。
- 工作区里以下内容不属于本次评审：`.gitignore` 中新增的 `promo/`，以及未跟踪的 `docs/*.md`。

## 必须遵守的项目规则（见 AGENTS.md）
- 用中文回复。shell 命令遵循 `/Users/ronny/.codex/RTK.md`：命令前加 `rtk`，需要原样执行时用 `rtk proxy <cmd>`。
- 只能跑没有桌面副作用的测试：`rtk proxy bash macos-app/scripts/test.sh --filter <套件>`。跑全量时加 `--skip ImageTextRecognizerTests`，因为 Vision 在这台机器上会挂起，基线也一样。需要私有剪贴板和隐藏窗口的测试，可以加 `LOCALCLIP_NAMED_TEST=1`。
- **禁止**设置 `LOCALCLIP_INTERACTIVE_TESTS=1`。**禁止**以下操作：打开弹窗或可见窗口、激活应用、往真实目标应用粘贴或拖放、启动已安装的应用、打开系统设置。凡是需要这些操作才能确认的问题，标为"需交互验证"，不要实际去验证。
- 已知不稳定：`CommentFeatureTests.excludedDeparturePreservesAllowedQueue` 在全量满载时偶发失败，单独跑能通过。它测的是采集排除逻辑，本次没有改动。

## 方案的硬约束（违反任何一条都算 Critical）
1. 不得丢失任何功能，也不得让任何功能变得不可用。现有每项功能都必须仍能通过三种方式完成：鼠标、仅键盘（Tab 焦点链和快捷键）、VoiceOver。逐项对照方案 §6.1 迁移表、§6.2 不退化清单、§6.3 输入方式表。
2. 以下行为全部保持可用：已有快捷键、双击、拖放（包括把多选整组拖到分类标签、拖出到外部应用）、右键菜单项、Esc 层级、IME 保护、隐藏内容、屏幕共享排除。
3. 任何焦点切换或按键转发都不能吞掉用户输入的字符。所有新增的按键处理都必须先判断 `hasMarkedText()`。
4. 所有新增动画在"减弱动态效果"开启时都要关闭。
5. 不改动 `LocalClipCore` 的存储、查询、schema 和粘贴管线。全仓只允许新建一个文件 `UI/LCStyle.swift`。
6. `ClipCard` 的新参数必须加入 `ClipCard.==`。不能破坏以下性能机制：equatable、局部订阅、只解码可见区、离屏释放。

## 作者自报的跳过和偏差（请判断理由是否成立，不要直接当成问题重复报告）
- U-01 第 2 步（打开面板时焦点直接给结果区）没有启用，因为需要 IME 首键交互验收。打开面板仍然聚焦搜索框。
- U-06 有两处没改，保持原样：
  - 3a：详情 popover 成为 key window 时的按键路由例外。
  - 4：把详情改成子 NSPanel。

  原因是隐藏窗口里无法确认 popover 会不会成为 key。
- U-17 材质透明度保持 0.76，因为离屏渲染无法在真实壁纸上核对对比度。
- U-09：
  - 混合类型的页脚只写"混合内容"，没有写"N 项"，因为拿到项数要改 Core 查询。
  - 图片不显示像素尺寸。
- U-14 只替换了这些：grep 能命中的值、10/11/13/14/15 这几档字号、圆角、阴影、分类选中色。
- 搜索框里的 ⌘C 原来由底栏按钮的 `.keyboardShortcut` 实现。底栏删除后改由 `AppDelegate.copiesRecordFromSearch` 显式保留，IME 组合中不触发。
- `ClipCard` 从 `private` 改成 `internal`，供单测使用。

## 重点风险（请逐项核实，不要只看这些）
- **U-01**：
  - `AppDelegate` 键盘监听中的转发条件：`event.window === panel`、第一响应者是 panel 或 nil、`forwardsToSearch`。
  - `focusSearchSynchronously()` 执行后 `return event`，事件能否进入新的 field editor。
  - `handleEscape()` 有三个入口（SearchField、监听、`ClipPanel.onCancel`），行为是否一致。
  - ⌘W（`performClose` 调用 `onClose`）是否仍然直接关闭面板。
- **U-04/U-05**：
  - 状态槽 popover 在 entry 消失时是否复位 `showingStatusDetail`，会不会残留并拦截结果区按键。
  - 正常状态下 `ignoreDescription` 能否被键盘和 VoiceOver 访问。
  - 多选"合并粘贴"是不是一次点击加一次选择。
- **U-06**：
  - `select(keepDetail:)` 和卡片锚定 popover 的 `Binding.set(false)` 之间是否有竞态，会不会让方向键跟随中途被关掉。
  - `detailSlow` 和 `detailFailed` 是否在以下时机正确复位：取消、换选、隐藏、请求代次变化。
- **U-07**：
  - `dismissHistory` 在 `panelPresented == false` 时直接返回。是否有调用方依赖它在面板未打开时做状态复位？例如 GUI 探针、设置、退出路径。
  - 淡出期间：按键被吞掉、`ignoresMouseEvents`、滚轮由 `panelVisible` 控制。
  - 重新打开时 `panelAnimationGeneration` 和 `panelFade` 能否正确取消。
  - `closePanel(false)` 是否覆盖了所有粘贴和入队路径。
- **U-08**：
  - 三个槽位隐藏时 `passThroughRect` 为 `.zero`。点击槽位时：不会选中相邻卡片、不会开始拖动、不会触发双击粘贴。
  - 页脚文字被固定槽位挤压后是否截断。
  - `.flagsChanged` 监听和角标在面板关闭时是否复位。
- **U-09**：
  - 正文 `fixedSize` 加测高 `textHeight`、`SyntaxCardPreview.sizeThatFits` 对性能和布局的影响。
  - 在 `Task.detached` 中调用 `NSWorkspace.icon(forFile:)` 是否线程安全。
  - 色值卡片的判定条件。
  - 隐藏内容时是否泄露正文。
- **U-10**：
  - `headerColor` 在 `body` 中计算，首次提取主色时在主线程绘制 8×8 位图，开销多大。
  - 静态字典缓存没有上限。
  - 重命名输入框在实色头部上是否可读。
- **U-11**：
  - 队列浮窗不成为 key 时，"结束"按钮能否点击。标为需交互验证，但请从代码层面判断风险。
  - `queueFeedback` 的路由：失败和回退不能丢，耗尽时最后一步的提示不能丢。
  - `sharingType` 和 `ownsHistoryWindow` 的排除逻辑。
- **U-12**：
  - 右键菜单 `.keyboardShortcut`（包括 Space）有没有可能在菜单关闭时被窗口捕获，导致重复执行。
  - ⌘R 在搜索框和查询在途时的行为。
  - 所有原有菜单项是否都还在。
- **U-15/U-16**：
  - 在 ViewModel 里用 `withAnimation` 包裹 `items.removeAll`，配合 LazyHStack 和 equatable 卡片的副作用。
  - 离散滚轮 `withAnimation` 与 `pendingOffset` 累加是否冲突。
- **U-19**：
  - `headerRect` 收窄到标题文字后，tiny 卡片和长标题是否仍能双击重命名。
  - 头部其他区域双击是否改为粘贴。

## 建议执行
1. 通读方案的 §0.2、§3、§4（U-01～U-19）、§6、§7。
2. 逐个提交看 diff，对照方案的"方案 / 保留 / 验收"条目。
3. 跑相关测试，例如：
   ```
   rtk proxy bash macos-app/scripts/test.sh --filter 'CommentUITests|QuitFocusTests|ReviewMetadataLoadingTests|TransformPasteTests'
   LOCALCLIP_NAMED_TEST=1 rtk proxy bash macos-app/scripts/test.sh --filter 'ClipRenameInteractionTests|CategoryDropRoutingTests'
   rtk proxy bash macos-app/scripts/test.sh --skip ImageTextRecognizerTests
   ```
4. 检查新增单测是否真的能拦住回归，要警惕只断言实现细节的测试。

## 输出格式
- 按严重程度排序列出问题：🔴 Critical（违反硬约束，或功能丢失、不可用）、🟡 Warning（与方案不符，或有明确风险）、🔵 Suggestion。
- 每条写明：所属 U-ID、`文件:行号`、具体失败场景（输入或状态 → 错误结果）、置信度（已确认 / 推测）。
- 单独列出：
  - 需交互验证的项，并给出建议的人工验证步骤。
  - 你跑过的测试命令和结果（通过 / 失败 / 跳过数）。
- 最后给出结论：可合入 / 修复后合入 / 不可合入。不要修改代码。
