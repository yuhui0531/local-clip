> Current fix status and verification limits: [review-fixes.md](review-fixes.md). The records below describe older versions.

> 历史0.2.0说明见[本地体验交付](local-experience-delivery.md)。以下保留为旧版记录，不能认证本轮功能、接收或性能；本轮产品验收由用户自测。

# AC01–AC27 实际验收记录

> 历史交付0.1.14（构建15）：历史卡片可拖到自定义分类标签，拖入高亮，复用持久化归属。保留同行类型分类/＋编辑及380pt底部布局；无升级兼容代码。本轮仅Release构建/严格签名检查，未启动应用或执行功能、GUI、SQLite、性能测试。

2026-10-10；macOS15.7.5/M2 Max/32GB/Swift6.2.4。U规则、I真实文件集成、M真实目标应用、P性能分别记录。**整体首版验收未完成。**

源码版本：[SHA256清单](../evidence/automated/delivery/source-sha256.txt)；Release二进制和构建检查：[release-verification.json](../evidence/automated/delivery/release-verification.json)。无Git仓库，不伪造commitID。自动证据A统一为[当前回归](../evidence/automated/20261010-103938-yKzK5v/swift-test.log)，测试名保留AC编号；52测试发现，50功能通过，2长性能条件跳过，由独立命令执行。当前预读及目标名称提示版本已干净重建Release，签名与Debug入口排除通过；源码归档见外部delivery-manifest。历史失败日志保留。

