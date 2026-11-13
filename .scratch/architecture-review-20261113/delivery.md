# LocalClip 审查后优化交付

九项任务已落地。上一轮独立验收三次完整运行全量静默套件，均为 **541 个测试函数通过、0 失败、79 跳过**。旧版 M1 的前后运行条件有差异，不能用来量化提速。独立验收发现访达定位后应用退出，修复与复测记录见文末。

## 任务状态

| 任务 | 状态 | 验证结果 |
| --- | --- | --- |
| 1 · M1/M3/M4/M5 | 完成 | Release 四个基准函数通过，旧数据已归档。 |
| 2 · F1 配额 | 完成 | 原实现在越线时将两张派生表都清空。新实现先淘汰最旧普通记录，验证了收藏、其余普通记录和新图的缩略图保留，幸存旧图的 OCR 行不变。 |
| 3 · F2 面板 | 完成，目视待验 | 预热卡片跳过 32 ms，正常动效淡入 0.12 s。隐藏窗口切换、关闭接管和草稿保护测试通过。 |
| 4 · F5 粘贴 | 完成，真实目标待验 | fake 测得原回退参数为 `true`，连续重入产生两次失败提示。修改后回退传 `false`，重入无反馈且首次粘贴成功。 |
| 5 · F3 打开存储失败 | 完成，弹窗待验 | 纯文案映射、坏头文件及 Schema 边界通过。重试复用已有状态栏项。独立验收复现查看数据目录后退出，后续修复见文末。 |
| 6 · F4 去重与占用缓存 | 完成 | 相应 M3 P95 为 161.49 和 1574.46 ms，均达实施门槛。测试覆盖同长度损坏 BLOB 去重后读取报错，以及已有 Staging 文件扩容后统计更新。 |
| 7 · F9 只读预览 | 完成 | 详情保留原 URL 且没有生成 `DragFiles`，输出、显式打开和导出仍可按需恢复。缺失文件的详情标注原件不存在，预览提示可在有副本时复制或另存。 |
| 8 · F10 启动校验 | 完成，使用指定备选 | 在外键损坏的 v5 副本上实证迁移仍能提交、版本变成 v6、文件字节改变。保留打开时检查，首次恢复复用校验结果，之后的恢复继续检查。损坏原库拒绝打开且字节一致。 |
| 9 · F14/F15 | 完成 | 架构文档更新为 v6；偶发超时用例迁至串行套件，两种策略参数串行运行，原 10 秒上限保留。针对用例两种参数均通过，独立验收的全量耗时仍接近上限。 |

## 与报告的差异

- F1、F5、F9 的推导均已复现。已有 OCR 配额测试原先还断言「采集越线保留旧记录」，与新的淘汰顺序冲突，更新为验证旧记录及其 OCR 行一并淘汰。OCR 写入超额仍验证不会淘汰历史。
- F4 的 `canCapture` M3 延迟包含原库预演事务和回滚。占用缓存复用聚合结果，仍重新测量目录字节数以发现原有文件被追加或截断。配额探测的高延迟未归因到聚合查询，缓存改动后的性能未单独测量。
- SQLite 的 `integrity_check` 检查页结构和约束。同长度的 BLOB 损坏可能仍满足 SQLite 约束，正文读取时的摘要校验会检测并报错。
- F10 的单事务只能回滚执行失败的迁移。外键已损坏的旧库能成功执行迁移，故必须在迁移前发现该类损坏。
- 原报告的 `presentHistory()` 现在由 `prepareSurface` 显式传入本次快捷键起点。原先 `loadPayload` 经 `detail` 取得恢复路径，现在两者共用可见性校验，各走自己的载荷路径。

## Release 基线

基于 `5592665`，加计时与基准夹具。MacBook Pro Mac14,5，Apple M2 Max 12 核，32 GB，macOS 15.7.5（24G624），arm64。P50 取中位数，P95 取 nearest-rank。

