# 技术设计与开发计划

> 来源：[修订后 PRD](../PRD-macOS剪贴板管理器-2026-10-09.md)
> 生成时间：2026-10-09
> 阶段：design；当前只交付计划，无应用实现。

## Why

### 背景与现状

这是从零建立的 macOS 本地应用。工作区目前是调查与需求文档，没有可复用的应用组件。已读取 PRD、复刻方案及设计/任务模板；没有独立 spec.md 或 SYSTEM-SPEC.md，以 PRD 的 F/AC 编号作为需求标识。

REA 证明的是被调查安装包中的接口与数据结构，不能证明本产品已完成采集、权限、搜索或粘贴。所有实现使用公开系统接口和自有数据结构。

### 设计目标 / 非目标

| 类型 | 说明 |
|---|---|
| 目标 | F01–F11 的本地采集、搜索、收藏、恢复、状态和容量控制 |
| 目标 | AC01–AC27 可重复执行；支持失败注入及真实目标应用验收 |
| 目标 | 其他 agent 可按固定接口和任务顺序实现，不重复选择技术路线 |
| 非目标 | F12–F14：多分类、连续粘贴、云同步、OCR、AI |
| 非目标 | 文件引用、导入 Paste 数据、用户标题、链接网络预览、正式商店发布 |

## What

### 1. 技术方案与开发基线

下表填补 PRD 的技术待定项，作为本次开发的确定默认值。T00 核对编译和真实格式行为；不满足时记录失败并调整技术方案，涉及支持范围变化必须显式列出。

| 项目 | 默认值 / 规则 | 理由与验证点 |
|---|---|---|
| OS / CPU | macOS 15+，arm64 | 与已发现的工具链目标一致，缩小首轮兼容矩阵；最低版本必须真机或 VM 验证 |
| 构建 | SwiftPM、Swift 6.2；系统框架，无远程包依赖 | CLT 可开展核心构建和测试；本轮不安装 Xcode |
| 应用形态 | LSUIElement 菜单栏应用，AppKit 生命周期和 NSPanel，SwiftUI 内容 | 系统焦点交由 AppKit 管理 |
| 数据目录 | Application Support/LocalClip-Development；测试用独立临时目录 | 与 Paste 和日常数据隔离 |
| 采集周期 | 初值 200ms；读取竞态最多重试 2 次 | 初始参数，最终依据 T20 实测调整，不保证无限速零漏采 |
| 内容边界 | 每次最多 32 项，支持格式原始字节合计不超过 50MiB | 超限整次跳过，不截断；这些是开发基线而非 Paste 实测值 |
| 图片预览 | 解码前检查尺寸；超过 40MP 不解码预览，保留已通过大小限制的原始数据 | 控制预览内存，不额外删除可恢复内容 |
| 保留 | 默认 30×24 小时；设置接受 1–365 天 | 最近有效用户复制时间起算 |
| 容量 | 默认 500MiB；设置接受 100–4096MiB，MiB=1,048,576 字节 | 与 PRD 默认值一致，限制必须可展示且可测试 |
| 快捷键 | 默认 Option+Command+V，可修改；注册冲突保留菜单栏 | 使用系统热键注册，不用全局键盘监听代替 |
| 默认动作 | 复制；直接粘贴需启用并检查 Accessibility | 保持有效手动回退 |
| 首次启动 | 说明保存范围后开始新变化采集；不导入启动前剪贴板 | 不把已有私密内容意外当成新采集 |

#### 1.1 支持格式与降级规则

| 格式 | 采集与恢复 | 文本检索/预览 | 验收 |
|---|---|---|---|
| UTF-8 纯文本 `.string` | 保留原字节及换行，不做正文改写 | 完整正文 | TextEdit、Safari、Chrome、VS Code |
| URL `.URL` 和同时存在的文本 | 保存所有受支持表示；不访问链接 | URL 原文及可读文本 | 浏览器地址栏到文本输入框 |
| RTF `.rtf` | 保存原始字节 | 提取文本，预览不运行脚本 | 加粗、斜体、换行、链接；TextEdit 富文本/Pages |
| HTML `.html` | 保存原始字节，恢复时写回；私有 CSS、脚本及复杂排版不承诺 | 使用本地解析器提取正文；无 WKWebView/远程图片加载 | 简单加粗、换行、链接；浏览器到支持的富文本目标 |
| PNG `.png`、TIFF `.tiff`、JPEG `public.jpeg` | 保存可读取的原始格式，不为去重重编码 | ImageIO 下采样缩略图；无 OCR | 原始像素与可见图像正确；TextEdit 富文本/Pages |
| 文件 URL、文件 promise、RTFD、私有格式 | 首版不恢复这些格式 | 提示支持范围 | 不读取文件本体，不把文件 URL 当普通网页 URL |

