# LocalClip 历史管理窗口：Review Agent 审查提示词

> **使用方式**：在 LocalClip 仓库（`/Users/ronny/VscodeProjects/rea`）中，把本文件交给一个能读代码、能跑本地测试的 coding Agent。
> - 被审查的改动尚未提交，位于当前工作区。
> - 本文件只授权**审查与静默测试**，不授权修改业务代码、提交或发布。
> - 不授权任何桌面交互：启动或激活应用、打开窗口、打开系统设置、真实粘贴或拖拽都不允许。

## Role

你是独立的代码审查者。你要找出这次“历史管理窗口”改动中的**真实缺陷、规格偏离、回归风险和测试漏洞**，不是复述实现，也不是重写方案。

- 回复使用中文。
- 每条结论都要附证据：代码位置、可复现的输入或操作序列、测试输出。
- 没有证据的猜测请标为“待确认”，并说明需要什么才能确认。

## 背景与规格

为菜单栏剪贴板应用 LocalClip（`macos-app`，Swift 6，macOS 15）新增一个独立、可缩放的“历史管理”窗口。原有底部历史面板及其全部功能必须保持不变。用户明确要求：**尽可能复用已有组件，禁止重复造轮子。**

已确认的设计如下（原型：https://claude.ai/artifact/PebmmJYrF2LQRX8X4bLeG8，打不开时以下文为准）。

**整体布局**：三栏，依次为侧栏、表格、检查器。工具栏只有侧栏开关、标题与记录数、搜索、检查器开关。

**侧栏**：
- 资料库：全部历史、收藏。
- 类型：文本、链接、图片、文件、混合。
- 分类：用户自建，带“+”按钮可在列表内新建：
  - 回车或失焦即创建，Esc 取消；
  - 颜色自动分配；
  - 名称重复时拒绝创建。

**表格上方的条**：
- 平时是筛选条：时间分段（全部 / 今天 / 近 7 天 / 近 30 天）、来源选择、清除筛选。
- 多选时在同一位置换成批量条：已选择 N 条、选择全部 N 条、收藏、分类…、删除、取消。

**表格**：
- 列：勾选框、类型图标、名称（收藏星标、次要文字、分类圆点）、来源、最近复制。
- 每行的编辑和删除按钮在悬停或选中时显示。
- 双击进入编辑。

**分页栏**：显示“1–10，共 N 条”；“每页”可选 25 / 50 / 100；上一页、页码输入框“/ N”、下一页。

**检查器**：
- 单选时依次显示：
  - 可编辑的名称和星标；
  - 来源行；
  - 按类型区分的预览；
  - 分类标签和“＋ 分类”；
  - 折叠的“记录信息”；
  - 按类型出现的附加按钮（复制图中文字 / 在访达中显示 / 打开链接）；
  - 主按钮“复制”。
- 多选时只列出所选记录的名称。

**右键菜单**：复制、纯文本复制、编辑…、收藏、分类、在历史面板中定位 ⌘G、删除。

**删除**：
- 多条或含收藏时，按存储层规则弹出确认附页。
- 删除后的提示条提供“撤销”，⌘Z 也可撤销。

**快捷键**：↩ 或 ⌘C 复制，⌘E 编辑，⌘D 收藏，⌫ 删除，⌘A 全选，Page Up / Page Down 翻页，Esc 取消多选。

**入口**：
- 菜单栏“历史管理… ⌥⌘H”；
- 面板“更多 › 历史管理…”，面板内也可按 ⌥⌘H；
- 卡片右键“在历史管理中显示”：打开窗口并选中该记录。

**关键决策**：
- 窗口自有查询、页码和选择状态，不改动面板状态。
- 写操作复用面板的“预览 → 确认 → 提交”流程（`HistoryViewModel.commit`）。
- 窗口**只复制，从不直接粘贴**到其他应用。
- 不改 schema、不加索引（schema v5，版本不等的库拒绝打开）。
- 存储单页上限 50 条，所以每页 100 条时分两次读取。
- 名称列不可排序（SQLite 没有拼音排序）。

**实现者自述的偏离**：
- 代码预览没有行号。
- 只有“最近复制”表头能切换正序/倒序，其余排序在筛选条的排序菜单里。
- Esc 不关闭窗口。

请判断这些偏离是否可以接受。

## 被审查的改动

用 `git status` 和 `git diff` 查看。`Domain.swift` 和 `HistoryStore.swift` 中的 `HistorySortOrder` 排序改动来自更早的一次会话，被本次保留并补了测试，**在审查范围内**。

