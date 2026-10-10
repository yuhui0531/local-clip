# 开发任务清单

> 来源：[design.md](design.md) 与 [PRD](../PRD-macOS剪贴板管理器-2026-10-09.md)
> 生成时间：2026-10-09
> 状态：实施中。逐项证据见执行记录，未勾选不代表完成。

## 执行约定

- 工程路径以项目根目录下的 `macos-app/` 为基准。任务文件路径均相对此工程；不得修改 Paste.app 或其用户数据。
- 每个任务启动时在该任务下补充负责人和状态；完成后填写实际证据链接，再勾选。状态允许未开始/进行中/受阻/完成，受阻任务不能计入完成数。
- 依赖满足后再改集成入口；只需要接口的工作可以使用 fake，但不得把 fake 演示当成真实系统测试通过。
- 只对行为关键的算法、持久化、边界和故障编写测试；文案和低风险配置不堆砌镜像测试。
- 任务完成证据格式：修改文件；验证命令；结果；证据路径；已知限制。未执行写“未执行”，不留含糊的“应该通过”。
- 小步提交或保存可恢复检查点；本目录当前无 Git，T01 仅在确定是新工程且符合工作区规则时初始化 Git，不操作远端或自动推送。

## 实施任务

- [x] **T00【基线】确认环境、格式和兼容边界**
  - 依赖：无。估算：0.5 人天。关联：design §1、§1.1、§1.2。
  - 目标：让后续任务使用同一套支持范围和工具链，不各自猜测。
  - 输入：PRD、design.md、当前机器；先检查适用的 AGENTS.md。
  - 涉及文件：`docs/environment.md`、`docs/compatibility.md`、`docs/decisions.md`。
  - 工作：记录 OS、CPU、Swift、SDK、CLT/Xcode 路径和目标应用版本；采用 macOS 15+/arm64、50MiB/32 项等设计基线；记录每种来源是否声明 source 标记、哪些真实格式需进一步探测。
  - 预期结果：基线表完整，最低系统的测试条件明确；机器缺少某个应用时只阻塞其真实验收，不谎称已经支持。产品名称可继续用 LocalClip，不因名称未定停工。
  - 验证：重跑环境命令并保存输出；检查兼容表所有单元都有“待测试/不支持/已通过/受阻”之一及原因。此时不授予权限、不启动登录项。
  - 验收关联：AC04、AC06、AC07、AC16、AC21 的前置条件。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-09T23:50:32+08:00；文件 docs/environment.md、compatibility.md、decisions.md；验证 sw_vers、xcrun swift --version、xcode-select、SDK、应用plist；结果基线一致，真实来源待T19；证据 macos-app/docs/environment.md。

- [x] **T01【工程】建立 SwiftPM 与本地 .app 骨架**
  - 依赖：T00。估算：1 人天。关联：design §1、§10。
  - 目标：在已有 CLT 环境建立可构建、测试、启动的最小工程。
  - 涉及文件：`Package.swift`、`Sources/LocalClip/App/`、`Resources/Info.plist`、`scripts/build-app.sh`、`.gitignore`、`Tests/LocalClipCoreTests/`。
  - 工作：创建 LocalClipCore、LocalClipMac 两个库和 LocalClip executable；Core 测试依赖 Core，集成测试依赖两库；设置 Swift 6.2/macOS 15；接入系统 SQLite 模块；建立菜单栏和退出入口；打包脚本按 SwiftPM 实际 bin-path 复制可执行文件及资源 bundle，不硬编码架构目录。
  - 预期结果：`swift build`、`swift test` 可运行；脚本生成 `dist/LocalClip.app`，具有独立 bundleID、LSUIElement 和稳定开发路径；此时不启动真实采集。
  - 验证：本地构建、启动、退出；资源路径有效；默认不注册登录项。
  - 验收关联：F03、F11 的工程前置。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-09T23:56:46+08:00；文件 Package.swift、main.swift、Info.plist、build-app.sh、test.sh、双库契约测试；验证 build-app.sh debug、test.sh、独立子进程启动2秒并退出；结果真实进程存活、测试实际执行；证据 macos-app/evidence/automated/20261009-*/swift-test.log、docs/environment.md；限制CLT无XCTest，采用Swift Testing。

- [x] **T02【契约】定义领域类型、错误和可替换系统边界**
  - 依赖：T01。估算：1 人天。关联：design §2、§6。
  - 目标：稳定采集、存储、搜索、粘贴、配置确认使用的接口。
  - 涉及文件：`Sources/LocalClipCore/Domain/`、`Tests/LocalClipCoreTests/Support/`。
  - 工作：定义 ID、Instant、Snapshot、SourceAttribution、PasteRequest/PasteResult、SearchPage、ChangePreview、StorageUsage 和错误枚举；定义 fake Clock、pasteboard 和应用 adapter、存储故障注入点；明确 Sendable/MainActor 边界。
  - 预期结果：所有模块能引用同一契约；copy 与 directPaste、original 与 plainText 正交；不存在模糊的 `success: Bool` 代替粘贴结果。
  - 验证：编译接口与最少行为样例；确保 domain 不引入 SQLite 指针或 AppKit 对象。
  - 验收关联：AC08、AC18、AC24、AC26 的测试边界。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-09T23:56:46+08:00；文件 Sources/LocalClipCore/Domain/Domain.swift；验证 test.sh；结果Sendable值、MainActor系统边界、粘贴四类结果、存储故障断点编译通过；证据自动日志；无AppKit/SQLite句柄泄漏到契约。

  - 续接执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T09:37:47+08:00；文件 Domain.swift、HistoryStore.swift；补canCapture异步契约，真实候选dry-run测量是否有可释放空间；原库/revision不变；验证final test.sh完整50测试，48功能通过，2条件性能跳过；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

- [x] **T03【存储验证】验证配额和失败保留的可行性**
  - 依赖：T02。估算：2 人天。关联：design §4。
  - 目标：证明物理配额、原子替换和失败不丢旧记录可以同时满足；只使用合成临时库。
  - 涉及文件：`Tests/LocalClipCoreTests/StorageFeasibilityTests.swift`、`Sources/LocalClipCore/Storage/CommitStrategy.swift`、`docs/storage-feasibility.md`。
  - 工作：测量 DELETE journal、FULL autovacuum、BLOB 共享与页占用；执行 backup 候选、淘汰、实际测量、关闭连接和同卷原子替换；在候选写入、校验、替换前后中断子进程并重开数据库。
  - 预期结果：候选超额或保存失败时旧条目和收藏保持；成功只出现完整新状态；不能删除普通内容后再发现空间不够。普通事务快路径只有在包含 journal 的保守预算已被证明后才启用。
  - 验证：20MiB 新内容对 490MiB 不可释放/500MiB 上限场景；共享 BLOB 场景；磁盘故障注入；测量整个写入过程的峰值占用与重启恢复。
  - 验收关联：AC15、AC17、AC25、AC26。
  - 完成条件：可复现测试与 `storage-feasibility.md` 都具备；失败必须修复或明确修订技术方案，不能直接把风险移交给 UI。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-09T23:57:46+08:00；文件 CommitStrategy.swift、SQLiteConnection.swift、StorageProbe.swift、StorageFeasibilityTests.swift、CrashRecoveryTests.swift、docs/storage-feasibility.md；验证 test.sh；结果真实500MiB拒绝且旧库字节不变、共享BLOB、物理回收、六处SIGKILL旧/新完整态；证据 macos-app/evidence/automated、docs/storage-feasibility.md；限制不启用未经证明的快路径、未测硬件掉电。

  - 最终增量记录：负责人 Codex；状态：完成；更新时间：2026-10-10T09:51:12+08:00；生产rowid collector完整保持原NOT EXISTS语义，NULL孤儿与收藏共享引用真实生产库验证；旧journal预算未证明，未启用普通事务快路径或跳过候选校验；证据 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log、macos-app/evidence/independent/20261010-rowid-optimization/report.md

- [x] **T04【数据库】建立模型与迁移**
  - 依赖：T03。估算：1.5 人天。关联：design §3、§4。
  - 目标：建立唯一历史事实来源和可安全升级的 schema。
  - 涉及文件：`Sources/LocalClipCore/Storage/SQLiteConnection.swift`、`Schema.swift`、`Migrations.swift`、`Tests/LocalClipCoreTests/SchemaTests.swift`。
  - 工作：建立 clips/items/representations/blobs/text_content/thumbnails/settings/store_meta；配置和读取校验 SQLite pragma；参数绑定；级联与 BLOB 引用回收；启动校验 schema 版本。
  - 预期结果：约束和索引齐备，外键生效；高版本库在旧应用中拒绝写入；迁移失败不覆盖原库。
  - 验证：真实临时文件库创建/重开、约束失败、引用共享、高版本拒绝、迁移故障恢复。禁止仅在内存库测试磁盘行为。
  - 验收关联：AC02、AC14、AC15。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:00:10+08:00；文件 Schema.swift、HistoryStore.swift、SchemaTests.swift；验证 test.sh --filter SchemaTests；结果高版本拒写且哈希不变、失败不发布半库、外键/长度约束通过；schema=1，首版不需历史迁移；证据自动日志。

- [x] **T05【历史存储】实现入库、去重和提交后通知**
  - 依赖：T04。估算：2 人天。关联：design §3、§4、§6。
  - 目标：实现 HistoryRepository 的 ingest/detail/loadPayload/events。
  - 涉及文件：`Sources/LocalClipCore/Storage/HistoryStore.swift`、`CommitStrategy.swift`、`Sources/LocalClipCore/Domain/ContentFingerprint.swift`、对应测试。
  - 工作：规范指纹、精确内容核对、更新时间/来源、收藏状态保持；有序多项恢复；仅在提交后发 revision；operationID 防止提交后错误触发重复重放。
  - 预期结果：同样原始内容合并，不同格式独立；自身恢复不触发 ingest；保存失败不发布新增事件。
  - 验证：内容顺序、格式顺序、相同正文不同 RTF、重启持久化、提交前后故障、重复 operationID。
  - 验收关联：AC01–AC04、AC15、AC26。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:09:40+08:00；文件 HistoryStore.swift、Domain.swift、HistoryTests.swift；验证 test.sh；结果原始多项持久化、共享BLOB、同字不同格式、格式枚举顺序稳定、operationID重放不增加次数；证据自动日志；所有写入走候选。

- [x] **T06【系统采集】实现稳定的多格式快照**
  - 依赖：T02。估算：1.5 人天。关联：design §1.1、§5.1。
  - 目标：将 NSPasteboard 转换为可传递的值对象。
  - 涉及文件：`Sources/LocalClipMac/System/MacPasteboardClient.swift`、`Sources/LocalClipMac/Features/ContentDecoder.swift`、`Tests/LocalClipIntegrationTests/PasteboardSnapshotTests.swift`。
  - 工作：支持白名单、保留 item 顺序、读取前后计数核对、有界重试、总大小/项数检查；先检查标记再读取载荷；读取失败不保存半份快照。
  - 预期结果：纯文本/URL/RTF/HTML/PNG/TIFF/JPEG 按协议输出；不支持 item、超限及混合快照均明确跳过。
  - 验证：fake 中在第 2 个表示读取时改变计数；32/33 项、50MiB 边界；先拒绝 marker 再断言未读取正文；真实剪贴板探测只在显式手动测试阶段。
  - 验收关联：AC01、AC04、AC06、AC22。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:09:41+08:00；文件 MacPasteboardClient.swift、ContentDecoder.swift、PasteboardSnapshotTests.swift；验证 test.sh；结果32/33项、50MiB边界、混合不支持整次拒绝、变更竞态三次有界重试通过；证据自动日志；真实格式接收留T19。

- [x] **T07【采集策略】实现来源、标记与配置版本**
  - 依赖：T02。估算：1 人天。关联：design §1.2、§5.1。
  - 目标：使未知来源、排除应用、暂停与敏感标记具有唯一结果。
  - 涉及文件：`Sources/LocalClipCore/Domain/CapturePolicy.swift`、`SourceAttribution.swift`、对应测试。
  - 工作：按 bundleID 匹配声明来源；未知默认保存但受其他策略限制；敏感/临时任一标记跳过整次；配置改变递增 revision；原因不含正文。
  - 预期结果：前台应用推测不升级为可靠来源；不能绕过入库前新策略；保存与跳过都能说明原因。
  - 验证：已排除/未排除/未知/冲突来源、多项部分敏感、暂停与未知组合；正文不出现在日志 spy 中。
  - 验收关联：AC10、AC11、AC18、AC22。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:09:41+08:00；文件 SourceAttribution/Settings策略（Domain.swift）、MacPasteboardClient.swift；验证源声明/冲突/未知/多项敏感零正文读取测试；结果通过；证据自动日志；来源声明不具防伪保证。

- [x] **T08【采集闭环】连接队列、状态和自身写入过滤**
  - 依赖：T05、T06、T07。估算：1 人天。关联：design §5.1、§7。
  - 目标：形成从真实变化到已提交历史的唯一入口。
  - 涉及文件：`Sources/LocalClipMac/Features/CaptureCoordinator.swift`、`Sources/LocalClipCore/Domain/CaptureStatus.swift`、对应集成测试。
  - 工作：初值轮询、启动与恢复基线、有限缓冲、写入前策略复查、exact changeCount+指纹过滤；暂停、访问受限、容量满、繁忙和存储错误分别反馈。
  - 预期结果：暂停期间不采/不补；用户紧接着的新复制不被全局暂停误过滤；未提交内容不显示为已记录。
  - 验证：A/B/C 稳态、读取期间暂停、策略改变、队列满、自己写入后用户立即覆盖，以及容量恢复不取消主动暂停。
  - 验收关联：AC01、AC09–AC11、AC13、AC18。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。



  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T01:30:40+08:00；文件 CaptureCoordinator.swift、EndToEndTests.swift；验证 rtk proxy bash macos-app/scripts/test.sh；结果8份有界队列、繁忙跳过、读取中暂停、自写后立即用户复制均通过；证据 macos-app/evidence/automated/20261010-012825/swift-test.log；真实系统采集待T19。

- [x] **T09【搜索】实现字面匹配、排序和分页**
  - 依赖：T05。估算：1.5 人天。关联：design §5.2。
  - 目标：完整检索正文/URL/来源，不依赖三字分词限制。
  - 涉及文件：`Sources/LocalClipCore/Search/SearchService.swift`、`SearchNormalizer.swift`、`Tests/LocalClipCoreTests/SearchTests.swift`。
  - 工作：NFC、ASCII 大小写折叠、完整字面查询、匹配级别排序、收藏/类型过滤、50 项分页、queryID/revision；完整正文路径不只搜摘要。
  - 预期结果：两字词、单字、引号、百分号、下划线、emoji、代码及长文本末尾都正确；旧响应不会覆盖新查询。
  - 验证：固定集合精确期望 ID 和顺序；缓存缺失回退；删除/到期条目不可命中；跨页无重复漏项，数据变更时重查。
  - 验收关联：AC05、AC14、AC19、AC25。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T02:29:44+08:00；文件 SearchNormalizer.swift、HistoryStore.swift、HistoryViewModel.swift；验证 final test.sh（--scratch-path .build-verify，LOCALCLIP_NAMED_TEST=1）；中文单字/短词、NUL、NFC/ASCII、代码URL字面、完整正文尾部、分页revision、queryID乱序全部通过；证据 macos-app/evidence/automated/20261010-023217-Fbxzx3/swift-test.log

- [x] **T10【内容恢复】实现原格式与纯文本复制**
  - 依赖：T05、T06。估算：1 人天。关联：design §1.1、§5.3。
  - 目标：将历史内容准确写回剪贴板，并识别自身写入。
  - 涉及文件：`Sources/LocalClipMac/Features/ClipboardRestoreService.swift`、`System/MacPasteboardClient.swift`、对应测试。
  - 工作：恢复前重新验证存在及期限；original 保留多项/多表示；plainText 按提取优先级与 LF 连接；无文本项目禁用；写入时生成自身 operation token。
  - 预期结果：原格式不因展示摘要而损失；纯文本无富文本表示；写入失败不返回 copied。
  - 验证：数据字节/类型/item 顺序、无文本图片、多项混合、写入失败、已删或到期条目。
  - 验收关联：AC06、AC09、AC14、AC21。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:09:41+08:00；文件 PasteCoordinator.swift、MacPasteboardClient.swift；验证 EndToEndTests、HistoryTests；结果原始支持格式完整恢复、纯文本转换、写失败不虚报、精确receipt识别自写；证据自动日志；真实接收留T19。

- [x] **T11【直接粘贴】实现权限、焦点与手动回退**
  - 依赖：T10。估算：1.5 人天。关联：design §5.3。
  - 目标：只对记住的目标尝试一次直接粘贴，准确报告结果。
  - 涉及文件：`Sources/LocalClipMac/Features/PasteCoordinator.swift`、`System/MacApplicationClient.swift`、`System/AccessibilityAccess.swift`、对应测试。
  - 工作：TargetToken、一次激活、前台观察与期限、发送前身份/剪贴板重查、权限说明及回退；构造并发送粘贴键按下/释放事件，不能吞掉用户其他按键状态。
  - 预期结果：无权限仍能复制；错误目标不发送；剪贴板被用户更新后保留新内容并停止；只显示 commandSent，不伪造 delivered。
  - 验证：fake 应用事件序列精确断言；目标退出、PID 重用、激活失败、焦点切换、剪贴板切换、写入失败；真机结果留给 T19。
  - 验收关联：AC07、AC08、AC24。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:09:41+08:00；文件 PasteCoordinator.swift、MacApplicationClient.swift；验证 AC07_AC08_AC24_directPasteSafety；结果无权限/退出/PID重用/激活失败/焦点切换/剪贴板更新/写失败不误发；只有commandSent；证据自动日志；真实权限和接收留T19。

  - 续接执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T09:37:47+08:00；文件 PasteCoordinator.swift、EndToEndTests.swift；所有fallback复核WriteReceipt，焦点+剪贴板同时变化保留用户B且零事件；独立probe修复前FAIL/后正确结果保留；真实AX关闭回退及TextEdit手动C接收另有M证据，不宣称授权直接通过；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