| AC | 层级/fixture | 已执行结果及测试定位（证据A） | 整体状态 / 未验证范围 |
|---|---|---|---|
| AC01 | I+M / TXT-A/B/C | persistDeduplicateAndOrder、captureRestoreAndImmediateUserCopy；实际TextEdit A/B/C逐次复制后历史C/B/A见[截图](../evidence/manual/20261010-resume/AC01-C-B-A.png) | 通过 |
| AC02 | I+M / 内容/收藏/设置 | persistDeduplicateAndOrder、productionHistoryTermination、settingsPersistence，重开保留 | 受阻：实际正常退出/重启，无旧板补采 |
| AC03 | U+I / 同快照复采 | 一条记录，copyCount/last更新，收藏保持 | 通过 |
| AC04 | U+I / RICH/MULTI | formatSensitiveAndItemOrder，不同格式不合并，item顺序敏感、type枚举顺序无关 | 通过 |
| AC05 | U+I+M / ZH/CODE/URL/尾部 | literalSearchAndPagination、embeddedNULAndCanonicalContext，NFC/ASCII字面、符号/全文/上下文正确 | 受阻：真实中文短词、::、URL片段与无匹配结果已观察；全文尾部/筛选/中文IME仍待测 |
| AC06 | I+M / TXT/IMG/MULTI | realNamedRoundTrip、imagePreviewBoundary，7格式字节和顺序一致、真实图像尺寸边界；[实际TextEdit手动A接收](../evidence/manual/20261010-resume/TextEdit-TXT-A-received.png) | 部分通过：TXT已有真实接收；PNG附件1920×1080、RGBA全等；TIFF/JPEG与受支持多项接收待测 |
| AC07 | U+M / 直接粘贴 | directPasteSafety，成功分支仅commandSent | 部分通过：当前签名Safari纯文本直接、TextEdit富文本直接实际接收；旧Safari失败保留，其他必测矩阵待测 |
| AC08 | U+M / 权限关/目标退出 | directPasteSafety，写失败无copied，权限关/退出安全回退 | 受阻：真实无权限目标未变、手动粘贴C接收；目标退出分支M待测 |
| AC09 | U+I / 自写A紧接用户B | metadataRaceDoesNotLoseNextUserCopy、realNamedRoundTrip、captureRestoreAndImmediateUserCopy | 通过，无一秒全局忽略 |
| AC10 | U+I+M / SOURCE | sourceBoundary、realNamedPrivacy，声明排除不读正文/无残留 | 受阻：真实生产者来源边界 |
| AC11 | U+I+M / PAUSE | pauseNoBackfill、busyQueueAndPauseDuringRead、modelPauseGateAndSaveFailure | 通过：真实A暂停复制不采；恢复无补采；随后B入库，最终重新暂停；在途暂停分支U/I已通过 |
| AC12 | U+I / TIME/QUOTA | retentionAndExpiredUnfavorite，期限/稳定淘汰、收藏保护 | 通过 |
| AC13 | U+I / 收藏超额/暂停 | impossibleSaveKeepsOldContent、favoritesOverQuotaAndDryPreview、registrationFailureAndIndependentPause、largeRejectionAllowsSmallNextCopy、capacityProbePreservesReleasableFullStore | 通过 |
| AC14 | I+M / 删除与异步 | deletedContentAndCacheFallback、viewModelQueryAndDeletion，旧query/详情/缩略图不能复活 | 部分通过：普通文本实际删除后唯一查询0、收藏保留；真实在途查询/缩略图删除仍待测 |
| AC15 | I / 故障注入 | candidateFailureKeepsOriginal、schemaFailure、postCommitUnavailable，旧库保持 | 通过；真实硬件ENOSPC/断电未执行，不混同注入 |
| AC16 | P / 1万文本/100图/近配额 | [性能报告](performance.md)，服务层和命名板压力/10分钟空闲已测 | 受阻：UI端到端未执行；预读优化后文本/新图服务P95=122/141ms，近配额550ms；不能据此标复制可见达标 |
| AC17 | U+I / 500MiB | real500MiBQuotaRefusesWithoutDeleting，原库520192000字节、新20MiB拒绝，旧哈希不变 | 通过 |
| AC18 | U+I+M / 未知/PRIVATE | sourceBoundary、realNamedPrivacy，未知默认保存，带标记整次过滤 | 受阻：真实TextEdit未声明来源保存并显示未知；敏感真实生产者及说明M待测 |
| AC19 | U+I / TIME | lastValidUserCopyOnly、retentionAndExpiredUnfavorite，最近有效用户复制起算、边界不可访问；publishedExpiryDeadline及expiredPageRevealsOlderFavorite验证已发布卡/详情及时消失并补页 | 通过 |
| AC20 | U+I+M / 过期收藏 | retentionAndExpiredUnfavorite，取消不改、确认清理、未过期仅取消收藏 | 受阻：实际确认弹窗 |
| AC21 | I+M / RICH | richAndPlain、realNamedRoundTrip，原RTF/HTML完整、纯文本无富格式 | 部分通过：当前TextEdit原格式/纯文本实际文件文字4段落一致，加粗/Latin italic/完整链接保留与去除均验证；Pages原格式实际接收有截图/AX；Pages纯文本、图片、直接粘贴及HTML-only未验证 |
| AC22 | U+I / PRIVATE | sensitiveBeforeAnyBodyRead、policyRecheckedAtIngest、realNamedPrivacy，正文前整次过滤 | 通过 |
| AC23 | U+M / 热键 | registrationFailureAndIndependentPause；实际API冲突被拒，释放可注册 | 受阻：冲突界面/菜单栏/快捷键实际打开 |
| AC24 | U+M / 身份/焦点/板变化 | directPasteSafety，PID重用/切换B/激活失败/新板不误发 | 受阻：正常Safari/TextEditA实际接收已补证；真实退出/激活失败/前台切换M仍待测 |
| AC25 | U+I / BLOB/缓存/待回收 | sharedBlobAndJournalBudget、productionSharedBlobAndNullOrphan、realCleanupPermissionFailure、allocationBlocksAreCounted、indexBudgetPreservesOriginal | 通过，未回收不虚报释放、原正文仍可搜 |
| AC26 | I / 需淘汰+SIGKILL | candidateFailureKeepsOriginal和两组各6真实终止断点，旧/新完整、收藏/BLOB/FK/hash/quota一致 | 通过 |
| AC27 | U+I+M / 设置下调/旧token | staleConfirmationAndSettingsPersistence、favoritesOverQuotaAndDryPreview，取消不改、stale重做、收藏超额暂停 | 受阻：实际预览确认与恢复无补采 |

## E01–E08

| ID | 已执行 | 状态 / 剩余 |
|---|---|---|
| E01 | 跨50项分页键盘选择模型；真实SwiftUI浅/深/紧凑渲染 | 部分通过：实际空历史、重新打开面板；全键盘、中文候选、Escape、多屏仍待测 |
| E02 | queryID乱序、删除失效、分页revision、尾部/缺缓存回退、已发布期限截止及50项到期补页 | 通过 |
| E03 | fake发送前板改写停止、保留新内容；独立probe覆盖焦点与剪贴板同时变化，不显示旧已复制 | 通过自动分支；实际边界仍属AC24受阻 |
| E04 | 主动/容量暂停独立；设置失败恢复持久状态；恢复新基线 | 通过 |
| E05 | 实际SMAppService只读；只有用户点击才请求注册 | 受阻：开启/关闭/拒绝/重新登录 |
| E06 | 32项/50MiB及unsupported混合整体跳过，不截断 | 通过 |
| E07 | [动态请求计数](../evidence/automated/html-network-20261010/result.json)：真实命名板→生产采集/HTML解码→临时SQLite/字面搜索→派生预览；前后各1控制请求，正文资源请求0；原HTML bytes保留，状态回调不含fixture正文/完整URL | 通过已执行服务分支；未覆盖实际GUI绘制与所有系统网络 |
| E08 | 高版本拒写、schema失败保原库、提交后重开失败不重放 | 历史v1验证通过；0.1.11新增v1→v2升级未验收，0.1.13按用户要求移除此分支 |

