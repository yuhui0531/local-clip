# LocalClip 0.3.1（22）：代码展示与智能文件粘贴

2026-10-11后续修正：0.3.0的目标识别遗漏Zed窗口焦点，且面板期间unknown在焦点恢复后不重试，用户报告Swift/JSON无法粘贴正文。0.3.1补足Zed的特定窗口识别并保持VS Code原编辑控件身份，恢复焦点后重试转换，保留原权限、焦点、身份、文件、历史与剪贴板检查。66个回归测试通过（code-smart-paste-fix/regression-native-fix.log）；Release签名、arm64、资源及代码节匹配已确认。实际接收与最终证据见[本次排查记录](../../paste-report/implementation-plan-2026-10-10/debug-log-2026-10-11-code-file-paste.md)。下文0.3.0测试记录保留，不将其受阻结果或旧通过数当作0.3.1接收验收。

日期：2026-10-11。实施完成并交付 Release 应用；Zed/VS Code的Swift/JSON原生接收通过，四份实际另存文件逐字节一致。其他目标未重验，不能声称全部目标应用验收通过。没有历史迁移、schema升级或兼容框架。开关关闭保留原有输出组合，包括明确选择纯文本时复制文件路径。

## 已实现

- 历史文字/富文字卡片及完整详情自动识别代码并高亮；始终启用，完全不读取智能粘贴设置。普通文字保留原展示。复用离线 highlight.js 11.11.1（BSD-3-Clause）与系统 JavaScriptCore，不执行剪贴板代码、不加载网页或网络资源。官方接口：[highlight.js API](https://highlightjs.readthedocs.io/en/latest/api.html)。源码与许可证随应用资源和源码包交付。
- 设置中的「代码文件智能粘贴」默认关闭，通过原有 SQLite 设置保存；重启保持，运行时切换，无修改历史载荷。可选存储值的有效默认值为 false，使用现有 Codable/JSON 存储，不新增解码层或迁移。
- 开启后仅在有效原目标、权限和文本编辑元数据同时满足时，后台读取代码文件正文。Finder继续原文件复制逻辑；其他文件管理器、未知/只读/密码/禁用目标、缺权限、读失败均保留整组原文件。
- 文本控件支持 AXTextArea/AXTextField/AXSearchField；自绘编辑器、文档及网页通过明确 AXEditable 或可写选区声明编辑能力。Zed 1.23.2实际仅暴露AXWindow，采用限定bundle的窗口回退；其他无法确认的 IDE 保留原文件。原生粘贴焦点检查仍允许非文本目标，没有收紧原有粘贴能力。
- 保留文件文字的缩进、LF/CRLF、中文与emoji。按原文件/记录顺序组合，多文件间增加一个换行；不裁剪、不重新格式化。Finder保留原文件名、扩展名和字节。
- 文件读取扩展名白名单；UTF-8及显式BOM UTF-16LE/BE、UTF-32LE/BE严格回编码核对，解码时移除编码标记。二进制控制字符、非法编码、缺文件、目录、符号链接、FIFO等非普通文件拒绝整组转换。每文件4MiB、整组8MiB，最多64文件；超限保持原文件。
- 在后台读取、写入和焦点恢复后复查文件身份、设置、目标、历史和剪贴板；关闭开关或分类变为不确定时恢复自己仍持有的原文件，用户新复制不会被覆盖。发送事件仍只报告「指令已发送」，不表示收到。
- 修正回归发现的容量下调提交与预演不一致：保护内容超过新配额仍保留、普通内容在候选库内淘汰、之后拒绝新增；失败不先删除旧内容。

## 修改位置

Domain.swift（可选设置及目标分类契约）；CodeFileReader.swift；SyntaxHighlighter.swift；SyntaxPreview.swift；HistoryView.swift；SettingsView.swift；PasteCoordinator.swift；MacApplicationClient.swift；Package.swift及Sources/LocalClipMac/Resources/。测试在 CodeFeaturesTests.swift；原有测试边界在 EndToEndTests、DerivedAndViewModelTests、SearchRetentionQuotaTests、CrashRecoveryTests 更新。HistoryStore.swift修正上述配额提交；StorageProbe与配额fixture按当前schema真实占用设置容量，不改变故障断点或旧内容保护断言。VisualProbe/main增加Debug限定的隔离展示验证，Release不含探针。

## 0.3.0历史验证及证据（0.3.1接收见顶部排查记录）

环境：macOS 15.7.5（24G624），Apple Silicon arm64，Apple Swift 6.2.4；最低部署仍macOS15。

| 类别 | 实际结果 | 证据（相对于macos-app） |
| --- | --- | --- |
| 新功能+原有回归 | 65个启用测试、19个suite全部通过；包含真实临时SQLite、12个SIGKILL断点、500MiB旧内容保护、格式恢复、敏感先过滤、检索/删除/到期、权限/焦点/剪贴板竞争 | evidence/delivery/code-smart-paste/regression-packaged-final.log |
| 真实剪贴板服务器 | 私有命名NSPasteboard的3个测试通过；原始格式、多项、隐私、新开关下fileURL/string类型及精确正文 | evidence/delivery/code-smart-paste/named-board.log；最终回归再次执行 |
| 代码格式 | JSON、Java、Python、JavaScript、TypeScript、YAML、XML、HTML、CSS、Shell高亮；代码文件json/java/py/js/ts/yaml/yml/xml/html/css/sh及大写扩展名原文读取通过 | CodeFeaturesTests.swift及regression-packaged-final.log |
| 异常边界 | 多文件全组回退、4/8MiB上限、BOM编码、非法编码/NUL、目录/符号链接/FIFO、文件替换、未知/只读/安全控件、运行时关开关、新用户复制 | 同上 |
| 实际组件渲染 | actual HistoryView及详情共用组件的浅/深色像素检查；开关关闭与开启均有语法颜色 | cards-off-light.png、cards-on-dark.png、detail-off-light.png、detail-on-dark.png（同证据目录），另有packaged-resources-light.png证明封装.app资源查找 |
| 真正第三方目标接收 | **受阻/未通过验收**：当前Debug测试进程实际AXIsProcessTrusted=false。没有用fake事件计数、命名剪贴板或截图高亮代替接收证据 | system-api.json、packaged-system-api.json |
| Release性能 | 1次冷启动、30次未缓存/缓存高亮、10次4MiB后台读取通过；仅组件阶段，不代表跨应用接收延迟 | performance-release-final.log、performance-release-final.json、performance-summary.json |
| Release产物 | 完整构建、签名、arm64、0.3.0（21）、主程序UUID与SwiftPM一致、JS及许可证资源检查 | release-packaged-final.log、artifacts.json |
| 源码快照 | 白名单源码、资源、测试、脚本及交付资料；不包含用户/测试SQLite或Paste资源 | source-archive.json、source-verification.json |

最初编译缺少CLT _Testing_Foundation overlay，使用现有test.sh的-disable-cross-import-overlays及Testing framework设置解决；普通swift test没有实际运行测试的日志不计为通过。red-smart.log记录先行行为失败，旧失败记录保留。封装复查发现SwiftPM自动生成器在.app顶层定位资源bundle，而实际封装资源在Contents/Resources；修正应用直接读取封装资源，另用真正的Debug .app渲染验证，不依赖构建目录。签名前后整个主程序哈希会因代码签名不同而变化，产物分别记录，并核对Mach-O UUID与__text代码节。Release首次因Debug视觉探针在编译期间修改被Swift正确拒绝，冻结源码后重新构建通过；该失败日志保留。首次全回归发现配额错误及旧fixture固定页预算/详情未打开/激活回调没有触发的问题，修复后最终完整回归65个通过，未删断言或跳过失败项。

## 0.3.0历史目标兼容矩阵（后续Zed/VS Code结果见排查记录）

| 目标 | 已实现选择 | 已执行验证 | 实际接收 |
| --- | --- | --- | --- |
| 标准文本编辑器/输入框/textarea | 开启且确认可编辑→完整正文；关闭→原逻辑 | 文本角色分类、真实命名板类型、SQLite+fake目标全链路 | TextEdit等未验证，权限受阻 |
| 浏览器可编辑控件/contenteditable | 文本角色或明确编辑能力→正文；未知保留文件 | 角色/可编辑性/安全及只读边界 | Safari/Chrome网页接收未验证 |
| Coding IDE/自绘编辑器 | 明确编辑能力/可写选区→正文；无法确认保留文件 | 自绘角色与选区边界；目标变化不发送旧文本 | Zed/VS Code/Codex接收未验证 |
| Finder | 原始文件，不读取正文 | fileURL字节、file目标分支回归 | 本轮Finder目录实际复制未执行 |
| 其他文件管理器/未知应用 | 原始文件，沿用原生行为 | unknown分支与整组保留 | 未验证具体应用接收 |

## 性能及限制

Release原始样本在performance-release-final.json。冷引擎51.542ms（单次）；约700字符未缓存高亮中位10.906ms/P95 11.849ms；缓存中位0.100ms/P95 0.114ms；4MiB UTF-8读取中位8.081ms/P95 9.286ms。高亮及文件读取在后台，缓存最多64项且键不含正文，单次只着色前8192个UTF-16单位；详情的剩余正文仍完整可选择，原剪贴板和历史不截断。未缓存P95<16ms、缓存P95<1ms、4MiB读取P95<100ms的组件目标达到；这些是本轮组件目标，不替代PRD全部端到端性能验收。大量文件、整个粘贴动作、目标AX响应及接收时间未测。上述性能采样在封装资源路径修正前完成；最终高亮/读取算法没有变化，但封装.app冷启动没有另行量测。

语法自动识别对很短/歧义片段可能无法确定语言，失败显示普通文字；不提供用户关闭高亮的开关。没有GBK等猜测解码，没有符号链接追踪，读取失败保持原文件。未知应用是否接受原文件由应用决定，保留原内容不保证它支持该类型。

实际第三方验收仍需用户在系统界面给正在运行的测试/交付应用辅助功能权限；本轮不修改权限数据库。Finder读取当前目录可能还需要用户授予自动化权限。不得把当前测试二进制的false推断为交付Release已获授权或未获授权。Release尚未通过正常启动路径读取正式历史来做验收；Debug隔离视图与静态.app检查分别列证据。

## 交付与复现

应用：`macos-app/dist/LocalClip.app`，0.3.1（22）；源码：`macos-app/dist/LocalClip-source.tar.gz`。直接交付给用户测试，不发布、不上传内容、不读取/改写用户或Paste历史。

在项目根目录执行：

```sh
rtk proxy bash macos-app/scripts/build-app.sh release
rtk proxy python3 macos-app/scripts/package-source.py
rtk proxy env LOCALCLIP_NAMED_TEST=1 bash macos-app/scripts/test.sh
rtk proxy env LOCALCLIP_CODE_PERF=1 LOCALCLIP_CODE_PERF_OUTPUT=/private/tmp/localclip-code-performance.json bash macos-app/scripts/test.sh -c release --filter CodePerformanceTests
```

图像探针仅Debug可用。`LOCALCLIP_DATA_DIR`也仅Debug有效，禁止用它启动Release做隔离验收。
