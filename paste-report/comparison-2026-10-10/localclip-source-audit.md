# LocalClip 0.1.14 源码能力审计

审计时间：2026-10-10。对象为工作区 `macos-app` 的实际源码及已打包应用元数据。源码与 dist 应用的 Info.plist 均为 **0.1.14，构建15**。本报告只判定 LocalClip 具备什么接口和实现；Paste 是否具备对应功能，须由主比较报告另外引用 Paste 官方、包内或运行证据，不能从本表反向推定。

本轮只读源码和已有证据，没有启动应用、运行测试或基准，没有读取用户剪贴板或历史数据库，没有修改产品、任务或构建。证据强度：**源码实现 ≠ 当前版本运行通过**。当前交付清单明确 `currentVersionTestsExecuted=false`、`currentVersionPerformanceMeasured=false`、`currentVersionVisualVerified=false`。之前版本的50项功能通过及部分 Safari/TextEdit/Pages 接收不能认证0.1.14。

## 主要发现

1. 分类已支持新建、重命名、拖入、多个分类归属和移除归属，但并不是完整 Pinboard 生命周期：没有删除分类、拖动排序、自选颜色、分类专用快捷键；只按创建时间排序，色标从ID派生。
2. **加入分类不保护内容免于期限/容量淘汰**，只有收藏保护。分类与收藏是两套独立状态。因此用户把常用内容拖入分类后，仍可能按30天默认期限或容量规则删除。此为明确源码行为差异，不是运行故障推断。
3. 新拖拽只在 LocalClip 内归类。provider 注册 `.ownProcess` 类型，负载是36字节UUID令牌，而非文本/图片/文件原始内容；不能因此宣称能从历史卡片拖到其他应用。
4. UI只有单条 `selectedID`。底层删除支持ID数组，但没有多选、多条批量分类/复制/删除、合并粘贴、连续粘贴队列。原始一次复制中的多项顺序已保存，这与用户多选多个历史条目是不同能力。
5. 原格式恢复、自动粘贴、底部全宽、来源图标、滚轮/Esc/快捷键切换等均已写入源码；当前版本仍没有目标应用实际接收或GUI性能验收，不能列为“与Paste已等效”。

## 能力矩阵

路径均相对 `/Users/ronny/VscodeProjects/rea/macos-app/`。行号用于对应完整源码，不把字段或字符串单独视为运行证据。状态“实现”均仅表示源码实现。

