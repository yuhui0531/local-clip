# LocalClip 0.3.14（构建36）

Current delivery: every clipboard kind supports an optional persistent display name. Double-click the coloured header or use 重命名 in its context menu; Enter saves, Esc cancels, clearing restores the default. Body double-click retains its existing paste behaviour. The full-history tab says 剪贴板. Names preserve content, ordering, copy identity, selection, categories and favourites; they are stored in `clips.title` (schema v4; other schema versions are refused, no migration) and are searchable. Current storage, interaction defaults and performance baseline: [architecture](docs/architecture.md). Independent source review has no actionable findings. Debug/Release have zero failures. Repeated-search overhead is 23.60 ms (limit 60 ms); initial-cycle overhead is 69.73 ms and remains a concern. Details and user-owned physical checks: [review fixes and evidence](docs/review-fixes-r01-r12.md).

The app is built from the current reviewed source, with no source exclusions. Packaging replaces the executable with a new inode; it does not install, launch or restart the running application. Use `dist/LocalClip.app` and `dist/LocalClip-source.tar.gz`; version, signature, architecture, hashes and archive checks are recorded in the review report. No commit, push or publication was performed.

## Previous 0.3.8（构建30）delivery


Current follow-up: in a single category's browsing list, newly added or re-dropped items appear at the left; multi-selection keeps its source order. A valid external recopy also promotes the existing item in each of its categories. Unaffected members retain their order, and manual ordering remains available. Search relevance and combined-category copy-time ordering remain intact. Implementation and regression evidence: [newest-first ordering](../changes/active/localclip-review-fixes/debug-log-2026-10-11-newest-first-order.md). Quit the old app and open `dist/LocalClip-0.3.8-build30.app` to use build 30; this turn did not launch or install it.

Build 30 is packaged from the reviewed and fully tested source snapshot. Separate in-flight CI export-callback changes remain intact in the working checkout and are excluded from this verified app/source archive. The ordering implementation matches the checkout; the delivery manifest records the one differing export-writer input.

Previous follow-up: shared native category-drop routing on the panel's hosting view, covering every supported clipboard kind and newly created categories: [category drop routing](docs/category-drop-routing.md). Its artifacts and review belong to build 29.

Previous follow-up: native drag-event handoff, compact confirmation sheets and viewport-sized progressive history loading. Its measurements and review belong to build 28: [progressive history loading](docs/progressive-history-loading.md).

Previous follow-up: LC-06 scaling, card drag hit areas and frozen source selection, card drag animation, and external-click panel dismissal. Its measurements belong to the recorded earlier builds: [scaling, drag and focus checks](docs/scaling-drag-focus-checks.md).

Previous review fixes: preserve loaded history and detail during captures, keep queued copies across preference saves, make Copy deterministic, reject terminal code conversion, retain search indexes under quota pressure, and use bounded in-memory thumbnails. Full status and verification: [review fixes](docs/review-fixes.md). The independent 0.3.2 review found two remaining defects; 0.3.3 adds page-boundary/hidden-burst preservation and worker-side privacy checks; the independent follow-up found page amplification, corrected in 0.3.4 with an exact published range and continuation cursor. Release UI target receipt remains pending.

## 0.2.4（20）的既有界面基础

此前压缩卡片标题、来源图标和底部统计，扩大正文与长文件名区域；正方形卡片及分类布局继续保留。三组隔离合成数据的实际SwiftUI像素已检查，证据`evidence/delivery/local-experience/ui-024/`。完整功能、目标接收、性能与此前未完成的真实鼠标拖放仍由用户自测。无兼容、迁移或历史数据更改。

- 应用：`dist/LocalClip.app`
- 源码：`dist/LocalClip-source.tar.gz`
- [当前使用说明、权限、自测与限制](docs/local-experience-delivery.md)
- [本轮任务](../paste-report/implementation-plan-2026-10-10/tasks.md)
- 当前审查修复证据：`evidence/review-fixes/`；历史0.3.0调试接收证据：`evidence/delivery/code-smart-paste-fix/`
- 既有界面证据：`evidence/delivery/local-experience/`

```sh
rtk proxy bash macos-app/scripts/build-app.sh release
```

在项目根目录执行上述命令。只构建并打包，不启动、安装或发布应用。每次启动在存储恢复后自动监听新的剪贴板变化；手动暂停只作用于本次运行，定时暂停按期限保留。macOS15+、Apple Silicon；本地ad hoc签名。

