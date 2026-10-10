# Paste 复刻方案与改进建议

本文是设计建议，不是已完成的代码或测试。依据是本目录 REA-REPORT.md 中的安装包、数据模型和接口证据，并辅以 Apple 和 SQLite 的官方文档。默认目标是 macOS 本地剪贴板工具；跨平台、移动端、团队共享另行规划。

## 1. 产品目标

第一版完成一个可信的使用闭环：复制内容后自动保存，快捷键打开历史，中文和英文都能检索，选中旧内容后可以再次粘贴，退出重启后历史仍然存在。用户要能看懂采集是否开启、为什么某次复制被忽略，以及数据是否仅留在本机。

第一版范围：文本、URL、图片、有限富文本、历史卡片、快捷键、搜索、收藏、来源应用、应用排除、暂停采集、保留期限、容量限制、手动粘贴回退。文件引用加入前要验证文件权限和失效行为。

后续范围：Pinboard、多项连续粘贴、导入导出、iCloud、OCR、语义搜索、AI/MCP。原版功能存在，并不代表都应该进入第一版。

## 2. 技术选择

建议 Swift 为主：AppKit 管理菜单栏、浮动面板、应用焦点、剪贴板和系统交互；SwiftUI 管理设置、卡片和详情视图。本地数据用 SQLite，并通过一个 HistoryStore 模块集中处理事务、迁移、检索和清理。

选择 SQLite 是为了显式控制搜索、容量与逐项同步策略，不是因为 Paste 的 Core Data 方案有问题。若团队最熟悉 Core Data，首版本地版也可以用它；不要为了搜索另建一套互为事实来源的历史数据库。检索索引始终应可从历史内容重建。

后续 Apple 设备同步优先评估 CKSyncEngine，但需要自己持久化同步状态、处理本地记录映射和删除语义。NSPersistentCloudKitContainer 是 Core Data 路线的另一种选择，两者不应在同一批记录上各自管理同步。

## 3. 模块和 Interface

模块对调用方暴露少量完整操作，把状态、失败处理和性能约束留在内部。

| 模块 | Interface 的主要职责 | 内部 Implementation |
|---|---|---|
| ClipboardCapture | 返回稳定快照或明确的跳过原因 | changeCount 检查、读取、采集竞态、格式支持 |
| CapturePolicy | 决定保存、跳过或保留在会话内 | 来源应用排除、敏感标记、临时数据、大小限制 |
| HistoryStore | 保存、查询、收藏、删除、执行保留规则 | SQLite 事务、迁移、附件引用和垃圾回收 |
| Search | 按查询及筛选返回有序结果 | 中文短词匹配、索引、排序、取消过期查询 |
| PasteAction | 将项目放回剪贴板或交付给目标应用 | 格式选择、焦点恢复、权限检查、自写去重 |
| HistoryPanel | 展示结果并执行用户选择 | 快捷键、卡片加载、键盘导航、窗口布局 |

Sync 仅在确实开发同步时增加。为采集器使用系统 Adapter 和测试快照 Adapter，才能用同一个 Interface 验证多格式、敏感标记与读取竞态；不为没有第二种实现的假想变化添加插件层。

## 4. 采集流程

1. 记录 NSPasteboard.general.changeCount。
2. 周期检查是否变化。可从 200 ms 开始实验；这是初始设计参数，不是 Paste 的实测值，也不是性能保证。
3. 检查暂停、系统访问状态、排除应用和可读取的类型标记。
4. 保存当前代数，读取支持的 items/representations；完成后再核对代数。
5. 若读取期间代数改变，放弃混合快照并有界重试。系统没有替本应用保留所有中间版本，因此不能承诺任意快速复制都零丢失。
6. 对原始内容生成稳定哈希，事务提交元数据和有效附件引用。
7. 再通知界面刷新，并异步生成缩略图或索引。

不要监听 Command+C 来当作复制成功。鼠标菜单复制、应用内复制和远程剪贴板都可能改变内容。也不要把前台应用直接当成精确复制来源：后台写入、自动化、Handoff 和远程工具都可能造成错误归因。来源不确定时允许显示“未知”，并保留归因依据。

