# 历史管理窗口 UX 修正提示词（2026-10-21）

在仓库根目录 `/Users/ronny/VscodeProjects/rea` 下工作，回复中文。

## 背景

LocalClip（`macos-app`，Swift 6，macOS 15）的“历史管理”窗口已实现，全选作废修复也已在真实界面验收通过。用户反馈：**明细很不直观，看不到具体历史记录的内容。**

对照已确认原型（https://claude.ai/artifact/PebmmJYrF2LQRX8X4bLeG8 的 `project/Main.dc.html`；设计全文见 `macos-app/docs/history-manager-review-prompt-20261021.md` 第 18–80 行），结构一致，主要差在表格的宽度分配和几处交互细节。

本次只修 UX，不改存储层、schema、窗口模型的全选与写入逻辑（全选身份 `selectAllID` 刚验收通过，不要动）。

## 约束

- 遵守 `AGENTS.md`：默认只跑无桌面副作用的测试；弹窗、窗口测试和真实界面操作需要用户在对话里明确同意。
- 尽可能复用已有组件，禁止重复造轮子；底部历史面板的布局和行为不得改变。
- 不提交、不推送、不发布、不安装，除非用户另行要求。

## 真实界面观察（证据）

截图在 `/Users/ronny/Library/Application Support/Claude/side-session-notes/local_5b69d58d-bdff-467e-8fef-55e117532dd8/ux-shots-20261021/`，窗口为默认 1120×700，检查器打开。

## 待修问题（按优先级）

### P1 名称列被压到约 100pt，内容看不见

- 现状：`HistoryManagerView.swift` 中 `TableColumn("名称")` 未设宽度，被压得很窄，每行只剩 “UI verify ro…”；最后一列右侧却空着一大块（见 `A2-*.jpg`）。
- 原型：名称列 `flex: 1`，占满表格剩余宽度；来源 92px、最近复制 112px 固定。
- 要求：名称列成为唯一伸缩列（例如 `.width(min: 200, ideal: 360)`），其余列保持窄而固定；表格不再出现右侧空白。
- 验收：默认窗口、检查器打开时，名称列至少占表格宽度一半，“UI verify row 29” 这类文字完整可见。

### P1 一行里能看到的内容太少

- 现状：`NameCell` 只有在有自定义名称时才显示灰色的 `row.preview`；未命名记录只显示首行，截断后相邻记录难以区分。
- 原型：主文字 = 名称或首行；有名称时后接灰色首行。保持这个规则。
- 要求：在不改行高的前提下，让用户不点开也能分辨内容，例如给名称单元格加 `.help(...)` 显示较长的内容预览（复用已有的摘要字段，不新增读取正文的查询）。隐藏内容（`hideContents`）开启时不得泄露正文。
- 如果你认为需要更大改动（例如两行行高），先说明理由，等用户确认再做。

### P2 默认窗口尺寸

- 现状：`HistoryManagerWindow.swift` 默认 1120×700。原型为 1180×820。
- 要求：默认尺寸改为 1180×820；已有 autosave 帧的用户不受影响。

### P2 跨页全选时，行勾选框与“已选择 N 条”不一致

- 现状：点“选择全部 29 条”后，批量栏显示“已选择 29 条”，但表格里只有原先勾的 2 行是勾选状态（见 `A1-*.jpg`）。
- 要求：全选状态下，可见行的勾选框应全部显示为选中，或用其他方式明确表示“全部已选”。

### P2 表头缺少“选择本页全部”勾选框

- 原型第一列表头有一个勾选框，用于选择或取消本页全部（`aria-label="选择本页全部"`）。实现里表头为空。

### P2 新建分类按回车后提示“已存在同名分类”

- 现象：侧栏点“+”，输入“验证”后回车，分类已创建，随即又弹出“已存在同名分类，请使用其他名称”。
- 原因推测：`onSubmit(commit)` 和 `onChange(of: draftFocused)` 失焦时都会调用 `commit()`，导致提交两次。
- 要求：从根上修：`commit()` 只生效一次（例如先把 `creating` 置为 false 再执行创建）。回车、失焦、Esc 三种路径都要覆盖测试。

### P3 “历史已变化，已取消全选，请重新选择”提示在真实界面没看到

- `HistoryManagerModel.expireSelectAll` 会调用 `show(...)`。但真实界面中，全选后写入新记录（菜单展开期间），1 秒后截图里没有这条提示（见 `A2-*.jpg`、`B2-*.jpg`），全选是静默清除的。
- 要求：查明提示是没显示、被覆盖还是过早消失，确保用户能看到全选被取消的原因。

### P3（低把握）快速连点相邻两行勾选框时，弹出了编辑附页

- 现象：新建分类后快速点击第 2、3 行勾选框，第 2 行没勾上，随后弹出第 3 行的编辑附页。可能是 `contextMenu(... primaryAction:)` 把两次点击当成了双击。
- 要求：先确认能否复现。若能，点击勾选框列不应触发 `primaryAction`。

## 验证

1. 针对改动补静默用例（新建分类只提交一次、全选时勾选状态、默认尺寸等可在模型或纯视图层测的部分），运行：
   `rtk proxy bash macos-app/scripts/test.sh --filter 'HistoryManagerTests|HistoryPaging|InspectorPreviewLayout'`
2. 涉及共享组件时，跑完整静默套件 `rtk proxy bash macos-app/scripts/test.sh`。已知 `HistoryManagerTests.selectingAllRefusesWrites` 在全量并行负载下偶发等待超时，单独重跑会通过；如再出现，单独说明。
3. 真实界面复核需要用户同意。获准后用隔离验收包：
   `rtk proxy bash scripts/build-gui-check.sh evidence/manual/<新目录> named`（在 `macos-app` 下运行），不碰真实剪贴板和真实历史；截图对比上面的 P1、P2 项。

## 输出

- 每个问题：改了什么（文件:行）、怎么验证的、结果。
- 没做或没能验证的项单独列出，说明原因。
- 测试命令与结果；跳过的交互测试单独报告。