---

以下是0.1.14及之前版本的历史README，保留已有工程记录。旧格式、目录、行为、通过数及样本不代表0.3.8；当前说明以上方链接为准。

# LocalClip 0.1.14

macOS 15+ / Apple Silicon 本地剪贴板管理器。Swift 6.2、SwiftPM、AppKit、SwiftUI；SQLite 是唯一持久历史存储。首版 F01–F11 已连接生产入口，采用用户要求的 Paste 风格底部横向卡片界面。2026-10-10追加了双击复制、屏幕全宽底部固定和文件对象支持。

**0.1.14仅完成本轮构建与签名检查，功能由用户自行测试，尚不能宣布首版验收完成。以下历史接收和测试记录属于文件功能加入前的版本。** 旧测试签名授权后，TextEdit直接粘贴、RTF原格式与纯文本均有实际接收证据。用户人工准备Safari焦点后，当前签名直接粘贴完整文本已实际接收；Safari富文本原格式/纯文本、TextEdit当前签名富文本直接及纯文本、PNG真实接收已补证。历史Safari失败保留，旧原因未确定。历史面板可通过Finder重新打开恢复访问，设置窗口绑定仍失败；并非所有原生应用连接断开。剩余目标矩阵、输入法、多屏、真实UI性能及macOS15.0环境未完成。候选顺序预读已降低服务层提交延迟，不能代替复制到可见验收。具体结果见 [验收记录](docs/acceptance-results.md)、[兼容矩阵](docs/compatibility.md)、[性能报告](docs/performance.md)、[限制](docs/known-limitations.md)。

## 构建与运行

在项目根目录 `/Users/ronny/VscodeProjects/rea` 执行；不需要第三方包或网络下载。

```sh
rtk proxy xcrun swift --version
rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release
rtk proxy open macos-app/dist/LocalClip.app
```

产物：`dist/LocalClip.app`，ad hoc 本地签名；未做 Developer ID 签名、公证、安装或发布。菜单栏图标进入历史/设置；再次打开应用由新实例接替并展示历史；默认快捷键 Option–Command–V。启动在存储恢复后自动监听，不再要求手动点击“开始记录”；不导入启动前或暂停期间的剪贴板内容，仍先过滤敏感/临时标记并遵守来源排除和容量限制。支持 UTF-8 文本、非文件 URL、RTF、HTML、PNG、TIFF、JPEG、真实文件 URL 原始表示及最多32项顺序，单次支持表示合计最多50MiB；图像超过40MP不生成预览，原始格式仍可恢复。

面板与当前显示器同宽、贴屏幕底边，禁止拖动/缩放；单击选择，双击原格式复制后自动粘贴到打开面板前的应用焦点，无需回车。右下角“复制”按钮仅恢复剪贴板。

默认30天、500MiB、复制模式、登录启动关闭。原格式恢复使用保存的原始字节；纯文本转换不携带 RTF/HTML。直接粘贴需要用户在系统设置授予辅助功能权限；界面只报告“粘贴指令已发送”，不表示目标已经接收。登录启动只在用户点击后调用系统注册，并显示实际状态。

Release 固定数据目录：`~/Library/Application Support/LocalClip-Development/`。`History/history.sqlite` 为持久历史；`Staging/` 为候选提交空间，未回收文件计入占用。SQLite 未加密；删除不承诺法证擦除。退出后备份整个自有目录可保留历史，不要在运行中单独替换数据库。

## 隔离开发与测试

Debug 才支持 `LOCALCLIP_DATA_DIR`，Release 忽略覆盖。自动测试不读取 general pasteboard 或用户 Paste 数据。

```sh
rtk proxy bash macos-app/scripts/build-app.sh debug
rtk proxy macos-app/dist/LocalClip.app/Contents/MacOS/LocalClip --prepare-test-store /Users/ronny/VscodeProjects/rea/macos-app/evidence/manual/isolated-data
rtk proxy open -n --env LOCALCLIP_DATA_DIR=/Users/ronny/VscodeProjects/rea/macos-app/evidence/manual/isolated-data macos-app/dist/LocalClip.app
rtk proxy env LOCALCLIP_NAMED_TEST=1 LOCALCLIP_PROBE_BINARY=/Users/ronny/VscodeProjects/rea/macos-app/.build-verify/debug/LocalClip bash macos-app/scripts/test.sh --scratch-path /Users/ronny/VscodeProjects/rea/macos-app/.build-verify
```