- [x] **T12【保留清理】实现期限、收藏和删除**
  - 依赖：T05。估算：1.5 人天。关联：design §5.4。
  - 目标：明确期限和收藏例外，所有访问入口遵守相同可见性规则。
  - 涉及文件：`Sources/LocalClipCore/Storage/RetentionService.swift`、`HistoryChangeService.swift`、对应测试。
  - 工作：24 小时期限、Clock 注入、重复复制延长、过期收藏取消前确认、定时触发、preview/apply 版本校验；删除同时使索引/详情/恢复不可用。
  - 预期结果：到期无需等待物理清理就不可见；取消确认不更改内容；共享 BLOB 不误删。
  - 验证：29天23:59:59/30天边界、31天前首采今天复采、自身恢复不续期、过期取消收藏、清理失败、用户确认前又收藏的竞态。
  - 验收关联：AC12、AC14、AC19、AC20、AC27。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T00:19:05+08:00；文件 HistoryStore.swift、SearchRetentionQuotaTests.swift；验证期限边界、最近复制续期、收藏/取消过期收藏、旧确认token、删除入口；结果通过；证据自动日志；取消确认不会apply。

  - 续接执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T09:37:47+08:00；文件 HistoryViewModel.swift、DerivedAndViewModelTests.swift；按nearest截止时刻撤销到期卡/详情，50项到期后刷新页让旧收藏可见；注入Clock测试实际运行自动deadline，无需1分钟物理清理；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

- [x] **T13【容量管理】实现实际占用、预算和配额修改**
  - 依赖：T05、T12。估算：2 人天。关联：design §4、§5.4。
  - 目标：把 T03 验证方案应用于所有新增和派生写入。
  - 涉及文件：`Sources/LocalClipCore/Storage/QuotaService.swift`、`UsageMeter.swift`、`CommitStrategy.swift`、对应测试。
  - 工作：实际文件字节与 journal/待回收统计；共享归属；稳定淘汰顺序；不足预拒绝；下调预览及确认；超额暂停与恢复；磁盘不足和应用 quota 分开提示。
  - 预期结果：不可容纳时不删除旧条目，成功保存和淘汰一起生效；物理回收失败不虚报空闲空间。
  - 验证：AC17 固定容量场景、配额恰好边界、派生增长、待回收文件、降低至收藏以下、实际磁盘 ENOSPC 注入。
  - 验收关联：AC12、AC13、AC15、AC17、AC25–AC27。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T01:30:40+08:00；文件 HistoryStore.swift、CommitStrategy.swift、FailureBoundaryTests.swift；验证 test.sh；结果真实500MiB预拒绝、旧内容不变、下调干跑、收藏超额保留、共享归属、实际权限拒绝回收仍计量、缓存预算回退均通过；证据 macos-app/evidence/automated/20261010-012825/swift-test.log、docs/storage-feasibility.md；未测硬件磁盘耗尽，已注入SQLITE_FULL类失败。

  - 续接执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T09:37:47+08:00；文件 HistoryStore.swift、CaptureCoordinator.swift、SearchRetentionQuotaTests.swift、EndToEndTests.swift；过大单条只拒绝本条，后续可容纳小条目保留；实际全满普通内容可释放时不全局暂停，收藏/待回收超限仍暂停；真实库dry-run不改旧字节；500MiB失败保旧回归通过；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

  - 最终增量记录：负责人 Codex；状态：完成；更新时间：2026-10-10T09:51:12+08:00；文件 HistoryStore.swift、HistoryTests.swift；覆盖索引搜孤儿rowid而非扫描全部正文，删除普通共享引用保留收藏原bytes，最后引用删除回收；NULL孤儿也回收、FK/integrity通过；独立rowid增量PASS；真实配额失败旧库保持仍通过；证据 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log、macos-app/evidence/independent/20261010-rowid-optimization/report.md

- [x] **T14【派生内容】实现缩略图、文本缓存与回退**
  - 依赖：T09、T13。估算：1 人天。关联：design §1.1、§4.3、§5.2。
  - 目标：提升展示速度，不影响原始内容完整性与配额。
  - 涉及文件：`Sources/LocalClipMac/Features/DerivedContentService.swift`、`ThumbnailRenderer.swift`、对应测试。
  - 工作：ImageIO 下采样、40MP 预览边界、无网络 HTML 文本提取、可见行请求合并；派生提交前检查 revision/存在性/配额；缺缓存时正文回退。
  - 预期结果：缩略图失败仍可复制；删除后在途任务不能复活内容；额满时派生写入延期且文本仍能找到。
  - 验证：超大像素图、小压缩大解码图、含远程 URL 的 HTML、本地捕获服务零请求、并发删除、索引空间不足。
  - 验收关联：AC06、AC14、AC25。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T02:29:44+08:00；文件 ThumbnailRenderer.swift、HistoryStore.swift、DerivedAndViewModelTests.swift、FailureBoundaryTests.swift；final test.sh；真实PNG/TIFF/JPEG ImageIO下采样与40MP边界、删除竞态、缓存缺失全文回退、派生容量不足保护原始全部通过；证据 macos-app/evidence/automated/20261010-023217-Fbxzx3/swift-test.log

  - 动态补证记录：负责人 Codex；状态：完成；更新时间：2026-10-10T10:02:06+08:00；文件 evidence/automated/html-network-20261010/{Probe.swift,run.py,result.json,compile.log,probe.log}；命令 rtk proxy python3 macos-app/evidence/automated/html-network-20261010/run.py；真实专用命名板→生产CaptureCoordinator/ContentDecoder→临时SQLite/字面搜索→DerivedContentService，HTML含loopback图片/脚本/CSS/iframe/link资源；控制请求前后各1，生产资源请求0（完成后等待800ms）；编译/执行退出0，原HTML字节保持、状态回调无正文/完整URL；general未触碰，无外网，临时库删除；独立审查发现原source-only证据缺口后补证，不将本分支扩大为所有GUI/系统网络验收；证据 macos-app/evidence/automated/html-network-20261010/result.json

- [x] **T15【设置】实现持久化、热键、排除和登录启动**
  - 依赖：T07、T11、T13。估算：1.5 人天。关联：design §7。
  - 目标：把设置操作与真实系统状态、一致性预览连接。
  - 涉及文件：`Sources/LocalClipMac/UI/SettingsView.swift`、`System/HotKeyService.swift`、`System/LoginItemService.swift`、对应测试。
  - 工作：采集、动作、应用选择器、容量/期限、热键冲突、权限状态；来源未知说明；登录启动读取系统 status，仅用户操作时注册。
  - 预期结果：设置失败不显示成功；取消破坏性确认不改设置；快捷键冲突仍可菜单栏操作；重启设置保留。
  - 验证：fake 系统冲突/拒绝，配置范围校验、重启持久化、preview stale；真实快捷键及登录启动状态在 T19 验证。
  - 验收关联：AC02、AC08、AC18、AC23、AC27。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。


  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T02:29:44+08:00；文件 SettingsView.swift、HistoryViewModel.swift、HotKeyService.swift、LoginItemService.swift；final test.sh和Debug --system-check；持久化/范围/旧token、保存失败恢复实际设置、暂停读取门、fake热键冲突及实际Carbon重复注册拒绝通过；SMAppService读取notFound，无授权/注册操作；证据 macos-app/evidence/automated/20261010-023217-Fbxzx3/swift-test.log、macos-app/evidence/manual/interface/system-api.json；真实用户注册操作留T19

- [ ] **T16【界面】完成历史面板、详情与键盘交互**
  - 依赖：T08、T09、T10、T11、T12、T14、T15。估算：2 人天。关联：design §7。
  - 目标：把完整业务服务连接成可日常使用的界面。
  - 涉及文件：`Sources/LocalClipMac/UI/HistoryPanelController.swift`、`HistoryView.swift`、`ClipDetailView.swift`、`HistoryViewModel.swift`、`App/AppDelegate.swift`。
  - 工作：搜索、收藏/类型过滤、摘要与来源、详情和动作；queryID、选中项稳定性、分页；中文输入法；全部状态与确认弹窗；面板目标 token 生命周期。
  - 预期结果：不用鼠标也能完成找回；中文候选确认不会误粘贴；空态/失败/过滤原因可解释；界面不直接查询 SQLite。
  - 验证：窗口手动冒烟与 ViewModel 状态测试；两次乱序查询；搜索中删除/到期选中条目；多显示器边界；输入法组合。
  - 验收关联：AC01、AC05–AC08、AC14、AC20、AC23、AC24、AC27。
  - 完成证据：部分证据见执行记录；尚未满足全部完成条件。


  - 执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T02:29:44+08:00；文件 HistoryView.swift、HistoryViewModel.swift、SearchField.swift、AppDelegate.swift；实际SwiftUI浅/深/680pt像素渲染通过，final test.sh查询/删除/键盘跨页模型通过；采用用户要求Paste风格底部卡片；真实键盘/IME/多屏因Mac锁定受阻；证据 macos-app/evidence/manual/interface、macos-app/evidence/automated/20261010-023217-Fbxzx3/swift-test.log、macos-app/docs/interface.md

  - 续接执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:37:47+08:00；文件 HistoryViewModel.swift、AppDelegate.swift；reopen真实showHistory解决native窗口访问；实际原生Paste风格卡片已打开，TextEdit A/B/C历史C/B/A、恢复A收到、无权限fallback后C手动收到；Mac已解锁；并发用户输入导致fixture隔离失效，已暂停/删除专用测试库，待独占输入时段；中文/键盘/多屏仍未完成；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

  - 预读与授权续接记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:48:18+08:00；实际改动 Sources/LocalClipMac/{System/MacApplicationClient.swift,UI/HistoryView.swift}；直接粘贴增加身份一致的应用名称提示，当前真实AX观察目标为Safari。完整回归50功能通过；原生工具点击More→设置后再次native pipe closed，reset及fresh getApp失败；全键盘/IME/多屏/设置M未齐，暂不勾选。证据 macos-app/evidence/automated/20261010-103938-yKzK5v、macos-app/evidence/manual/20261010-authorized-restart/observations.json

- [x] **T17【恢复】验证崩溃、启动与后台竞态**
  - 依赖：T08、T13、T14。估算：2 人天。关联：design §4、§5.4。
  - 目标：证明程序在不正常退出时不会留下半份历史或让删除内容复活。
  - 涉及文件：`Sources/LocalClipCore/Storage/RecoveryService.swift`、`Tests/LocalClipCoreTests/CrashRecoveryTests.swift`、测试子进程入口。
  - 工作：候选准备/提交前/提交后 failpoint、SQLite 未结束事务、staging 垃圾计量、恢复前不采集、删除与派生并发、用户暂停与容量状态叠加。
  - 预期结果：重启后完整旧态或新态；失败候选不覆盖原库；被删内容不能从旧缓存返回；未回收计入容量。
  - 验证：真正终止测试子进程再重开临时库，不只抛异常；每个断点检查逻辑条目、BLOB 引用、完整性与实际大小。
  - 验收关联：AC02、AC14、AC15、AC25、AC26。
  - 完成证据：见本项执行记录；最终回归 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log，最终交付源码hash macos-app/evidence/automated/delivery/source-sha256.txt。

  - 执行记录：负责人 Codex；状态：完成；更新时间：2026-10-10T02:29:44+08:00；文件 StorageProbe.swift、CommitStrategy.swift、HistoryStore.swift、CrashRecoveryTests.swift；final test.sh实际SIGKILL两组各6断点；生产组须淘汰普通旧内容，提交前旧态保持、提交后完整新态、收藏/BLOB/FK/hash/quota通过；真实权限拒绝回收仍计量、删除竞态和独立暂停通过；证据 macos-app/evidence/automated/20261010-023217-Fbxzx3/swift-test.log

- [ ] **T18【集成】完成首版流程联调**
  - 依赖：T16、T17。估算：1 人天。关联：design §5、§7。
  - 目标：通过真实临时存储和 fake 系统边界验证所有服务已接通。
  - 涉及文件：`Tests/LocalClipIntegrationTests/EndToEndTests.swift`、`Fixtures/`、测试运行说明。
  - 工作：使用 acceptance.md 的固定 fixtures 和 Clock；执行采集/搜索/恢复、暂停、过滤、清理、配额和故障；补额外检查 E01–E08。
  - 预期结果：F01–F11 全有调用链与测试；正式入口没有 mock 服务；所有测试使用独立目录且没有外部网络依赖。
  - 验证：完整自动测试通过，并检查 AC 映射；fake 层通过只标为自动集成通过。
  - 验收关联：AC01–AC27 的可自动化部分。
  - 完成证据：部分证据见执行记录；尚未满足全部完成条件。

  - 执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T02:29:44+08:00；自动集成已执行：final test.sh发现46测试，44功能通过，2长性能条件跳过另行执行；真实临时SQLite、命名NSPasteboard、生产ViewModel无正式mock入口；证据 macos-app/evidence/automated/20261010-023217-Fbxzx3/swift-test.log、macos-app/docs/acceptance-results.md；T16真实UI完成条件受锁屏阻塞，依赖未完整验收，暂不勾选

  - 续接执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:37:47+08:00；文件 EndToEndTests.swift、DerivedAndViewModelTests.swift及Core容量测试；50发现/48功能通过/2性能条件跳过；新增50写fixture导致旧固定120ms测试失败并unchecked索引崩溃，失败原日志092746-QnJ6KL保留；改3秒截止条件等待+guard后通过；T16真实UI依赖尚未完全验收；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

  - 最终增量记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:51:12+08:00；文件 HistoryTests.swift、BenchmarkTests.swift；最终51发现/49功能通过/2条件性能跳过；真实共享引用/NULL孤儿新增生产测试通过；metadata整对象比较失败094039-HATgki原日志保留，改比canonical原bytes；新图片性能20不同编码新插入另外执行通过；T16真实UI未完全验收；证据 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log、macos-app/evidence/independent/20261010-rowid-optimization/report.md

  - 预读与授权续接记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:48:18+08:00；实际改动 Sources/LocalClipCore/Storage/CommitStrategy.swift、Tests/LocalClipCoreTests/StorageFeasibilityTests.swift；32MiB以上克隆候选只读顺序预读，创建故障点移到预读前；真实40MiB候选chmod导致EACCES覆盖生产open失败，body不执行、原bytes/占用不变、候选清理、完整integrity通过。命令 rtk proxy env LOCALCLIP_NAMED_TEST=1 LOCALCLIP_PROBE_BINARY=/Users/ronny/VscodeProjects/rea/macos-app/.build-verify/debug/LocalClip bash macos-app/scripts/test.sh --scratch-path /Users/ronny/VscodeProjects/rea/macos-app/.build-verify；52发现/50功能通过/2条件性能跳过，最后8.415秒、退出0；两组各6 SIGKILL与实际500MiB拒绝仍通过。T16全部依赖未完成不勾选。证据 macos-app/evidence/automated/20261010-{102835-kQvtAz,103938-yKzK5v}、macos-app/evidence/independent/20261010-prefetch-access-failure/report.md

- [ ] **T19【真机验收】执行真实应用与权限矩阵**
  - 依赖：T18。估算：2 人天。关联：design §1.1、§5.3、§9。
  - 目标：证明真实剪贴板、多格式和目标应用接收行为。
  - 涉及文件：`docs/compatibility.md`、`evidence/manual/`、`docs/acceptance-results.md`。
  - 工作：按 acceptance.md 逐项操作 TextEdit、Safari/Chrome、VS Code、Pages；分别检查手动/直接、原格式/纯文本、权限关闭、焦点变化、热键、设置和来源识别。
  - 预期结果：支持矩阵每个要求格都有实测证据；缺应用、权限、最低 OS 时写受阻及已完成范围，不补写通过。
  - 验证：保存接收结果截图/录屏、应用及系统版本、输入 fixture 和状态；权限由用户在系统设置中授予，agent 不自动更改 TCC 数据库。
  - 验收关联：AC01、AC02、AC05–AC11、AC18、AC20–AC24、AC27。
  - 完成证据：部分证据见执行记录；尚未满足全部完成条件。


  - 执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T02:29:44+08:00；文件 docs/compatibility.md、docs/acceptance-results.md、Fixtures/manual；CUA再次明确Mac locked，目标TextEdit/Safari/Chrome/VSCode/Pages未执行接收；实际命名剪贴板7格式字节一致和Carbon/AX/login只读API已执行，不能代替M；证据 macos-app/evidence/manual/20261010-blocked/ui-automation.md、macos-app/evidence/manual/interface/system-api.json

  - 续接执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:37:47+08:00；Mac已解锁，实际TextEdit1.20纯文本A/C手动收到及真实AX关闭fallback通过，actual来源未知保存；文件 evidence/manual/20261010-resume/*.png、observations.json；并发clipboard导致fixture隔离失效，暂停并删除isolated-data；无意外内容证据保留、无TCC修改；授权直接/其他应用/富文本/图片等剩余矩阵待用户独占输入与系统授权；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

  - 预读与授权续接记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:48:18+08:00；实际改动 Fixtures/manual/authorized-20261010/*、docs/{compatibility.md,acceptance-results.md,known-limitations.md}；旧测试签名LaunchServices API辅助功能true，TextEdit实际授权直接接收完整文本、RTF原格式加粗/链接可见与纯文本手动接收，保存接收截图/RTF文件；Safari手动接收完整文本，两次直接未见接收，失败保留、根因待查。更新测试二进制签名后实际AX=false，用户重新授权待完成；CUA再次native pipe closed且reset失败；Chrome file页面被URL策略拒绝，未绕过。旧异常一次性隔离目录已删，最新非fixture条目暂停后经UI确认删除，当前3条合成fixture且暂停。证据 macos-app/evidence/manual/20261010-authorized-restart/{observations.json,permission-current-bundle.json,*.png,*.rtf}；不以commandsent认证接收

  - 本轮完成与阻塞记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T11:03:14+08:00；当前UI工具getApp timeout后getState明确Mac锁定；用户手动解锁问询已发，不绕过原生工具或修改权限。当前测试签名辅助功能仍以最后API false为准，解锁不等于授权。证据 macos-app/evidence/manual/20261010-authorized-restart/native-connection-status-0301.json；真实矩阵仍受阻。

  - 重新授权续接：负责人 Codex；状态：受阻；更新时间：2026-10-10T13:58:50+08:00；用户解锁/重新授权/恢复插件，rtk proxy open -n <同签名测试app> --args --system-check <permission-regranted.json> 实际AX=true。原生getApp无可见窗口timeout，重开曾遗漏数据override，立即暂停/终止PID52311，默认库不删除/读取正文；新直接exe隔离PID52527实际UI权限回退，随后暂停/终止并无正文读取删除该一次性测试库。使用 rtk proxy open -n --env LOCALCLIP_DATA_DIR=/Users/ronny/VscodeProjects/rea/macos-app/evidence/manual/20261010-regrant/launchservices/isolated-data /Users/ronny/VscodeProjects/rea/macos-app/evidence/manual/20261010-resume/LocalClip.app，同签名无需再构建；0条/暂停和进程环境实际核对，采集一次Safari fixture后立即暂停。目标提示目前微信，未误发事件；原生绑定动作不证明全局热键/前台，待用户一次人工焦点核对。README隔离启动命令已纠正，docs兼容/验收与本轮观察已更新；证据 macos-app/evidence/manual/20261010-regrant/{isolation-status.json,observations.json,launchservices/launch-context.json}、20261010-authorized-restart/permission-regranted.json；T19保持未完成。

  - 连接再阻塞：负责人 Codex；状态：受阻；更新时间：2026-10-10T14:02:01+08:00；More点击返回用户改变app/需最新状态，下一次getAXState和reset+fresh getApp均native pipe closed；只读确认LS隔离PID53507仍存活，采集最后已暂停。已请求恢复插件及一次Safari人工前台/热键，当前无需再次TCC授权。已纠正README/兼容/验收/限制/性能中的旧false/锁屏当前描述；证据 macos-app/evidence/manual/20261010-regrant/native-connection.json。未新增目标接收或设置验收通过，T19仍未完成。

  - 继续核对记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T14:05:30+08:00；用户重新授权、恢复插件、解锁已确认；只读ps布尔核对PID53507与测试二进制/隔离env均匹配。再次getApp仍返回Sky Computer Use native pipe closed before response，未新增接收/设置/GUI性能通过；证据 macos-app/evidence/manual/20261010-regrant/native-connection.json。无源码改动，既有50功能与Release构建结果保持原范围，不重复重载测试。

  - Safari焦点续接记录：负责人 Codex；状态：部分通过/未完成；更新时间：2026-10-10T14:44:00+08:00；新增evidence/manual/20261010-safari-ready截图/AX/真实RTF和RTFD附件/属性及像素核对，更新README/docs与本清单。当前同签名LS主进程：Safari准备焦点后直接文本接收138UTF8字节；TextEdit富文本直接实际接收；两端原格式/纯文本差异、加粗/Latin italic/完整href真实文件核对；PNG经Preview实际复制→历史→TextEdit附件1920×1080，Pillow解码RGBA全等。实际短中文/代码/URL查询、Down/Up、收藏视图、普通删除后查询0、收藏删除取消、暂停A无补采/恢复后B入库完成；AC11补齐M。首普通清理Cancel用了截图后旧AX索引，实际删测试fixture，Cancel无效保留；刷新索引后的收藏Cancel通过。当前3条合成数据且采集暂停。Settings绑定仍失败；其他原生app可读，历史Finder重开恢复，不推断全局连接或产品故障；Preview无文档初试514秒超时保留，明确Open With后可用。命令 rtk proxy python3（textutil实际文件与Pillow像素核对），CUA真实交互；50功能/Release源码无变化不重复测试；完整M/P未齐，T19未勾选。

- [ ] **T20【性能】运行固定数据集与资源测试**
  - 依赖：T18。估算：1.5 人天。关联：design §4、§5.2、§9。
  - 目标：测量 PRD P95 与容量边界成本，定位并修复真实瓶颈。
  - 涉及文件：`scripts/benchmark.sh`、`Fixtures/BenchmarkManifest.json`、`docs/performance.md`、`evidence/performance/`。
  - 工作：生成一万条文本、代表性图片及近配额集合；记录面板/搜索/复制到可见的端到端时间、CPU、内存、空闲功耗信息；分别报告冷/热与快/慢提交路径。
  - 预期结果：达到目标或明确失败项并修复；不能删除慢样本、漏记失败复制或只报告服务层时间代替 UI 可见时间。
  - 验证：按 acceptance.md 的次数和分位方法；有修复时针对受影响基准复测；不为了达到数值减少全文检索或跳过持久化。
  - 验收关联：AC16、AC17、AC25。
  - 完成证据：部分证据见执行记录；尚未满足全部完成条件。

  - 执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T02:29:44+08:00；文件 BenchmarkTests.swift、SystemBenchmarkTests.swift、benchmark.sh、benchmark-system.sh、docs/performance.md；最终Release服务200查询/200文本/20图片复采/30近配额原样本齐备；最新服务searchP95=27.551209ms、text=479.872375ms、image=499.166542ms、quota=1030.942625ms，端到端复制预算未解决；命名板4×100压力及120空闲样本已测；system包装退出2（测试0）如实记录，脚本语法已修复；UI冷/热/搜索可见/复制可见受锁屏阻塞；证据 macos-app/evidence/performance/20261009T182206Z-delivery、20261009T180735Z-system、docs/performance.md

  - 续接执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:37:47+08:00；最终生产源码Release服务复测完成：20261010T013052Z-postfix，145.696秒测试退出0，200文本/200查询/20图片复采/30近配额样本齐全；searchP95=27.338416ms、text=548.396875ms、image=535.581084ms、quota=1086.109209ms；文本服务子区间已超500ms总预算，真实性能失败待优化；GUI可见计时未测；正在分段profiling，不删慢样本、不弱化保存失败保旧；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

  - 最终增量记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:51:12+08:00；文件 HistoryStore.swift、HistoryTests.swift、BenchmarkTests.swift、docs/performance.md；分段profile与等价rowid覆盖索引优化已验证，原始各阶段慢样本不删除；最终服务20261010T014419Z-final-new-images退出0，200查询/200文本/20真正新PNG-TIFF-JPEG/30近配额；P95 search26.841125ms、text488.822541ms、新image494.903875ms、quota1038.943458ms；未含轮询UI，复制可见预算仍未解决；当前源码命名板四阶段400输入完成，1000/500ms各100保存，200ms52保存/48busy，50ms20保存/7busy/73未观察；10分钟120样本空闲测试仍运行20261010T014705Z-system，不能提前标通过；证据 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log、macos-app/evidence/independent/20261010-rowid-optimization/report.md

  - 系统复测完成记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:01:49+08:00；命令 rtk proxy env LOCALCLIP_BENCHMARK_FIXTURE=macos-app/evidence/performance/20261010T013052Z-postfix bash macos-app/scripts/benchmark-system.sh --scratch-path macos-app/.build-bench-postfix（实际使用绝对路径）；测试/包装均退出0，815.771秒；120空闲原样本606.556973秒，单核心CPU均值0.130277%、P95 0.161379%，峰值resident378912768字节含压力阶段；无并行构建/测试，其他用户应用不受控；energy/wakeups unavailable；400压力输入完整保留，当前生产源码；GUI端到端与复制预算尚未完成，T20未勾选；证据 macos-app/evidence/performance/20261010T014705Z-system/{benchmark.log,stress.json,idle-resources.json,wrapper-status.json,run-provenance.json}、macos-app/docs/performance.md

  - 预读与授权续接记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:48:18+08:00；实际改动 CommitStrategy.swift、StorageFeasibilityTests.swift、docs/performance.md；真实新APFS clone只读诊断证明512MiB mmap未解决冷读，保持192MiB顺序预读后完整quick_check P95=74.38225ms（独立诊断）；生产Release同v2服务测试45.157秒、测试/包装退出0，P95 search26.055917ms、text122.093375ms、20新PNG/TIFF/JPEG141.462542ms、30近配额550.153458ms，慢样本全保留，仍非复制到可见。命令 rtk proxy env LOCALCLIP_BENCHMARK_REUSE=/Users/ronny/VscodeProjects/rea/macos-app/evidence/performance/20261010T014419Z-final-new-images LOCALCLIP_BENCHMARK_PHASE=prefetch bash macos-app/scripts/benchmark.sh --scratch-path /Users/ronny/VscodeProjects/rea/macos-app/.build-bench-postfix；证据 macos-app/evidence/performance/{mmap-validation-20261010,20261010T021901Z-prefetch}。当前源码Release压力/10分钟空闲正在20261010T024249Z-system执行，命令 rtk proxy env LOCALCLIP_BENCHMARK_FIXTURE=/Users/ronny/VscodeProjects/rea/macos-app/evidence/performance/20261010T021901Z-prefetch bash macos-app/scripts/benchmark-system.sh --scratch-path /Users/ronny/VscodeProjects/rea/macos-app/.build-bench-postfix；完成前不标通过。GUI/P真实可见仍受原生工具阻塞，暂不勾选

  - 本轮完成与阻塞记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T11:03:14+08:00；当前源码系统压力/空闲已完成；实际命令见上一条，测试和包装均退出0，808.641秒；1000/500/200ms各100输入/100保存，50ms100输入/27保存/73未观察，0明确跳过；120空闲样本607.314427秒，CPU均值0.145651%、P95 0.185802%，峰值resident382156800字节含压力。无GUI、energy/wakeups unavailable；docs/performance.md已更新，证据 macos-app/evidence/performance/20261010T024249Z-system/{benchmark.log,stress.json,idle-resources.json,summary.json,wrapper-status.json,source-provenance.json}。UI端到端尚未确认达标，不勾选。

- [ ] **T21【交付】输出 Release 包与可接续证据**
  - 依赖：T19、T20。估算：1 人天。关联：design §9、§10。
  - 目标：使用户和下一位 agent 能构建、运行、复现测试并了解限制。
  - 涉及文件：`README.md`、`scripts/build-app.sh`、`dist/LocalClip.app`、`docs/acceptance-results.md`、本任务清单。
  - 工作：干净构建 Release；检查 bundle/资源/签名；启动与持久化冒烟；汇总 AC 状态、真实支持矩阵、性能、已知限制与开发包安装运行说明。
  - 预期结果：源码、构建命令和产物一致；没有待办核心路径、假数据入口或“事件已发出即粘贴成功”的误报。只有全部要求通过才宣布首版完成。
  - 验证：从空 build 目录重建，复现关键手动路径；检查交付文档和证据文件实际存在。正式签名/公证未做就明确说明，不能自动发布。
  - 验收关联：全部 AC 与发布条件。
  - 完成证据：部分证据见执行记录；尚未满足全部完成条件。

  - 执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T02:29:44+08:00；文件 README.md、Resources/LocalClip.icns、scripts/build-app.sh、docs/*、dist/LocalClip.app；空.build-release-clean Release构建退出0（54.43s），arm64/15.0/bundle资源/ad hoc签名和Debug探针排除检查通过；二进制SHA256=3af188c4adcd8b943dde7c8e55c0d47ff1c68a817071260bea02ce74b2f29092；源码hash和全部AC报告齐备；证据 macos-app/evidence/automated/delivery；Release真实启动/退出受锁屏阻塞、T19/T20未满足，未宣布首版完成

  - 续接执行记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:37:47+08:00；空.build-release-postfix-20261010 Release58.323秒退出0，实际arm64/15.0/资源/ad hoc签名和Debug覆盖/探针排除通过；二进制SHA256=f159800e7131cc1b0c9af0f5e3cd198ed47d3fef6bb961a59f550aec66398954；更新源码hash、AC/兼容/性能/限制、独立初次FAIL与后续PASS_WITH_CONCERNS各自保留；M/P发布门未完成，不宣称首版交付完成；自动证据 macos-app/evidence/automated/20261010-092826-ZJT1Qf/swift-test.log；独立证据 macos-app/evidence/independent/20261010-final-delta/report.md

  - 最终增量记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T09:51:12+08:00；空.build-release-final-rowid-20261010 Release54.070秒退出0，arm64/15.0/资源/ad hoc签名/Debug helper及数据覆盖排除通过；最终binary SHA256=136fe675927909ec0127d0858623c3ef684aada5f6d06481f910441979c6b224；源码hash已更新62文件，全部27 AC和8 E与本地证据链接校验通过；更新首版报告/矩阵/限制，M/P发布门仍未全部满足；证据 macos-app/evidence/automated/20261010-094103-6SMysd/swift-test.log、macos-app/evidence/independent/20261010-rowid-optimization/report.md

  - 交付汇总续接记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:02:16+08:00；新增scripts/package-source.py可复现打包源码/PRD/任务与全部原始证据，排除生成数据库/测试app及probe二进制、自引用外部manifest；源码SHA256更新63文件；当前Release二进制保持136fe675927909ec0127d0858623c3ef684aada5f6d06481f910441979c6b224，49功能通过、两项独立性能均完成，真实TextEdit手动/AX关闭证据保留；E07动态本地服务器补证通过；M权限/独占输入与GUI性能发布门仍未齐备，17/22状态保持；命令 rtk proxy python3 macos-app/scripts/package-source.py；产物 macos-app/dist/{LocalClip.app,LocalClip-source.tar.gz}；证据 macos-app/evidence/automated/delivery/{source-sha256.txt,delivery-manifest.json}、macos-app/docs/{acceptance-results.md,compatibility.md,performance.md,known-limitations.md}
  - 预读与授权续接记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T10:48:18+08:00；现有dist Release和源码压缩包仍是预读前快照，未冒充当前代码；已更新AC/矩阵/性能/限制报告，保留旧失败及独立报告。当前专用Debug测试.app经完整50功能回归更新，实际签名改变需用户重新授权。当前Release重新构建/manifest刷新待系统资源测量完成后执行，避免并行重载影响测量；真实Release冒烟与M/P发布条件未齐，首版未宣布完成


  - 本轮完成与阻塞记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T11:03:14+08:00；完成空.build-release-prefetch-20261010当前源码Release构建51.818秒、退出0，arm64/minOS15.0/systemSQLite/ad hoc签名/Debug入口及数据覆盖排除通过；SHA256 d6ba3d6f955e85d65cd6bdc1df0e36c1df700603032c2917934868561e1815aa。命令 rtk proxy python3 macos-app/evidence/automated/release-20261010-prefetch/verify.py；保存旧app/manifest到pre-prefetch-snapshot；更新README测试52/50、docs验收/性能/限制、test-summary。源码归档及hash一致性随后核对。Release实际首次启动/退出/重启受锁屏阻塞，T19/T20发布门未齐，保持未完成。证据 macos-app/evidence/automated/release-20261010-prefetch/{release-build.log,release-verification.json,build-source-hashes.json}。

  - 归档核对记录：负责人 Codex；状态：受阻；更新时间：2026-10-10T11:04:26+08:00；命令 rtk proxy python3 macos-app/scripts/package-source.py；当前68源码文件hash均匹配归档；逐一核对所有tar成员与工作区原bytes一致，排除生成数据库、测试app/probe；构建源码hash仍全部一致，27 AC/8 E齐备、94本地证据链接无缺失。新Release实际启动与目标接收、GUI性能未完成；外部macos-app/evidence/automated/delivery/delivery-manifest.json记录最终归档hash避免自引用；旧snapshot与失败记录保留。

  - 续接独立核对：负责人 Codex；状态：受阻；更新时间：2026-10-10T11:08:25+08:00；独立资源/Release核对增量PASS_WITH_CONCERNS：120原样本统计、44构建hash、68源码hash及当前Release SHA一致；报告 macos-app/evidence/independent/20261010-prefetch-resources-release/report.md 明确完整首版FAIL/未完成。复制build-source-hashes.json到delivery目录关闭相对引用缺口；当前签名LaunchServices只读复查仍AX=false（permission-current-bundle-0306.json），Mac锁定待用户手动操作；文档和当前复查证据进入再归档，最终归档hash以外部manifest为准，17/22不变。

## 完成状态

> 进度：17/22 已完成
> 人天估算合计：31；环境就绪且熟悉 Swift/macOS 的估算，不是发布日期。

## 里程碑

| 里程碑 | 任务 | 退出条件 |
|---|---|---|
| M0 工程与风险验证 | T00–T04 | .app 可构建；接口与 schema 固定；配额/事务原型有证据 |
| M1 核心能力 | T05–T11 | 采集、去重、搜索、恢复及粘贴策略可通过自动测试 |
| M2 完整本地产品 | T12–T17 | 清理、配额、设置、界面与恢复全部接通 |
| M3 验收与交付 | T18–T21 | 自动、真实应用、性能证据齐备，Release 包可复现 |

T00–T04 是优先顺序，T06/T07 在 T02 后可独立进行。只有任务依赖满足才能合入对应集成路径。

  - 续接归档核对：负责人 Codex；状态：受阻；更新时间：2026-10-10T14:08:00+08:00；本轮只更新README/验收/兼容/性能/限制与tasks，以及权限/隔离/原生连接元数据；保留历史独立审查并新增状态纠正增量。源码及Release二进制不变，50功能通过保持原执行证据。命令 rtk proxy python3 macos-app/scripts/package-source.py；逐成员与workspace、68源码hash、44构建源码hash和Release二进制一致性由delivery-manifest登记。17/22状态保持；T16/T18/T19/T20/T21未完成，真实Release运行、M/P矩阵及最低系统环境不冒充已验证。

  - 用户停止测试记录：负责人 Codex；状态：由用户停止自动测试并自行验收；更新时间：2026-10-10T15:01:51.772757+08:00；立即停止UI交互、新增测试及性能运行，不再等待Pages人工焦点回复。Pages原格式实际接收有AX/截图及本地Pages文件；Plain/图片/Direct与其他未执行项保留。更新README/验收/兼容/限制与操作记录；源码及Release不变，不宣布首版完整验收完成。仅刷新当前源码/文档/证据归档供用户自行测试。


## 2026-10-10 用户追加交互与文件对象（Delta）

依据：[追加需求](interaction-files-delta.md)。负责人 Codex；更新时间：2026-10-10T15:12:04.553406+08:00。用户要求自行测试，以下实现与真实验收分别记录。

- [x] D01 双击原格式复制：替换卡片Button与双击冲突；单击选择，双击直接恢复，不依赖回车或默认动作。
- [x] D02 全宽底部固定：屏幕frame全宽/底边；禁止拖动缩放，监听显示器配置变化，覆盖Dock区域。
- [x] D03 文件对象：真实文件URL顺序保存、格式敏感去重、路径检索、文件卡片/筛选；Finder窗口定位/授权/身份复查及不覆盖副本复制。
- 验证策略：仅Release构建与签名检查；真实操作由用户自行测试，不补写通过。原T16/T18/T19/T20/T21状态保持。

- 实现/构建记录：D01–D03实现完成；实际操作验收待用户自测。修改Core的Domain.swift/SearchNormalizer.swift/HistoryStore.swift；Mac的MacPasteboardClient.swift/ContentDecoder.swift/PasteCoordinator.swift/FinderFileService.swift/AppDelegate.swift/HistoryView.swift/HistoryViewModel.swift/SettingsView.swift；Resources/Info.plist；README、docs及本Delta清单。
- 构建：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；Release0.1.1（2）退出0，13.978秒；脚本内ad hoc签名及严格签名检查成功。首次编译发现NSAppleScript SDK返回值非Optional，已修复；修复后构建通过。证据：`macos-app/evidence/automated/20261010-interaction-files/{build-result.json,release-build.log,initial-build-failure.txt}`。
- [ ] D04 用户自测：双击各格式、屏幕底部/全宽/多屏、文件及目录/多项顺序/Finder授权/同名副本/原件缺失/失败结果；本轮未执行，不使用旧50项通过记录代替。


## 2026-10-10 追加双击自动粘贴（0.1.2）

- [x] D05 ← 用户追加：双击记录自动返回打开面板前的应用，粘贴到原textarea/可编辑输入框。权限、应用身份、同一控件焦点、启用/可写性及剪贴板收据必须满足；未知控件回退手动；明确复制按钮/Finder文件副本行为保持。
- [ ] D06 用户自行验收：目标输入框插入位置/格式、两输入框焦点变化、切换应用、授权回退、剪贴板变化；未执行。
- 负责人Codex；源码MacApplicationClient.swift/AppDelegate.swift/HistoryViewModel.swift/PasteCoordinator.swift/HistoryView.swift、Core/Domain.swift、Resources/Info.plist；本轮只做Release构建与签名检查，不运行测试或原生UI自动化。

- D05实现/构建完成，D06真实验收未执行。Release0.1.2（3）构建退出0，耗时19.648秒；脚本内ad hoc签名和严格签名检查成功。命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；证据：`macos-app/evidence/automated/20261010-doubleclick-paste/{build-result.json,release-build.log,build-source-hashes.json}`。未启动应用、未操作用户输入框、未运行测试或性能验证。

## 2026-10-10 粘贴失败修复（0.1.3）

- [x] D07 用户报告Codex/Zed双击后没有插入：目标为修正粘贴能力判断、焦点恢复与不可见反馈；接口为ApplicationClient的焦点就绪/失败原因/权限提示契约；完成条件为代码修复及Release构建/严格签名检查，实际接收单列D08。
- [ ] D08 用户验证新版Codex/Zed实际插入、插入位置/原格式及可见失败提示；未执行。用户此前停止自动测试，本轮未重新操作输入框。
- 负责人Codex；实际修改：Sources/LocalClipCore/Domain/Domain.swift；Sources/LocalClipMac/System/MacApplicationClient.swift；Sources/LocalClipMac/Features/PasteCoordinator.swift；Sources/LocalClipMac/UI/{AppDelegate.swift,HistoryViewModel.swift}；Resources/Info.plist；README/docs、interaction-files-delta.md、debug-log-2026-10-10-paste.md。路径以macos-app为基准，开发计划文件以paste-report/development-plan为基准。
- 修复：移除AXValue setter门槛；非激活面板保留原应用；同一输入控件稳定等待后按已核对PID发送一次Command-V；持续复核权限/目标/剪贴板；显示不抢焦点的阶段提示。缺权限时只调用系统授权提示，不修改TCC。
- 验证命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；Release0.1.3（4）退出0，耗时15.771秒，脚本ad hoc签名/严格检查成功。首次Swift6 C常量并发标注构建错误已修复，原失败日志保留。未执行功能、真实目标或性能测试；未重启用户应用。
- 证据：macos-app/evidence/automated/20261010-paste-diagnosis/{build-result.json,release-build.log,build-source-hashes.json,signing-process-metadata.json,current-signing-metadata.json}；排查依据见同目录开发计划debug-log。运行时AX权限与此次具体失败阶段仍待确认，不能因构建成功宣布粘贴已验证。

## 2026-10-10 取消发送提示（0.1.4）

- [x] D09 移除“粘贴指令已发送，请确认目标输入框”弹窗，只在失败/回退时提示。负责人Codex；目标/完成条件为移除commandSent反馈分支并通过Release构建/签名检查；接口仍使用原showPasteFeedback，仅改变调用分支。实际修改Sources/LocalClipMac/UI/HistoryViewModel.swift、Resources/Info.plist及README/docs/追加变更记录。
- 命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.4（5）退出0，耗时15.581秒；ad hoc签名与严格检查通过。证据：macos-app/evidence/automated/20261010-remove-send-toast/{build-result.json,release-build.log,build-source-hashes.json}。没有启动/重启应用、操作输入框或执行测试；真实接收仍为D08待用户验证。

## 2026-10-10 非文本框目标修复（0.1.5）

- [x] D10 移除文本角色、AXIsEditable门槛，支持由原应用原焦点处理原生粘贴。目标为纠正截图对应的主动拒绝；接口沿用ApplicationClient.isPasteFocusReady/sendPaste；完成条件为移除错误门槛、保留安全检查并通过Release构建/签名检查。
- [ ] D11 用户验证编辑器、文档、图片/其他画布等原生接收与插入位置；未执行，继续遵循用户自行测试。
- 负责人Codex；修改Sources/LocalClipMac/{System/MacApplicationClient.swift,Features/PasteCoordinator.swift,UI/HistoryViewModel.swift,UI/HistoryView.swift}、Resources/Info.plist、README/docs和开发计划记录。原应用完整身份/同一AX焦点/权限/明确禁用状态/剪贴板收据保留，无应用名单或文本角色限制，Finder流程保持。
- 命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.5（6）退出0，耗时15.004秒，ad hoc签名/严格检查成功。仅源码检查与构建，未启动/重启用户应用或执行功能/目标/性能测试。
- 证据：macos-app/evidence/automated/20261010-generic-paste-target/{user-reported-editor-rejection.png,build-result.json,release-build.log,build-source-hashes.json}；根因/自检见debug-log-2026-10-10-generic-paste-target.md。实际接收待用户验证。

## 2026-10-10 历史滚动与Esc（0.1.6）

- [x] D12 触控板/鼠标滚轮横向浏览、接近页尾自动加载、Esc关闭。负责人Codex；目标为旧历史可访问且关闭可靠；接口沿用SwiftUI ScrollView/ScrollPosition、HistoryViewModel.loadMore与本地AppKit事件；完成条件为实现并通过Release构建/严格签名。
- [ ] D13 用户实际验证触控板左右/上下滑动、普通/横向/Shift滚轮、自然方向/惯性/首尾、超过50条分页选择、搜索/卡片/中文组合输入Esc关闭；未执行，遵循此前用户自行测试要求。
- 实际修改Sources/LocalClipMac/UI/{HistoryScrollWheel.swift,HistoryView.swift,AppDelegate.swift,SearchField.swift}、Resources/Info.plist、README/docs与开发计划记录。保留LazyHStack、原分页queryID/revision/loading保护、键盘选择定位；不更改存储/粘贴。
- 命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.6（7）退出0，耗时15.752秒；ad hoc签名及严格检查成功。仅源码检查与构建，未启动/重启应用、操作用户电脑或运行功能/设备/性能测试。
- 证据：macos-app/evidence/automated/20261010-history-scroll-escape/{build-result.json,release-build.log,build-source-hashes.json}；根因与边界见debug-log-2026-10-10-history-scroll-escape.md。

## 2026-10-10 失焦关闭（0.1.7）

- [x] D14 历史面板失去焦点自动关闭。负责人Codex；目标为点击外部/切换窗口或应用时隐藏，内部菜单/详情不误关闭；接口采用NSWindow/NSMenu通知及详情呈现状态回调；完成条件为实现和Release构建/严格签名检查。
- [ ] D15 用户验证外部点击（原应用/桌面/其他应用）、切换窗口/应用、搜索/中文输入/菜单/详情、设置/确认对话框、重新打开；未执行，继续由用户自行测试。
- 修改Sources/LocalClipMac/UI/{AppDelegate.swift,HistoryView.swift,HistoryViewModel.swift}、Resources/Info.plist、README/docs及开发计划。等待60ms核对key窗口关系，菜单/详情结束重查，关闭不抢焦点/不改剪贴板，退出清理任务/观察者。
- 命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.7（8）退出0，耗时16.094秒；ad hoc签名/严格检查成功。未启动/重启应用、操作用户电脑或执行功能/真实交互/性能测试。
- 证据：macos-app/evidence/automated/20261010-focus-dismissal/{build-result.json,release-build.log,build-source-hashes.json}；记录debug-log-2026-10-10-focus-dismissal.md。

## 2026-10-10 快捷键切换（0.1.8）

- [x] D16 同一注册快捷键切换历史面板显示/隐藏。负责人Codex；目标为已打开时再按一次关闭；接口为HotKeyService.onInvoke→AppDelegate.toggleHistory；完成条件为真实可见状态分支实现及Release构建/严格签名通过。实际修改Sources/LocalClipMac/UI/AppDelegate.swift、Resources/Info.plist、README/docs及开发计划记录。关闭调用原dismissHistory，重新打开调用showHistory；菜单/应用重开不改成toggle。
- [ ] D17 用户验证默认/自定义快捷键重复按下、详情打开时关闭、Esc/失焦关闭后再次打开；未执行，继续自行测试。
- 命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.8（9）退出0，耗时16.134秒；ad hoc签名/严格检查成功。未启动/重启应用、操作用户电脑或执行测试。证据：macos-app/evidence/automated/20261010-hotkey-toggle/{build-result.json,release-build.log,build-source-hashes.json}。

## 2026-10-10 单实例接替（0.1.9）

- [x] D18 新打开实例接替旧实例。负责人Codex；目标为避免多个实例同时采集/写库/注册快捷键；接口为SingleInstanceService.takeOver→AppDelegate.startServices及NSWorkspace重新打开；完成条件为实现启动门禁、新旧交接并通过Release构建/严格签名检查。修改Sources/LocalClipMac/System/SingleInstanceService.swift、Sources/LocalClipMac/UI/AppDelegate.swift、Resources/Info.plist、README/docs及开发计划记录。等待旧进程真正终止；POSIX进程锁持有到进程退出，较晚启动者胜出；6秒失败不启用新服务。
- [ ] D19 用户自测正常重新打开、不同路径同ID副本、旧版本首次open -n升级、并发启动、崩溃后重启/遗留空锁文件、菜单与快捷键只有一套；未执行。
- 命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.9（10）退出0，耗时16.506秒；ad hoc签名/严格检查成功。首次flock API编译错误改为fcntl POSIX记录锁后构建通过，失败日志保留。未启动应用、关闭用户进程或执行功能/真实应用/性能测试，原17/22及AC状态保持。证据：macos-app/evidence/automated/20261010-single-instance/{build-result.json,release-build.log,build-source-hashes.json,release-build-attempt-1.log}。记录debug-log-2026-10-10-single-instance.md。

## 2026-10-10 来源应用与图标（0.1.10）

- [x] D20 来源声明优先、缺失时前台应用归因与APP图标。负责人Codex；目标为纠正所有未声明应用均显示未知；接口为SourceApplicationObserver.source(for:count)→MacPasteboardClient.observedSource、持久sourceBasis与卡片图标；完成条件为实现、策略差异记录和Release构建/严格签名通过。修改Mac的System/SourceApplicationObserver.swift、System/MacPasteboardClient.swift、UI/AppDelegate.swift、UI/HistoryView.swift、UI/SettingsView.swift；Core/Domain/Domain.swift注释；Resources/Info.plist、README/docs、开发计划。本轮不变更SQLite schema、内容哈希或恢复格式。
- [ ] D21 用户自测Zed/Codex/Safari/Finder复制的来源/图标、来源检索、声明优先、冲突/非法声明未知、切应用/后台写入、排除边界、敏感标记与自身恢复；未执行。
- 构建：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.10（11）退出0，16.991秒，ad hoc签名/严格检查成功。首次通知名称不存在，改SDK公开didDeactivate；第二次Swift6隔离检查报错，改为只跨隔离传递PID，两次日志保留。没有读取用户剪贴板、启动应用或执行单元/集成/真实应用/性能测试。原17/22及AC历史结果不变。证据：macos-app/evidence/automated/20261010-source-app/{build-result.json,release-build.log,build-source-hashes.json,release-build-attempt-1.log,release-build-attempt-2.log}；排查记录debug-log-2026-10-10-source-app.md。

## 2026-10-10 分类新建与重命名（0.1.11）

- [x] D22 用户分类。负责人Codex；目标为可创建/重命名并实际归类与浏览历史；接口为HistoryStore.categories/createCategory/renameCategory/setCategory、ClipDetail.categoryIDs与SearchRequest.categoryID；完成条件为SQLite持久化/候选迁移、归属与筛选UI实现及Release构建/严格签名通过。修改Core/Domain/Domain.swift、Storage/Schema.swift、Storage/HistoryStore.swift；Mac/UI/HistoryView.swift、UI/HistoryViewModel.swift、UI/AppDelegate.swift；Resources/Info.plist、README/docs及开发计划。使用schema2及级联FK，不改变内容哈希或复制原始载荷，归属增删与命名均递增查询版本。
- [ ] D23 用户自测新建/重命名（空/重复/Unicode/超长）、跨重启保存、多个分类归属/移除、分类搜索/超过50条分页、删除/到期/淘汰级联、原格式与来源、不同v1库升级/高版本拒写、升级空间不足及提交前/后崩溃恢复；未执行。
- 构建：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.11（12）退出0，5.920秒，ad hoc签名/严格检查成功。新增分类条后固定高度调整为490pt，分类名对话框高于面板层级；最终名称校验包含Unicode换行。此前构建日志保留。未启动应用、读取或修改用户数据库、执行单元/SQLite集成/故障恢复/真实应用/性能测试。原17/22状态保持；E08明确旧结果不包含本次迁移。证据：macos-app/evidence/automated/20261010-categories/{build-result.json,release-build.log,build-source-hashes.json}。

## 2026-10-10 键盘删除、性能与面板（0.1.12）

- [x] D24 实现键盘删除、选中性能与紧凑透明布局。负责人Codex；目标为快捷删除、避免切换读取完整载荷/全排反复刷新、处理已识别的布局与背景闪变因素；接口为HistoryViewModel.deleteSelected/selectedMetadata/detailVisibilityChanged、HistoryStore.metadata、ClipMetadata、Equatable ClipCard及HistoryBackdrop；完成条件为源码整改和Release构建/严格签名。修改Core/Domain/Domain.swift、Storage/HistoryStore.swift；Mac/UI/HistoryViewModel.swift、UI/HistoryView.swift、UI/AppDelegate.swift、UI/SearchField.swift、UI/HistoryScrollWheel.swift、新建UI/HistoryBackdrop.swift；Features/ThumbnailRenderer.swift；Resources/Info.plist；README/docs及开发计划。删除仍确认、精确世代/在途撤销保留，恢复/写库完整校验不降低；schema仍为2。
- [ ] D25 用户自测⌫/⌦/Fn–Delete（搜索有字/空/中文组合/重复/取消确认/失败恢复/连续邻项）、快速选择大图/长文、详情按需、纯文本/分类/来源、旧图像/查询不复活、多屏打开/右侧闪烁、380pt布局/透明度与系统降低透明度；性能计时/FPS/CPU/内存前后对比未执行。
- 构建：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.12（13）退出0，21.097秒，ad hoc签名/严格检查成功。第一次Equatable actor隔离构建失败，比较方法改为nonisolated且只比较可发送的纯显示值后通过，失败日志保留。没有启动应用、操作输入/剪贴板/用户库或运行单元/SQLite集成/真实GUI/性能测试。原17/22及AC历史结果不变；实际不卡顿或无闪烁不能据构建宣称。证据：macos-app/evidence/automated/20261010-panel-performance/{build-result.json,release-build.log,build-source-hashes.json,release-build-attempt-1.log}；排查记录debug-log-2026-10-10-panel-performance.md。

## 2026-10-10 同行分类与截图样式（0.1.13）

- [x] D26 同行分类及新建纠正。负责人Codex；目标按用户截图表现自定义标签，完整保留文件/文本/图片类型且位于同一行，禁止升级兼容代码；接口HistoryView.categoryTab/CategoryEditor、HistoryViewModel.editCategory/saveCategory及现有HistoryStore分类API；完成条件源码实现、移除迁移、Release构建/严格签名。实际修改Core/Storage/Schema.swift、Storage/HistoryStore.swift；Mac/UI/HistoryView.swift、UI/HistoryViewModel.swift、UI/AppDelegate.swift；Resources/Info.plist；README/docs及开发计划。彩色点由稳定ID派生，不改schema；＋名称编辑与重命名popover保护键盘/焦点；类型与自定义互斥选择。未读取/修改用户数据。
- [ ] D27 用户自测同一行类型/自定义标签、＋创建/非法重复名称、右键重命名、许多分类横向滚动、记录归属/查询/重启、名称编辑退格/Enter/Esc/中文输入/失焦、380pt布局；未执行。D23中的旧库迁移验收被用户明确取消，不作为当前待办；其余历史未完成验收保留。
- 验证命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；退出0，25.188秒；ad hoc签名与严格签名校验成功。静态`rtk proxy rg -n 'Schema.migrate|func migrate|version == 1|schema-v2' macos-app/Sources`无匹配。未启动/关闭应用或执行任何自动功能/SQLite/GUI/性能测试。原17/22及AC历史结果不变。证据：macos-app/evidence/automated/20261010-category-tabs/{build-result.json,release-build.log,build-source-hashes.json}。

## 2026-10-10 拖入自定义分类（0.1.14）

- [x] D28 历史卡片原生拖入分类。负责人Codex；目标支持直接拖到自定义分类且保留原记录/原归属；接口HistoryViewModel.beginCategoryDrag/dropIntoCategory、NSItemProvider进程内表示、CategoryTab.onDrop及现有HistoryStore.setCategory；完成条件源码实现、Release构建/严格签名通过。实际修改Mac/UI/HistoryView.swift、UI/HistoryViewModel.swift、Resources/Info.plist；README/docs及开发计划。自定义标签局部State高亮，类型标签不接收；随机令牌60秒/单次消费，载入后检查记录/目标/在途删除，库内再次验证期限和存在性。无原始载荷读取或剪贴板恢复、无迁移/兼容代码。
- [ ] D29 用户自测文本/图片/文件卡片拖入、标签高亮、取消/超时、重复/多分类、持久化重开、删除/到期/容量失败、单击双击与横向滚动/焦点配合；未执行。原AC与D27及其他历史待办不重标通过。
- 验证：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`；0.1.14（15）退出0，1.128秒；ad hoc签名/严格校验成功。补齐内部拖放类型声明前的成功构建也保留独立日志，最终快照对应声明后的构建。没有启动应用、读取用户剪贴板/数据库或执行单元/SQLite/GUI/性能测试。证据：macos-app/evidence/automated/20261010-category-drag/{build-result.json,release-build.log,build-source-hashes.json}。