每个 pasteboard item 保留其受支持的全部表示；表示顺序规范化只用于哈希，item 顺序不变。若一个 item 没有任何受支持表示，则整次复制跳过，避免多项恢复时丢项；混有未知额外表示但每项均有支持表示时可保存，在详情标注“仅保留支持格式”。任一支持表示读取失败、支持内容总量超限或任一项目存在敏感标记时，整次跳过。

纯文本恢复按 item 顺序将提取文本以一个 LF 连接，保留各 item 内的换行；若任何 item 无可提取文本则禁用该操作，避免静默遗漏图片。同一 item 的文本提取优先级：显式纯文本 → URL → RTF → HTML。HTML 只提取文字，不请求外部资源；展示为原生文本，不执行 HTML。

#### 1.2 来源归因

公共剪贴板的来源标记属于协作约定，不是可验证的安全身份。`SourceAttribution` 保存 bundleID、显示名、来源依据和置信分类。

- 本版将语法有效、可解析的 `org.nspasteboard.source` 标记作为“声明来源”，显示其应用并按 bundleID 应用排除规则；多个项目声明冲突则为未知。这是产品中的可靠匹配依据，不宣称具有防伪能力。
- 仅观察到前台应用不能作为可靠复制来源，不据此伪造来源或执行排除。没有声明来源时为未知，执行其余策略后默认保存。
- 来源标记只用于归因，不计入内容哈希和恢复内容；用户重新复制同一内容时更新最近来源，未知来源不会沿用旧的确定来源。
- T00 必须记录真实来源应用是否提供标记。合成标记测试只能证明过滤规则，不等于这些真实应用都可可靠归因。设置页展示这一限制；不能通过读取其他应用进程或私有 API 补齐。

### 2. 架构决策与职责

| 模块 | 职责 | 执行上下文与依赖 |
|---|---|---|
| Domain | Snapshot、Clip、Policy、Search、Paste 等值类型和规则 | Foundation；值类型可跨执行上下文传递 |
| MacAdapters | NSPasteboard、来源、热键、权限、应用激活、登录启动 | AppKit / ApplicationServices / ServiceManagement，系统对象限制在 MainActor |
| CaptureCoordinator | 周期采集、竞态、自身写入过滤、策略重查、入库队列 | 单一采集任务；依赖系统 adapter、HistoryStore |
| HistoryStore | 所有数据库读写、去重、保留、容量及恢复 | 单独串行存储执行队列；SQLite 句柄不跨队列 |
| SearchService | 规范化字面查询、排序、分页、命中位置 | 后台执行；存储快照查询，无第二份历史事实来源 |
| PasteCoordinator | 复制、目标激活、发送前焦点检查、回退 | MainActor 系统交互；原始内容读取走存储队列 |
| UI | 菜单栏、面板、详情、设置和确认弹窗 | MainActor；只使用服务接口，不直接写数据库 |

SwiftPM 固定三个 target：LocalClipCore 库承载领域、存储和搜索；LocalClipMac 库承载系统 adapter、协调层和 UI；LocalClip executable 仅承载启动和依赖组装。单元测试依赖 Core，集成测试依赖 Core 与 Mac 库，不以导入 executable target 作为测试前提。

只对实际需要替换的边界建立 protocol：PasteboardClient、ApplicationClient、Clock、StorageFaultInjector 和 HistoryRepository。实际系统 adapter 与测试 fake 使用同一契约；不建设插件系统、远程 API 或多仓库服务。