| 文件 | 改动要点 |
| --- | --- |
| `Sources/LocalClipCore/Domain/Domain.swift` | `SearchRequest.offset`（无游标时的起始位置，不计入 `signature`）、`countTotal`；`SearchPage.total`；`HistorySortOrder` |
| `Sources/LocalClipCore/Storage/HistoryStore.swift` | `searchExecution`：浏览路径用 `COUNT(*)`；字面检索路径在最终 SELECT 里加 `(SELECT COUNT(*) FROM matching)`；只有 `countTotal && cursor == nil` 时才计数。新增 `categoryMemberships(_:)`，一页一次查询分类归属。排序 ORDER BY 切换 |
| `Sources/LocalClipMac/UI/ClipDetailContent.swift`（新增） | 从 `HistoryViewModel.loadDetail` 抽出的详情加载：富文本、高亮、识别结果、原图、是否可编辑 |
| `Sources/LocalClipMac/UI/HistoryManagerModel.swift`（新增） | 窗口状态与操作。重点看 `reload`（越界回退、两次取页）、`publish`、`reveal`、`selectAllMatching`、`apply`、`handleKey` |
| `Sources/LocalClipMac/UI/HistoryManagerView.swift`（新增） | `NavigationSplitView` + `Table` + `.inspector` + `.searchable`；提示条；编辑附页（复用 `ClipContentEditor`） |
| `Sources/LocalClipMac/UI/HistoryManagerWindow.swift`（新增） | `NSWindow` 子类：最小 900×560，自动保存窗口位置尺寸，`onClose` |
| `Sources/LocalClipMac/UI/AppDelegate.swift` | `showHistoryManager(reveal:)`；激活策略在打开时切为 `.regular`、关闭时恢复；`applySharing` 覆盖新窗口；状态栏菜单与主菜单“窗口”加入入口；本地按键监视器把管理窗口的事件转交 `handleKey`；面板 ⌥⌘H |
| `Sources/LocalClipMac/UI/HistoryViewModel.swift` | 抽出共用代码：`commit`、`changeMessage`、`output`（复制并记录使用）、`restoreDeleted`、`openTargets`、`renameFailure`、`undoFailure`、`categoryFailure`。新增 `openHistoryManager` 回调；`jumpToHistory(category:id:)`；事件订阅里同步 `canUndoDeletion` |
| `Sources/LocalClipMac/UI/HistoryView.swift` | 从面板详情抽出 `ClipDetailPreview` 与 `ClipRecordInfo`；新增 `displayTitle`、`sourceDescription`；`CopyAge` 改为 internal；“更多”菜单和卡片右键加入口 |
| `Sources/LocalClipMac/UI/ClipContentEditor.swift` | 编辑状态新增 `init?(detail:)`、`detectLanguage()`、`save(to:)`，以及共用的错误文案 |
| `Tests/LocalClipCoreTests/HistoryPagingTests.swift`、`Tests/LocalClipIntegrationTests/HistoryManagerTests.swift`（新增） | 分页、总数、排序、筛选、删除后页码回退、撤销、按键；另有一个由 `LOCALCLIP_MANAGER_PERF` 控制、默认不运行的 1 万条性能测试 |
| `docs/architecture.md`、`docs/performance.md` | 窗口结构说明与分页实测数据 |

## 审查重点

请对下列清单逐项给出结论：**问题 / 无问题 / 无法判断**。不要只挑容易的项。

### A. 存储层分页与总数

1. **快照与条件一致性**：`total` 与本页数据是否来自同一快照、同一组条件？分别检查浏览路径与字面检索路径，以及收藏、类型、分类、来源、时间、排序的各种组合。
2. **字面检索的总数**：经过候选集缓存收窄（`candidate_set LIMIT 5001`）后，总数还对吗？命中超过 5000 条时，深页（如 offset 9950）还能取到数据吗？
3. **越界处理**：浏览路径越界抛 `invalidCursor`，字面检索路径越界返回空页。模型依赖这一差异做回退，这一差异本身是否稳定可靠？
4. **查询身份**：`offset` 不计入 `signature`，会不会让面板的旧结果缓存或续页校验出错？
5. **`categoryMemberships`**：SQL 参数个数有没有上限风险？对已删除的 id 是否安全？
6. **排序（`HistorySortOrder`）**：
   - 排序值相同时次序是否稳定？
   - 多次分页时会不会重复或遗漏记录？
   - `orderParams` 只在 `recentDesc` 加单一分类时生效，这一点是否正确？

### B. 窗口模型（`HistoryManagerModel`）

1. **竞态**：在 `reload` 期间改筛选、翻页、收到存储事件、关闭窗口，会不会让旧结果覆盖新状态？`loadTask` 被取消后，还会不会写入 `rows`、`page`、`loading`？
2. **每页 100 条**：两次取页之间如果有新记录写入，第二次的 offset 会不会造成重复或遗漏？
3. **删除后回退**：删光最后一页后回退到最后一页的逻辑，会不会死循环或多次重入？
4. **选择状态**：
   - `selection` 和 `allMatching` 在换页、换筛选、事件刷新、删除后是否正确失效？
   - `selectAllMatching` 跨页收集 id 时不校验 revision，期间记录变化会怎样？
   - 拿 1 万条 id 做批量删除，耗时如何、会不会撞上 `deletionEstimate` 的 4096 条上限？
5. **`reveal`**：只在首页里找要选中的记录，不在首页就报“记录已删除、到期或不在首页”。这对“在历史管理中显示”是否构成功能缺陷？
6. **详情加载**：`loadDetail` 的去重条件（summary、分类、指纹）会不会漏掉重命名、编辑内容、分类变化后的刷新？
7. **按键（`handleKey`）**：
   - 文字编辑、输入法组字、附页打开、编辑器打开时，是否一律交还系统？
   - ⌘C 在没有选择时也被吞掉，是否合理？
   - ⌫ 长按（`isRepeat`）处理是否正确？
   - **隐藏内容**（`hideContents`）时，⌫ / ⌘D / 批量操作仍可执行，面板在这种情况下不允许盲删。
8. **事件订阅**：
   - 窗口打开期间每复制一次就收到 `.changed` 并整页重查（含计数）。频繁复制时是否需要合并或防抖？
   - `.settings` 事件是否也要刷新来源列表 `sources`？
   - 窗口关闭后订阅和任务是否全部释放？
9. **撤销状态**：管理窗口的 `canUndo` 与面板的 `canUndoDeletion`、`recordUndoQuery`、`pendingDeletion` 是否一致？调用 `restoreDeleted()` 会不会误改面板状态？

### C. 写入与确认

1. **确认附页的挂载**：`apply` 用 `ChangeConfirmation.confirm`，它挂在 `NSApp.keyWindow` 上，而它的注释写的是“只承载设置窗口发起的确认”。在管理窗口里调用时，keyWindow 一定是管理窗口吗？附页显示期间，按键和焦点关闭逻辑会不会受影响？
2. **面板乐观移除**：`commit` 没传 `willApply` / `didApply`，所以管理窗口删除时面板不会先行移除卡片，只靠事件刷新。面板在可见和不可见两种状态下表现是否都正确？
3. **重命名**：管理窗口直接调用 `store.renameClip`，没有面板的世代保护。快速连续提交会不会乱序？名称框是否会在保存成功前被外部刷新覆盖？
4. **新建分类**：失焦提交、回车提交、Esc 取消三者交织时，会不会重复创建或丢失输入？
5. **编辑附页**：
   - 保存失败时草稿是否保留？
   - Esc 能否先收起“放弃修改”确认？
   - ⌘S 是否可用？
   - 附页打开期间，窗口的按键监视器是否正确让路？

### D. 共用代码抽取（面板回归风险，最高优先级之一）

逐一对照抽取前后的行为（可用 `git diff` 看原实现）：

1. **`perform` → `output`**：`recordUse` 原来在提示显示之后执行，现在在之前，时序变了。`notifyPasteResult` 依赖面板的 `message`，顺序是否仍然正确？
2. **`beginContentEdit`**：改用 `ClipContentEditorState(detail:)` 和 `detectLanguage()` 后，丢掉了原来的 `contentEditor === editor` 守卫。编辑器被关闭或替换后，识别结果仍会写入已废弃的对象，这是否无害？
3. **`saveContentEdit` → `editor.save(to:)`**：错误映射与 `saving` 状态是否完全等价？
4. **`undoDeletion` → `restoreDeleted`**；**`openSelected` → `openTargets`**；**粘贴队列摘要 → `displayTitle`**：行为是否等价？
5. **`ClipDetailPreview` / `ClipRecordInfo`**：从面板 `ClipInspector` 抽出后，面板详情的布局、高度和 `LC-F01` 长文滚动行为是否不变？
6. **事件订阅里新增 `canUndoDeletion` 同步**：会不会让面板 ⌘Z 在 `recordUndoQuery` 判定上出错？
7. **重复造轮子检查**：还有没有重复实现可以复用已有组件或函数？实现者认为必须自写的有三块，请评估理由是否成立：
   - 带“撤销”按钮的提示条：面板现有提示无按钮；
   - 多条记录的分类菜单：面板的 `SelectedCategoryItems` 只服务单条选中；
   - 表格、侧栏、分页栏：面板没有对应组件。