NSPasteboard 支持多项及多种格式。一个复制操作可能包含多个文件，也可能同时包含 plain text、HTML、RTF 和图片。快照要保留 item 顺序及支持格式的原始字节；显示用的纯文本和缩略图是派生数据。重型、延迟生成或不支持的格式要有明确限制，不要无界读取所有声明类型。

## 5. 推荐数据模型

| 数据 | 字段示例 | 用途 |
|---|---|---|
| Clip | id、kind、createdAt、lastCopiedAt、contentHash、sourceApp、sourceConfidence、deviceId、byteSize | 用户看到的一张历史卡片 |
| Representation | clipId、itemIndex、pasteboardType、payloadRef、byteSize、digest | 有序剪贴板项目的多格式原始内容 |
| DerivedContent | clipId、displayText、searchText、thumbnailRef、OCRText | 可以重建的搜索和展示数据 |
| Pinboard | id、name、sortOrder | 用户组织内容 |
| PinboardItem | pinboardId、clipId、position | 同一个内容可以属于多个 Pinboard |
| Policy | sourceApp、captureMode、retention、syncScope | 采集和保留策略 |

首版只需保存 lastCopiedAt/copyCount，不必另建永久复制事件日志。大型二进制载荷独立存储，小数据可内联；阈值要通过读写与容量测试决定。不要让列表首屏读取所有完整图片。

哈希应覆盖有序 item、类型和原始 payload，不能仅按展示纯文本判断相同。格式不同的两次复制可能显示同样文字，但再次粘贴时行为不同。去重可以合并完全相同的 payload、更新最近复制时间；这是一项产品规则，必须明确，不是 REA 已确认的原版逻辑。

文件引用默认只记录引用和必要的恢复信息，不自动备份文件全文。原文件删除、移走、权限撤回时，应显示失效而不是假装能恢复。

## 6. 粘贴流程和循环控制

打开面板前保存目标应用；选中后恢复支持的剪贴板表示，隐藏面板并请求目标应用重新激活，再按权限和模式执行直接粘贴。未获权限或目标状态不确定时，保持“已复制，可手动粘贴”的有效回退。

直接粘贴模块必须区分：剪贴板写入成功、键盘事件发送成功、目标应用接收成功。前两项不等于第三项。原格式和纯文本模式也要分开验收。

记录自己写入后的 changeCount 和内容哈希，只过滤匹配的自写快照。可补充自定义来源标记帮助多个工具协作，但不能只依赖标记。不要通过全局暂停采集一秒来去重，那会漏掉用户在这一秒里的真实复制。

连续粘贴队列必须允许用户重新指定下一项或重试，不能只因事件已发送就认定某项已成功进入目标字段。

## 7. 搜索设计

从第一版就覆盖中文、英文、链接和代码。展示字段与搜索字段分离；搜索字段可由用户标题、正文、URL、标签、来源应用和后续 OCR 组成。

首版可用有界的字面子串搜索和类型/应用/时间筛选，先测 1 万条记录，再按瓶颈升级索引。输入作为字面查询处理，不把用户粘贴的代码或标点直接当全文检索语法。

FTS5 trigram 支持子串检索，但少于 3 个 Unicode 字符的 MATCH 查询不产生匹配结果。两字中文查询需要独立的正确性路径，例如有界 LIKE；大数据量时再考虑中文分词或其他索引。部署前核对所用 SQLite 构建实际支持的功能。

默认排序建议：明确匹配优先，再按最近复制时间；用户主动进入的 Pinboard 范围优先约束结果。使用频率可作为次级因素，不让旧的常用项目压过明确匹配。结果展示命中的上下文和来源，便于确认是否选对。

## 8. 隐私和可靠性改进

这些是改进机会，不代表已证明原版都缺失。

