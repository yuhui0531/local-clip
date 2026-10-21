# 历史管理窗口遗留问题修复提示词（2026-10-21）

在仓库根目录 `/Users/ronny/VscodeProjects/rea` 下工作，回复中文。

## 背景

历史管理窗口（`macos-app/Sources/LocalClipMac/UI/HistoryManager*.swift`）已做过三轮 UX 修正，并在真实界面复核了三轮。报告在：
- `macos-app/evidence/manual/ux-fix-20261021/`（第一轮截图）
- `macos-app/evidence/manual/ux-fix2-20261021/review-20261021.md`
- `macos-app/evidence/manual/ux-fix3-20261021/review-20261021.md`

除 B3 外，其余各项都已复核通过（第一轮遗留的列宽、全选作废提示、勾选列连击、新建分类，第二轮的来源行、预览填满、多选汇总、底部面板）。下面是还没解决或没验证的问题，按优先级排列。工作区里有未提交的改动，都是这几轮的修改，请在其基础上继续，不要回退。

## 约束

- 遵守 `AGENTS.md`：默认只跑无桌面副作用的测试；弹窗、窗口测试和真实界面操作需要用户在对话里明确同意。不要设置 `LOCALCLIP_INTERACTIVE_TESTS=1`。
- 尽可能复用已有组件，禁止重复造轮子。
- 底部历史面板的布局和行为不得改变（`LC-F01` 测高规则、“记录信息”默认折叠、分类编辑弹窗）。
- 不改存储层和 schema；全选身份 `selectAllID` 的逻辑不要动。
- 先查明原因再改；拿不准的，写出依据和可选方案，不要猜着改。
- 不提交、不推送、不发布、不安装，除非用户另行要求。

## 问题

### 1. B3 检查器首次打开的默认宽度（已改，待真实界面确认）

- 现象：`inspectorColumnWidth(min: 300, ideal: 400, max: 640)`，偏好清空后首次打开，检查器仍约 300pt。
- 已做的修改：`HistoryManagerWindow.init` 在挂上 `contentViewController` 之前，先把内容视图设成默认尺寸 `content.view.setFrameSize(Self.defaultSize)`。推测的原因是：窗口先缩到内容的初始尺寸再放大，检查器在窄窗口里被压到最小值，之后不再回到理想宽度。这个推测还没有在真实界面证实。
- 要做的：
  - 用隔离验收包确认首次打开约 400pt（见文末“验证”）。
  - 若仍不对，查 SwiftUI 是否为分栏或检查器存了状态（`ideal` 的文档说明是“在没有状态恢复时的初始宽度”），也查 `NSHostingController` 的 `sizingOptions = []` 与 `sceneBridgingOptions` 是否有影响。给出原因和方案，不要自建宽度持久化。
- 已知限制，不算缺陷：在 1180 宽的窗口里，检查器最多只能拖到约 447pt，是被表格最小宽度挡住了。

### 2. 造数据时偶尔漏掉一条记录

- 现象：验收用的造数据工具向私有命名剪贴板 `local.localclip.gui.scaling-check` 每 0.45 秒写一条。写 28 条只入库 27 条（缺第 18 条），写 64 条只入库 63 条（缺第 23 条）。
- 造数据工具：`/private/tmp/claude-501/-Users-ronny-VscodeProjects-rea/32b8b503-af4b-4af1-b5a8-add17a9e24e6/scratchpad/gui/seed.swift`（可能已被清理，逻辑很简单：`clearContents` + `setString`，然后 sleep 0.45 秒）。
- 要做的：
  - 查 `macos-app/Sources/LocalClipMac/Features/CaptureCoordinator.swift` 的轮询间隔、`changeCount` 基线、去重、`ownReceipt` 判断，以及忙碌或排队时的丢弃路径。判断这是只在验收包（命名剪贴板）里出现，还是真实系统剪贴板也会漏。
  - 先写一个静默测试复现：用假剪贴板或私有剪贴板，按 0.45 秒间隔连写几十条，统计入库条数。复现后再修；复现不了就写清楚排查过程和怀疑点。
  - 注意：两条内容相同、或者和已有记录重复时，按现有规则合并，不算漏。先确认缺的那条不是重复内容。