并发规则：所有存储变更排队，执行一个事务期间不 await 外部工作；不得依赖 Swift actor 在 await 前后仍保持互斥。耗时哈希、搜索、解析和图片解码离开 MainActor。面板和设置不持有活跃数据库句柄；一次查询完成就释放读取资源，防止旧数据库被替换后仍向其写入。

### 3. 数据模型变更

新增单一 `history.sqlite`。首版所有原始表示都在 SQLite BLOB 中，元数据查询不得顺带加载全部 BLOB。无外部附件引用，因此不需要跨数据库与附件的提交协议。

| 表/实体 | 核心字段与类型 | 约束 / 用途 |
|---|---|---|
| clips | id TEXT；contentHash BLOB；firstCopiedAtMs/lastCopiedAtMs INTEGER；copyCount INTEGER；kind TEXT；isFavorite INTEGER；sourceBundleID/sourceName TEXT nullable；sourceBasis TEXT；previewText TEXT | id 主键；contentHash 唯一；copyCount≥1；收藏布尔约束；预览摘要允许截短但搜索正文不截短 |
| items | clipID TEXT；itemIndex INTEGER | 联合主键；外键级联；从 0 开始连续，保存复制顺序 |
| representations | clipID TEXT；itemIndex INTEGER；type TEXT；blobDigest BLOB | 联合主键 clip/item/type；引用 items 和 blobs；原始类型可重建 |
| blobs | digest BLOB；byteCount INTEGER；payload BLOB | digest 主键；长度校验；不同 clip 相同表示共享一份 BLOB |
| text_content | clipID TEXT；itemIndex INTEGER；plainText TEXT；normalizedText TEXT | 可从原始表示重建；与原始条目同一有效性边界；仅缓存优化，不决定条目是否可见 |
| thumbnails | clipID TEXT；revision INTEGER；encodedImage BLOB；byteCount INTEGER | 可删除和重建；写入前复查条目存在及 revision |
| settings | singletonID INTEGER；schemaVersion INTEGER；retentionDays INTEGER；quotaBytes INTEGER；defaultAction TEXT；captureEnabled INTEGER；shortcut JSON；excludedBundleIDs JSON；settingsRevision INTEGER | 单例；集中验证和持久化；登录启动实际状态从系统读取 |
| store_meta | singletonID INTEGER；schemaVersion INTEGER；storeRevision INTEGER；lastOperationID TEXT | 原子操作版本、迁移及重启后的提交辨识 |

索引：clips(contentHash)、clips(isFavorite,lastCopiedAtMs,firstCopiedAtMs,id)、clips(lastCopiedAtMs,id)、representations(blobDigest)。不使用 Cascade 删除 blobs；仅在引用数为零后删除。更新时间和来源与去重合并同一事务，过期未清理记录在 ingest 时按不存在处理，不复活已删除 ID。

去重哈希输入：规范版本号、有序 item 数、每项按类型标识排序后的受支持表示类型/长度/原始字节。必须使用带长度的编码避免拼接歧义。来源、时间、自己写入的控制标记不参与。SHA-256 使用 CryptoKit；命中哈希后核对规范内容，避免仅凭摘要删除数据。

收藏与普通条目共享载荷时计入收藏载荷；普通条目删除不能虚报这部分空间可回收。数据库页结构、索引、空闲页、日志等计入公共占用。UI 分类相加不能靠未校验的估算伪装成实际总占用。

### 4. 容量、事务与故障恢复

#### 4.1 必须保持的不变量

1. 未确认持久化的新内容不能触发不可恢复的旧内容删除。
2. UI 只能读取已提交的新状态；容量不足不是“先删再试”。
3. 实际占用包含 SQLite 数据库及其日志，不能把 DELETE 行数乘正文长度当成磁盘释放量。
4. 收藏、去重内容和派生内容使用同一个配额判断入口。
5. 保存失败返回后，原有未到期条目仍可检索和恢复；进程崩溃后只能恢复为完整旧状态或完整新状态。

SQLite 的事务原子性只覆盖数据库，不自动覆盖任意附件文件。SQLite 删除记录也不必立即缩小数据库文件。这两点是采用单库 BLOB 并先做 T03 的原因。[SQLite 原子提交](https://www.sqlite.org/atomiccommit.html)、[SQLite 空间回收](https://sqlite.org/lang_vacuum.html)

#### 4.2 确定的首版提交策略

使用 `journal_mode=DELETE`、`synchronous=FULL`、`foreign_keys=ON`；数据库创建前开启 `auto_vacuum=FULL`。配置后读取验证，不能假定未知 pragma 报错。一个存储变更入口选择以下两条路径，外部行为完全相同：

- **有足够余量且不需要淘汰：**普通 SQLite 事务写入。T03 给出包含数据库增长、最坏回滚日志与公共占用的保守预算；只在该预算可容纳时使用。无法可靠计算预算则使用下一条路径，不能关闭日志来省空间。
- **需要淘汰、接近上限或预算不能证明：**在同一卷的独立 staging 目录通过 SQLite backup API 生成候选数据库，在候选内完成新内容、去重与普通条目淘汰，回收空间、关闭句柄后测量实际大小。超额则继续在候选内按既定顺序淘汰；即使删完普通内容仍超额则丢弃候选，原库完全不变。

候选校验、同步到磁盘后，阻止新查询短暂进入，关闭原库全部连接，使用同卷单文件原子替换提交候选；替换前失败继续使用旧库，替换成功即为提交点，通过 operationID/storeRevision 确认新状态。不得用“先删除原库再移动候选”，不得在仍有 WAL 或活跃句柄时替换，不进行两个文件轮流 rename 的伪原子方案。替换成功后重开失败属于“提交后存储不可用”，不得误报旧内容仍存在或再次重放同一次插入。

SQLite backup API 用于产生一致候选，不能直接复制正在写入的数据库文件。[SQLite backup API](https://www.sqlite.org/backup.html)

T03 必须实际证明当前文件系统、关闭连接后的替换和崩溃恢复语义；没有通过前不进入完整存储实现。先实现候选路径，再在有证据的预算下实现普通事务快路径。候选路径可能需要复制较大数据库，T20 单独记录其延迟；不得用牺牲原子性或排除慢样本来通过性能目标。

#### 4.3 文件布局与计量

`History/history.sqlite` 及同目录日志计入容量；首版缩略图和文本索引在库内。`Staging/<operationID>/` 只在活跃写入期间作为临时工作空间，检查可用磁盘空间并设置一个操作的上限，不保留多代候选。工作空间保守预算为原库与候选及其日志所需空间，不足时提前拒绝。

启动先恢复/清理 staging 再开启采集。失败候选若无法删除，标记为待回收并计入实际占用，不能靠改目录名长期绕过配额；待回收仍导致超额时保持采集暂停。诊断日志独立设置小容量轮转，不保存正文。

下调 quota 是允许出现“已有存量超额”的明确场景：确认后持久化新上限，清理普通条目，保留收藏，不再新增；恢复条件为实际占用加必要新写入预算可容纳。被跳过的内容不自动补采。

缩略图和可重建索引不足以容纳时先放弃其写入，保留原内容。正文搜索回退读取原始可提取表示；不能因为索引缓存没生成而漏掉命中。正常期限清理独立于新内容保存，不混入失败保存对旧条目的保留断言。

### 5. 核心行为流程

#### 5.1 采集与隐私

- 启动、恢复采集时将当前 changeCount 作为基线，不采集旧内容。轮询只在有变化时读取。
- 先读取所有项目类型和敏感标记，不先生成缩略图、临时文件或日志正文。ConcealedType/TransientType 任一命中跳过整次。
- 读取前后 changeCount 不一致，放弃整份混合快照并有界重试。NSPasteboard 的同步提供者可能阻塞，不能宣称超时参数可以强制中断系统调用；记录慢读取并避免递归/无限重试。
- 系统调用留在已验证的 adapter 上下文，得到 Data 值后再离开 MainActor 做哈希和解析。
- 入库前重新核对 settingsRevision、暂停和排除策略；用户暂停或修改排除期间仍在处理的快照不得绕过新策略。
- 自身恢复在开始写入前设置短期 operation 状态，写入结束记录确切最终 changeCount 与指纹，只过滤匹配快照；计数变化即失效，不使用“暂停一秒”。写入失败也要消除自己造成的空/半成品，不能当作用户复制。
- 缓冲最多 8 份快照且累计 64MiB；达到上限时保留已排队内容、跳过新快照并显示“处理繁忙，未记录”。任何丢弃不得显示成功。

NSPasteboard 支持多项目/多种格式；类型与 changeCount 是采集基础，轮询和重试次数是本产品决策。[Apple NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)

#### 5.2 搜索

首版对查询与正文做 Unicode NFC 和 ASCII 英文字母大小写折叠，不删除标点，不转换全角符号，不做分词；空查询返回历史。完整查询作为一个字面子串，不把空格自动变成 AND，不把 `%`、`_` 或引号解释成 SQL/FTS 语法。SQL 全部参数绑定，LIKE 路线需转义通配符，或使用 instr 路线。

匹配排序：正文/URL 完全相等 → 正文/URL 前缀 → 正文/URL 子串 → 仅来源名称命中；同等级最近复制降序、ID 固定顺序。类型/收藏筛选先约束候选。每页 50 条，查询及分页携带 storeRevision 和 queryID；数据版本变化时重新查询，旧响应不覆盖新输入。

查询防抖初值 60ms；取消过期工作且复查 queryID。命中上下文返回原文区间，不直接拿规范化字符串的字节偏移截原文。首屏不解码完整图片。FTS5 不作为首版依赖；未来若引入 trigram，仍须保留两字中文正确性路径。[SQLite FTS5](https://www.sqlite.org/fts5.html)

#### 5.3 恢复与直接粘贴

PasteRequest 同时包含输出格式 original/plainText 与动作 copy/directPaste，避免把两种维度混成一个开关。恢复开始前检查条目仍存在且未到期；随后加载受支持的完整数据，再写剪贴板。

直接粘贴记住面板打开前的 PID、bundleID 和进程身份，不能只凭重用的 PID。权限未授予不弹反复请求，只提供说明和系统设置入口。写剪贴板失败时不发键盘事件；写入完成后关闭面板，发起一次激活请求并观察前台状态，最长等待 500ms。激活失败或发送前观察到其他应用获焦则手动回退。

发送前再次检查目标身份、前台应用以及剪贴板仍是本次恢复的 changeCount/指纹；若用户已复制其他内容，停止粘贴，提示“剪贴板已变化，请重新选择”，保留用户新内容，不能再声称所选条目仍在剪贴板。不能通过无限重试来抢焦点。

只报告 copied、commandSent、fallback、failed 四类结果，不创建系统无法可靠证明的 delivered 状态。应用内具体输入框由用户负责，真实测试必须检查实际接收位置。

#### 5.4 保留、删除与配置确认

注入 Clock；所有普通条目的可见性先按 lastCopiedAt 与保留期限判断，再查索引/详情/恢复。不仅清理任务，所有读取入口也必须过滤到期记录。使用 UTC 毫秒记录时间，24 小时为一天；执行期间的超时使用单调时钟。

清理触发：启动、唤醒、每分钟、保存后、期限修改后。重复复制刷新 lastCopiedAt，自身恢复/浏览不刷新。取消过期收藏、减少容量、修改期限及批量删除采用 preview → 用户确认 → apply；预览携带 storeRevision/settingsRevision，确认时状态已变化则重新预览，不能用旧确认删除新收藏。

删除事务成功后立即驱逐 UI、搜索缓存和预览；已启动的派生任务提交前检查条目 revision，禁止已删内容重建。数据库中删除后仍占用的空闲页计入实际占用；只有物理回收成功才显示已释放字节。不承诺法证级擦除。

### 6. 接口定义

下表是契约签名，不是实现。公共返回值不暴露 SQLite 句柄或 AppKit 对象。

| 接口 | 签名 | 输入/输出约定 | 错误或跳过 |
|---|---|---|---|
| 采集 | `capture(after: Int, policy: CapturePolicySnapshot) async -> CaptureOutcome` | noChange / snapshot / skipped(reason)；snapshot 带 before/afterCount、item、source、policyRevision | accessUnavailable、changedDuringRead、sensitive、unsupported、tooLarge、busy |
| 保存 | `ingest(_ snapshot: ClipboardSnapshot, at: Instant) async throws -> IngestResult` | inserted / deduplicated / skipped；插入必须在持久化提交后返回 | StoreError；最终策略复查 |
| 检索 | `search(_ request: SearchRequest) async throws -> SearchPage` | queryID、字面查询、scope、kind、cursor；返回 revision、摘要和命中范围 | invalidCursor、cancelled、unavailable |
| 详情 | `detail(id: ClipID, at: Instant) async throws -> ClipDetail` | 不可见或已删条目统一 notFound | notFound、corruptPayload |
| 恢复数据 | `loadPayload(id: ClipID, at: Instant) async throws -> ClipboardPayload` | 完整有序支持格式；与 detail 分离，避免列表批量读 BLOB | notFound、corruptPayload |
| 复制/粘贴 | `perform(_ request: PasteRequest) async -> PasteResult` | request 含 ClipID、format、action、TargetToken；结果含 fallback 原因 | clipboardWriteFailed、clipboardChanged、permissionRequired、targetChanged |
| 变更预览 | `preview(_ change: HistoryChange) async throws -> ChangePreview` | 收藏切换、批量删除、期限/容量调整；返回 token、数量、预计释放及文案 | invalidSettings、notFound |
| 确认变更 | `apply(_ token: ChangeToken) async throws -> ChangeResult` | 校验 store/settings revision；返回实际结果及实际释放量 | stalePreview、diskFull、ioFailure |
| 定时清理 | `expire(at: Instant) async throws -> CleanupResult` | 按当前设置清理普通条目，返回数量/实际释放 | 不删除收藏 |
| 空间查询 | `usage() async throws -> StorageUsage` | measuredTotal、favoritePayload、normalPayload、common、pending、temporary；temporary 单列 | measurementFailed 不伪装为 0 |
| 配置 | `updateCaptureSettings(_ change: CaptureSettingsChange) async throws -> SettingsSnapshot` | 非破坏性设置也有 revision；容量/期限走 preview/apply | invalidSettings、registrationFailure |
| 状态订阅 | `events() -> AsyncStream<HistoryEvent>` | 提交后发布 revision/status；不携带正文或图片 | 取消订阅释放资源 |
| 启动恢复 | `recover() async throws -> RecoveryReport` | 恢复 SQLite、候选垃圾、迁移检查；完成后才开始采集 | incompatibleSchema、corruptStore |

关键值类型：

| 类型 | 必需成员 |
|---|---|
| ClipboardSnapshot | captureID、changeCount、capturedAt、orderedItems、source、policyRevision、canonicalHash |
| PasteboardItemValue | index、supportedRepresentations、declaredTypes；标记只进入策略，不持久化正文 |
| TargetToken | PID、bundleID、进程启动身份、面板会话 ID |
| SearchRequest | queryID、literal、scope(all/favorites)、kind(optional)、pageSize、cursor(optional) |
| ChangePreview | operation、token、storeRevision、settingsRevision、affectedCount、estimatedReclaimBytes、requiresConfirmation |
| StoreError | diskFull、quotaExceeded、ioFailure、corruptPayload、incompatibleSchema、stalePreview、postCommitUnavailable |

### 7. 界面与配置实现约定

- 面板建议初始 900×460pt，缩小到当前屏幕可见区域内；首版不复刻 Paste 美术资源。顶部搜索、全部/收藏、类型筛选，下方历史和详情。
- 打开聚焦搜索；输入法 marked text 存在时 Enter 用于确认候选，不能误触粘贴。方向键只在不破坏输入法编辑的条件下导航；Escape 先取消输入法组合，再关闭面板。
- 空历史、无命中、加载中、保存失败和容量限制分别显示。缩略图按可见行加载，取消不可见工作；copy/direct 结果文案使用 PRD。
- 暂停状态、访问状态与容量状态分别保存；“恢复采集”不能覆盖用户主动暂停，释放容量也不能自动撤销主动暂停。
- 设置的登录启动使用 SMAppService.mainApp，展示实际 status；注册请求成功不等于系统授权完成。仅由用户操作开关触发注册，不在测试启动时自动注册。[Apple register](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29?changes=_4)
- 应用排除通过应用选择器获取 bundleID；不把应用名当唯一键。设置持久化成功后才展示已生效。

### 8. 关键决策与理由

| 决策 | 选择与替代方案 | 理由 |
|---|---|---|
| 数据层 | SQLite；不同时使用 Core Data | 配额、原子淘汰和查询有单一控制点 |
| 载荷 | 首版 BLOB；不立即分离附件 | 与元数据一库提交，避免旧附件删除后无法回滚；T03/T20 验证代价 |
| 日志 | DELETE；暂不使用 WAL | 候选文件替换和实际占用更可控；单机串行写入足够 |
| 搜索 | 字面查询；不首发 FTS/Spotlight | 中文短词与符号正确性更直接；性能不达标再优化同一语义 |
| 工程 | SwiftPM + 打包脚本；不强制 Xcode 项目生成器 | 当前环境即可开始；完整 Xcode 只在需要 XCUITest 时引入 |
| 集成测试 | 真实临时 SQLite + fake 系统边界 | 覆盖事务/恢复，而不默认改用户剪贴板和权限 |
| 运行态验收 | 单独真实应用矩阵 | 模拟事件发送不能证明应用收到内容 |

### 9. 风险与权衡

| 风险 | 影响 | 处理 |
|---|---|---|
| 来源标记缺失或伪造 | 无法普遍准确归因和排除 | 未知默认行为明确；真实矩阵报告支持情况，不用前台猜测充当证据 |
| 同步 pasteboard provider 阻塞 | 采集/UI 延迟 | 支持白名单、有限重试、实测；不能把取消 Task 误当取消系统调用 |
| 候选库路径较慢 | 接近容量时延迟 | 优先完成正确性；保守快路径只在预算证明后启用；记录慢路径 P95 |
| 源库接近配额、磁盘也不足 | 无法安全生成候选 | 明确拒绝并保留旧内容，不以先删旧记录腾盘解决 |
| 焦点在检查后再次变化 | 事件可能进入非预期位置 | 保持检查与发送相邻，不承诺无法保证的全局原子性；用户可使用复制模式 |
| HTML/RTF 解析器行为 | 外部资源读取或高耗时 | HTML 使用无网络本地文本提取；用本地捕获服务验证零网络请求 |
| 最低 OS 未测试 | 兼容性承诺不足 | T19 必须单列最低 OS；不能把 deployment target 当运行通过 |

发布策略：先交付 Debug/Release 本地 `.app`；登录启动和权限实测采用固定路径与稳定开发标识。T21 记录签名方式，ad-hoc 开发包不能宣称已公证。数据库迁移事务化；高版本 schema 在旧程序中拒绝写入。首版不设计自动更新服务，保留测试库而不操作用户历史。

### 10. 变更文件清单

以下是待创建的工程路径，均相对于新工程 `macos-app/`，当前并不存在。

| 路径 | 操作 | 内容 |
|---|---|---|
| Package.swift | 新建 | LocalClipCore、LocalClipMac 库、LocalClip 可执行程序、测试目标 |
| Sources/LocalClipCore/Domain/ | 新建 | 值类型、错误、策略和时间语义 |
| Sources/LocalClipCore/Storage/ | 新建 | SQLite wrapper、schema、HistoryStore、配额和恢复 |
| Sources/LocalClipCore/Search/ | 新建 | 字面搜索与排序 |
| Sources/LocalClip/App/ | 新建 | AppDelegate、依赖组装、生命周期 |
| Sources/LocalClipMac/System/ | 新建 | pasteboard、目标应用、热键、权限、登录启动 adapter |
| Sources/LocalClipMac/Features/ | 新建 | CaptureCoordinator、PasteCoordinator、派生内容 |
| Sources/LocalClipMac/UI/ | 新建 | 历史、详情、设置、状态视图 |
| Tests/LocalClipCoreTests/ | 新建 | 核心规则、真实临时数据库、故障注入 |
| Tests/LocalClipIntegrationTests/ | 新建 | 协调层、系统边界 fake、流程集成 |
| Fixtures/ | 新建 | 可生成的合成文本、RTF/HTML、图片和测试 manifest |
| Resources/Info.plist | 新建 | 开发标识、LSUIElement、版本字段 |
| scripts/build-app.sh | 新建 | 构建、资源复制、本地签名、生成 .app |
| scripts/benchmark.sh | 新建 | 合成数据性能测量入口，不触碰真实历史 |
| docs/environment.md、docs/compatibility.md | 新建 | 实施机器、格式及目标应用的真实结果 |

## How

### 任务拆分

详细的逐项输入、文件与完成条件见 [tasks.md](tasks.md)。下面的人天估算包含实现和该项验证，不等于 agent 耗时。

| ID | 任务名称 | 关联设计章节 | 依赖 | 估算人天 |
|---|---|---|---|---|
| T00 | 【基线】环境和兼容边界确认 | 1 | 无 | 0.5 |
| T01 | 【工程】SwiftPM 与 .app 骨架 | 1、10 | T00 | 1 |
| T02 | 【契约】领域类型和测试边界 | 2、6 | T01 | 1 |
| T03 | 【存储验证】配额与原子替换原型 | 4 | T02 | 2 |
| T04 | 【数据库】模型与迁移 | 3 | T03 | 1.5 |
| T05 | 【历史存储】持久化与去重 | 3、4 | T04 | 2 |
| T06 | 【系统采集】多格式稳定快照 | 1.1、5.1 | T02 | 1.5 |
| T07 | 【采集策略】来源、敏感标记、配置版本 | 1.2、5.1 | T02 | 1 |
| T08 | 【采集闭环】队列、暂停、自身写入 | 5.1 | T05、T06、T07 | 1 |
| T09 | 【搜索】字面匹配与分页 | 5.2 | T05 | 1.5 |
| T10 | 【内容恢复】原格式与纯文本复制 | 1.1、5.3 | T05、T06 | 1 |
| T11 | 【直接粘贴】权限、焦点与回退 | 5.3 | T10 | 1.5 |
| T12 | 【保留清理】期限、收藏、删除 | 5.4 | T05 | 1.5 |
| T13 | 【容量管理】配额与确认操作 | 4、5.4 | T05、T12 | 2 |
| T14 | 【派生内容】缩略图和正文回退 | 1.1、4.3、5.2 | T09、T13 | 1 |
| T15 | 【设置】持久化、热键与登录启动 | 7 | T07、T11、T13 | 1.5 |
| T16 | 【界面】面板、详情与键盘操作 | 7 | T08、T09、T10、T11、T12、T14、T15 | 2 |
| T17 | 【恢复】重启、崩溃与并发边界 | 4、5.4 | T08、T13、T14 | 2 |
| T18 | 【集成】全部首版流程 | 5、7 | T16、T17 | 1 |
| T19 | 【真机验收】应用与权限矩阵 | 1.1、5.3、9 | T18 | 2 |
| T20 | 【性能】容量和资源基准 | 4、5.2、9 | T18 | 1.5 |
| T21 | 【交付】Release 包与证据归档 | 9、10 | T19、T20 | 1 |
| 合计 | 22 个任务，环境就绪且熟悉 Swift/macOS 的工作量估算 | — | — | 31 |

执行顺序：T00–T05 优先建立底座；T06/T07 可在接口固定后独立开展。随后完成采集、搜索、恢复和数据管理，最后连接界面。T19 和 T20 可分别验证，但一个通过不能替代另一个。

若由多人或多个 agent 实施，应明确文件负责人：数据库及 schema 单人负责；T06/T07 共享的 Domain 修改先达成契约；UI 不得复制一套业务规则。此处是交接约定，不代表本轮已启动开发代理。

## Verify

- 所有 F01–F11 均有对应任务；F12–F14 明确排除。
- AC01–AC27 的任务、层级、数据和证据映射见 [acceptance.md](acceptance.md)。
- 文档包含方法签名、类型和状态契约，不包含应用方法体或已实现的 SQL。
- T03 是存储设计可行性关卡；T19 是真实行为关卡；T20 是性能关卡，三者不能互相替代。
- 技术选择和参数为开发基线；未执行任何应用实现测试，任务均未完成。

## Impact

- 新增独立 macOS 工程和自有本地数据目录。
- 使用系统 SQLite、AppKit、SwiftUI、CryptoKit、ImageIO、ApplicationServices 和 ServiceManagement。
- 不依赖 REA 运行，不读取 Paste 历史，不接入云服务。
- 未来更换存储方案需要维持 HistoryRepository 与 AC 行为，而不是让 UI 适配多个事实来源。