最后一条执行 Swift Testing 单元、真实临时 SQLite、真实子进程 SIGKILL、专用命名 NSPasteboard 测试。CLT 缺少 `_Testing_Foundation` overlay，脚本禁用 cross-import overlays 并使用 CLT Testing framework；未执行 XCTest/XCUITest。52个测试被发现：50个功能测试通过，2个长性能测试由独立命令执行。历史失败日志保留，不覆盖为通过。

```sh
rtk proxy bash macos-app/scripts/benchmark.sh --scratch-path /Users/ronny/VscodeProjects/rea/macos-app/.build-bench
rtk proxy env LOCALCLIP_BENCHMARK_FIXTURE=/绝对路径/已完成性能目录 bash macos-app/scripts/benchmark-system.sh --scratch-path /Users/ronny/VscodeProjects/rea/macos-app/.build-system
```

性能脚本仅创建合成 fixture 库和命名 pasteboard，保留全部原始样本。服务层结果不能替代 UI 端到端验收。

## 源码导览

`LocalClipCore`：值类型契约、格式敏感指纹、字面搜索、SQLite、候选原子提交、容量/期限/收藏/删除。`LocalClipMac`：原生剪贴板、采集队列、焦点安全粘贴、ImageIO、Carbon 热键、SMAppService、AppKit 窗口和 SwiftUI 界面。`LocalClip`：真实 AppKit 入口；Debug 测试探针由条件编译隔离。

原 PRD、技术设计、验收方法保持在 `../paste-report/`；逐项实际修改、命令及证据登记在 [tasks.md](../paste-report/development-plan/tasks.md)。原生界面渲染证据见 浅色、深色、紧凑，这些图像是实际 SwiftUI 内容，不是目标应用接收证据。

当前真机证据：实际C/B/A历史、TextEdit接收A、无权限回退、操作记录。最新真实接收与查询证据见 本轮记录、TextEdit原始字节与RTF属性核对。测试库只含合成fixtures且采集已暂停；用户已重新解锁与授权；最新续接见 会话记录。调试测试通过LaunchServices的`open --env`传入隔离目录；直接启动可执行文件的实际权限上下文不同。重开前确认测试进程已在运行，不能让自动启动遗漏数据目录。

源码与证据压缩包：`dist/LocalClip-source.tar.gz`。生成命令：`rtk proxy python3 macos-app/scripts/package-source.py`；生成库和测试二进制不打入源码包，由fixture生成器重建。带自有hash的delivery-manifest在压缩包外保留，避免自引用。

最新真实验收：Safari直接与富文本、TextEdit当前签名与PNG、暂停不补采。PNG实际接收1920×1080且解码像素全等；TextEdit实际保存文件核对加粗/Latin italic/完整链接，纯文本无这些属性。预览源先通过Open With明确选Apple Preview，避免默认Picview关联。测试采集最后暂停，当前仅3条合成数据。

用户已选择自行测试，自动验收已停止。现有Release本地测试包可按上方命令运行；未完成验收项保留在docs。Pages原格式实际接收另有截图/AX与本地保存文件，其余Pages格尚未验证。

## 本轮追加：文件对象与Finder

在Finder中复制文件/文件夹，新的历史会以“文件”卡片保存引用和顺序。文件本体不备份到历史库，原件移动/删除后需重新复制。在目标Finder文件夹中按Option–Command–V打开面板，再双击文件卡片，会复制副本到该窗口当前实际目录。同名自动生成“副本”名称；从其他应用打开面板时，双击会尝试粘贴到原应用焦点；是否接受文件由目标应用决定。

首次Finder目录查询可能显示系统“自动化”授权，请允许LocalClip控制Finder。最近使用、搜索结果等虚拟目录及文件promise不作为目标；失败提示保留手动粘贴回退。普通“复制”按钮始终只恢复剪贴板。

按用户要求，本轮未执行功能、真实Finder/多屏或性能测试，只做Release构建/签名检查；旧测试结果属于旧版本。追加范围与待自测项见[变更说明](../paste-report/development-plan/interaction-files-delta.md)。使用新版前退出旧LocalClip进程，再打开当前`dist/LocalClip.app`；本轮没有自动启动应用或操作您的文件。