### 3. 从“窗口”菜单打开历史管理时的异常（第一轮观察到，之后没再复核）

- 现象：从“窗口”菜单打开时，窗口短暂放大到接近全屏；没有点击，却自动选中了第 22 行，“记录信息”也展开了。当时“记录信息”还是折叠项，现在已改为来源行。
- 要做的：
  - 对照 `AppDelegate` 里打开管理窗口的几个入口：菜单栏、“窗口”菜单、面板“更多”、卡片右键“在历史管理中显示”。看它们在定位记录、激活策略和窗口尺寸上有什么差别。
  - 判断问题 1 的修改是否已经顺带解决了“短暂放大”。
  - 自动选中某一行，只应在“在历史管理中显示”时发生（`reveal` / `pendingReveal`）。其他入口不应残留上次的定位目标，必要时补静默测试。

### 4. 全量测试在负载下偶发超时

- 现象：全量静默套件里，几个测试会偶发超时失败（14–27 秒），单独重跑都能通过，例如：
  - `HistoryManagerTests` 的 `selectingAllRefusesWrites`、`staleSelectAllCallbackIsRejected`
  - `AC11_busyQueueAndPauseDuringRead`、`AC19_E02_publishedExpiryDeadline`、`queuePanelKeepsSkipNotes`、`persistentFailureStopsAfterBound`、`renameSubmissionsStayOrderedAndErrorsStayScoped`、`detailDismissalKeepsRequestedTransform`
- 证据：`macos-app/evidence/automated/20261021-203328-t5iNwP/swift-test.log`、`20261021-203424-Vo3iF6/`。
- 要做的：找出共同原因，例如固定时长的 sleep、按墙钟时间的等待、共享的主线程或 actor 被并行测试占满。改成等待明确的条件或注入的时钟，不要只是把超时时间调大。不要为了测试稳定去改生产行为。

### 5. 小项（可选）

- 部分选中本页时，“选择本页全部”勾选框显示为未选中。可以考虑显示为部分选中（mixed）状态：SwiftUI `Toggle` 不直接支持，先评估，代价大就不做。
- 空格放大全文（第二轮列为可选，当时没做）：评估与表格键入查找、输入框焦点、编辑附页的冲突后再决定，做的话复用 `ClipDetailPreview(fills: true)`。

## 还没在真实界面验证的项（只需验证，不需改代码）

- 检查器 640pt 的上限（需要更宽的窗口）。
- 名称单元格里类型图标的悬停提示。
- 绿色按钮进入真正的全屏后列宽是否正常，以及能否正常退出。
- 图片记录在检查器里按可用空间放大（造数据工具只能写文本，需要另外准备图片记录）。
- 跨页全选收集期间检查器显示“正在选择全部…”（63 条收集太快，没截到，可造 1000 条以上再试）。

## 验证

1. 每处修复补一个静默测试；能在模型层测的，就不要依赖窗口。
2. 运行：
   `rtk proxy bash macos-app/scripts/test.sh --filter 'HistoryManagerTests|HistoryPaging|InspectorPreviewLayout|CaptureRetry'`
   改动共享代码后，跑完整静默套件 `rtk proxy bash macos-app/scripts/test.sh`，并写明偶发失败是否已消除。
3. 真实界面复核需要用户同意。没有电脑控制工具时，构建隔离验收包（在 `macos-app` 下运行 `mkdir -p evidence/manual/<新目录> && rtk proxy bash scripts/build-gui-check.sh evidence/manual/<新目录> named`），交给有电脑控制工具的会话复核。
   - 看默认宽度前，先删掉 bundle `local.localclip.gui-check` 的偏好 `NSWindow Frame LocalClipHistoryManagerWindow`。
   - 只用正式的电脑控制工具，不用脚本注入输入，不动已安装的 LocalClip。

## 输出

- 每项：原因、改了什么（文件:行）、怎么验证的、结果。
- 没做或没能验证的项单独列出，说明原因。
- 测试命令与结果；跳过的交互测试单独报告。
