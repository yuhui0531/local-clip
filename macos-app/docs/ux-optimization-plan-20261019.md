# LocalClip UX 优化最终方案（2026-10-19）

> **本文是后续 UX 优化的唯一实施依据**，取代以下三份评审输入：
> - `ux-paste-benchmark-20261019.md`（本仓库，Claude 版对标报告）
> - `ux_upgrade_report.md`（外部报告 A）
> - `localclip-vs-paste-uiux-plan-20261019.md`（外部报告 B）
>
> 基线：`main@dea4d44`，LocalClip 0.3.45（构建67）。本次只做评审与方案，未改任何代码。
> 证据边界：LocalClip 以源码为准；Paste 以 2026-10-19 读取的官方帮助页为准（[搜索与筛选](https://pasteapp.io/help/search-and-filters)、[快捷键](https://pasteapp.io/help/keyboard-shortcuts)）。未运行 Paste.app，未做速度、帧率对比，本文不作任何“比 Paste 更快/更流畅”的结论。

---

## 0. 结论

LocalClip 能力完整，体验差距集中在 **几何不稳定、焦点模型、界面框架过重、反馈缺失、动效缺失** 五处。最终方案共 19 项，分三批：

| 批次 | 目标 | 项目 |
|---|---|---|
| **A（P0）主路径与几何** | 打开即可用、卡片不跳变、每次操作有回应 | U-01 焦点与键入即搜 · U-02 稳定几何 · U-03 工具栏重组 · U-04 状态槽 · U-05 多选模式 · U-06 预览响应 · U-07 面板动效 |
| **B（P1）卡片与任务** | 内容易扫读、操作易发现 | U-08 卡片底部行 · U-09 分类型预览 · U-10 来源色头部 · U-11 队列浮窗 · U-12 右键菜单与 ⌘R · U-13 详情内容优先 · U-14 视觉规范 |
| **C（P2）打磨** | 细节质感 | U-15 列表过渡 · U-16 滚轮与尾部加载 · U-17 材质 · U-18 设置文案 · U-19 标题双击区 |

### 0.1 对三份报告的关键纠正

1. **“搜索中 Return 直接粘贴”不采纳**（Claude 版 UX-02、报告 A 3.1）。Paste 官方原文：输入后按 Return，焦点移到结果区；再按 Return 才粘贴。LocalClip 当前行为与 Paste 一致，也是用户已有习惯。改为在状态槽中显示“↩ 进入结果 / ↩ 粘贴到 X”（U-04），让用户清楚下一步会发生什么。
2. **“打开后焦点在搜索框”需要改**（报告 B 主张保持）。Paste 官方原文：打开后可以直接键入，也可以按 ⌘F 聚焦搜索框。也就是说，打开后焦点在结果区，键入时自动转入搜索。LocalClip 打开即聚焦搜索框，所以打开后按 Space 输入的是空格而不是预览，按 Delete/⌘A 也作用于文字，结果区键入则没有任何响应。U-01 按 Paste 方式修正。
3. **报告 B 的几何问题属实**，需要按缺陷处理：出现筛选条时卡片边长减少 22pt；面板高 299pt 时卡片边长 194pt，300pt 时反而只有 179pt（`dense = height < 300` 同时切换了工具栏和底栏高度）。Claude 版遗漏了这一点。
4. **Esc 分级**（报告 A）与 Paste 官方一致（Escape 会关闭搜索），采纳。
5. `focusRequest` 同时是 **文件预览的显示周期标识**（`ClipCard.previewGeneration`、`GUIRenderWitness.displayCycle`）。U-01 不能简单停止发放 `focusRequest`，必须另外拆出一个搜索焦点请求，否则重开面板时文件卡片不会重新校验。三份报告都没有指出这一点。现有测试没有覆盖“重开后文件卡片重新校验”；`ReviewMetadataLoadingTests.hostedSearchReceivesNewFocusToken`（L45）断言的是搜索框跟随 `focusRequest` 聚焦，U-01 后需要改写。
6. 本文经过一轮独立代码复核（2026-10-19），复核发现的调用点遗漏、动画与 `isVisible` 状态冲突、⌘R 在搜索框的行为、队列现有反馈等问题已全部修正到下文。

### 0.2 首要约束：不得造成功能丢失或不可用

本方案中任何一项与本约束冲突时，以本约束为准。

1. **入口不减少**：现有每个功能，在改动后都必须仍能通过**原来支持的每一种输入方式**完成，包括鼠标、仅键盘（Tab 焦点链和快捷键）、VoiceOver。可以增加新入口，但不能因为移除可见控件，让某种输入方式失去访问路径。逐项对照见 §6.3。
2. **行为不降级**：已有快捷键、双击、拖放（包括多选拖到分类标签）、右键菜单项、Esc 层级、IME 保护、隐藏内容、屏幕共享排除等行为保持可用。确需改变的交互（如 Esc 分级、标题双击区收窄），只能增加步骤或改变触发位置，不能让功能无法完成，并且必须在本文中明确写出。
3. **输入不丢失**：任何焦点切换或转发都不能吞掉用户键入的字符。
4. **准入门槛**：每个提交都要通过 §6 的迁移表、§6.2 不得退化清单和 §6.3 输入方式对照。任何一项达不到时，该项**回退到现有实现，不合入**，不能以“已知限制”的名义带病交付。
5. **验证未完成不算通过**：需要交互授权才能验证的点（如 IME 首键），在获得验证前按“未通过”处理，相关行为保持现状。

---

## 1. 评审总表（三份报告的全部建议 → 最终处置）

处置：✅ 采纳 · 🔀 合并/修改后采纳 · ⏸ 延后 · ❌ 不采纳。

| 来源 | 建议 | 处置 | 最终项 | 理由 |
|---|---|---|---|---|
| C UX-01 / A 3.1 部分 | 结果焦点优先、键入即搜 | ✅ | U-01 | 与 Paste 官方一致，修复 Space/Delete 语义漂移 |
| C UX-02 / A 3.1.1 | 搜索中 Return 直接粘贴 | ❌ | U-04 提示替代 | 与 Paste 官方及现有习惯冲突 |
| A 3.1.2 | Esc 先清空搜索再关闭 | ✅ | U-01 | Paste 官方一致，成本低 |
| A 3.1.3 | 搜索框自适应伸缩 | ❌ | — | 装饰性改动，会引起工具栏布局位移 |
| B UX-01 | 稳定几何、消除阈值反向缩小 | ✅ | U-02 | 由公式可证的缺陷 |
| C VI-01 / A 1.1 | 移除常驻底栏 | 🔀 | U-02/U-04/U-05 | 采纳移除，同时满足 B 的“固定上下文区域”要求：上下文信息放入工具栏状态槽，不再占用底部 |
| B UX-01 | 固定 44pt 两行底栏 | ❌ | U-04 替代 | 状态槽同样稳定，且每张卡片多出 45pt |
| B UX-02 | 焦点感知的按键提示 | 🔀 | U-04 | 提示从底栏移到状态槽 |
| B UX-08 | 显示粘贴目标、长错误可展开 | 🔀 | U-04 | 空闲时状态槽显示“↩ 粘贴到 X”，错误可点开查看全文 |
| C MO-03 | 复制成功提示 | 🔀 | U-04 | 用状态槽提示；“复制”不会关闭面板（`PasteCoordinator` L96），不需要面板外提示 |
| C VI-02 / A 1.2 | 工具栏降噪、去品牌字、图标去圆圈 | ✅ | U-03 | — |
| C VI-02 / A 1.2.2 vs B UX-04 | 类型标签收进菜单 vs 保留一键 | 🔀 | U-03 | 折中：5 个类型改为图标分段控件，仍一次点击，宽度约为原来的 1/3；宽度不足时退回现有 `kindMenu` |
| A 1.2.3 | 分类选中用分类色、matchedGeometry 动画 | 🔀 | U-14 | 采纳分类色底；分类标签是 AppKit `NSButton`，matchedGeometry 不适用 |
| B UX-10 | 显示实际生效的筛选 | 🔀 | U-03/U-04 | 筛选按钮显示计数，前缀问题进状态槽；不在 View 层再写一套解析器 |
| B UX-11 | 多选上下文入口 | 🔀 | U-05 | 多选操作条占用状态槽位置；导航区和搜索保持可见，否则多选拖到分类标签、切换范围和搜索会失效 |
| B UX-03 | 详情加载原位反馈 | ✅ | U-06 | popover 绑定要求 `detail != nil`，加载中没有任何反馈，属实 |
| C UX-03 | Space 开关、方向键跟随预览 | ✅ | U-06 | `select()` 切换卡片时会关闭详情，属实 |
| C MO-01 / A 3.2.2 / B UX-13 | 面板入场退场动效 | 🔀 | U-07 | 窗口 frame 不移动，只做透明度变化和内容层位移（移动 frame 会画到下方相邻显示器）；粘贴与队列路径不做退场动画 |
| C VI-03 | ⌘1–9 角标按修饰键显示 | ✅ | U-08 | — |
| B UX-05 | 卡片动作槽固定、命中区 ≥24pt | ✅ | U-08 | 悬停时插入按钮会挤压页脚文字，属实 |
| A 2.1.3 | 页脚改为悬浮在内容上 | ❌ | U-08 替代 | 会遮挡内容，并且与固定动作槽冲突 |
| C VI-05 / A 2.2 / B UX-07 | 分类型预览、文件大图标、颜色整卡 | 🔀 | U-09 | — |
| A 2.2 图片 | 图片 `scaledToFill` | ❌ | U-09 | 裁切后不利于辨认截图；改为完整 fit、不加渐隐、减少留白 |
| A 2.2 链接 | 首字母大徽章 | ❌ | — | 收益低；坚持不联网 |
| C VI-04 / A 2.1.1 | 来源应用色头部 | 🔀 | U-10 | 采用 Paste 式实色头部加白字（用户已确认），对比度由校正规则保证 |
| A 2.1.2 | 卡片圆角 16、双层阴影 | 🔀 | U-14 | 圆角统一为 12，只保留单层柔和阴影 |
| A 4.1 / B UX-11 | 粘贴队列独立浮窗 | 🔀 | U-11 | 面板外现有进度只有 3 秒提示和菜单栏“结束粘贴队列（n/m）”，没有常驻进度；浮窗替代队列的逐步提示，不叠加 |
| C UX-04 / A 4.2 | 右键菜单分组与原生快捷键 | ✅ | U-12 | 不强制要求图标（macOS 15 是否显示菜单图标由系统决定） |
| Paste 官方 | ⌘R 重命名 | ✅ | U-12 | — |
| C VI-08 / B UX-09 | 详情内容优先、元数据折叠 | ✅ | U-13 | — |
| C VI-06 / B UX-06 | 视觉规范常量 | ✅ | U-14 | 在多个文件中复用，可以新建一个小文件 |
| C MO-02 | 删除收拢、选择环过渡 | 🔀 | U-15 | 不给搜索结果的全量重排加动画（B 的约束） |
| A 3.3 / B UX-14 | 离散滚轮平滑 | 🔀 | U-16 | 只处理 `!hasPreciseScrollingDeltas` 的情况，触控板不动 |
| C VI-09 / A 3.2.1 / B UX-06 | 材质通透度 | 🔀 | U-17 | 先保证对比度，后调透明度；报告 A 的 0.28 过低，不采纳 |
| A 4.3.2 / B UX-15 | 设置文案分层 | ✅ | U-18 | — |
| C UX-05 | 标题双击命中区收窄 | ✅ | U-19 | — |
| A 4.3.1 | 更换提示音 | ❌ | — | 已有开关（设置 › 复制新内容时播放提示音），属主观偏好 |
| B UX-12 | 转换菜单分组 | ⏸ | — | 已是稳定的两列菜单，没有问题证据 |
| B UX-16 | 统一状态与辅助功能 | 🔀 | 各项验收 | 作为每项的验收条款，不单列 |
| B §9.4 | 用户可用性测试 | ⏸ | — | 不属于编码交付范围，可在批次 A 完成后由产品侧另行安排 |
| B UX-08 | 自动重试、新权限弹窗链 | ❌ | — | B 本身也不建议 |

---

## 2. 核心设计决策

| ID | 决策 | 结论 |
|---|---|---|
| D1 | 卡片头部着色 | **已确认：来源应用主色实色头部 + 白字（同 Paste）**；主色按白字对比度 ≥4.5:1 校正 |
| D2 | Return 语义 | 保持两段式（与 Paste 一致）；靠状态槽提示与结果焦点优先来消除困惑 |
| D3 | 底栏 | 移除；上下文信息全部进入工具栏状态槽；多选时状态槽位置显示多选操作条；原底栏的单条记录操作同时进入“更多 › 所选记录”子菜单，保证键盘和 VoiceOver 可达 |
| D4 | 类型入口 | 图标分段控件（一次点击）；宽度不足时退回 `kindMenu` |
| D5 | 面板动效 | 窗口 frame 固定；淡入 0.18s，同时内容层从下方 12pt 移到原位；用户关闭时淡出 0.12s；粘贴/队列关闭时立即 `orderOut`；减弱动态效果时只做即时显示 |
| D6 | 品牌 | **已确认：工具栏完全移除品牌图标与“LocalClip”字样**；品牌由菜单栏图标、关于窗口和设置窗口承担 |

---

## 3. 目标布局规格

### 3.1 几何（U-02 的硬性约束）

```
拖动条 8 ─┐
工具栏 44 ├─ 固定，不随高度、筛选、多选、状态变化
卡片区     ┘  上下各 10 留白
卡片边长 = 面板高 − 72        （280→208，340→268，520→448；严格单调）
```

- 删除 `dense` 对工具栏和底栏高度的切换，`toolbarHeight` 固定为 44。
- 删除 `FilterStrip` 行（22pt）。筛选摘要、队列状态和解析问题分别迁入 U-03/U-04/U-11。
- `HistoryView.cardSide(height:)` 去掉 `filtered` 参数，以下 5 处生产调用点全部改为新签名：`HistoryView.swift:30`、`AppDelegate.swift:116`、`AppDelegate.swift:398`、`HistoryViewModel.swift:264`、`ClipContentEditor.swift:371`（同时删除其 L370 自行拼出的 `filtered` 表达式）；2 处测试调用 `SpecifiedReviewVisualTests.swift:47`、`SizeLabelVisualTests.swift:53` 同步修改。删除 `hasFilterStrip`，并改写 `CommentUITests:191` 中对它的断言。
- 水平方向常量（卡片区左右 padding 24、卡片间距 16，硬编码在 `HistoryScrollWheel.swift:73` 和 VM 的 `historyStride`/L521/L558/L572–576/L1336）本方案不改；实施时把它们和垂直 padding 收为 `HistoryView` 上的静态常量，原则是“边长函数和每个 padding/spacing 常量各只定义一次”。
- `ClipContentEditor.anchorRect` 的回退值 `topOffset = 56`（L252，等于拖动条 8 + 旧工具栏 48）改为 52，最好直接引用工具栏常量。
- 卡片字号阈值（`previewFontSize`：<200 用 12、<260 用 13、否则 15）保持不变，随边长单调变化。

### 3.2 工具栏槽位（从左到右）

```
[剪贴板][收藏] │ [类型图标分段×5] │ [分类…][＋][⌄]   ⟶   [状态槽 ≤260] [搜索 200] [筛选·N] [更多] [置顶] [关闭]
```

多选（`selectedIDs.count > 1`）时，**只有状态槽位置**交叉淡入为多选操作条（最宽 320pt，图标按钮加 tooltip）；左侧导航区、分类标签、搜索框保持原样，以保证多选拖到分类标签、切换范围和继续搜索都可用：

```
[!] [已选 N 项] [合并粘贴 ▾] [加入队列] [分类 ▾] [收藏] [删除] [取消选择]
```

`[!]` 只在有错误时出现，点按弹出错误全文，这样错误与多选操作不会互相遮挡。

“更多”菜单新增 **“所选记录”子菜单**：直接粘贴、原格式复制、纯文本复制、收藏/取消收藏、加入分类 ▸、详情、编辑内容（项目可用性与原底栏一致，无选中时整组禁用）。“更多”按钮在 Tab 焦点链中，所以原底栏的全部操作对仅键盘用户依然可达。

### 3.3 卡片结构

```
┌ 头部 40（来源色实色 + 白字）：标题 / 相对时间 · 识别徽标 · 收藏星 · 应用图标 ┐
│ 正文：按类型渲染（U-09）                                                    │
└ 底部行 22：度量文字 ……………… [固定动作槽 3×24] [⌘N 仅按住修饰键时显示] ┘
```

---

## 4. 实施项

每项包含：问题与证据 → 方案 → 复用 → 必须保留 → 验收。行号对应 `dea4d44`，编码前需在 HEAD 上重新核对。

### 批次 A（P0）

#### U-01 结果焦点优先、键入即搜、Esc 分级

- **证据**：`AppDelegate.showHistory()` L428 `model.focusRequest = UUID()` 经 `SearchField.updateNSView` 把搜索框设为第一响应者；结果区焦点下可打印字符落到 `default: return event`，没有任何响应；Esc 有三条入口：`SearchField` L44（直接关闭面板）、键盘监听 L747–751（依次关闭分类编辑、筛选、详情，最后关闭面板）、`ClipPanel.cancelOperation`/`keyDown`（L13、L26，经 `onCancel` 关闭面板）。
- **方案**：
  1. 在 `HistoryViewModel` 中新增 `@Published var searchFocusRequest = UUID()`，`SearchField` 的 `focus` 改为订阅它。`focusRequest` **继续在每次打开面板时发放**，仍只作为显示周期标识，供文件预览和 GUI 探针使用。
  2. `showHistory()` 末尾调用 `model.focusResults?()`；⌘F（L758）改为发放 `searchFocusRequest`。
  3. 在键盘监听 `!editing` 分支、方向键/Return 处理之前加入转发：无 ⌘⌃⌥ 修饰键、`event.characters` 为可打印字符、且不是 Space/Return/Delete/Tab/Esc/方向键时，在监听中**同步**执行 `panel.makeFirstResponder(searchField)`，然后 `return event`，让 AppKit 把这个事件按正常流程派发给新的 field editor，首键因此经由输入法。这需要模型能拿到搜索框：由 `SearchField.Coordinator` 在 `makeNSView` 时登记 `weak var field`，模型提供 `focusSearchSynchronously()`。不要手动调用 `keyDown`。判定逻辑写成纯函数 `AppDelegate.forwardsToSearch(_:editing:) -> Bool`。
  4. Esc 层级：IME 候选 → 自有弹窗（分类编辑 → 筛选 → 详情，保持现有顺序）→ **搜索词非空时清空搜索（不关闭面板，焦点回结果区）** → 关闭面板。写成一个函数 `model.handleEscape() -> Bool`（返回是否仍需关闭面板），三条 Esc 入口（`SearchField.onEscape`、键盘监听 L747、`ClipPanel.onCancel`）都调用它。
- **复用**：`focusResults`、`isHistorySearchEditor`、`hasMarkedText` 守卫、`navigateFromSearch`。
- **保留**：两段式 Return；搜索框内 Delete 只删文字；Tab 沿原生焦点链（与 Paste 的“Tab 在搜索框和结果间切换”不同，暂不改）；重命名、内容编辑、分类编辑弹窗中的按键不转发。
- **验收**：打开后直接按 Space 预览选中卡片；直接按 `a`，搜索框得到 `a` 并过滤结果；中文拼音输入法下打开后直接键入 `ni` 出现候选（需交互授权验证）。**准入门槛**：英文、中文拼音、日文输入法下，打开后连续快速键入的每个字符都必须完整进入搜索框，不得丢失首键。验证未通过或未获授权验证前，U-01 的第 2 步（打开时焦点放在结果区）不得合入，打开面板仍聚焦搜索框（现状）；第 1、3、4 步（拆分焦点请求、结果区键入转入搜索、Esc 分级）不依赖它，可以先合入；有搜索词时按 Esc 清空搜索、面板不关；无搜索词时按 Esc 关闭；重开面板后文件卡片仍重新校验（新增测试：`focusRequest` 变化后，文件卡片的 `previewGeneration` 推动重新校验）；`ReviewMetadataLoadingTests.hostedSearchReceivesNewFocusToken` 改为断言搜索框跟随 `searchFocusRequest`；纯函数单测覆盖各类修饰键、Space、方向键和控制字符；三条 Esc 入口行为一致。

#### U-02 稳定几何、移除常驻底栏

- **证据**：`HistoryView.cardSide` L14–19、L28、L73、L77–92；340pt 时卡片 219pt，加筛选条后 197pt；299pt 时 194pt，300pt 时 179pt。
- **方案**：按 §3.1 实施，删除底栏 `HStack`、`Divider` 和 `FilterStrip` 行。底栏原有元素全部按 §6 迁移表迁出，不删除任何入口。
- **复用**：`HistoryFooterState` 及其局部订阅保持不变（改由状态槽和多选模式订阅），以维持“只有统计订阅列表”的性能约束；`HistorySelectionActions` 的按钮逻辑迁入 U-05。
- **验收**：280–520pt 逐 pt 扫描，卡片边长严格单调、等于 `H−72`；开关来源、日期、前缀条件、队列、多选时，卡片边长变化为 0；首屏分页数量（`configureHistoryViewport` 推出的 `viewportPageSize`）随新边长正确；680/900/1440pt 宽度下工具栏无重叠。

#### U-03 工具栏重组

- **方案**：
  1. 品牌：删除工具栏左侧的红底图标和“LocalClip”字样（`HistoryView` L39–43 整个 HStack，D6）；左侧留白与卡片区左边距对齐（24pt）。“关于 LocalClip”仍在菜单栏菜单中。
  2. 类型：非紧凑时改为 5 个 SF Symbol 图标按钮（`text.alignleft`、`link`、`photo`、`doc.on.doc`、`square.stack`，与卡片 `symbol` 一致），复用 `ToolbarTabStyle`，带 `.help` 和 `accessibilityLabel`；紧凑时保持现有 `kindMenu`。
  3. 搜索框移到右侧组的状态槽之后，宽 200pt；占位文字改为“搜索 N 条”（N 来自 `HistoryFooterState`，有更多时显示 `N+`）；查询在途时在框内右侧显示小转圈（替代底栏统计里的转圈）。
  4. 筛选按钮：有筛选时显示为 accent 色并带数字，如 `筛选 · 2`；点开仍是现有 `FilterEditor`。`FilterEditor` 已支持单项清除（来源选“全部来源”、关闭日期开关，L1097–1103）和“清除筛选”，不需要改。
  5. 图标去掉圆圈：符号名由各调用点传入，需要逐个修改——筛选 `line.3.horizontal.decrease.circle(.fill)`→`line.3.horizontal.decrease`、置顶 `pin.circle(.fill)`→`pin`/`pin.fill`、关闭 `xmark.circle`→`xmark`、“更多”Menu 自带的 `ellipsis.circle`（L66）→`ellipsis`、分类溢出菜单 `chevron.down.circle`（L155）→`chevron.down`。`ToolbarIconButton` 字号改为 14pt medium、次要色，选中态用 accent 色底。
- **保留**：类型与分类一次点击可达；分类溢出菜单、渐隐、拖放目标不变；“更多”菜单的全部项目不变。
- **窄宽度**：面板宽度 <1000pt 或启用紧凑布局时，状态槽收为 28pt 图标（有内容时显示对应状态图标，点按弹出全文和操作按钮），多选操作条收为“已选 N ▾”菜单，搜索框 160pt。
- **验收**：1440pt 宽、5 个分类时所有控件一行放下且无截断；680pt 宽（最小宽度）、30 个分类时，搜索框、筛选、更多、置顶、关闭都完整可见可点；每个原有入口都能一次到达。

#### U-04 工具栏状态槽

单一组件，按优先级显示一条内容，宽度 ≤260pt，单行截断，点按后弹出 popover 显示全文。低优先级内容被高优先级暂时覆盖时，其操作仍有其他入口：“开始监控”在“更多”菜单中（已有），队列“结束”在队列浮窗和菜单栏菜单中（已有）。

| 优先级 | 内容 | 来源 | 点按 |
|---|---|---|---|
| 1 | 错误或回退原因（粘贴失败、权限、容量满、查询前缀问题） | `model.message` 加新增的严重程度字段、`capture.capacityBlocked`、`queryProblems` | 显示全文与下一步建议；“开始监控”等按钮就地提供 |
| 2 | 已停止监控 / 定时停止 | `recordingPaused`、`statusLabel` | “开始监控” |
| 3 | 粘贴队列进行中（面板打开时） | `pasteQueueStatus` | “结束” |
| 4 | 临时通知（已复制、已收藏、已删除 · ⌘Z 撤销） | `notice` | — |
| 5 | 焦点提示：搜索焦点且有搜索词时显示“↩ 进入结果”；结果焦点时显示“↩ 粘贴到 [图标] TextEdit”或“↩ 复制”（按 `settings.defaultAction`） | first responder + `model.target` | — |

- `model.message` 目前是通知和错误共用的普通字符串（VM L98–117），无法区分类别。新增 `messageSeverity: .notice / .failure`，在现有写入 `message` 的位置按语义赋值（`notice()` 为 `.notice`，`showPasteResult` 中的回退与失败、`change` 的 catch 分支为 `.failure`）；不改变 `message` 原有的写入时机。
- 错误类消息持续显示，直到下一次用户操作或点按关闭；通知类沿用现有 4s 恢复规则。
- 状态槽的 `.help` 继承原底栏状态文字的 `model.ignoreDescription`（HistoryView L83）。
- “复制”不会关闭面板（`PasteCoordinator` L96），复制成功只在状态槽显示“已复制”；不新增面板外提示。
- 隐藏内容模式下，状态槽不得显示任何正文。
- 状态变化通过 `AccessibilityNotification.Announcement` 朗读，仅限优先级 1–4。
- **验收**：每个优先级都能独立触发并正确显示；高优先级不会被低优先级覆盖；两次快速操作中，旧计时器不会清掉新的错误；焦点提示在 first responder 变化后的同一渲染周期内更新；不显示“已粘贴成功”之类无法证实的措辞（仍使用“已发送粘贴”的现有语义）。

#### U-05 多选模式

- **方案**：`selectedIDs.count > 1` 时，状态槽位置以 0.12s 交叉淡入切换为 §3.2 中的多选操作条；导航区、分类标签、搜索框不变。按钮直接调用现有接口：`perform(join:)`（合并方式菜单沿用右键 `JoinStyle` 列表）、`startPasteQueue(orderedSelection)`、`categoryItems`、`change(.favorites…)`、`change(.delete…)`、`select(nil)`。含图片等不支持合并的项目时，“合并粘贴”禁用并说明原因（沿用 `selectionHasNonText`）。
- **保留**：右键中的多选入口全部保留；`orderedSelection` 仍按列表顺序；删除走原有撤销或确认流程。
- **验收**：多选后入队、合并都从“右键 → 子菜单 → 项”减少为一次点击加一次选择；多选状态下把卡片拖到分类标签仍能整组加入分类；多选状态下仍可切换范围、类型、分类和修改搜索词；有错误时 `[!]` 可见；选择数回到 1 时状态槽恢复；多选期间卡片几何不变。

#### U-06 预览与详情响应

- **证据**：`HistoryScroller` L273 的 popover 显示条件包含 `detail?.summary.id == item.id`，加载中没有反馈；`quickLook()` 只能打开、不能切换关闭；`select()` 切换卡片时会把 `showingDetail` 置为 false。
- **方案**：
  1. 加载反馈：触发详情 100ms 后若 `detailLoading` 仍为真，在该卡片的详情动作槽显示小转圈，状态槽显示“正在准备预览…”；完成后按最终尺寸一次弹出；失败时状态槽显示“预览未能读取 · 重试”。延迟任务随取消、换选、隐藏和请求代次一起结束。
  2. Space 切换：`showingDetail` 为真时关闭，否则调用 `quickLook()`；文件仍走系统 Quick Look。
  3. 方向键跟随：在 VM 中增加 `previewFollowsSelection`，由 Space 打开时置为真。`select()` 当前在 L631 同步把 `showingDetail` 置为 false，而 `loadDetail` 的守卫要求 `showingDetail` 为真（L670），所以需要给 `select` 增加 `keepDetail: Bool = false` 参数；`navigate()` 在 `previewFollowsSelection` 为真时传入 `true`，并调用 `loadDetail()`。点击卡片或显式详情入口仍沿用现有规则，`CommentUITests:185–186`（点击换卡会关闭详情）必须保持通过。
  3a. 按键路由：详情 popover 可能成为 key window（`QuitFocusTests:120`），此时 `routesHistoryShortcuts`（L735）因事件窗口不是面板而不处理 Space、←/→、Esc。需要在 `routesHistoryShortcuts` 中增加例外：`previewFollowsSelection` 为真、事件窗口属于详情 popover、且第一响应者不是可编辑文本时，Space/←/→/Esc 交给历史处理。详情内文字选择时的 ⌘C 仍归文本。实施前先用隐藏窗口测试确认 popover 是否成为 key，再决定是否需要此例外。
  4. 若卡片锚定的 popover 换锚时出现闪烁，第二步把 `ClipInspector` 放进子 `NSPanel`，参考 `ClipContentEditorPopover`“独立于滚动卡片存活”的做法，并纳入 `ownsHistoryWindow`，设置 `sharingType`。
- **验收**：注入 0/80/500/2000ms 延迟，80ms 内完成时不闪转圈，500ms 时有可见反馈；从 A 切到 B 后 A 不再弹出；Space 开/关；预览打开时 ←/→ 连按 10 次内容随之更新（包括焦点在 popover 中时）；Esc 先关闭预览；隐藏内容模式下 Space 无效；点击换卡仍会关闭详情。

#### U-07 面板入场与退场

- **前提（复核发现）**：退场动画期间 `panel.isVisible` 仍为 true，而 `toggleHistory`（L376）、`scheduleFocusDismissal`（L498/L501）、点击监听（L633）、键盘监听（L729）、滚轮监听（`HistoryScrollWheel` L101）都以 `isVisible` 判断面板是否打开。直接加退场动画会导致：退场中按快捷键变成再次关闭、淡出中的 Return/点击仍被当作历史操作、`didResignKey` 重复触发 `dismissHistory`。
- **方案**：在 `AppDelegate` 内实现，不新建类型。
  - 新增 `private var panelPresented = false`，`showHistory` 置为 true，`dismissHistory` 开头置为 false。上述 5 处判断全部改用 `panelPresented`（滚轮监听通过 model 暴露的只读值获取）。`dismissHistory` 改为幂等：`panelPresented` 已为 false 时直接返回。
  - 显示：窗口 frame 一次设为最终值，**不移动**（移动 frame 会画到下方相邻显示器）。`alphaValue = 0` 后 `makeKeyAndOrderFront`，用 `NSAnimationContext` 以 0.18s、`CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)` 把 alpha 变为 1；同时 `HistoryView` 根视图做 `offset(y: 12 → 0)`（由 model 的 `panelEntrance` 值驱动，SwiftUI 动画），位移限制在窗口内部。
  - 隐藏：分两种情况。**用户关闭**（Esc、关闭按钮、快捷键、失焦）：状态复位保持同步，然后 0.12s 淡出，完成后 `orderOut`，期间 `ignoresMouseEvents = true`。**粘贴与队列触发的关闭**（`PasteCoordinator` L108/L246 的 `closePanel`、VM L1383 `startPasteQueue`）：立即 `orderOut`，不做动画。给 `closePanel` 增加 `animated: Bool` 参数来区分。
  - 重入：用 `panelAnimationGeneration` 计数；新的显示请求取消正在进行的淡出，旧的 completion 不得隐藏已重新打开的面板，并恢复 `alphaValue = 1`、`ignoresMouseEvents = false`。
  - 减弱动态效果：时长为 0，不做位移。
  - ⌘V 通过 `postToPid` 发送到目标进程（`MacApplicationClient` L193），面板残留不会接收这次粘贴，但仍要做交互验证。
- **验收**：快速连开连关 20 次，无残留透明窗口，开关状态与快捷键次数一致；淡出期间按 Return 或点击不触发任何历史操作；打开后立即按 Return 粘贴，目标应用能收到内容（需交互授权验证）；粘贴、入队后面板立即消失；`show_history_submitted` 计时不变；首帧宽度即为全宽；`panelAnimationGeneration` 重入有单测。

### 批次 B（P1）

#### U-08 卡片底部行

- **证据**：L674–697，悬停或选中时插入 18pt 按钮，挤压 `footerText`；⌘1–9 角标常驻。
- **方案**：
  1. 动作槽固定宽度：3 个槽位（编辑、详情、收藏），每个命中区 24×24pt、图标 13pt。未悬停或未选中时 `opacity 0` 并 `allowsHitTesting(false)`，**但仍占位**；不支持编辑的类型对应槽位留空。`infoRect`/`passThroughRect` 改为覆盖整个槽位区域。
  2. 新增收藏按钮（迁出底栏收藏入口），调用 `change(.favorites…)`。
  2a. VoiceOver：卡片目前只有“选择、复制并粘贴、重命名、编辑内容”4 个辅助功能动作（L738–741），原底栏按钮对 VoiceOver 是独立可达的。删除底栏后，为卡片补充命名动作：“详情”“收藏/取消收藏”“原格式复制”“纯文本复制”“直接粘贴”，可用性与原底栏一致（隐藏内容、无文本时禁用）。“加入分类”通过 VoiceOver 的右键菜单（VO-Shift-M）和“更多 › 所选记录”到达。
  3. ⌘N 角标：新增 `.flagsChanged` 本地监听，修饰键恰好等于 `settings.quickModifiers` 时设置 `model.quickBadgesVisible = true`；`ClipCard` 新增 `showsQuickBadge` 参数并加入 `==`；角标 0.12s 淡入。
- **验收**：悬停、选中、取消选中时，度量文字起点和角标位置不变；点击槽位不会选中邻卡、不会开始拖动、不会触发双击粘贴；280pt 面板下仍可操作；不按修饰键时无角标，但卡片 `.help` 仍写明“⌘N 快速粘贴第 N 条”（修饰键按设置显示），快捷键在设置中也可查看，可发现性不降为零；VoiceOver 动作菜单中能找到新增的 5 个动作。

#### U-09 分类型内容预览

| 类型 | 方案 | 复用 |
|---|---|---|
| 文本/代码 | 只在内容溢出时加底部 16pt 渐隐（现在对所有内容都加，L664–669） | `SyntaxText` |
| 图片 | 不加渐隐；`ThumbnailPreview` 的 padding 从 9 改为 4；透明图片使用中性底色；保持 `scaledToFit` | `ThumbnailPreview` |
| 不可预览文件、目录、失效文件 | 正文居中显示 `NSWorkspace.shared.icon(forFile:)` 56pt，下方两行文件名（中间截断）；目录、失效文件显示对应状态文字。消除“正文空白”（见 `size-280-visible.png` 第 3 张） | 详情 L1026 的写法 |
| 颜色值（检测为 `.color` 且文本只有色值） | 正文区铺满该颜色，居中显示等宽色值，按明度自动选黑或白字 | `DetectionBadge` 的颜色解析 |
| 链接 | 保持 host 加 URL 层级，不联网 | — |

页脚度量口径：文本/链接为“N 字”；图片为“大小”（能廉价取得像素尺寸时显示“宽×高 · 大小”）；文件为“N 项 · 大小”或“文件夹”；混合为“N 项”。“复制 N 次”移到详情中。

- **验收**：透明 PNG、超宽或超长截图、PDF、代码文件、目录、已删除文件、混合记录、长 URL、`#FF8800` 都能被辨认；图片底部不被渐隐；离屏任务仍会取消；不新增网络请求；`SizeLabelVisualTests` 更新基线后通过。

#### U-10 来源色头部（D1）

- **决策**：用户已于 2026-10-19 确认采用 **Paste 式实色头部 + 白字**。这推翻了 2026-10-12 评审中“饱和头部与内容抢视觉”的结论，可读性改由下文的对比度规则保证。
- **方案**：
  1. **主色提取**：在 `SourceApplicationObserver` 中按 bundleID 缓存：把图标绘制到 8×8 位图，按饱和度加权求平均，并排除接近灰色的像素（饱和度 <0.15）。图标整体为灰色时（如 Finder 之外的单色图标），回退到中性深灰 `#5A5F6B`。没有来源时，回退到现有的类型色（`ClipCard.tint`）。
  2. **对比度校正**：在 HSB 空间中保持色相，逐步降低亮度，直到白字对比度 ≥4.5:1（WCAG 相对亮度公式）；饱和度上限 0.85，避免荧光色。校正结果和主色一起缓存，深浅色模式共用，头部不随外观变化。
  3. **头部**：`ClipCard` 头部背景改为实色 `headerColor`（替换现在的 `tint.opacity(0.13)`）。标题为白色 semibold；相对时间为白色 0.75；`DetectionBadge` 改为白字加 `white.opacity(0.18)` 底；收藏星保持橙色并加 0.5pt 白描边；应用图标直接放在色块上，不另加底。没有应用图标时，类型 SF Symbol 改为白色，底为 `white.opacity(0.18)`。
  4. **重命名输入框**：编辑状态下输入框使用 `white.opacity(0.2)` 底和白字，光标与选区保持可见。
  5. **选中环**：仍是卡片外侧 4pt 处的 accent 外环。头部色与 accent 接近时（如 Safari、VS Code 的蓝色），外环与卡片之间的 4pt 间隙负责区分，不改环色。
  6. 类型仍由右上角 SF Symbol 表达（已有）。
- **复用**：`SourceApplicationObserver.icon(for:)`、`ClipCard.tint`（作为回退色）、`DetectionBadge`。
- **验收**：Safari、VS Code、微信、备忘录、Finder、未知来源的记录同屏时可以区分；对每个头部色计算白字对比度，单测断言均 ≥4.5:1，并覆盖黄色、浅绿等高亮度图标；深浅色截图中头部文字清晰；主色与校正色按 bundleID 只计算一次，滚动 500 张卡片不重复计算；accent 为蓝色时，蓝色头部卡片的选中状态仍可辨认。

#### U-11 粘贴队列浮窗

- **证据**：队列开始后面板会关闭（VM L1383）。面板外的进度只有每步弹出 3 秒的 `showPasteFeedback`（VM L1384、L1434–1436）和菜单栏菜单中的“结束粘贴队列（n/m）”（AppDelegate L277–279），用户在目标应用里连续粘贴时看不到常驻进度和下一项内容。
- **方案**：复用 `feedbackPanel` 的创建方式（无边框、非激活、`ignoresMouseEvents = false` 只用于“结束”按钮、不成为 key），新建一个队列面板，固定在当前屏幕 `visibleFrame` 右下角，宽 260pt。内容：`粘贴队列 2/5`、下一项的一行摘要（隐藏内容模式下显示“内容已隐藏”）、快捷键提示、“结束”按钮。`pasteQueueActive` 变为 false 时淡出。设置 `sharingType` 以遵守 `excludeFromSharing`，并纳入 `ownsHistoryWindow` 的排除名单（它不属于历史面板）。
  - **与现有提示去重**：浮窗显示期间，队列开始和每步成功的 `showPasteFeedback` 不再弹出，改为更新浮窗；失败、回退（`failed == true`）在浮窗内以警告样式显示原因，不另弹提示。菜单栏“结束粘贴队列（n/m）”保留。
- **保留**：队列推进、失败、过期跳过、10 分钟空闲结束等规则完全不变。
- **验收**：每粘贴一项，计数在 1 帧内更新；屏幕上任何时刻只有一个队列相关浮层；失败原因可见；结束或耗尽后浮窗消失；该浮窗不抢焦点、不改变粘贴目标。

#### U-12 右键菜单与 ⌘R

- **方案**：
  - 右键菜单：去掉标题里的“ · ⌘T”这类文字，改用 `.keyboardShortcut` 让系统在右侧显示快捷键（键盘监听先处理事件，菜单快捷键只用于展示；需加单测确认 ⌘T/⌘G/⌘O 只执行一次）。
  - 工具栏“更多”菜单：SwiftUI `Menu` 的快捷键在菜单关闭时可能仍然生效。搜索框编辑中且 `canUndoFromSearch` 为假时，⌘Z 现在会放行给文字撤销（L775、L781），给“撤销删除”绑定 ⌘Z 可能劫持文字撤销。因此“撤销删除”“设置…”保留标题中的快捷键文字，不绑定 `.keyboardShortcut`；“退出”已有的 ⌘Q 绑定保持不变。
  - 一级菜单按四组排列：**使用**（直接粘贴、原格式复制、纯文本复制、转换后粘贴…、多选专属项）／**整理**（编辑内容…、重命名、收藏、加入分类 ▸、移出当前分类、移动 ▸）／**查看**（预览、详情、定位 ▸、打开、在 Finder 中显示 / 打开方式…、存储为文件…、复制图中文字）／**删除**。“向前移动 / 向后移动”收进“移动 ▸”，“在历史中定位 / 在分类中定位”收进“定位 ▸”。不删除任何项目。
  - 新增 ⌘R（keyCode 15）→ `beginRename(selectedID)`，加入 `handleRecordCommand` 的按键白名单。与 ⌘E/⌘I 一致，搜索框中按 ⌘R 也会重命名当前选中记录（`handleRecordCommand` 有意允许搜索编辑器使用记录快捷键，`CommentUITests:63–66`）；查询在途时同样被拦截。
- **验收**：原有右键菜单项全部能找到，文字里不再有“·快捷键”后缀；结果区和搜索框中按 ⌘R 都能重命名选中记录；查询在途时 ⌘R 不作用于旧记录；搜索框中 ⌘Z 仍是文字撤销（`canUndoFromSearch` 为假时）。

#### U-13 详情内容优先

- **方案**：`ClipInspector` 默认只显示标题、来源简述、正文和识别结果；“大小/复制/格式”和说明收进默认折叠的 `DisclosureGroup("记录信息")`。影响结果的提示（文件引用说明、私有格式未保存）保持可见。外框继续使用 `ClipContentLayout` 的 520×350pt。
- **验收**：默认正文可视区不小于基线；展开元数据不改变外框；编辑入口和草稿保护不变。

#### U-14 视觉规范

- **方案**：新建 `UI/LCStyle.swift`（会被多个文件复用，可以新建），只包含：
  - 字号：`caption 10`（只用于角标和徽标）、`meta 11`、`body 13`、`title 14`、`heading 15`；代码字号上限 12.5 保留。
  - 圆角：`panel 16`、`card 12`、`control 6`、`pill` 为 Capsule。
  - 间距：4/8/12/16/24。
  - 阴影：卡片默认 `black 0.08, r 4, y 2`，悬停 `0.14, r 8, y 4`。
  然后逐个替换 `HistoryView`、`CategoryDropTarget`、`ClipContentEditor`、`ChangeConfirmation`、`SettingsView` 中的硬编码值。分类标签选中时的背景由灰底改为 `分类色 0.16`。
- **验收**：在 UI 目录中 grep `size: 9\b|size: 10.5|cornerRadius: 3\b|cornerRadius: 5\b|cornerRadius: 7\b` 无结果；深浅色截图中同类元素的尺寸一致。

### 批次 C（P2）

#### U-15 列表过渡
删除时，`items.removeAll` 包在 `withAnimation(.snappy(duration: 0.2))` 中，卡片使用 `.transition(.opacity.combined(with: .scale(0.92)))`；选中环加 `.animation(.easeOut(duration: 0.12), value: selected)`；`scrollEpoch` 切换时只加 0.12s 淡入，不给重排加动画。减弱动态效果时全部为 nil。验收：1 万条历史中连续删除时，主线程不出现超过 50ms 的阻塞。

#### U-16 滚轮与尾部加载
`HistoryScrollWheel` 只对 `!hasPreciseScrollingDeltas` 的事件把 `onScroll` 包在 `withAnimation(.smooth(duration: 0.15))` 中；`pendingOffset` 的累加逻辑不变。“更多历史”卡片在自动加载时只显示转圈，加载失败时才显示可点击的“重试”。验收：外接鼠标滚动连续无跳格；触控板行为与基线一致。

#### U-17 材质
`HistoryView` L95 的叠加透明度从 0.76 试到 0.55，材质 `.popover` 与 `.menu` 各出一组深浅色截图，在高对比壁纸上检查工具栏文字对比度（≥4.5:1），不达标则保持原值。卡片底色保持不透明。

#### U-18 设置文案
五个分组保持不变；每个关键控件附一句“改变后会怎样”，技术细节（`org.nspasteboard.source`、AX、字节换算）放进“了解限制”折叠区或 `.help`。权限、文件引用、富文本转换等影响判断的说明仍就地可见。所有设置项仍可到达。

#### U-19 标题双击命中区
`headerRect` 改为只取 `cardTitle` 文字的 frame（给 `cardTitle` 加 `onGeometryChange`）；头部其他区域双击改为粘贴。重命名同时可用 ⌘R（U-12）和右键。需要更新 `ClipRenameInteractionTests` 中关于命中区的假设。

---

## 5. 实施顺序

| 顺序 | 项 | 成本 | 依赖 / 风险 |
|---|---|---|---|
| 1 | U-02 稳定几何 | M | 先改公式与引用点，再迁出底栏内容；与 U-03/U-04/U-05 同一个提交，避免出现入口丢失的中间态 |
| 2 | U-03 工具栏重组 | M | 同上 |
| 3 | U-04 状态槽 | M | 同上 |
| 4 | U-05 多选模式 | S | 同上 |
| 5 | U-01 焦点与键入即搜 | M | 必须拆分 `focusRequest`；IME 首键需交互验证 |
| 6 | U-06 预览响应 | M | popover 换锚闪烁时启用子面板方案 |
| 7 | U-07 面板动效 | M | 放在批次 A 最后；需先把 5 处 `isVisible` 判断改为 `panelPresented` |
| 8 | U-08 → U-14 | 各 S–M | U-10 的对比度校正需要单测覆盖 |
| 9 | U-15 → U-19 | 各 S | — |

成本口径：S ≤1 人日，M 为 1–3 人日；含安静回归，不含交互验收。

**合入门槛**（适用于每个提交）：§6.1 迁移表、§6.2 不得退化清单、§6.3 输入方式对照逐项通过。任何一项未通过时，该改动回退到现有实现，不合入（§0.2 第 4 条）。

建议的提交拆分：**A1**（U-02 至 U-05）、**A2**（U-01）、**A3**（U-06）、**A4**（U-07）、**B**（每项一个提交）、**C**（可合并成一个提交）。每个提交注明对应的 U-ID、前后渲染截图和未验证范围。

---

## 6. 功能保全

### 6.1 底栏与筛选条入口迁移表（U-02 的验收清单）

| 原位置 | 原元素 | 新位置 |
|---|---|---|
| 底栏 | 状态点与“正在监控” | 正常时不显示；异常时显示在状态槽（U-04） |
| 底栏 | 消息文字及其 `.help(ignoreDescription)` | 状态槽及其 `.help`（U-04） |
| 底栏 | “开始监控”链接 | 状态槽按钮（U-04） |
| 底栏 | 条数与加载转圈 | 搜索占位“搜索 N 条”和搜索框内转圈（U-03） |
| 底栏 | 分类菜单（含勾选已属分类、新建分类） | 右键“加入分类”（已有）、拖到分类标签（已有）、多选操作条“分类”（U-05）、“更多 › 所选记录 › 加入分类”（勾选状态与原菜单一致，含“新建分类…”） |
| 底栏 | 收藏 | 卡片动作槽（U-08）、右键（已有）、多选操作条（U-05）、“更多 › 所选记录”、VoiceOver 动作 |
| 底栏 | 详情 | 卡片动作槽、⌘I、Space（已有）、“更多 › 所选记录”、VoiceOver 动作 |
| 底栏 | 编辑 | 卡片动作槽、⌘E（已有）、“更多 › 所选记录”、VoiceOver 动作（已有） |
| 底栏 | 纯文本复制 | 右键（已有）、“更多 › 所选记录”、VoiceOver 动作；⇧Return 纯文本粘贴（已有） |
| 底栏 | 复制按钮及其 `.keyboardShortcut("c")` | 结果区 ⌘C 由键盘监听处理（已有，L782）；右键“原格式复制”。删除底栏前**先补测试固定现状**：搜索框编辑时按 ⌘C 现在是复制搜索文字还是复制记录（按钮的快捷键可能在键盘监听放行后生效）。删除后行为必须与测试一致，如需在搜索框中保留“复制记录”，在键盘监听中显式实现 |
| 底栏 | 粘贴主按钮与次按钮（默认动作为复制时次按钮是“直接粘贴”） | Return、双击、右键“直接粘贴”、“更多 › 所选记录”的“直接粘贴”和“原格式复制”、VoiceOver 动作；目标应用名显示在状态槽焦点提示中 |
| 底栏 | 已选 N 条 | 多选操作条“已选 N 项”（U-05） |
| 筛选条 | 来源、日期 chip | 筛选按钮计数和 `FilterEditor` 中的单项清除（U-03） |
| 筛选条 | 队列进度与“结束” | 状态槽（面板内）和队列浮窗（面板外）（U-04/U-11） |
| 筛选条 | 前缀条件只读展示 | 搜索框文字本身；前缀问题显示在状态槽 |

### 6.2 不得退化清单

- **输出**：原格式/纯文本、默认动作、⌘1–9 快速粘贴、⇧Return、⌥ 仅复制的转换、合并、队列、Finder 文件复制路径。
- **数据**：编辑保持 ID 与元数据；指纹并发检查；过期、删除、隐藏后重新验证；不迁移、不清空用户库。
- **整理**：收藏、分类多归属、排序、拖入分类（含多选整组拖入）、拖出到外部应用、范围多选、定位、删除撤销与超预算确认。
- **输入**：中文 IME 优先、Tab 原生链、Esc 分级、拖动阈值、浮层关闭时点击的消费、未保存草稿保护。
- **桌面**：非激活面板、目标身份、权限回退、自有窗口识别、置顶、多显示器、全屏。
- **性能**：`ClipCard.equatable()`、输入/列表/统计分开发布、可见区才解码、离屏释放、首屏按视口查询。任何新增参数都要加入 `ClipCard.==`。
- **隐私**：`hideContents` 时状态槽、队列浮窗、预览都不泄露正文；新增窗口遵守 `excludeFromSharing`。
- 不改 `LocalClipCore` 的存储、查询、schema 和粘贴管线。

### 6.3 输入方式对照（§0.2 第 1 条的验收表）

改动后每个单元格都必须有入口；“原有”指现在已经存在、本方案不改的入口。

| 功能 | 鼠标 | 仅键盘 | VoiceOver |
|---|---|---|---|
| 粘贴 / 直接粘贴 | 双击（原有）、右键（原有） | Return（原有）、“更多 › 所选记录” | 卡片动作“复制并粘贴”（原有）、“直接粘贴”（新增） |
| 原格式复制 | 右键（原有） | ⌘C（原有）、“更多 › 所选记录” | 卡片动作“原格式复制”（新增） |
| 纯文本复制 | 右键（原有） | “更多 › 所选记录” | 卡片动作（新增） |
| 纯文本粘贴 | 无（现状即无鼠标入口，本方案不改；可先“纯文本复制”再粘贴） | ⇧Return（原有） | ⇧Return（原有） |
| 收藏 | 卡片动作槽、右键（原有）、多选操作条 | “更多 › 所选记录” | 卡片动作（新增） |
| 加入分类 | 右键（原有）、拖到标签（原有）、多选操作条 | “更多 › 所选记录 › 加入分类” | 右键菜单（原有）、“更多”菜单 |
| 详情 | 卡片动作槽（原有）、右键（原有） | ⌘I、Space（原有） | 卡片动作（新增） |
| 编辑内容 | 卡片动作槽（原有）、右键（原有） | ⌘E（原有） | 卡片动作（原有） |
| 重命名 | 双击标题（收窄到标题文字）、右键（原有） | ⌘R（新增） | 卡片动作（原有） |
| 合并粘贴 / 加入队列 | 右键（原有）、多选操作条 | 多选操作条在 Tab 链中 | 右键菜单（原有）、多选操作条 |
| 开始 / 停止监控 | “更多”菜单（原有）、状态槽按钮 | “更多”菜单（原有） | 同左 |
| 撤销删除 | “更多”菜单（原有） | ⌘Z（原有） | “更多”菜单 |
| 清除筛选 | `FilterEditor`（原有）、空态按钮（原有） | 同左（Tab 链） | 同左 |
| 结束粘贴队列 | 队列浮窗、状态槽、菜单栏（原有） | 菜单栏（原有） | 同左 |
| 查看状态与错误全文 | 状态槽点按 | 状态槽在 Tab 链中 | 状态槽朗读 + 通告 |

---

## 7. 验证

遵循 `AGENTS.md`：

- 默认只跑无桌面副作用的测试：`rtk proxy bash macos-app/scripts/test.sh --filter <suite>`。相关套件：`CommentUITests`（L191 `hasFilterStrip` 断言需改写）、`ReviewMetadataLoadingTests`（L45 需改为 `searchFocusRequest`）、`ClipRenameInteractionTests`（L93 断言 `headerRect` 为整行宽度，U-19 需改写）、`QuitFocusTests`、`SpecifiedReviewVisualTests`、`ClipContentEditorTests`、`SizeLabelVisualTests`、`ReviewRemediationVisualTests`、`SpecifiedReviewUITests`、`TransformMenuTests`、`InspectorPreviewLayoutTests`。U-02 改动了共享几何，批次 A 合入前需要跑完整安静套件。
- 新增单测：`cardSide` 单调性与 `H−72`、`forwardsToSearch`、`handleEscape` 分级、状态槽优先级与 `messageSeverity`、`panelPresented`/`panelAnimationGeneration` 重入、快捷键角标的修饰键匹配、`focusRequest` 推动文件卡片重新校验、搜索框中 ⌘C 的现状固定测试、多选状态下拖到分类标签整组加入、“更多 › 所选记录”各项与原底栏可用性一致、卡片新增 VoiceOver 动作存在且可用性正确。
- 视觉：用 Debug `--render-ui` 合成数据渲染 280/340/520 三档高度 × 深浅色 × 680/1440 两档宽度，与 `size-280-visible.png` 等基线对比。
- **交互验收**（IME 首键转发、动画观感、打开后立即粘贴、队列浮窗、多显示器）需要用户明确授权后才能设置 `LOCALCLIP_INTERACTIVE_TESTS=1` 运行；未授权时在交付说明中单独列为“未覆盖”，不能算作通过。
- 性能回归门槛：同硬件、同 Release、同合成库，打开面板和搜索的 p95 相对基线恶化同时超过 10% 和 10ms 时，不得合入。

---

## 8. 不在本轮范围

联网链接预览、OCR 入库检索、富文本保格式编辑、复制自动入栈与反转、云与 AI、单击直接粘贴、取消删除保护、改变分类多归属、重写列表或 UI 框架。上述项目如有需要，另立需求。

## 9. 已确认决策

- D1：卡片头部采用 Paste 式来源色实色头部 + 白字（2026-10-19）。
- D6：工具栏完全移除品牌图标与字样（2026-10-19）。

本方案无其他待决事项，可按第 5 节顺序开始实施。