## 双击自动粘贴（0.1.2）

先在目标应用选择需要粘贴的位置（编辑器光标、文档、画布或输入框），再按Option–Command–V打开面板并双击历史记录。LocalClip会恢复原格式剪贴板、关闭面板、返回原应用；核对同一目标焦点及剪贴板未变化后发送原生粘贴。需要系统辅助功能权限；本地ad hoc更新后若系统不认可权限，请通过系统界面重新授权。

无权限、原焦点不可读取/已禁用、用户切换应用或焦点变化时，仅复制并提示手动粘贴。程序不扫描或点击另一个textarea，也不会替换整个输入框值。状态“已发送粘贴指令”只表示指令发出。本轮只构建/签名检查，Safari/Chrome/TextEdit等真实接收仍由用户自行测试。

## 粘贴失败修复（0.1.3）

用户报告Codex/Zed双击后面板消失但输入框没有变化。本轮修正了AXValue setter错误门槛、输入焦点恢复时序及隐藏回退提示：历史使用非激活面板，等待原控件稳定后向已核对的目标进程发送一次Command-V，结果以不抢焦点的短暂提示显示。权限仍由系统与用户决定，发送提示不等于接收成功。

本轮仅源码/SDK/签名元数据检查及Release构建；未操作用户输入框或恢复自动验收。退出旧LocalClip后再打开当前dist/LocalClip.app才能使用新代码。具体依据、命令及证据见[排查记录](../paste-report/development-plan/debug-log-2026-10-10-paste.md)。

## 0.1.4 去掉发送提示

按用户要求，粘贴指令发出后不再弹出“请确认目标输入框”提示，只在失败或手动回退时显示原因。粘贴安全检查保持；本轮仅Release构建/签名检查，没有启动应用或操作用户输入框。使用新版需退出旧LocalClip并重新打开当前dist/LocalClip.app。

## 0.1.5 支持原应用焦点的原生粘贴

取消文本角色及AXIsEditable门槛，不限定textarea或特定应用：编辑器、文档、画布等由原应用处理Command-V。原焦点、身份、权限、禁用状态和剪贴板核对保留；不读取/替换输入内容。正常发送不弹窗；Finder文件副本流程不变。只做构建/签名检查，实际接收待用户验证。详见[排查记录](../paste-report/development-plan/debug-log-2026-10-10-generic-paste-target.md)。

## 0.1.6 滚动浏览与Esc

在历史卡片区域，触控板左右滑动与鼠标横向滚轮保持系统行为；普通鼠标上下滚轮及触控板上下滑动转换为左右浏览，遵循系统自然方向。接近末尾自动加载下一页，不必反复点击“更多历史”；保留滚动条和左右键选择。Esc从搜索框、卡片和中文组合输入状态直接关闭面板。监听仅在本应用历史区域/面板内生效。

本轮仅源码检查、Release构建及严格签名验证，没有启动应用或测试真实鼠标/触控板/输入法。退出旧LocalClip后重新打开当前dist/LocalClip.app。详见[排查记录](../paste-report/development-plan/debug-log-2026-10-10-history-scroll-escape.md)。

## 0.1.7 失焦自动关闭

点击历史面板外、转到其他窗口/应用时自动隐藏历史；面板内搜索、菜单和详情临时接管焦点时保留。关闭不激活旧目标或修改剪贴板。仅源码检查、Release构建与严格签名；真实窗口行为待用户验证。退出旧LocalClip再打开当前dist/LocalClip.app。详见[排查记录](../paste-report/development-plan/debug-log-2026-10-10-focus-dismissal.md)。

## 0.1.8 快捷键切换显示/隐藏

同一个已注册快捷键（默认Option–Command–V）首次打开历史，面板已显示时再次按下就关闭，再按重新打开。按真实可见状态判断，沿用失焦/主动关闭入口；关闭时不刷新历史或重记目标。菜单栏“打开历史”和重新打开应用仍明确展示。仅Release构建/签名检查，未启动应用或实际按键测试。使用新版需退出旧LocalClip再打开当前dist/LocalClip.app。

## 0.1.9 单实例接替