| 场景 | 样本数 | P50（ms） | P95（ms） | 最大（ms） |
| --- | ---: | ---: | ---: | ---: |
| M3 重复 50 MiB 图片载荷 | 100 | 139.02 | 161.49 | 163.89 |
| M3 约 50 MiB 文件副本 | 100 | 136.51 | 161.67 | 164.59 |
| M3 配额已满 `canCapture` | 100 | 1547.12 | 1574.46 | 1577.36 |
| M3 约 260 MiB 库完整性检查 | 100 | 60.03 | 85.84 | 88.72 |
| M4 50,000 条短文本 | 10 | 117.14 | 135.08 | 135.08 |
| M4 1,000 条 × 1 MiB 文本 | 10 | 418.45 | 468.74 | 468.74 |
| M5 约 260 MiB 库启动恢复 | 10 | 110.91 | 116.44 | 116.44 |
| M5 约 2 GiB 库启动恢复 | 10 | 862.20 | 879.38 | 879.38 |

新版 M1 的同条件对照见文末。M5 未清除操作系统页缓存。 [性能基线](../../macos-app/docs/performance.md)

## 测试证据

本节保留第一轮实施过程，包含后续已重跑的早期失败。最新的完整运行见文末。

下表的参数接在 `rtk proxy bash macos-app/scripts/test.sh` 后。统计单位为测试函数，带参数的用例仍计一个函数。交互开关全程关闭。Release 运行在临时 SwiftPM 副本中使用同一脚本，临时排除了五个无法在 Release 编译的 Debug 专用探针测试文件。未改项目清单。

| 命令参数 | 通过 | 失败 | 跳过 | 结果 |
| --- | ---: | ---: | ---: | --- |
| `-c release --no-parallel --filter 'StorageBaselineTests|HistorySubmissionBaselineTests'`，打开两个基准开关 | 4 | 0 | 0 | 基线 |
| `-c release --no-parallel --filter HistorySubmissionBaselineTests`，打开面板基准开关 | 1 | 0 | 0 | 只加入 F2 后对照 |
| `--filter quotaPressurePreservesSurvivingDerivedRows` | 1 | 0 | 0 | 原实现复现整表清空 |
| `--filter 'SearchRetentionQuotaTests|CrashRecoveryTests|FailureBoundaryTests|StorageFeasibilityTests|ImageTextIndexTests|ClipContentEditTests|ClipRenameTests|ReviewRegressionTests|EndToEndTests'` | 71 | 0 | 0 | 淘汰规则 |
| `--filter 'SurfaceTransitionTests|PasteQueueTests|HistorySubmissionBaselineTests'` | 23 | 0 | 1 | 隐藏窗口及切换 |
| `--filter 'fallbackUsesClipboardFeedback|repeatedPasteProducesNoFailureFeedback'` | 0 | 2 | 0 | 原实现回退传 `true`，重入反馈非空 |
| `--filter 'HistoryPermissionTests|PasteQueueTests|TransformPasteTests|EndToEndTests'` | 36 | 0 | 0 | 粘贴反馈修改后 |
| `--filter 'StorageOpenFailureTests|SchemaTests|StartupCaptureTests'` | 10 | 0 | 0 | 打开失败与启动 |
| `--filter 'FailureBoundaryTests|ImageTextIndexTests|CachedFileCopyTests|ReviewRegressionTests|SearchRetentionQuotaTests'` | 45 | 2 | 0 | 阶段运行，详见下文 |
| `--filter 'corruptV5IsRejectedWithoutChangingDatabase|CachedFileCopyTests'` | 1 | 1 | 0 | 原实现读详情后生成文件，原 URL 和无落盘断言均失败 |
| `--filter 'CachedFileCopyTests|DragFileLifecycleTests|QuickPreviewTests|FileCardPreviewTests'` | 12 | 1 | 5 | 已报告的 RTF 失败；另有进程崩溃 |
| `--filter 'FailureBoundaryTests|HistoryReorderTests|CrashRecoveryTests|SchemaTests|StartupCaptureTests|StorageOpenFailureTests|ExcludedDepartureCaptureTests|CommentFeatureTests'` | 33 | 0 | 0 | 启动校验与串行测试 |
| `--filter 'CachedFileCopyTests|cancellationWaitsForInFlightMaterialization|renamedImageIsolatesInPlaceWrites|FailureBoundaryTests|SchemaTests|SearchRetentionQuotaTests|ImageTextIndexTests|StorageOpenFailureTests|ExcludedDepartureCaptureTests'` | 33 | 0 | 0 | 文件副本、纯存储拖出及配额 |
| 无参数，全量静默 | 144 | 1 个已记录断言失败，未出最终计数 | 70 | 日志停止增长后中止，计数为当时已输出结果 |
| `--skip '<四个已知平台用例>'` | 3 | 0 个已报告失败 | 70 | 并行重跑仍停滞，已中止 |
| `--no-parallel --skip '<四个已知平台用例>'` | 159 | 3 个已收尾失败，另 1 个测试崩溃 | 24 | 私有剪贴板返回空指针，进程退出 |
| 最终相关串行命令（见下） | 101 | 0 | 5 | 4 个基准门控及 1 个可见预览门控 |