## 真实应用及发布门

[目标矩阵](compatibility.md)逐格列未验证范围。2026-10-10用户解锁后，CUA实际操作TextEdit，打开原生LocalClip面板，完成AC01和文本手动恢复及真实无权限回退。见[操作记录](../evidence/manual/20261010-resume/observations.json)。未向测试目标误报发送即接收。随后并发用户剪贴板活动破坏fixture隔离，已暂停并删除本轮专用测试库；没有保存意外条目的截图或正文证据。剩余general剪贴板验收等待无其他输入的时段。辅助功能开启仍由用户在系统设置授予；登录项未启用。历史[锁屏记录](../evidence/manual/20261010-blocked/ui-automation.md)保留。本轮先完成授权接收；更新测试签名后需重新授权，原生连接断开后2026-10-10T03:01Z工具再次明确Mac锁定，等待用户手动解锁；详见[最新连接记录](../evidence/manual/20261010-authorized-restart/native-connection-status-0301.json)。

当前Release从空`.build-release-prefetch-20261010`编译，51.818秒退出0；bundle/资源/arm64/deployment15/依赖/ad hoc签名检查通过，Debug探针及数据覆盖不在Release中。二进制SHA256 `d6ba3d6f955e85d65cd6bdc1df0e36c1df700603032c2917934868561e1815aa`，详见[当前构建核对](../evidence/automated/release-20261010-prefetch/release-verification.json)。此前Release和manifest保存在该目录pre-prefetch-snapshot，不覆盖历史证据。实际Debug原生入口可操作，Release首次启动、正常退出和重启仍待验证；codesign不能证明这些操作。原PRD未改写，Paste应用及历史未访问。

## 独立验收与修复

[初次FAIL](../evidence/independent/20261010-pre-fix/report.md)、[首次修复后PASS_WITH_CONCERNS](../evidence/independent/20261010-post-fix/report.md)、[最终增量PASS_WITH_CONCERNS](../evidence/independent/20261010-final-delta/report.md)分别保留。修复早期粘贴回退缺少receipt检查、已显示到期内容延迟隐藏、过大单条拒绝阻断后续小条目，以及到期第一页补页。独立评价限于检查的行为，仍不代表完整M/P验收。

新增并发fixture暴露固定120ms测试等待，失败[原日志](../evidence/automated/20261010-092746-QnJ6KL/swift-test.log)保留；改为3秒截止的条件等待及缺结果guard后，[最终51测试](../evidence/automated/20261010-094103-6SMysd/swift-test.log)通过（49功能、2条件跳过）。未把失败或性能跳过改写为通过。

[GC初次优化的独立Warning](../evidence/independent/20261010-digest-optimization/report.md)及[最终rowid增量PASS](../evidence/independent/20261010-rowid-optimization/report.md)独立保留。最终原始共享BLOB与NULL孤儿测试执行生产HistoryStore；首次断言错把派生metadata与原始bytes一起比较的失败日志也保留。完整候选quick_check/FK、FULL同步和原子提交未弱化。

[交付一致性审查](../evidence/independent/20261010-delivery-review/report.md)整体FAIL保留，因M/P发布条件未齐备。其指出的E07动态计数缺口随后执行上述独立命名板/本地服务器probe补证；没有改写原审查。当前源码系统性能复测测试和包装均退出0，见[状态](../evidence/performance/20261010T014705Z-system/wrapper-status.json)，不代表GUI性能通过。

[完成记录补充审查](../evidence/independent/20261010-delivery-review-completed/report.md)确认63源码hash、当时266文件归档、Releasehash、系统120样本与E07动态计数一致，关闭这三项局部证据缺口；整体仍FAIL。该补充保留其审查时归档快照，随后自身及本说明加入最终源码包，最终包hash以外部delivery-manifest为准。

## 2026-10-10预读与授权续接