新实例启动时先请求同一用户、同一bundle ID的旧LocalClip退出，确认旧进程终止并取得进程锁后才打开历史数据库、启动采集和注册快捷键。锁由系统在进程退出时释放；不删除锁文件。并发启动按启动时间/PID确定最新实例，较旧启动者退出。接替期间可短暂存在尚未启用服务的新进程，历史服务只允许一个实例使用。

正常再次打开0.1.9时，macOS若将请求交给已有进程，已有进程会显式启动新实例并退出；新实例准备完成后展示历史。菜单“打开历史”和快捷键不会重启应用。旧实例6秒内未退出时，新实例提示并退出，不强杀或同时启用存储。Debug GUI同bundle ID副本也参与接替，Debug命令行探针不进入此启动流程。

首次从旧版本升级，请强制启动一次新版，因为旧进程尚无新的重新打开处理逻辑：

```sh
rtk proxy open -n /Users/ronny/VscodeProjects/rea/macos-app/dist/LocalClip.app --args --show-history
```

之后正常打开即可接替。仅Release构建与签名检查；本轮未启动应用、未关闭用户进程，实际接替/并发启动/异常退出待用户自测。

## 0.1.10 来源应用与图标

以前只有org.nspasteboard.source声明才显示应用，没有声明就显示未知。本轮按用户要求调整展示：声明优先；没有任何声明时，观察剪贴板变化时的前台应用，显示名称和本机APP图标。切换应用的停用通知会关联尚未轮询到的复制计数，降低刚复制就切应用的竞态。前台推断可能误判后台写入，不等同于可靠生产者身份；卡片来源提示、详情与设置说明记录依据。冲突/非法声明和无法判断的情况仍未知。

来源basis和名称写入同一个SQLite历史，来源名称可检索，不影响格式敏感去重或恢复格式。应用排除仍仅匹配声明；敏感/临时标记检查先于正文读取和预览/索引。自身恢复不增加历史，不推断自身来源。不为已有未知历史事后填充当前应用；新版的新复制或同内容再次复制才有新归因。

图标使用公开AppKit API，缓存运行应用或已安装应用图标；未安装/无法解析的来源使用类型图标。没有读取Paste历史/数据库或使用私有来源接口。Release构建/严格签名通过；没有执行真实复制、来源/图标验收或回归测试，按用户要求自行测试。

## 0.1.11 分类创建与重命名（历史实现，界面及升级分支已由0.1.13替代）

历史面板新增分类栏，点击“新建分类”输入名称创建；右键分类选择“重命名分类…”或点击当前分类旁的铅笔按钮修改名称。分类名称为1–64字符，去两端空白、NFC规范化、英文ASCII大小写去重；空名称、重复、换行和控制字符拒绝保存。创建后可回到“剪贴板历史”，右键记录→“加入分类”，或选中记录后使用底部“分类”菜单；一条记录可属于多个分类。分类内可右键“从当前分类移除”，底部菜单也可切换归属，移除归属不删除原内容。

点击分类查看其历史，搜索/类型筛选/分页均在所选分类内执行。点击“剪贴板历史”或“收藏”退出分类筛选。分类名称与归属在SQLite持久保存，重命名保留ID和归属；记录仍按原收藏/期限/容量规则清理，分类不自动收藏或延长期限。删除记录会同时清理归属，不复制正文或改变原格式。分类栏可横向滚动，底部固定全宽面板高度调整为490pt，保留完整卡片空间。

数据库由v1升级到v2，在取得单实例锁后、开始采集前执行。升级仅在独立候选库内添加分类表/索引并检查容量、完整性/FK与同步，然后原子替换；不删除旧历史腾空间。空间不足/提交前失败保留原v1库并停止启动。升级成功后旧版0.1.10及更早版本不能打开v2库，不支持降级迁移。分类写入也遵守原候选提交/配额机制，失败不显示为已保存。

本轮仅Release构建与严格签名检查，没有启动应用、读取/修改用户数据库或执行迁移/分类功能测试。实际操作、重启持久性、v1迁移、配额/崩溃恢复待用户自测；不能以历史v1测试代替v2验收。

## 0.1.12 键盘删除、浏览优化与紧凑面板

空搜索或卡片焦点下，Backspace（⌫）与Forward Delete（⌦，Mac键盘通常为Fn–Delete）删除当前选中记录，沿用原预览/确认/候选提交流程。搜索框有文字、中文marked text、名称对话框或其他窗口时保留正常编辑，按键重复不连续弹确认。一次只处理一个历史变更。确认后只撤销被删卡片并选择相邻项，旧查询/详情/异步图像仍有世代与存在检查；失败从持久历史重新查询。

选择高亮立即更新；25ms合并快速连续选择后的轻量元数据读取，不读取图片BLOB或做完整哈希。完整内容仅详情展开、复制/粘贴及需要生成未缓存缩略图时读取。关闭详情释放大内容；卡片按自身显示值做Equatable刷新，其他卡片不随全部模型发布重建。异步缩略图复查改为轻量metadata，原始恢复完整性校验和SQLite提交验证保持。分类菜单用轻量归属，纯文本按钮按各项支持文本表示判断资格，实际输出仍由原payload解码/校验；异常编码不保证可转换。

不对已可见卡片重复滚动，越界时定位且不叠加滚动动画。同次采集只通过持久变更流刷新，不再额外触发onCommit查询。打开面板先确定最终屏幕尺寸再挂载/布局内容，已有内容不因打开重新读取全部详情；加载指示和右侧操作栏保留固定空间，降低布局跳变。上述是源码层面因素处理，未证明用户报告的闪烁全部来自它们。

固定全宽底部面板高度由490pt降到380pt；卡片250×200pt，同步压缩工具栏/留白/预览行数，完整内容仍可从详情查看。磨砂背景用behindWindow的NSVisualEffectView，固定active避免key状态变换；只将背景alpha降至0.78，文字和卡片保持不透明。尊重系统“降低透明度”。没有降低整个应用窗口alpha。

仅Release构建/严格签名检查。未读取用户剪贴板/历史、启动或关闭应用，未运行功能/真实应用/性能/视觉测试。选择耗时、复制到可见、CPU/内存和闪烁改善都没有新的测量结果；真实效果由用户自测。SQLite仍为v2，本轮未增加新的迁移版本。

## 0.1.13 同行分类与面板内新建

“全部、文本、链接、富文本、图片、文件、混合”和自定义分类现在放在同一条横向导航中，不再单列分类栏。自定义分类采用彩色圆点、名称和浅色选中胶囊；末尾固定“＋”，分类多时仍可新建，标签区域可横向滚动。点击类型退出自定义分类，点击自定义分类退出类型和收藏筛选；点击历史/收藏恢复对应的全部类型范围。字面搜索仍在当前范围内执行。

点击“＋”在面板内填写名称并创建；右键自定义标签选择“重命名分类…”在同一编辑窗口修改。空名称不能提交，重复、超长或非法名称显示就地错误；保存成功后更新标签。名称编辑中的退格、方向键、回车和中文输入不会触发历史删除/粘贴；Escape取消编辑。颜色由分类ID稳定派生，重命名/重启不变，不新增颜色字段或数据转换。记录归类仍用右键或底部分类菜单。

按用户要求删除v1→v2迁移函数及启动升级分支，不编写兼容代码。现有schema2数据直接保留和使用；不同结构只拒绝打开，不重置、迁移或覆盖旧库。开发过程中未读取或修改用户库。0.1.11升级描述仅为历史记录，本版不执行它；其迁移自测不再属于当前要求。

保持全宽底部380pt、透明背景、键盘删除和轻量选中路径。本轮只验证Release构建与严格签名，未启动应用、读取剪贴板或执行自动测试，视觉和实际交互待用户自测。

## 0.1.14 拖入自定义分类

按住历史卡片拖到同一行的自定义分类标签，标签显示对应色彩的底色和边框；松开即可加入分类。加入后保留原记录及原分类归属，一条记录仍可属于多个分类。只在保存成功后显示“已加入分类”，失败保留原内容并提示。文本、图片、文件等类型标签仍用于类型筛选，不是用户分类拖放目标。

拖拽不读取完整正文/图片/文件，也不恢复general剪贴板。使用声明的内部拖放类型和本进程可见的短期随机令牌，拖拽预览只显示“加入分类”；外部文本/文件不能当作历史记录导入。载入令牌后再确认当前记录、目标分类与令牌有效性；SQLite写入再次检查期限/存在性，已删除/到期的记录不能被拖拽恢复。重复加入不会产生重复归属。没有schema升级或兼容代码。

本轮Release构建及严格签名检查通过，未启动应用或运行自动功能、真实GUI、SQLite故障或性能测试，实际拖拽手势与点击/滚动配合由用户自测。