```sh
rtk proxy bash macos-app/scripts/test.sh --no-parallel --filter 'SearchRetentionQuotaTests|CrashRecoveryTests|FailureBoundaryTests|StorageFeasibilityTests|ImageTextIndexTests|HistoryReorderTests|SchemaTests|StorageOpenFailureTests|StartupCaptureTests|HistoryPermissionTests|PasteQueueTests|TransformPasteTests|SurfaceTransitionTests|CachedFileCopyTests|cancellationWaitsForInFlightMaterialization|renamedImageIsolatesInPlaceWrites|CommentFeatureTests|ExcludedDepartureCaptureTests|HistorySubmissionBaselineTests|StorageBaselineTests|QuickPreviewTests'
```

并行和串行排除参数均为 `'DragFileLifecycleTests/(sessionCleanupPreservesExternalReferences|largeSelectionPreparationRetainsEveryItem)|FileCardPreviewTests/richTextDocumentThumbnail|ImageTextRecognizerTests/recognizesEveryEXIFOrientation'`。

- 初次 Release 编译有基准夹具错误，修复后遇到仓库现有的 Debug 专用接口引用。出错的文件为 `CaptureRetryTests`、`HistoryLoadingTests`、`HistoryManagerTests`、`PasteQueueTests` 和 `SurfaceTransitionTests`。临时副本首次构建也因源文件在复制时发生变化而停止，固定源码副本重跑通过。
- F1 第一次改后回归为 70 通过、1 失败、0 跳过。旧 `capacityNeverEvictsHistoryForIndex` 的「同时保留两条记录」断言已按任务的新规则修订。
- F4 阶段运行中，`AC25_pendingFilesAreMeasured` 的夹具误将文件句柄指向目录，已修正。该次也选入了 F9 的复现测试，当时尚未实现 F9。
- `richTextDocumentThumbnail` 未取得 RTF 缩略图。 `sessionCleanupPreservesExternalReferences` 遇到 AppKit 拒绝 `public.png` UTI 并终止进程。在未修改的 `5592665` 临时副本上用 `--filter 'sessionCleanupPreservesExternalReferences|richTextDocumentThumbnail'` 复现了两者。
- 全量并行日志中，`recognizesEveryEXIFOrientation` 的八个参数均在夹具的 `CIContext.createCGImage` 得到 nil。串行回退中，`imageFileRule` 的图片后缀识别为 false，`imageFilesAppearInImageAndFileFilters` 的结果少了图片文件，`dragExportsApplicationFileURL` 的私有剪贴板写入失败且读回 nil。 `cardReorderingThroughHostingDestination` 的滚动和拖放操作断言失败，随后在私有剪贴板空指针处终止。
- 自动审批拒绝了在文件系统沙箱外复跑系统服务相关套件，理由是可能触发 Quick Look、Core Image 或拖拽相关桌面服务，当前缺少明确的桌面授权。沙箱外复跑没有执行。

## 待授权的桌面复测

- F2 首帧与 Reduce Motion。在预热后呼出面板，快速开关并在设置和管理界面之间切换，检查首卡布局、焦点、闪烁及半透明残留。开启 Reduce Motion 后复测。
- F3 存储失败。用隔离数据目录分别放入不兼容版本和损坏的库，验证说明、在访达中显示、重试和退出，确认状态栏项只出现一次。
- F5 真实粘贴。在不能恢复 AX 焦点的目标里触发回退，核对剪贴板图标，再手动粘贴验证内容；连续按 Enter 确认只发一次粘贴。
- F9 文件预览及拖出。对原件已删除但有副本的隔离记录打开详情和预览，再复制、另存或拖到访达，核对提示、目标文件和字节。

## 待决定

- F8 搜索框 Enter 是否直接粘贴第一条，涉及现有键盘行为及中文输入法组字。
- 根目录 `AGENTS.md` 引用的 `GLOSSARY.md` 和 `docs/adr/` 均不存在。
- M4 两种负载超过 80 ms 参考值。是否另立任务评估索引及 Schema 方案。

## 2026-11-14 隔离桌面复测

- 修正失效文件卡与详情对副本状态的描述。隔离库中的原件不存在且副本仍在时，卡片实测显示「原件不可用 · 可复制历史副本」，详情显示「原文件不存在 · 已保存副本」。只查询已保存副本的项目索引。交互测试验证真实预览窗口显示恢复指引，且未生成 DragFiles。
- 不兼容库展示版本说明及三个按钮。「在访达中显示数据目录」定位到隔离目录，替换为正常测试夹具后点「重试」进入历史。损坏库展示完整性说明，点「退出」结束隔离应用，测试库 SHA-256 不变。
- 普通和减弱动态效果下，首帧可见测试的两种参数在成功运行中均看到最新首卡和已绘制图片。首次普通动效运行有一个旧卡 OCR 断言失败，复跑通过。现有测试自建面板，未量化真实快捷键连按时的逐帧动画。系统减弱动态效果已恢复为原先的关闭状态。
- 使用未授辅助功能权限的隔离包对同一文本卡连按 Enter，观察到已复制回退提示。手动粘贴到空白文本编辑文稿，内容正确。权限回退仍在状态栏显示权限警示，普通回退提示条的图标与受信任目标的实际发送次数未由桌面复测确认。
- 拖拽探针记录失效文件卡开始拖动后取消，访达目标未收到该次拖出的文件。另以原格式复制后在访达粘贴成功取回 50 字节的副本，与数据库摘要一致。
- 初次补跑全量时，编辑器测试在剪贴板刚写入后即发下一次粘贴，可能命中仍在进行的复制。测试现等待复制完成提示，再发起下一次操作。生产粘贴互斥逻辑保留。


## 2026-11-14 独立验收问题修复

本轮修复已落地。桌面行为待隔离复测，Release 对照测到了隐藏首屏准备完成时约 33 ms 的提交差值，满配额复用结果时的元数据等待明显缩短。

| 任务 | 状态 | 变更及证据 |
| --- | --- | --- |
| 1 · 存储失败弹窗 | 已实现，未验证 | 每次显示创建新弹窗，访达定位后激活 LocalClip。仅第三按钮的返回值退出，Esc 绑定该按钮。连续收到三次非按钮响应就停止显示，保留状态栏退出入口。单测覆盖按钮及异常分支。独立验收复现的是访达定位后进程退出，关于复用同一弹窗时第二次 `runModal()` 异常返回的推断仍待确认。 |
| 2 · M1 面板对照 | 完成 | 关闭后立即呼出与确认首屏准备完成后呼出分别采样。 |
| 3 · 恢复重试校验 | 完成 | 第一次调用在任何可能抛错的操作前消耗打开阶段的校验结果。测试将版本改为 99 触发第一次失败，随后改回 6 并插入孤儿项，第二次调用检测到外键异常并返回 `corruptPayload`。 |
| 4 · 采集用例超时 | 完成 | 第一批改用等待采集排空，耗时仍受并行争用影响。最终把采集套件移到默认全量计划的独立阶段，其他套件继续并行。保留原 10 秒等待、两项断言和真实临时库。最终五次全量均通过，两个参数合计 0.055–0.066 秒。 |
| 5 · 失效文件状态 | 已实现，静默测试通过，桌面待复测 | 按原件存在性和对应序号判断副本状态。卡片显示部分缺失及副本覆盖情况，详情汇总第 5 项以后的文件，恢复访达双击和同名冲突提示。纯函数用例覆盖不同缺失组合。 |
| 6 · 正文损坏反馈 | 完成 | 载荷损坏报告「这条记录的内容已损坏，无法读取」。缺少纯文本的合成错误沿用现有提示。新测试用清零的文本 BLOB 验证提示和写入边界。 |
| 7 · 首帧桌面测试 | 完成编译，桌面待复测 | 预热场景移除额外 32 ms 等待。测试通过编译，默认门控跳过。 |
| 8 · 满配额采集探测 | 完成 | 库修订、目录占用、总字节和配额相同才复用预演结果。OCR、缩略图和恢复显式清理两份缓存。库内容每变化一次，下一次仍执行完整预演，收益来自库不变时的重复调用（主要是定时维护）。新增用例比较每次失效后的结果与新开库实例。 |

本轮用户可见变化涉及弹窗异常返回时的行为、文件卡片和详情文案、正文损坏的复制提示。已有测试断言均保留，变更集中在指定的计时夹具与采集等待，另新增五个测试函数。SQLite 的 FULL、fullfsync、DELETE 和 Schema v6 保持原配置。

### Release 基准

两份临时源码副本只相差 `prepareSurface` 一条等待条件。无等待与有等待交替执行三轮，各轮测试通过 1、失败 0、跳过 0。M3 测试通过 1、失败 0、跳过 0。命令、测量边界和原始样本位置见 [性能基线](../../macos-app/docs/performance.md)。

| 轮次 | 32 ms 等待 | 首屏状态 | 样本数 | P50（ms） | P95（ms） | 最大值（ms） |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 1 | 无 | 已准备 | 50 | 6.36 | 11.58 | 13.81 |
| 1 | 无 | 立即呼出 | 50 | 77.76 | 104.29 | 107.71 |
| 1 | 有 | 已准备 | 50 | 39.29 | 41.37 | 41.82 |
| 1 | 有 | 立即呼出 | 50 | 125.21 | 144.15 | 147.90 |
| 2 | 无 | 已准备 | 50 | 6.01 | 9.74 | 15.20 |
| 2 | 无 | 立即呼出 | 50 | 84.37 | 111.80 | 115.35 |
| 2 | 有 | 已准备 | 50 | 39.53 | 41.60 | 41.83 |
| 2 | 有 | 立即呼出 | 50 | 128.74 | 146.89 | 150.96 |
| 3 | 无 | 已准备 | 50 | 6.09 | 7.09 | 14.08 |
| 3 | 无 | 立即呼出 | 50 | 98.48 | 116.23 | 120.05 |
| 3 | 有 | 已准备 | 50 | 40.43 | 41.49 | 42.51 |
| 3 | 有 | 立即呼出 | 50 | 133.94 | 153.63 | 154.52 |

首屏已准备时，移除等待后各轮 P50 为 6.01–6.36 ms，对照为 39.29–40.43 ms，配对差为 32.93–34.34 ms，高于同组轮次波动。每组 150 个样本按 5 ms 分箱，准备完成场景未见分离的双峰。立即呼出时两组均出现两个聚集区，无等待组主要在 70–75 ms 与 100–110 ms，有等待组主要在 105–115 ms 与 135–145 ms。立即呼出时的 P50 跨轮波动更大，支持首屏准备时序影响旧基准的推断。基准未单独计量等待分支的耗时或命中次数。