| 优先级 | 建议 | 具体价值 |
|---|---|---|
| P0 | 明确区分采集开启、暂停、访问被拒绝、应用被排除 | 用户能解释“为什么没记住” |
| P0 | 敏感/临时内容先过滤，默认不进入附件、索引、日志和同步 | 防止表面删除后仍留在派生数据里 |
| P0 | 中文短词、代码子串和 URL 搜索 | 提升实际找回内容的成功率 |
| P0 | 原格式/纯文本可预期，直接粘贴有手动回退 | 降低误粘贴和权限失效的影响 |
| P1 | 按天数及总容量保留，显示文本/图片/附件占用 | 控制长期磁盘增长 |
| P1 | 每项/每应用可选择仅本机、允许同步、会话内保留 | 不必在全开和全关之间二选一 |
| P1 | 删除同时更新内容、缩略图、搜索索引和待同步删除 | 避免残留和跨设备复活 |
| P1 | 标签、用户标题、多个 Pinboard 引用同一内容 | 减少重复保存和命名混乱 |
| P2 | 本机 OCR；随后可选本地语义搜索 | 让截图和模糊记忆可检索 |
| P2 | 经用户逐次选择内容的 AI/MCP 输入 | 给 AI 提供明确上下文，而非默认暴露所有历史 |

密码格式或熵检测只能补充提示，不能准确判定所有密码。优先尊重应用明确的机密/临时类型约定和用户排除设置。org.nspasteboard.* 是生态约定，不是 Apple 保证所有应用都实现的标准。

本机落盘不自动等于加密。若选择内容加密，还要决定标题、索引、OCR、缩略图是否一起保护，密钥如何保存，以及加密对搜索的影响。加密和语义索引不是首版必须同时建设的两套系统。

## 9. 同步设计

等本地版稳定后再增加同步。预先区分 cloud-enabled 与 local-only，避免“用户关了同步但内容已经上传”。从已上传改为仅本机时，要处理远端删除，而不是仅停后续上传。

待同步变更、同步状态和删除标记要跨重启持久化；仅在确认远端提交后移除待处理操作。需要覆盖断网重试、退出重启、切换账号、多设备同时编辑、删除后离线设备重新上线等流程。垃圾回收和 tombstone 的清理时机要一并设计。

状态至少区分：未启用、等待上传、同步中、已同步、网络暂不可用、账号不可用、需要用户操作，并显示最后成功时间。不能用 enable-sync=true 当作成功信号。

普通 macOS NSPasteboard 自动参与系统 Universal Clipboard；Apple 没有开放直接控制该功能的 macOS 接口。复制来源标记和内容去重能改善兼容性，但不能承诺完全识别每一次远程复制。

## 10. 开发顺序和验收

阶段一：纯文本本地闭环。连续复制 A/B/C，三个项目可检索；选 A 后手动粘贴得到 A；重启后 A 仍在；被排除的测试应用不持久化内容。

阶段二：多格式、图片和直接粘贴。分别在 TextEdit、浏览器输入框、代码编辑器和办公软件中验证原格式、纯文本、图片、权限关闭和目标焦点变化。只能把实际验证的目标列为支持。

阶段三：Pinboard、中文搜索、容量和清理。验证两字查询、代码标点、多个 Pinboard 引用、清理不删固定项目，以及正文/索引/缩略图一致删除。

阶段四：同步。至少两台真实设备验证离线创建、恢复联网、重复重试、冲突和删除不复活。模拟服务通过不等于 iCloud 真机验收。

阶段五：OCR、语义检索和可选 AI/MCP。先证明传统搜索已经稳定，再评价新增功能是否真正减少找回内容的步骤。

建议性能目标：指定测试机、1 万条文本与典型图片数据集下，面板打开 P95 <150 ms、搜索 P95 <100 ms、复制到可见 P95 <500 ms。这些是待验证的目标，不是现有产品或拟实现产品已经达到的实测结果。单独记录功耗、后台空闲 CPU、峰值内存、大图复制耗时和丢失/跳过原因。

## 参考资料

- REA 二进制与模型证据：REA-REPORT.md，evidence/rea-model.json，evidence/rea-macho.json。
- Apple NSPasteboard：https://developer.apple.com/documentation/appkit/nspasteboard/
- Apple changeCount：https://developer.apple.com/documentation/appkit/nspasteboard/changecount
- Apple pasteboard accessBehavior：https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972
- Apple Accessibility trust：https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted
- SQLite FTS5：https://www.sqlite.org/fts5.html
- Clipboard 生态约定：https://nspasteboard.org/
- Apple CKSyncEngine：https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9
- Apple Core Data/CloudKit 同步：https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer
