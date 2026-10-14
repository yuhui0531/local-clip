> Current schema compatibility and recovery requirements: [Schema recovery contract](schema-recovery-contract.md). Historical acceptance below is not evidence for the 2026-10-14 remediation.

> Current fix status and verification limits: [review-fixes.md](review-fixes.md). The records below describe older versions.

> 历史0.2.0说明见[本地体验交付](local-experience-delivery.md)。以下保留为旧版记录，不能认证本轮功能、接收或性能；本轮产品验收由用户自测。

# 实际兼容矩阵

> 历史交付0.1.14（构建15）：历史卡片可拖到自定义分类标签，拖入高亮，复用持久化归属。保留同行类型分类/＋编辑及380pt底部布局；无升级兼容代码。本轮仅Release构建/严格签名检查，未启动应用或执行功能、GUI、SQLite、性能测试。

实际系统macOS15.7.5(24G624)/M2 Max/32GB/Swift6.2.4。部署目标15.0/arm64；最低15.0及其他系统没有实测。CLT测试不是XCUITest。

## 已执行的格式协议检查

专用命名NSPasteboard→生产采集→真实临时SQLite→原格式恢复→NSPasteboard：UTF8文本、非文件URL、RTF、HTML、PNG、TIFF、JPEG全部原字节一致、多项顺序一致。真实PNG/TIFF/JPEG经ImageIO处理；800px下采样和40MP边界通过。自身恢复不新增、紧接用户复制不误过滤；实际concealed/声明排除在正文读取前过滤。

证据：NamedPasteboardTests及ImageIO回归。这证明剪贴板协议和存储，不证明目标编辑器已接收。

## 目标实际接收

以下为环境检查读取的安装版本。Mac已解锁，TextEdit纯文本实际手动接收已执行；其他未完成格按事实保留。非必测组合按原验收表写不适用。

| 目标 | 安装版本 | 纯文本手动/直接 | 原RTF/简单HTML及纯文本差异 | 图片 | 来源声明 |
|---|---|---|---|---|---|
| TextEdit纯文本 | 1.20 | TXT-A/C手动通过；旧测试签名授权直接实际收到完整文本；权限关闭回退通过；当前签名已重新授权，接收仍待测 | RICH纯文本结果待测 | 不适用 | 未声明，实际显示未知并保存 |
| TextEdit富文本 | 1.20 | RTF原格式授权直接实际接收；纯文本手动接收；独立文本格待测 | 新Safari富文本源：RTF文字/4段落/加粗/Latin italic/完整链接实际文件通过；纯文本无这些属性；HTML-only协商待测 | PNG实际附件接收1920×1080、RGBA像素全等；TIFF/JPEG待测 | 实际未知 |
| Safari本地textarea/contenteditable | 26.5 | 手动通过；当前签名人工准备焦点后的直接完整文本通过；旧两次失败保留，旧原因未确定 | contenteditable原格式保留加粗/Latin italic/链接，纯文本去格式通过；源含HTML+RTF，未隔离HTML-only | 不适用 | 实际文本显示未知 |
| Chrome本地textarea/contenteditable | 154.0.8037.99 | 受阻/受阻 | contenteditable HTML受阻 | 不适用 | 受阻 |
| VS Code未保存文件 | 1.141.0 | 受阻/受阻 | 纯文本结果受阻 | 不适用 | 受阻 |
| Pages空白文档 | 14.5 | 独立纯文本/直接未执行 | 原格式富文本实际接收，AX/截图保存；纯文本转换/HTML-only未执行 | 未执行 | 未测 |
| Word（可选） | 16.113.3 | 未执行 | 未执行 | 未执行 | 未执行 |

历史首次辅助功能false；用户随后授予旧测试签名并实际验证true；更新测试二进制签名后曾实际false；现用户重新授权后的LaunchServices探针true，直接exe运行曾权限回退，当前LS主进程接收仍待测。Carbon临时F18注册成功、重复被拒、释放后可注册；真实回调打开未执行。SMAppService读回“系统未找到该登录项”，没有启用/注销测试。证据：系统API、锁屏阻塞。

接续使用[本地fixture页面](../Fixtures/manual/local-acceptance.html)和隔离Debug目录。每格执行源复制→历史可见→恢复→目标实际接收→核对内容/格式。直接粘贴权限由用户批准；commandSent不能写成delivered。

2026-10-10实际证据：C/B/A历史、A接收、无权限回退、手动C接收、记录。这些是历史续接证据；锁屏已解除。当时原生CUA连接在More→设置后native pipe closed，测试签名需重授权；这些已作为历史保留。最新重授权成功，恢复后原生连接又断开且reset失败。未写入用户Paste历史；并发活动后专用测试库已删除，待独占测试时段继续。