| 调用 | 样本数 | P50（ms） | P95（ms） | 最大值（ms） |
| --- | ---: | ---: | ---: | ---: |
| 首次，完整预演 | 100 | 1568.44 | 1591.16 | 1593.55 |
| 紧接第二次，缓存命中 | 100 | 27.25 | 49.65 | 52.29 |

每组同时发起 100 次 `metadata` 请求，测量从请求到返回的总时延，包含元数据请求之间的排队。首次仍执行原预演事务，紧接的第二次在库、占用和配额均未变时命中缓存。内容变化后，下一次仍需完整预演。

### 静默测试与命令

用下列命令执行变更涉及的相关套件。私有命名剪贴板单独开启自己的开关。

```sh
rtk proxy bash macos-app/scripts/test.sh --filter 'StorageOpenFailureTests|StartupCaptureTests|SurfaceTransitionTests|SchemaTests|HistoryReorderTests|CrashRecoveryTests|CaptureRetryTests|ExcludedDepartureCaptureTests|CommentFeatureTests|CachedFileCopyTests|QuickPreviewTests|FileCardPreviewTests|HistoryManagerTests|TransformPasteTests|EndToEndTests|PasteQueueTests|HistoryPermissionTests|NamedPasteboardTests|FirstFrameDesktopTests|HistorySubmissionBaselineTests|SearchRetentionQuotaTests|FailureBoundaryTests|ImageTextIndexTests|StorageBaselineTests'
LOCALCLIP_NAMED_TEST=1 rtk proxy bash macos-app/scripts/test.sh --filter NamedPasteboardTests
rtk proxy bash macos-app/scripts/test.sh --filter 'CachedFileCopyTests|QuickPreviewTests|FileCardPreviewTests|HistoryManagerTests'
rtk proxy bash macos-app/scripts/test.sh --filter ExcludedDepartureCaptureTests
rtk proxy bash macos-app/scripts/test.sh
```

| 运行 | 通过 | 失败 | 跳过 | 采集用例两参数合计（秒） | 日志目录 |
| --- | ---: | ---: | ---: | ---: | --- |
| 改前全量对照 | 541 | 0 | 79 | 16.066 | `20261114-021122-yuTnjs` |
| 相关套件 | 171 | 0 | 11 | 4.882 | `20261114-021540-94Visf` |
| 私有命名剪贴板 | 3 | 0 | 0 | — | `20261114-021656-cdyHA5` |
| 文件相关回归 | 65 | 0 | 3 | — | `20261114-022801-O66DUr` |
| 等待排空方案，全量 1 | 546 | 0 | 79 | 13.950 | `20261114-022825-nSGbKt` |
| 等待排空方案，全量 2 | 546 | 0 | 79 | 19.980 | `20261114-022901-mdqUCr` |
| 等待排空方案，全量 3 | 546 | 0 | 79 | 17.365 | `20261114-022941-hOxUuz` |
| 等待排空方案，全量 4 | 546 | 0 | 79 | 16.508 | `20261114-023022-Wv0Crl` |
| 等待排空方案，全量 5 | 546 | 0 | 79 | 17.102 | `20261114-023102-PiGtFO` |
| 采集套件单独过滤 | 1 | 0 | 0 | 0.086 | `20261114-023157-8xdR21` |
| 独立调度，全量 1 | 546 | 0 | 79 | 0.066 | `20261114-023223-tIWGjs` |
| 独立调度，全量 2 | 546 | 0 | 79 | 0.055 | `20261114-023303-RBRvJw` |
| 独立调度，全量 3 | 546 | 0 | 79 | 0.060 | `20261114-023347-07V0MA` |
| 独立调度，全量 4 | 546 | 0 | 79 | 0.059 | `20261114-023428-2YhuE2` |
| 独立调度，全量 5 | 546 | 0 | 79 | 0.056 | `20261114-023509-7PMvUM` |

日志目录均位于 `macos-app/evidence/automated/`。等待排空方案五次均通过，但用例耗时 13.950–19.980 秒，没有达到时长要求，最终采用单独调度。默认全量分两个阶段，同一份日志汇总两次 Swift Testing 结果，任一阶段失败时脚本返回非零。

### 用户桌面复测

本轮桌面开关保持关闭。以下步骤供用户在隔离库中复测。

1. **弹窗按钮**。在仓库根目录运行 `check_dir=$(rtk proxy mktemp -d /tmp/localclip-storage-check.XXXXXX)` 和 `rtk proxy bash macos-app/scripts/build-gui-check.sh "$check_dir"`。用 `rtk proxy mkdir -p "$check_dir/working-store/History"` 创建测试目录，用 `rtk proxy sqlite3 "$check_dir/working-store/History/history.sqlite" 'PRAGMA user_version=99;'` 生成不兼容版本的测试库。启动 `$check_dir/LocalClip-GUI-Check.app`，点击「在访达中显示数据目录」。访达定位到 `working-store`，LocalClip 保持运行并重新显示弹窗。库保持版本 99 时点「重试」，仍显示版本错误，状态栏入口只有一个。点击「退出」后进程正常结束。另可重新启动并用 Esc 验证退出。运行 `log stream --level info --predicate 'subsystem == "local.localclip" AND category == "StorageRecovery"'` 查看原始响应值，预期依次为 1001、1000、1002。如果出现其他值，记录连续次数和进程是否仍在运行。
2. **文件卡片与详情**。在隔离库创建包含至少六个文件的记录，其中至少两项在第四项之后。混合有副本和无副本的文件，分别移走原件并重新打开面板。分别核对缺失项全有副本、部分有副本、均无副本三种提示，以及详情前四行与后续文件汇总。再检查全有原件的卡片样式、全目录卡片和无副本的失效预览。核对详情说明中的「历史已保存 N 个文件副本」、访达双击复制到当前文件夹及同名冲突停止说明。可见预览用例在本轮静默套件中按门控跳过。
3. **首帧与减弱动态效果**。获得桌面授权后，在系统的「减弱动态效果」关闭和开启状态下各执行一次 `LOCALCLIP_INTERACTIVE_TESTS=1 LOCALCLIP_FIRST_FRAME=1 rtk proxy bash macos-app/scripts/test.sh --filter FirstFrameDesktopTests`。核对首次可见帧显示最新首卡，图片已完成绘制，关闭再打开无旧首卡闪现。测试使用自建面板。真实热键与动效另用隔离包检查，完成后恢复系统原设置。

### 待用户确认

维护者确认保留 Release 基准入口。`hiddenSurfaceTest` 仅由测试配置入口设置，`configureSurfacesForTesting` 和 `toggleHistoryForTesting` 进入 Release 二进制，使基准可用相同编译模式。

### 2026-11-14 已授权的隔离桌面复测

- **存储失败弹窗通过。** 版本 99 的合成库触发版本错误。点击「在访达中显示数据目录」，访达选中隔离的 `working-store`，原进程继续运行并重新显示弹窗。点击「重试」仍显示版本错误，随后点击「退出」结束原进程。同一 PID 的模态响应依次为 `1001`、`1000`、`1002`，版本 99 库的 SHA-256 前后一致。另一次换入有效隔离库后点击「重试」，进入含三条合成记录的历史面板。原退出问题的历史根因仍未确认。
- **失效文件卡片和详情通过。** 三条记录各有六项，三项原件缺失。卡片分别显示「原件不可用 · 可复制历史副本」「原件不可用 · 部分文件有副本」「文件已移动、删除或无法访问」。详情列出前四项，区分「原文件不存在」与「原文件不存在 · 已保存副本」。三条记录最后两项均缺失，汇总分别显示其中 `2`、`1`、`0` 个有副本。详情的副本计数空格与访达双击及同名冲突说明均已核对。查看详情后隔离库未生成 `DragFiles`。
- 本次桌面复测范围为弹窗按钮及文件卡片与详情。普通与减弱动态效果下的首帧、Esc 和拖出未纳入本次。隔离验收目录中保存了 `modal.log` 和 `file-fixtures.log`。
- 随后打开「应用程序」里的 v0.3.83，现有历史列表正常加载，且可打开已有记录的详情。