| 编号 | 能力 | LocalClip 判定与实际边界 | 源码证据 |
|---|---|---|---|
| L01 | 历史采集、持久化、去重 | 实现。200ms轮询，32项/50MiB，原格式字节+多项顺序参与身份；支持类型外的表示不保存。 | `Sources/LocalClipMac/Features/CaptureCoordinator.swift:25–36,58–85`；`Sources/LocalClipMac/System/MacPasteboardClient.swift:44–99`；`Sources/LocalClipCore/Domain/Domain.swift:69–90`；`Sources/LocalClipCore/Storage/HistoryStore.swift:134–188` |
| L02 | 格式支持 | 部分。白名单8种：UTF8文本、URL、RTF、HTML、PNG、TIFF、JPEG、fileURL。RTFD、PDF原生表示、音视频/专有原生对象、Promise-only不在支持集；这些对象若另有支持的文本或文件URL表示，可保存该表示，不能等同原生对象完整支持。 | `Sources/LocalClipCore/Domain/Domain.swift:21–31`；`Sources/LocalClipMac/System/MacPasteboardClient.swift:75–96` |
| L03 | 文件历史/恢复 | 部分。存文件URL引用而非文件备份；原件移动/删除后无法凭历史重建内容。Finder双击按实际目录复制副本，权限/身份/剪贴板/目录复查有实现，当前版本未运行验收。 | `Sources/LocalClipCore/Domain/Domain.swift:45–60`；`Sources/LocalClipMac/Features/PasteCoordinator.swift:82–118`；`Sources/LocalClipMac/UI/HistoryView.swift:324` |
| L04 | 原格式/纯文本输出 | 实现。恢复受支持的所有表示与项目；纯文本需要每项可提取文本，以换行连接；无文本项不会被静默丢弃。没有更多变换器。 | `Sources/LocalClipMac/System/MacPasteboardClient.swift:21–32`；`Sources/LocalClipMac/Features/PasteCoordinator.swift:17–38`；`Sources/LocalClipCore/Domain/Domain.swift:63–67,296` |
| L05 | 双击自动粘贴 | 实现但可靠性未确认。目标PID/bundle/启动时间、AX原焦点身份、权限及写入收据复核；允许编辑器/画布，不限定textarea。返回commandSent只代表事件发送，没有接收检测或插入成功验证。 | `Sources/LocalClipMac/UI/HistoryViewModel.swift:233–250`；`Sources/LocalClipMac/Features/PasteCoordinator.swift:39–78`；`Sources/LocalClipMac/System/MacApplicationClient.swift:26–58,94–104` |
| L06 | 持久收藏 | 实现。收藏免期限及自动容量淘汰但计入容量；过期取消收藏需确认。 | `Sources/LocalClipCore/Storage/HistoryStore.swift:85–86,102–110,339–344,393–395` |
| L07 | 自定义分类新建/重命名 | 实现。＋内嵌popover编辑，1–64字符，去首尾空白/NFC，ASCII大小写去重；持久ID不因改名改变。 | `Sources/LocalClipMac/UI/HistoryView.swift:28–44,181–198`；`Sources/LocalClipCore/Storage/HistoryStore.swift:38–68` |
| L08 | 分类删除/排序/配色/快捷键 | 缺失。只存在create/rename/setCategory；列表按createdAtMs,id，颜色由ID哈希到6色，键盘入口没有分类专属热键。 | `Sources/LocalClipCore/Storage/HistoryStore.swift:44–80`；`Sources/LocalClipCore/Domain/Domain.swift:177–180`；`Sources/LocalClipMac/UI/HistoryView.swift:144–154`；`Sources/LocalClipMac/UI/AppDelegate.swift:320–345` |
| L09 | 分类归属与保留 | 部分。一个项目可属多个分类；移除归属不删正文；但分类不会自动收藏，期限和容量淘汰只检查isFavorite，分类不是永久保存保险。 | `Sources/LocalClipCore/Storage/HistoryStore.swift:71–86,102–110,407–415` |
| L10 | 拖卡片到分类 | 实现、实际手势未验证。卡片onDrag，标签onDrop/高亮，唯一令牌60秒失效，异步取值复查记录/目标后写归属；仅接受一条。 | `Sources/LocalClipMac/UI/HistoryView.swift:159–178,249–255`；`Sources/LocalClipMac/UI/HistoryViewModel.swift:320–359` |
| L11 | 拖出内容到其他应用 | 缺失。现有拖拽只导出ownProcess UUID，没有公开原内容提供者。没有向textarea/编辑器/Finder拖出的实现。 | `Sources/LocalClipMac/UI/HistoryViewModel.swift:320–351`；`Sources/LocalClipMac/UI/HistoryView.swift:253–255` |
| L12 | 多选及批量操作 | UI缺失。selectedID是单值，卡片点击选择一条；deleteSelected只能传一个ID。Core的delete数组是内部能力，不是产品多选。 | `Sources/LocalClipMac/UI/HistoryViewModel.swift:16,128–146,288–290`；`Sources/LocalClipMac/UI/HistoryView.swift:249–270`；`Sources/LocalClipCore/Domain/Domain.swift:207–208` |
| L13 | 合并多条/顺序或连续粘贴 | 缺失。PasteRequest只携带一个id，coordinator一次loadPayload、一次写板/发事件；没有历史条目队列、分隔符/选择顺序或next/advance。CaptureCoordinator的queue只用于采集入库，不能视为粘贴队列。 | `Sources/LocalClipCore/Domain/Domain.swift:256–263`；`Sources/LocalClipMac/Features/PasteCoordinator.swift:17–78`；`Sources/LocalClipMac/Features/CaptureCoordinator.swift:16,73–85` |
| L14 | 内容编辑/自定义标题 | 缺失。ClipSummary无标题字段、HistoryChange无编辑类型；详情只有只读Text/textSelection，分类名称TextField不代表历史正文编辑。 | `Sources/LocalClipCore/Domain/Domain.swift:152–168,207–208`；`Sources/LocalClipMac/UI/HistoryView.swift:308–329`；`Sources/LocalClipCore/Storage/Schema.swift:6–25` |
| L15 | 查找与筛选 | 实现字面全文/来源名查询，NFC+ASCII规范化，符号/短中文/URL片段字节匹配，匹配排序+最近复制；50条分页。没有正则、日期范围、结构化来源筛选、OCR索引。 | `Sources/LocalClipCore/Storage/HistoryStore.swift:258–330`；`Sources/LocalClipCore/Search/SearchNormalizer.swift:4–18`；`Sources/LocalClipCore/Domain/Domain.swift:191–205` |
| L16 | 分类+类型联合筛选 | 部分。Core可同传kind/categoryID，但UI点击类型清categoryID、点分类清kind，收藏入口也清类型/分类；用户不能直接在某分类内再点“图片”保留分类范围。 | `Sources/LocalClipMac/UI/HistoryView.swift:131–148`；`Sources/LocalClipCore/Storage/HistoryStore.swift:263–270,306–308` |
| L17 | 键盘、滚轮与面板开关 | 实现。单全局自定义热键显示/隐藏；方向键分页导航、Enter默认动作、Cmd-C、Esc、Delete/Backspace，IME和编辑名称避让；纵向滚轮映射横向，横向手势交原生惯性。无Cmd-number快速条目或类别切换快捷键。 | `Sources/LocalClipMac/UI/AppDelegate.swift:157–159,320–345`；`Sources/LocalClipMac/UI/HistoryView.swift:114–115`；`Sources/LocalClipMac/UI/HistoryScrollWheel.swift:71–94`；`Sources/LocalClipMac/UI/SettingsView.swift:71–86` |
| L18 | 面板布局/展示定制 | 底部全宽380pt、半透明和失焦关闭有实现；跟随鼠标所在屏幕/屏幕变化。没有用户自选停靠边、面板大小、卡片尺寸、布局密度或透明度设置。 | `Sources/LocalClipMac/UI/AppDelegate.swift:175–204,212–231,293–297`；`Sources/LocalClipMac/UI/HistoryBackdrop.swift:19`；`Sources/LocalClipMac/UI/SettingsView.swift:16–58` |
| L19 | 来源名称/应用图标 | 实现但存在推断边界。声明优先，缺失用前台/停用应用关联计数推断，冲突/非法声明未知；图标缓存，后台写板和竞态无法保证真实来源。当前版未实测。 | `Sources/LocalClipMac/System/MacPasteboardClient.swift:53–72`；`Sources/LocalClipMac/System/SourceApplicationObserver.swift:15–38,47–65`；`Sources/LocalClipMac/UI/HistoryView.swift:224–241` |
| L20 | 应用排除及敏感过滤 | 部分。ConcealedType/TransientType正文读取前整次过滤；排除只匹配声明来源bundleID，前台推断及未知不参与排除。选择普通不声明来源应用并不保证其复制被排除。没有网页域名、关键词、正则内容排除，也没有“识别所有密码”。 | `Sources/LocalClipCore/Domain/Domain.swift:143–147`；`Sources/LocalClipMac/System/MacPasteboardClient.swift:43–50,72–84`；`Sources/LocalClipMac/UI/SettingsView.swift:33–41` |
| L21 | 图片/OCR/图片编辑 | 只有PNG/TIFF/JPEG缩略图；40MP以上不解码，800px下采样。没有OCR、识别图片文字搜索、裁剪/调整/转格式/图片导出UI。 | `Sources/LocalClipMac/Features/ThumbnailRenderer.swift:8–22`；`Sources/LocalClipMac/UI/HistoryView.swift:308–329`；全源码符号边界 |
| L22 | 富文本、网页链接及文件预览 | 部分。富文本原字节保存，但卡片/详情只显示提取的纯文本；链接显示host/片段，不取网页标题/封面；文件只引用/路径说明，无QuickLook或文件内容预览。HTML提取不请求远端资源是刻意本地隐私方案。 | `Sources/LocalClipMac/UI/HistoryView.swift:282–304,313–326`；`Sources/LocalClipMac/Features/ContentDecoder.swift:5–18`；`Sources/LocalClipCore/Search/SearchNormalizer.swift:35–51` |
| L23 | 历史期限及容量 | 实现：默认30天/500MiB，可1–365天/100–4096MiB；不是无限历史。全局期限，无法分类/项目单独期限；只有收藏可长期保留。 | `Sources/LocalClipCore/Domain/Domain.swift:128–140`；`Sources/LocalClipMac/UI/SettingsView.swift:44–53` |
| L24 | 可靠保存、删除及派生失效 | 实现候选数据库写入→完整quick_check/FK→物理计量→同步→原子rename；失败不先删原库。查询世代、删除集合、到期deadline、缩略图存在/revision复查防旧内容回显。历史相关测试有证据，新增UI当前未回归。 | `Sources/LocalClipCore/Storage/CommitStrategy.swift:59–139`；`Sources/LocalClipMac/UI/HistoryViewModel.swift:87–104,127–187,189–214,253–285`；`Sources/LocalClipMac/Features/ThumbnailRenderer.swift:30–44` |
| L25 | 暂停、登录启动、快捷键设置 | 实现全局暂停与持久设置、系统SMAppService登录项和一个可录制全局热键。没有按应用设置粘贴格式/动作、自动到时恢复的暂停、多个动作热键或规则系统。 | `Sources/LocalClipMac/UI/SettingsView.swift:20–30,71–95`；`Sources/LocalClipCore/Domain/Domain.swift:128–140`；`Sources/LocalClipMac/Features/CaptureCoordinator.swift:40–55` |
| L26 | 同步/跨设备/手机/Web/团队分享 | 缺失。单macOS SwiftPM可执行与本地SQLite，没有CloudKit/iCloud/账号服务/同步协调/分享UI或iOS目标。此为当前Local-first定位，不自动建议复制到云端。 | `Package.swift:4–15`；`Sources/LocalClipMac/UI/AppDelegate.swift:42–46`；`Sources/LocalClipCore/Storage/CommitStrategy.swift:13–18`；全源码符号边界 |
| L27 | 数据导入/导出/备份恢复/迁移 | 产品能力缺失。没有导入/导出/备份UI；SQLite backup仅作内部原子提交候选复制，不是用户备份。schema仅接受精确2，迁移分支按用户要求移除；不得把“不支持升级兼容”列为待实现缺陷。 | `Sources/LocalClipCore/Storage/HistoryStore.swift:18–28`；`Sources/LocalClipCore/Storage/CommitStrategy.swift:79–85`；`Sources/LocalClipMac/UI/SettingsView.swift:16–58` |
| L28 | 加密/锁定/隐私模式 | 未实现应用级数据库加密、内容锁、解锁认证、安全模糊卡片或保密分类。普通SQLite保存明文原载荷；CryptoKit仅SHA256内容指纹，不能视为加密。系统磁盘加密状态不在本次核验范围。 | `Sources/LocalClipCore/Domain/Domain.swift:93–95`；`Sources/LocalClipCore/Storage/Schema.swift:15–28`；`Sources/LocalClipCore/Storage/SQLiteConnection.swift:83–90`；`Sources/LocalClipMac/UI/SettingsView.swift:41` |
| L29 | 多实例/最低系统/发布分发 | 单实例接替逻辑实现，系统macOS15+，当前本地arm64应用；当前升级兼容、签名/公证自动更新、App Store分发不是现有功能。当前签名为构建脚本ad hoc。最低macOS15.0与接替运行尚未验收。 | `Sources/LocalClipMac/UI/AppDelegate.swift:48–64,118–137`；`Sources/LocalClipMac/System/SingleInstanceService.swift`；`Package.swift:5`；`scripts/build-app.sh`；`Resources/Info.plist` |
| L30 | GUI性能成熟度 | 已做优化但未确认效果：LazyHStack/近尾分页、Equatable卡片、选择25ms合并轻元数据、详情按需读、固定操作区/最终frame。近配额全候选复制/校验仍与库大小相关，不能从代码宣称不卡。当前GUI端到端没有样本。 | `Sources/LocalClipMac/UI/HistoryView.swift:53–79,92–116`；`Sources/LocalClipMac/UI/HistoryViewModel.swift:127–175`；`Sources/LocalClipMac/UI/AppDelegate.swift:180–195`；`Sources/LocalClipCore/Storage/CommitStrategy.swift:70–114` |

## 验证与历史数据边界

- 当前版本运行能力：未执行。本报告所有“实现”均需主报告保留此限定，尤其L05、L10、L17–19、L29–30。
- `docs/acceptance-results.md:3–7` 及 `evidence/automated/delivery/delivery-manifest.json` 清楚区分当前仅构建与旧版测试。完整首版仍未通过全部AC。
- `docs/performance.md:11–21` 历史预读优化后服务测量：查询P95约26.056ms、第一页1.655ms、新文本122.093ms、新图片141.463ms、近配额550.153ms。均不含200ms轮询及GUI绘制；不是0.1.14实测。
- `docs/performance.md:62–69` 历史压力：200ms输入100/100保存；50ms输入100次只观察并保存27次，73次轮询未观察。不能宣称每次快速复制都不丢，也不能据此与Paste作未受控速度排名。
- 当前交付manifest保存用户此前反馈Codex/Zed粘贴失败及新修复未真实验收；不能把事件发送成功等同接收成功。

## 负向结论的搜索边界

静态审查覆盖 `macos-app/Sources/LocalClipCore/`、`macos-app/Sources/LocalClipMac/`、`macos-app/Sources/LocalClip/App/`、CSQLite桥、Package.swift、Info.plist、构建脚本，并读已有验收/性能/兼容/限制文档。重点逐段读Domain、HistoryStore、Schema、HistoryView/Model、SettingsView、AppDelegate、Capture/PasteCoordinator、MacPasteboard/ApplicationClient、SourceApplicationObserver、ThumbnailRenderer、ContentDecoder、HistoryScrollWheel。

负向搜索检查编辑/title、多选/selectedIDs、顺序/sequential、同步/CloudKit/icloud、分享/share、OCR/Vision、transform、snippet、QuickLook、导出/export、导入/import、category/delete/reorder/color/shortcut、URLSession/network 等，并核查Domain操作类型、UI入口、storage公开方法及package目标。`import Foundation`、CSQLite `export *`、内部backup、采集queue、SHA256、UI标题或测试探针不能误计为产品功能。

没有可疑缺失就扩展到用户数据、外部网络或应用运行；没有从“不见字符串”推断整个系统不支持。缺失结论只限此公开工作区源码/交付方案。第三方系统自带拖放、脚本自动化或Paste实际能力必须另外调查。

## 供主报告的优先级输入

**日常操作优先**：验证真实编辑器直接粘贴；补全分类永久保留语义和生命周期；公开原内容拖出；多选批量/顺序粘贴；Cmd-number/分类快捷键；按应用排除的实际覆盖。**随后提升使用效率**：正文编辑/标题、分类与类型联合筛选、富格式/文件更完整预览、GUI计时与大库延迟。

同步、OCR、AI、网络网页预览、加密/团队/移动端均应列为独立产品边界，不能因为Paste支持而擅自纳入当前首版。兼容/迁移代码用户已明确禁止，不作为建议新增项。

源码哈希索引：[`localclip-source-audit-hashes.json`](localclip-source-audit-hashes.json)。

## 补充核验：格式转换及设置细节

| 能力 | 当前状态 | 精确证据 |
|---|---|---|
| PDF/RTFD/颜色剪贴板对象 | 无对应原生type支持；有支持的附加文本/图片/fileURL才保存该表示，不应笼统宣称任何含这些内容的复制都整体拒绝。例如PDF文件的fileURL引用与原生PDF粘贴板数据是两类能力。 | `Sources/LocalClipCore/Domain/Domain.swift:21–30`；`Sources/LocalClipMac/System/MacPasteboardClient.swift:78–91` |
| 图片转文件粘贴/保存 | 缺失。仅original/plainText输出，Finder只认已有fileURLs；内部缩略图写成PNG并不创建用户可粘贴/保存的图片文件。 | `Sources/LocalClipMac/Features/PasteCoordinator.swift:21–38`；`Sources/LocalClipCore/Domain/Domain.swift:296`；`Sources/LocalClipMac/Features/ThumbnailRenderer.swift:18–22` |
| 登录时启动 | 已实现系统注册/取消及状态显示。不是自动默认开启；requiresApproval明确显示等待用户系统批准，注册函数返回不保证授权。 | `Sources/LocalClipMac/UI/SettingsView.swift:29–30,91–95`；`Sources/LocalClipMac/System/LoginItemService.swift:6–22` |
| 复制音效/反馈音设置 | 缺失。完整SettingsSnapshot、设置界面和采集成功分支无声音设置或播放调用。 | `Sources/LocalClipCore/Domain/Domain.swift:128–140`；`Sources/LocalClipMac/UI/SettingsView.swift:16–58`；`Sources/LocalClipMac/Features/CaptureCoordinator.swift:85–109` |
| 隐藏菜单栏图标设置 | 缺失。makeMenu无条件创建statusItem；没有相应持久配置或UI选项。 | `Sources/LocalClipMac/UI/AppDelegate.swift:141–154`；`Sources/LocalClipCore/Domain/Domain.swift:128–140` |
| 默认以纯文本粘贴 | 缺失。设置默认的是copy/directPaste动作，不是格式；未指定format的perform为.original，纯文本只有手动按钮。 | `Sources/LocalClipMac/UI/SettingsView.swift:23–26`；`Sources/LocalClipCore/Domain/Domain.swift:131,296–297`；`Sources/LocalClipMac/UI/HistoryViewModel.swift:224–227`；`Sources/LocalClipMac/UI/HistoryView.swift:109` |
| 暂停N分钟自动恢复 | 缺失。只有持久captureEnabled开关；暂停不含timer/deadline。visibilityDeadline是历史到期隐藏，不是采集暂停定时器。 | `Sources/LocalClipMac/Features/CaptureCoordinator.swift:40–55`；`Sources/LocalClipCore/Domain/Domain.swift:128–140`；`Sources/LocalClipMac/UI/HistoryViewModel.swift:204–214` |
| 共享/录屏时自动隐藏预览 | 缺失。没有共享屏幕检测、预览模糊/自动隐藏设置；失焦自动关闭不是识别正在共享屏幕。 | `Sources/LocalClipMac/UI/HistoryView.swift:236–278`；`Sources/LocalClipMac/UI/AppDelegate.swift:212–231,276–318`；`Sources/LocalClipCore/Domain/Domain.swift:128–140` |

Pinboard单归属/多归属：LocalClip多对多是产品语义差异，不是自动判定的缺陷；若Paste单条只属一个Pinboard，主报告应直接对照两个产品实际规则。分类是否永久保留则须单独说明：LocalClip只有收藏受保护，不能混用“分类”和“收藏”的含义。