[新独立审查](../evidence/independent/20261010-prefetch-access-failure/report.md)仅对预读错误保旧增量PASS，未认证整个产品。真实40MiB候选chmod后O_RDONLY返回EACCES，生产预读失败，body未执行、原库所有bytes及实际占用不变、完整integrity_check通过；两组6个SIGKILL及实际500MiB拒绝回归仍通过。

[新真实操作记录](../evidence/manual/20261010-authorized-restart/observations.json)覆盖旧测试签名授权的TextEdit直接接收、RTF原格式/纯文本和Safari手动。Safari直接两次未接收保留失败截图，不当成成功。更新后的测试应用有目标名称提示，观察到Safari目标；更新签名后系统API为false，用户重授权待完成。点击More→设置触发原生操作连接native pipe closed，再次reset仍失败；Chrome本地file页面又被浏览器URL策略拒绝，未绕过。

专用目录曾出现非fixture内容，已暂停、停止旧测试进程并删除那份一次性测试目录，未导出正文/截图；续接目录另一条非fixture内容通过LocalClip确认删除，剩余3条合成数据，当前采集暂停。没有访问Paste数据。仍不宣布首版全部交付。

最新[目标提示与接收文件独立审查](../evidence/independent/20261010-target-hint-manual-evidence/report.md)为增量PASS_WITH_CONCERNS，未认证完整产品。README已更新52发现/50功能通过、实际授权接收与当前权限false。最新系统复测808.641秒、测试及包装退出0、120空闲样本，见[状态](../evidence/performance/20261010T024249Z-system/wrapper-status.json)；同样不认证GUI性能。

当前测试应用的[续接权限复查](../evidence/manual/20261010-authorized-restart/permission-current-bundle-0306.json)仍为false；未改变任何系统权限数据库或补写真实接收通过。

[最新资源与Release独立核对](../evidence/independent/20261010-prefetch-resources-release/report.md)确认原样本计算、44构建源码hash、68源码归档hash及Release二进制一致；增量PASS_WITH_CONCERNS，完整首版仍FAIL/未完成。报告记录其审查时338文件归档快照，随后文档和报告自身加入当前归档；最终归档hash以外部delivery-manifest为准。

## 2026-10-10重新授权与隔离续接

[系统API](../evidence/manual/20261010-authorized-restart/permission-regranted.json)已返回true，原生连接可读。重新打开测试app曾遗漏LOCALCLIP_DATA_DIR，看到无关条目后立即暂停并终止确切进程，默认LocalClip目录保留，自动AX输出出现可见摘要但没有另外保存正文/截图。全新隔离用open --env启动，0条/暂停和实际进程环境已核对；[完整状态](../evidence/manual/20261010-regrant/observations.json)。实际绑定键盘不证明全局热键、前台目标；当前记住微信，未发粘贴事件。等待一次人工Safari焦点核对，AC07/24仍未通过。不改写旧失败或独立审查；本轮文档、权限与隔离证据随源码归档刷新；最终hash及成员一致性见外部delivery-manifest，源码归档不包含生成测试库。

本轮恢复后原生操作再次断开，见[连接记录](../evidence/manual/20261010-regrant/native-connection.json)：More点击拒绝后需重读状态，下一次getAXState及reset+fresh getApp均pipe closed；测试进程存活、采集最后已暂停。更新签名的历史false及03:01锁定已被用户操作解决，不再列为当前权限/锁屏阻塞；当前为原生连接、Safari实际前台核对及未完成矩阵。未新增真实接收通过，不推断产品已修复。

本轮续接再次核对隔离PID53507存活、二进制与LOCALCLIP_DATA_DIR匹配；getApp仍返回native pipe closed，未执行新的目标接收或GUI计时。最新[隔离与授权增量独立审查](../evidence/independent/20261010-regrant-isolation/report.md)保留当时文档漂移意见；随后README/限制/矩阵/本页已将用户解锁与APItrue、当前连接断开分别写明，不改写该审查快照。

[重新授权状态纠正增量审查](../evidence/independent/20261010-regrant-reconciliation/report.md)确认两项旧状态意见已关闭，44构建源码hash未变、106本地链接可解析；该文档纠正增量PASS，完整首版仍FAIL/未完成。

## 2026-10-10Safari焦点与真实接收续接

[本轮记录](../evidence/manual/20261010-safari-ready/observations.json)及[TextEdit实际RTF属性核对](../evidence/manual/20261010-safari-ready/TextEdit-rich-file-check.json)、[PNG接收像素核对](../evidence/manual/20261010-safari-ready/TextEdit-image-pixel-check.json)补齐当前签名Safari文本直接、TextEdit富文本直接、两端纯文本转换、PNG真实接收。实际UI短中文/代码/URL字面查询、上下箭头、收藏视图、删除后唯一查询0与暂停A/恢复无补采/随后B已执行。当前仅3条合成数据、采集暂停。普通清理意图Cancel的首试在截图后误复用了AX索引，实际删除一次性普通fixture，该Cancel测试无效；重新读取索引后的收藏删除Cancel保留成功。没有把无效用例改写成通过。

LocalClip原生状态在面板关闭/设置选择后出现pipe error，但Safari/TextEdit/Finder仍可读；Finder重新打开历史恢复。当前设置窗口自动化仍受阻，不能把单应用绑定错误一概归因插件全断开，或把旧Safari失败归因某一未证明的原因。Preview初次绑定无打开文档等待514秒超时，后通过Finder Open With明确打开fixture后可操作；默认图片关联Picview，未改默认设置。全矩阵/GUI性能/最低版本/登录项门仍未齐备，全部任务不宣称完成。

## 用户终止测试并自行验收

2026-10-10用户明确要求停止测试，改为自行测试。已立即停止所有原生交互与新增验证。Pages原格式已真实接收，保留[AX](../evidence/manual/20261010-safari-ready/Pages-rich-original-received.ax.txt)、[截图](../evidence/manual/20261010-safari-ready/Pages-rich-original-received.png)和本地Pages接收文件；Pages纯文本/图片/直接、其他未执行项不补写通过。先前Pages空RTF启动的长等待及后续窗口身份未确认均保留在[记录](../evidence/manual/20261010-safari-ready/observations.json)。当前源码和Release二进制未改动；交付的是供用户自行测试的本地包，完整首版验收没有完成。


## 2026-10-10 追加交互与文件对象

用户追加要求已进入本轮源码：双击原格式复制、屏幕全宽底部固定、真实文件URL引用与Finder目录副本复制。原记录保留为先前版本证据，不代表新版本回归通过。用户要求自行测试，本轮未执行功能、真实应用或性能测试；对应新行为均待用户自测。变更说明见[追加需求](../../paste-report/development-plan/interaction-files-delta.md)，构建记录见[本轮构建](../evidence/automated/20261010-interaction-files/build-result.json)。


## 0.1.2 双击自动粘贴

实现原输入控件AX身份/可编辑性检查及紧邻事件的剪贴板收据复查。双击自动返回原应用并尝试原生粘贴；明确复制按钮只复制；Finder文件沿用副本复制。未知控件/权限/焦点不满足时回退手动。构建记录见[本轮构建](../evidence/automated/20261010-doubleclick-paste/build-result.json)。用户要求自行测试，本轮未做真实目标接收、回归或性能验证。

## 0.1.3 粘贴排查

[排查记录](../../paste-report/development-plan/debug-log-2026-10-10-paste.md)记录AXValue错误门槛、焦点恢复时序与隐藏反馈修复。仅Release构建与严格签名检查；单元、SQLite、真实目标及性能均未重跑。原AC未提升为通过。

## 0.1.5 通用原生粘贴

不再按文本角色判断目标，保留原焦点和安全检查，由目标应用处理原生Command-V。[排查与截图](../../paste-report/development-plan/debug-log-2026-10-10-generic-paste-target.md)。仅源码检查/构建，不提高未验证的AC状态或性能结论。

## 0.1.6 历史浏览

[滚轮/触控板、分页、Esc修复记录](../../paste-report/development-plan/debug-log-2026-10-10-history-scroll-escape.md)。保持LazyHStack与原分页失效检查。普通垂直滚轮转换横移；横向手势保留系统处理。当前未验证实际设备、组合输入、多页旧记录选择或性能，不提高原AC通过状态。

## 0.1.7 失焦关闭

[失焦关闭实现与边界](../../paste-report/development-plan/debug-log-2026-10-10-focus-dismissal.md)。仅构建验证；外部点击/切换、搜索/菜单/详情/确认对话框、重新打开等实际行为未执行，不改变原AC和性能结论。

0.1.13本轮未执行单元、SQLite集成/故障恢复、真实剪贴板/目标应用或性能测试。D26仅为源码实现与构建/签名，D27为用户待自测；原AC01–AC27历史结果及未完成项保留。

D28仅完成0.1.14拖入分类源码与Release构建/严格签名。D29真实拖拽、成功持久化、重复归属、删除/到期/失败边界由用户自测，未执行；历史AC结果不认证本轮拖拽。
