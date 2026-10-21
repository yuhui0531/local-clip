# LocalClip 当前架构

> 本文描述代码的**当前**状态。`docs/` 下其他文档多为逐版本的过程记录，与本文冲突时以本文和代码为准。

## 模块

| 模块 | 职责 | 关键文件 |
|---|---|---|
| `LocalClipCore` | 纯值模型、SQLite 存储、检索；不依赖 AppKit | `Domain/Domain.swift`、`Storage/HistoryStore.swift`、`Storage/CommitStrategy.swift`、`Storage/Schema.swift` |
| `LocalClipMac` | 剪贴板采集、粘贴、菜单栏面板与设置 UI | `Features/CaptureCoordinator.swift`、`Features/PasteCoordinator.swift`、`UI/AppDelegate.swift`、`UI/HistoryViewModel.swift`、`UI/HistoryView.swift` |
| `LocalClip` | 可执行入口；Debug 下另含视觉/崩溃探针 | `App/main.swift` |

## 存储

- **位置**：`~/Library/Application Support/LocalClip-LocalEdition/History/history.sqlite`。
- **并发**：`HistoryStore` 是 actor，所有读写在其内串行；每次读取开一个短连接（实测 <1 ms）。
- **写入协议**（`CommitStrategy.commit`）：在原库上 `BEGIN IMMEDIATE` → 变更 → 配额检查（事务内按非空闲页计算，`auto_vacuum=FULL` 在提交时截断）→ `COMMIT`。
  - `journal_mode=DELETE` 回滚日志 + `synchronous=FULL` + `fullfsync=ON`：崩溃后 SQLite 自动回滚热日志，只会留下完整旧态或完整新态（`CrashRecoveryTests` 以真实 SIGKILL 覆盖每个断点）。
  - 超配额、故障注入或任何错误 → `ROLLBACK`；`dryRun`（容量预览、`canCapture`）执行同样变更后回滚。
  - 只有首次建库使用 staging 候选库 + `rename` 发布，保证不会出现半份 schema。
  - 启动 `recover()` 清理 staging 与崩溃遗留的非热日志，并做 `quick_check`；完整 `integrity_check` 由维护任务在面板隐藏时每天执行一次（在存储 actor 内，期间写入排队而不会因锁超时失败；仅确认损坏时进入不可用流程）。
- **Schema 版本**：当前 v4，卡片名称存于 `clips.title/normalizedTitle`。全新开发阶段不做旧库升级：版本不等的库拒绝打开且不修改文件。
- **派生数据**：缩略图在采集后台解码阶段生成并随记录同一事务写入 `thumbnails`；旧记录首次展示时补写，不递增 storeRevision。

## 采集 → 入库

`CaptureCoordinator` 每 200 ms 比较 `changeCount` → 标记/排除检查 → 后台读取正文 → 后台解码 + 生成缩略图 → `HistoryStore.ingest`。本应用写入的剪贴板由收据（计数+指纹）精确过滤。

## 粘贴

`PasteCoordinator.perform`：读取载荷 → 写剪贴板 → 激活原目标并等待焦点恢复 → 发送 ⌘V；任一步不满足时回退为「已复制 + 提示」。成功写入剪贴板的记录按设置「复制或粘贴后移到最前」调用 `HistoryStore.touch`。

## 交互默认值

- Enter：直接粘贴（`defaultAction`，可在设置改为仅复制）；⌘C 仅复制；Shift+Enter 纯文本粘贴；双击正文粘贴。
- 再次打开应用：同版本只显示历史面板；磁盘上的安装版本变化时才启动新实例接替旧进程。

## 历史管理窗口

- **入口**：菜单栏「历史管理… ⌥⌘H」、面板「更多 › 历史管理…」与面板内 ⌥⌘H、卡片右键「在历史管理中显示」（打开并选中所选记录）。
- **结构**：`HistoryManagerWindow`（`NSWindow` + `NSHostingController`，桥接工具栏与标题，尺寸位置自动记忆，最小 900×560）承载 `HistoryManagerView`（侧栏 | 表格 | 检查器）。打开时切到常规应用出现在 Dock/⌘Tab，关闭时恢复原激活策略并释放模型与事件订阅。共享屏幕排除设置同样作用于该窗口。
- **状态**：`HistoryManagerModel` 自有查询、页码与选择，不改动面板状态；按 `SearchRequest.offset` + `countTotal` 按页码取页（每页 100 时分两次取 50），删除后页码越界回到最后一页；订阅 `store.events()` 刷新。搜索框沿用面板前缀语法（`SearchQueryParser`）。
- **写入**：收藏、分类、删除都走 `HistoryViewModel.commit`（预览 → 按存储规则确认附页 → 提交），删除可在提示条或 ⌘Z 撤销；重命名、编辑内容直接调用存储接口。只复制，不直接粘贴。
- **按键**：由 `AppDelegate` 本地监视器转交 `HistoryManagerModel.handleKey`；文字编辑、输入法组字与附页期间一律交还系统。

## 性能基线（M2 Max，Release，3000 条 / 261 MiB）

| 指标 | 值 |
|---|---|
| ingest p50 / p95 / max | 2.9 / 3.6 / 25 ms，不随库大小增长 |
| 重命名 | 3.2 ms |
| 首页浏览 / metadata | 1.1 / 0.6 ms |
| 字面检索 | 13–24 ms |
| 启动 recover | 72 ms |