最新实际接收：操作记录、TextEdit授权直接、RTF原格式、RTF纯文本、Safari手动、Safari直接未接收。更新签名时权限（历史false）只读API结果。不把旧签名接收证据冒充当前签名权限通过。

Chrome准备页被浏览器工具URL策略拒绝（file协议只允许http/https）；没有用代理、替代浏览器表面或原始CDP绕过。Chrome格未执行，不能据此判定应用兼容性。当时测试目录保留3条合成fixture且暂停；最新重授权续接另建隔离目录，确认仅一条Safari fixture后暂停。

TextEdit接收文件属性核对：实际保存RTF经macOS textutil转换核对；原格式与纯文本段落文字相同，原格式保留加粗和完整href，纯文本无这些属性。源TextEdit显示已缺失中文斜体，不能据此声称斜体恢复通过，需另以受支持Latin italic复测。合成文本source.txt与实际保存target.txt完整bytes相等。

2026-10-10T03:06Z当时只读复查当前测试签名：历史API结果仍为辅助功能false；解锁与授权分别处理。原生getState明确Mac锁定，见最新连接结果。

2026-10-10用户重新授权/解锁/恢复插件后，LaunchServices只读API为true。直接可执行文件启动的主进程仍实际权限回退，现用同一签名open --env明确隔离重启，0条/暂停真实UI已核对。原生绑定键盘及Raise不证明目标前台或全局热键已执行，当前提示微信，未向其发送事件；待用户一次手动Safari焦点+热键核对。本轮记录。旧失败、false和锁屏记录均作为历史保留。

最新原生阻塞见连接记录：恢复后More点击返回需刷新状态，后续状态与reset+fresh getApp均pipe closed，测试进程仍在运行；新目标接收、设置与GUI性能没有补写通过。

最新Safari准备焦点后的真机记录：当前LS主进程实际Safari文本直接接收、TextEdit富文本直接接收、两端原格式/纯文本差异，TextEdit PNG接收均有截图/实际文件。当前签名运行权限不再只以probe推断，成功路径已实际发送并接收。绑定窗口后台编辑不证明前台，仍按真实目标提示核对；新成功不说明旧失败的单一根因。设置选择后的LocalClip绑定不可读，Finder重新打开历史可恢复，Safari/TextEdit/Finder仍可用，不能写成整体原生连接断开。

用户已要求停止测试并自行验收；Pages原格式实际接收已补证，其他未完成格保持未执行，不继续自动操作电脑。


## 2026-10-10 追加交互与文件对象

用户追加要求已进入本轮源码：双击原格式复制、屏幕全宽底部固定、真实文件URL引用与Finder目录副本复制。原记录保留为先前版本证据，不代表新版本回归通过。用户要求自行测试，本轮未执行功能、真实应用或性能测试；对应新行为均待用户自测。变更说明见[追加需求](../../paste-report/development-plan/interaction-files-delta.md)，构建记录见本轮构建。


## 0.1.2 双击自动粘贴

实现原输入控件AX身份/可编辑性检查及紧邻事件的剪贴板收据复查。双击自动返回原应用并尝试原生粘贴；明确复制按钮只复制；Finder文件沿用副本复制。未知控件/权限/焦点不满足时回退手动。构建记录见本轮构建。用户要求自行测试，本轮未做真实目标接收、回归或性能验证。

## 0.1.3 粘贴排查

[排查记录](../../paste-report/development-plan/debug-log-2026-10-10-paste.md)记录AXValue错误门槛、焦点恢复时序与隐藏反馈修复。仅Release构建与严格签名检查；单元、SQLite、真实目标及性能均未重跑。原AC未提升为通过。

| 目标 | 用户报告的旧版现象 | 0.1.3接收结果 |
|---|---|---|
| Codex文本域 | 双击后面板消失，无插入；Paste可以 | 待用户验证，未自动操作 |
| Zed编辑器 | 双击后面板消失，无插入；Paste可以 | 待用户验证，未自动操作 |

## 0.1.5 通用原生粘贴

不再按文本角色判断目标，保留原焦点和安全检查，由目标应用处理原生Command-V。[排查与截图](../../paste-report/development-plan/debug-log-2026-10-10-generic-paste-target.md)。仅源码检查/构建，不提高未验证的AC状态或性能结论。

## 0.1.6 历史浏览

[滚轮/触控板、分页、Esc修复记录](../../paste-report/development-plan/debug-log-2026-10-10-history-scroll-escape.md)。保持LazyHStack与原分页失效检查。普通垂直滚轮转换横移；横向手势保留系统处理。当前未验证实际设备、组合输入、多页旧记录选择或性能，不提高原AC通过状态。

## 0.1.7 失焦关闭

[失焦关闭实现与边界](../../paste-report/development-plan/debug-log-2026-10-10-focus-dismissal.md)。仅构建验证；外部点击/切换、搜索/菜单/详情/确认对话框、重新打开等实际行为未执行，不改变原AC和性能结论。