### E. 窗口、菜单与系统集成（静态审查，不要运行）

1. **激活策略**：只在首次创建时记录原策略。下列情况会怎样？
   - 设置窗口与管理窗口同时打开后，先关管理窗口；
   - 调试验收宿主（`GUIAcceptanceProbe`）本来就是 `.regular`。
2. **按键监视器**：新增的管理窗口分支放在“面板内容编辑器”分支之前。面板置顶并打开编辑器时，两边按键会不会互相干扰？面板的失焦关闭（`ownsHistoryWindow`）在 `showingDetail` 等状态下，会不会把管理窗口误判为“属于面板”而不关闭面板？
3. **共享屏幕排除**：新窗口在创建时和设置变化后，是否都应用了排除？
4. **快捷键冲突**：⌥⌘H 在状态栏菜单、主菜单、面板本地三处注册，会不会重复触发？会不会与系统快捷键冲突（⌥⌘H 是系统“隐藏其他应用”）？
5. **SwiftUI 实现细节**：
   - `NSHostingController` 设置了 `sceneBridgingOptions = [.toolbars, .title]` 和 `sizingOptions = []`，窗口最小尺寸和位置恢复能否生效？
   - `Table` 的 `sortOrder` 与排序菜单的双向同步，会不会循环触发？
   - 悬停才显示的行按钮在透明时是否仍可被点击或聚焦？对 VoiceOver 是否可达？

### F. 测试与性能

1. **覆盖缺口**：新测试漏掉了哪些关键路径？至少检查：
   - 来源筛选；
   - 前缀语法（`app:`、`in:` 等）；
   - 每页 100 条的两次取页；
   - 名称列表的空状态；
   - `reveal`；
   - 编辑保存；
   - 新建分类重名。

   请写出最小可复现测试的草稿（只写在回复里，不改仓库）。
2. **可靠性**：测试里用轮询等待（`until`），在负载下会不会偶发失败？
3. **性能数据**：`docs/performance.md` 的数据基于 Debug 构建和纯文本记录。结论措辞是否过度？

## 允许运行的命令

只允许静默测试，不得设置 `LOCALCLIP_INTERACTIVE_TESTS=1`：

```bash
rtk proxy bash macos-app/scripts/test.sh --filter 'HistoryManagerTests|HistoryPaging|InspectorPreviewLayout|CommentUI|CommentFeature|ReviewMetadataLoading|ClipContentEditor|ClipRenameInteraction|DerivedAndViewModel|ReviewFixes|ReviewRegression|CategoryDrop|HistoryLoading|SearchRetentionQuota|SpecifiedReviewSearch|HistoryTests'
```

```bash
rtk proxy bash macos-app/scripts/test.sh
```

```bash
LOCALCLIP_MANAGER_PERF=1 rtk proxy bash macos-app/scripts/test.sh --filter 'HistoryPagingTests/tenThousandRowPaging'
```

实现者给出的基线：
- **相关测试**：16 组 123 个测试通过。按测试函数计，115 个通过，8 个跳过（需要桌面交互或另外开启）。
- **全量**：共 514 个测试。按测试函数计，444 个通过，1 个失败，69 个跳过。失败的是 `CaptureRetryTests.sameContentCopiedDuringRetryKeepsNewestFacts`，单独重跑 3 次均通过，实现者判断是负载下的偶发失败，请独立核实。
- **1 万条分页（Debug）**：浏览首页 3.1 ms、末页 6.7 ms；字面检索约 35 ms。

## 输出格式

1. **结论摘要**：3–5 行，说明能否合入，以及阻塞项数量。
2. **问题列表**：按严重度排序（阻塞 / 重要 / 次要 / 建议）。每条包含：
   - `文件:行号`；
   - 问题描述；
   - 触发条件或复现步骤；
   - 影响；
   - 建议修复（一句话，不要贴大段代码）。
3. **清单结论**：A1–F3 逐项给出“问题 / 无问题 / 无法判断”和一句理由。
4. **测试执行记录**：运行的命令、通过/失败/跳过数、证据目录路径。跳过的交互覆盖要单独列出，不能算作通过。
5. **未能验证的事项**：例如真实窗口布局、Dock 切换、VoiceOver。说明原因，以及验证需要用户授权的哪些桌面操作。
