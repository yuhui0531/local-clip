# LocalClip 与 Paste 完整功能差距报告

报告日期：**2026年10月10日**。调查方式：**只读源码与已发布应用包对比**，并以 Paste 当前官方文档交叉核对。本报告属于功能评估，没有新增产品验收，也没有启动新的实施计划。

LocalClip 已具备本地剪贴板管理的主要流程，以及用户要求的屏幕底部界面。当前最主要的差距是：**直接粘贴的实际可靠性尚未证实、分类无法单独保证长期保留、无法向其他应用拖出真实内容、缺少多条记录操作、键盘流程不完整，以及搜索、预览和编辑能力较弱**。云同步、移动端和 AI 属于原定本地首版之外的独立扩展。

## 1. 对比对象、范围与证据强度

| 对比对象 | 已核实的身份 | 能够证明什么 |
|---|---|---|
| LocalClip 源码与 Release 应用 | **0.1.14，构建15**；工程位于 `/Users/ronny/VscodeProjects/rea/macos-app`；应用二进制与交付清单一致 | 证明代码实现和产物身份，不代表当前版本已实际运行通过 |
| 本机安装的 Paste | **6.0.3，构建14117**；位于 `/Applications/Paste.app`；通用二进制支持 arm64/x86_64；应用包最低系统声明为13.0 | 证明这个应用包的静态能力和功能声明 |
| Paste 当前公开产品能力 | 官方帮助、更新和隐私页面，访问日期为 **2026-10-10** | 证明当前公开文档描述的能力，不代表所有功能都存在于本机6.0.3中 |

Paste 主程序 SHA-256：`e0b96d48ee4027dccacded16dd3c738878496ef005b913580b34bfc89d31b2e7`。

LocalClip Release 主程序 SHA-256：`16cad28b4c165441ab196d800cc5806e24e2bda6160e8651e2d6ec04e544e3ec`。

身份与旧证据复用检查见[身份记录](/Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/identity-and-reuse.json)；源码快照见[37个文件的哈希索引](/Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/localclip-source-audit-hashes.json)；详细实现边界见[源码审计](/Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/localclip-source-audit.md)。另附可排序的[CSV 对比表](/Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/feature-matrix.csv)，其中的证据编号可通过本报告末尾的索引查阅。

当前交付清单明确标注：**当前版本未执行功能测试、性能测量和视觉验收**。以前的功能测试和目标应用接收记录属于旧版本。用户已经停止自动测试并选择自行测试，本次调查没有恢复测试。见[交付清单][D01]和[验收结果][D02]。

本次调查没有启动、重启或终止应用；没有读取或修改剪贴板正文、用户历史数据库、偏好设置及权限数据库。只检查了工程源码、既有工程证据、安装包资源和官方公开页面。产品源码、构建产物及任务状态保持不变。

### 状态与范围说明

| 状态 | 含义 |
|---|---|
| **已实现／待实测** | LocalClip 有具体实现，但当前版本的实际运行效果与对等程度尚未证实 |
| **部分实现** | 已实现一部分流程，但存在明确缺失步骤或较窄支持边界 |
| **缺失** | 在审查的源码、接口契约、存储和界面中未发现该产品能力 |
| **行为差异** | 两款产品的已知行为不同，不自动认定为缺陷 |
| **未知** | 现有证据不足以得出可靠的对比结论 |

优先级属于建议：**P0** 保障现有流程和用户信任；**P1** 补齐日常 Paste 式操作；**P2** 增强本地进阶能力；**P3** 为可选的生态或产品扩展。优先级建议不代表已获实施授权。

范围：**原版范围**指原定 F01–F11 及相关可靠性；**追加范围**指后来要求的交互、文件和自定义分类；**扩展范围**指原版不要求的能力。OCR、AI/MCP、云服务、连续粘贴、自定义记录标题和网络链接预览仍属于扩展。文件和自定义分类已在后续请求中加入。用户明确禁止升级兼容代码，本报告也不建议增加。

## 2. 最重要的差距

### 2.1 分类目前只负责归组，不能保证长期保留

LocalClip 只有 `isFavorite` 能防止记录到期和自动容量淘汰。加入分类不会改变收藏状态。因此，放进“提示词”分类但没有收藏的记录，仍可能在期限结束或容量清理时消失。这是明确的存储规则，不是根据界面推测出的故障。见[存储规则][S02]和[到期清理][S03]。

Paste 文档说明 Pinboard 中的记录不会到期，普通历史到期后仍可保留。LocalClip 的独立收藏能提供长期保留，但“加入分类”本身不能。这是常用内容复用场景中最重要的行为差异。见[Paste 保留规则][W09]。

### 2.2 自动粘贴有实现，但是否实际插入尚未解决

LocalClip 现在会恢复原目标身份和焦点，检查权限及剪贴板写入凭据，再发送原生 Command-V；不再把目标限定为 textarea 一类文本输入框。这修正了此前过窄的判断条件。但返回“指令已发送”仍不能证明 Codex、Zed、浏览器编辑器或其他目标实际接收了内容。见[粘贴协调器][S04]和[原生应用交互边界][S05]。

用户此前反馈 Codex/Zed 粘贴失败、Paste 可以成功，是有价值的问题线索，但不是对当前0.1.14的受控对比。最新交付记录没有本版实际接收证据。这里缺的是可靠性证明，而不是缺少发送粘贴的方法。Paste 的官方直接粘贴流程同样要求辅助功能权限；官方介绍也不能证明所有目标应用都兼容。见[直接粘贴帮助][W11]和[当前交付边界][D01]。

### 2.3 拖入分类不等于能拖入其他应用

LocalClip 卡片拖拽提供的是**仅限自身进程使用的 UUID 令牌**，用于内部分类归属。它没有向外部目标提供文本、图片或文件内容，因此当前没有把历史卡片拖进编辑器、Finder 或上传区域的真实内容输出路径。见[拖拽提供者][S06]。

Paste 文档支持向外部应用拖放内容。LocalClip 虽然已经能拖入分类，仍需要独立的拖出内容能力。见[Paste Mac 使用说明][W01]。

### 2.4 一次复制包含多项，不等于能多选多条历史

LocalClip 保留原始多项剪贴板快照中的支持格式和顺序。但界面只有单个 `selectedID`，每次粘贴请求也只携带一条历史 ID。没有多选、批量分类或删除、合并粘贴多条历史，以及连续粘贴队列。见[选择状态][S07]和[粘贴请求][S08]。

Paste 文档支持选择多条历史并一起粘贴；独立的 Paste Stack 还提供按序逐条粘贴并消耗队列的流程。这些是不同能力，不能据此否认 LocalClip 已有的原始多项存储。见[Paste Mac 使用说明][W01]和[Paste Stack][W06]。

### 2.5 界面位置相似，只完成了体验的一部分

底部全宽、降低高度、半透明、滚动浏览、Escape 关闭及分类标签均有实现。明确差距包括：高度固定、没有随高度变化的紧凑卡片模式、只能单选、键盘操作不完整、预览基础、分类管理有限。LocalClip 在宽度小于900pt时会缩短品牌和标签，这是响应式顶部布局，不等于可调整面板高度和卡片密度。

当前流畅度、闪烁、实际透明效果和视觉完成度没有新增运行证据，本报告不宣称像素级一致，也不比较两款应用的实际速度。见[面板布局][S09]、[历史界面][S10]和[性能记录][D03]。

## 3. 完整能力对比表

下表 Paste 一列默认使用**当前官方文档基线**，明确标注“应用包声明”或“未知”的除外。不能把该列当成本机 Paste 6.0.3 的执行结果。LocalClip 链接指向具体实现；完整行号范围和缺失能力的搜索边界见配套源码审计。

### A. 采集、格式与保留

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| A01 | 自动保存本地历史 | 文档说明后台采集。[W07] | 200ms轮询并写入 SQLite；当前构建实际运行待验证。[S11] | 已实现／待实测 · P0 · 原版范围 |
| A02 | 文本、URL、图片和富文本 | 支持文本、链接、图片及带格式复用。[W07][W08] | 支持 UTF8文本、URL、RTF、HTML、PNG、TIFF、JPEG；白名单之外的应用格式表示不保留。[S12][S13] | 部分实现 · P1 · 原版范围 |
| A03 | 原格式与多项顺序 | 文档说明保留格式，但未给出所有 UTI 的完整保真契约。[W08] | 保存受支持的原始字节和多项顺序；不同格式参与内容身份判断。不能说只保存摘要。[S12][S13] | 已实现／待实测；与Paste完全对等程度未知 · 原版范围 |
| A04 | 文件对象 | 文档说明文件采集。[W07] | 支持文件URL；保存的是引用，不是文件备份。原件移动或删除后无法从历史重建内容。已有 Finder 目录复制路径。[S14] | 部分实现 · P1 · 追加范围 |
| A05 | 识别颜色的记录 | 可识别符合规则的六位十六进制颜色。[W07] | 没有颜色类型、色块、转换和颜色专用索引；颜色代码仍是普通文本。[S12][S10] | 缺失 · P2 · 扩展范围 |
| A06 | 原生PDF/RTFD及应用专有对象 | 支持PDF预览；原生PDF/RTFD采集契约未证实。[W01] | 白名单没有这些原生表示；附带的支持文本或文件URL仍可能保存。这是支持边界，不能笼统认定为相对Paste的确定缺陷。[S12][S13] | 对比支持情况未知；LocalClip契约较窄 · P2 |
| A07 | 包含永久保留的期限设置 | 可配置历史期限，包含永久保留。[W09] | 普通历史支持1–365天，默认30天，没有永久选项；收藏不受期限影响。[S15][S03] | 行为差异／缺少选项 · P2 · 扩展范围 |
| A08 | 高频连续复制 | 未取得Paste受控丢失率测量。 | 历史测量中50ms变化可能在轮询前被覆盖；当前版高频采集性能未知，不能量化Paste速度优势。[S11][D03] | 对等程度未知／已知采样边界 · P0 · 原版范围 |

### B. 面板、浏览与键盘

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| B01 | 屏幕底部全宽时间线 | 文档描述底部横条。[W01] | 已有底部全宽面板。[S09] | 已实现／待实测 · 追加范围 |
| B02 | 调整高度与紧凑模式 | 拖动上边缘调整高度；较低时切换紧凑布局。[W01] | 固定380pt；没有用户调高低或随高度变化的紧凑卡片。已有随宽度变化的顶部标签。[S09][S10] | 部分实现 · P1 · 扩展范围 |
| B03 | 跟随工作屏幕 | 在当前工作屏幕打开。[W01] | 按鼠标所在屏幕定位并响应屏幕变化；键盘操作及多屏场景是否等效未证实。[S09] | 部分实现／行为差异 · P1 · 追加范围 |
| B04 | 鼠标和触控板浏览历史 | 两种设备均有文档支持。[W01] | 横向滚动、纵向滚轮映射和延迟分页已有实现；实际设备和长历史浏览待实测。[S16][S10] | 已实现／待实测 · P0 · 追加范围 |
| B05 | 显隐切换与Escape关闭 | 有对应快捷键。[W04] | 同一快捷键切换显隐；Escape关闭；失焦关闭并避让自身对话框。[S17][S18] | 已实现／待实测 · 追加范围 |
| B06 | 来源应用、图标和复制时间 | 文档说明显示来源和时间。[W01] | 已显示图标、名称和时间；来源声明优先，推断存在竞态和后台写入边界。不确定时仍可显示未知。[S13][S19][S10] | 可靠性部分实现 · P0 · 原版／追加范围 |
| B07 | 首尾跳转与扩展选择 | 支持首尾、Shift方向键和全选。[W04] | 主要是单步方向键；Command组合绕过本地处理；不支持历史记录多选。[S18][S07] | 缺失 · P1 · 扩展范围 |
| B08 | 键盘搜索流程 | 支持聚焦、筛选控件及搜索框与结果切换。[W03] | 有搜索框，但未补全Cmd-F、筛选、Tab结果导航；Return直接执行默认动作。[S20][S18] | 部分实现 · P1 · 原版范围 |
| B09 | 删除与撤销 | 列出Delete和Cmd-Z，但未说明所有破坏性操作均能撤销。[W04] | 已实现Delete/Backspace及文本编辑避让；未发现产品撤销操作或栈，不能假定删除可恢复。[S18][S21] | 部分实现 · P1 · 原版／追加范围 |
| B10 | 视觉稳定与选择响应 | 未取得同条件基准或像素审查。 | 延迟卡片、轻量选择元数据、25ms合并和稳定操作栏是代码优化，并非实测流畅度。[S07][S10][D03] | 质量待验证 · P0 · 追加范围 |

### C. 复制、粘贴、外部复用与多条操作

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| C01 | 双击／Return直接插入 | 文档说明原生直接粘贴及权限不足时的回退。[W11] | 双击尝试直接粘贴；Return按配置动作执行，默认复制；当前目标实际接收待证实。[S04][S22] | 部分实现／行为差异 · P0 · 原版／追加范围 |
| C02 | 仅复制 | 有Cmd-C操作。[W04] | 有复制按钮和Cmd-C路径，以及自身写入过滤。[S22][S13][S11] | 已实现／待实测 · 原版范围 |
| C03 | 单次纯文本粘贴 | 支持纯文本操作和修饰键。[W08] | 有纯文本复制按钮，但Shift-Return仍进入原格式默认动作，没有纯文本分支。[S18][S22][S10] | 部分实现 · P1 · 原版范围 |
| C04 | 默认纯文本模式 | 有全局默认设置。[W08] | 设置选择复制／直接粘贴动作，不能选择默认原格式／纯文本；没有全局纯文本默认值。[S15][S23] | 缺失 · P1 · 扩展范围 |
| C05 | 数字快捷粘贴 | 可用数字快捷键操作可见条目1–9。[W19] | 没有Cmd-1…9及纯文本变体处理。[S18] | 缺失 · P1 · 扩展范围 |
| C06 | 向其他应用拖放文本／图片／文件 | 支持外部拖放复用。[W01] | 当前只提供内部分类令牌。[S06] | 缺失 · P1 · 扩展范围 |
| C07 | 图片作为文件用于Finder／上传 | 已宣布图片转文件粘贴与拖放。[W14] | 支持图片剪贴板字节，但没有向用户输出文件的路径；缩略图PNG只是内部派生数据。[S04][S24] | 缺失 · P1 · 扩展范围 |
| C08 | 多选与批量操作 | 支持多选和批量加入Pinboard。[W02][W04] | 只能选一条，没有批量复制／归类／删除界面；Core数组删除接口不等于产品多选。[S07][S21] | 缺失 · P1 · 扩展范围 |
| C09 | 多条历史合并粘贴 | 支持一起粘贴多条记录。[W01] | 请求只有单ID，没有历史合并输出或排序界面；原始多项快照是另一种已支持能力。[S08] | 缺失 · P1 · 扩展范围 |
| C10 | Paste Stack连续粘贴 | 有队列及正反方向逐条消耗流程。[W06] | 没有粘贴队列和下一条状态；采集队列与此无关。原版明确不包含。[S08][S11] | 缺失 · P2 · 扩展范围 |

### D. 自定义分类与Pinboard

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| D01 | 新建与重命名 | 可通过＋和上下文操作管理名称。[W02] | 已有新建／重命名浮层、稳定ID及名称校验；类型和自定义分类按要求同行显示。[S25][S10] | 已实现／待实测 · 追加范围 |
| D02 | 历史记录拖入分类 | 支持拖入Pinboard。[W02] | 已有原生令牌、悬停反馈和持久归属；手势、焦点和持久化实际效果待用户测试。[S06][S26] | 已实现／待实测 · 追加范围 |
| D03 | 已归类记录长期保留 | Pinboard寿命与普通历史不同。[W09] | 分类不保护期限或容量淘汰，只有收藏保护。[S02][S03] | 行为差异，重要保留缺口 · P0 · 追加范围 |
| D04 | 删除分类 | 支持删除Pinboard。[W02] | 没有删除分类操作；应另行决定只删归属还是同时删内容，不能静默照搬破坏性规则。[S25] | 缺失 · P1 · 追加范围 |
| D05 | 自选分类颜色 | 支持选择颜色。[W02] | 只有由ID推导的六色，没有用户选色和颜色持久配置。[S27][S28] | 缺失 · P1 · 追加范围 |
| D06 | 分类及分类内条目排序 | 两者都支持拖动排序。[W02] | 分类按创建时间／ID排列，没有手动分类和条目顺序持久化。[S25][S02] | 缺失 · P1 · 追加范围 |
| D07 | 同一项归属多个分类 | 文档说明每项同时只属于一个Pinboard。[W02] | LocalClip是多对多；加入B不必移除A。可能有用，不自动认定为故障。[S02] | 行为差异 · 产品规则选择 · 追加范围 |
| D08 | 从分类移除 | 支持取消归属。[W02] | 已有移除归属，且不删除历史正文。[S02][S26] | 已实现／待实测 · 追加范围 |
| D09 | 键盘创建和切换分类 | 有新建及前后Pinboard快捷键。[W04] | 有鼠标标签和＋，缺少对应键盘动作。[S18][S25] | 缺失 · P1 · 追加范围 |

### E. 搜索与筛选

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| E01 | 正文和元数据检索 | 支持正文、标题及元数据检索。[W03] | 已有正文、URL、来源名称字面搜索；没有自定义记录标题。中文短词、代码和URL片段按字面处理。[S29] | 部分实现 · P1 · 原版范围 |
| E02 | 结构化来源应用筛选 | 有专门的来源筛选。[W03] | 输入应用名称能匹配，但没有来源应用选择器或筛选标签。[S29][S10] | 缺失 · P1 · 扩展范围 |
| E03 | 日期范围筛选 | 支持日期过滤。[W03] | SearchRequest和界面都没有日期范围；保留期限不是搜索筛选。[S30] | 缺失 · P2 · 扩展范围 |
| E04 | 类型与分类联合筛选 | 有搜索过滤和Pinboard范围。[W03][W14] | Core能同时接收，但界面选类型清分类、选分类清类型。[S31][S29] | 部分实现 · P1 · 追加范围 |
| E05 | 多分类搜索范围 | 已宣布多个Pinboard筛选。[W14] | SearchRequest只有一个category ID，没有多分类查询界面。[S30] | 缺失 · P2 · 扩展范围 |
| E06 | 搜索内联建议筛选 | 有上下文筛选界面。[W03] | 只有固定类型／分类标签和文本框。[S10][S20] | 缺失 · P2 · 扩展范围 |
| E07 | 搜索图片内文字 | 支持OCR图片搜索。[W03] | 只有缩略图，没有OCR提取、索引和高亮。原版明确不包含。[S24][S32] | 缺失 · P2 · 扩展范围 |
| E08 | 搜索结果跳回原始上下文 | 支持跳回历史或Pinboard。[W03] | 没有恢复原列表及位置的跳转动作。[S10][S20] | 缺失 · P2 · 扩展范围 |
| E09 | 设备筛选和跨设备搜索 | 支持设备过滤。[W03] | 没有设备身份和同步记录；依赖独立的跨设备产品能力。[S30][S33] | 缺失 · P3 · 扩展范围 |

### F. 预览、编辑与创建

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| F01 | 完整Quick Look预览 | Space可预览PDF、链接等。[W01] | 详情只有只读文本／图片／路径视图，没有系统Quick Look入口。[S34] | 部分实现 · P1 · 扩展范围 |
| F02 | 保真富文本预览 | 支持原位带格式编辑。[W05] | 保存原始RTF/HTML，但卡片和详情显示提取的纯文本。存储保真不等于显示保真。[S34][S32] | 部分实现 · P1 · 原版范围 |
| F03 | 编辑已保存内容 | 支持保留格式的文字编辑。[W05] | 没有正文编辑操作、界面及存储变更契约。[S35][S34] | 缺失 · P2 · 扩展范围 |
| F04 | 自定义记录标题 | 支持重命名记录。[W05] | 没有自定义标题字段；分类改名是另一种操作。原版明确不包含。[S35] | 缺失 · P2 · 扩展范围 |
| F05 | 不复制也能新建记录 | 支持新文本记录。[W01] | 没有新文本产品操作；入库来自采集内容。[S35][S11] | 缺失 · P2 · 扩展范围 |
| F06 | 图片旋转与文字提取 | 有图片编辑和文字提取。[W05] | 只解码和缩略，没有图片编辑或OCR界面。[S24][S32] | 缺失 · P2 · 扩展范围 |
| F07 | 颜色选择器与编辑 | 已宣布内置颜色编辑。[W14] | 没有颜色对象和编辑器。[S12][S34] | 缺失 · P2 · 扩展范围 |
| F08 | 链接标题／缩略图和内置浏览器 | 有网络预览及浏览器／媒体预览。[W23] | 只显示host／URL／文本，没有联网元数据和浏览器；原版明确排除，具有隐私收益。[S34][S32] | 按范围未实现 · P2 · 扩展范围 |
| F09 | 打开链接／文件、Finder定位与打开方式 | 有打开快捷键；应用包包含定位／打开方式标签。[W04][R02] | 只显示路径，没有对应产品按钮；Paste包内动作的实际运行本轮未证实。[S34][S18] | 缺失 · P1/P2 · 扩展范围 |
| F10 | 从iPhone扫描文档 | 已宣布连续互通扫描。[W14] | 没有扫描动作或连续互通桥接。[S33][S34] | 缺失 · P3 · 扩展范围 |

### G. 隐私、设置、安全与生态

| 编号 | 能力 | Paste 证据 | LocalClip 现状与差距 | 状态／优先级／范围 |
|---|---|---|---|---|
| G01 | 排除应用 | 文档支持用户选择应用排除。[W10] | 只匹配声明的来源bundle ID；推断／未知来源不参与排除。选中应用不保证它的所有复制都被排除。[S36][S23] | 策略覆盖部分实现 · P0 · 原版范围 |
| G02 | 采集前过滤敏感／临时数据 | 有过滤设置，且说明密码扩展的识别边界。[W10] | 在读取正文、预览和索引前检查标记；不承诺识别全部密码。[S13][S36] | 已实现／待实测 · 原版范围 |
| G03 | 定时暂停并自动恢复 | 支持定时及手动恢复。[W10] | 只有持久采集开关，没有恢复截止时间或定时器。[S11][S15] | 部分实现 · P1 · 扩展范围 |
| G04 | 屏幕共享／录屏时隐藏 | 已宣布可见性设置。[W14] | 没有识别共享／录屏的保护；失焦关闭不等于此功能。[S09][S15] | 缺失 · P1 · 扩展范围 |
| G05 | 采集音效／隐藏菜单栏图标 | 本机应用包设置标签声明两者。[R02] | 没有声音或可见性设置；始终创建菜单栏项。Paste实际行为本轮未运行证实。[S37][S23] | 相对应用包声明缺失 · P2 |
| G06 | 登录启动 | 有启动设置说明。[W17] | 已有SMAppService注册、取消和状态界面；系统批准由用户操作。[S38] | 已实现／待实测 · 原版范围 |
| G07 | 配置多个工作流快捷键 | 支持多个动作重映射和修饰键选择。[W04] | 只有一个可录制的全局唤起快捷键；没有Stack、分类及全局格式修饰键设置。[S23][S18] | 部分实现 · P1/P2 · 扩展范围 |
| G08 | 本地优先存储 | 本地数据及可选私有iCloud有文档说明。[W16] | SQLite本地历史，没有云和网络预览；属于定位选择，不是缺陷。[S33][S39] | 已实现／待实测 · 原版范围 |
| G09 | 保存失败保旧、清理和容量 | Paste精确事务及物理容量规则未恢复。 | 候选校验、同步、原子替换；失败保留旧历史。收藏受保护且计容量，已有派生失效处理及历史故障证据。[S40][S03][S07] | LocalClip已实现；对等程度未知 · P0 · 原版范围 |
| G10 | iCloud同步与设备恢复 | 支持可选iCloud存储及恢复。[W16] | 没有同步或iCloud恢复；内部SQLite backup是提交机制，不是用户备份功能。[S39][S40] | 按范围未实现 · P3 · 扩展范围 |
| G11 | iPhone／iPad配套流程 | 有移动应用、键盘／扩展及iPad多任务。[W20][W21] | 只有macOS目标，没有移动客户端、扩展和移动拖放。[S33] | 按范围未实现 · P3 · 扩展范围 |
| G12 | 共享Pinboard与访问角色 | 有共享及权限管理。[W12] | 没有邀请、权限角色、共享同步服务和团队界面。[S33][S28] | 按范围未实现 · P3 · 扩展范围 |
| G13 | Apple快捷指令自动化 | Mac/iOS动作有文档说明。[W24] | 没有AppIntents／快捷指令动作；全局面板快捷键不是自动化集成。[S33] | 缺失 · P2/P3 · 扩展范围 |
| G14 | MCP集成 | 有本地MCP服务及批准客户端访问。[W15] | 没有MCP服务、客户端授权或搜索／读取／整理工具。原版明确不包含。[S33] | 按范围未实现 · P3 · 扩展范围 |
| G15 | AI写作工具和上下文建议 | 有写作工具及满足条件时的智能建议。[W05][W13] | 没有AI编辑或建议；建议所需系统／硬件高于原版最低基线，不是每台Mac均可对等的能力。[S32][S33] | 按范围未实现 · P3 · 扩展范围 |
| G16 | 支持系统与处理器 | 当前帮助说明支持Intel及macOS14+。[W18] | macOS15+／Apple Silicon是既定基线，不属于实现缺陷。本机Paste6.0.3包声明则为13.0。[S33][R01] | 支持范围差异 · P3 |
| G17 | 可信分发与更新 | 官方直接下载及App Store分发有文档说明。[W01] | 本地Release .app使用ad hoc签名；没有开发者公证、商店分发和产品更新器。这些不属于原定本地交付要求。[S41][D01] | 交付成熟度差异 · P2/P3 |
| G18 | 单实例接替 | Paste精确接替契约未证实。 | 已有新实例接替；并发启动和崩溃恢复当前未验收。[S42][D01] | LocalClip已实现／待实测；对等程度未知 · 追加范围 |
| G19 | 应用级加密与锁定分类 | 审查的Paste资料未证实该能力。 | 普通SQLite BLOB，没有应用锁／加密；SHA-256指纹不是加密。未检查FileVault。[S12][S39] | 对比能力未知，不能虚构Paste差距 |
| G20 | 通用手动导入／导出／备份界面 | 未证实任意格式的产品导入导出界面。[W16] | 没有此类界面，但不能据此认定落后于Paste；用户也未要求迁移代码。[S40][S23] | 对比未知／LocalClip缺少该产品选项 |

对比表共 **76个对比点**。这些是工作流区别，不是76个彼此独立的缺失功能。没有计算功能对等百分比：缺少运行标准和权重时，不能把实现、规则差异和未知项压成可靠的比例。

## 4. 用实际场景解释差异

| 场景 | LocalClip当前行为 | 对比含义 |
|---|---|---|
| 把常用提示词放进自定义分类 | 只增加归属，不自动收藏 | 若用于长期复用，需要明确保留规则；当前用户还需单独收藏。[S02][W09] |
| 把同一项从分类A拖到B | 可以增加B并保留A | Paste文档是单Pinboard归属；LocalClip多归属属于规则差异，不说明拖拽失败。[S02][W02] |
| 把图片历史拖到浏览器上传区域 | 内部令牌不提供外部内容／文件 | 拖入分类不能满足此流程；Paste另有图片转文件能力。[S06][W14] |
| 选五条以前的片段一起使用 | 不能选择五条历史 | 需要多选状态、可见选择反馈和明确合并输出；一次原始复制保存五项并不能解决。[S07][S08][W01] |
| 在“物理知识”分类内找图片 | 点图片类型会清除分类范围 | 界面阻止了Core已经支持的联合条件。[S31][S29] |
| 排除一个不写来源标记的应用 | 前台推断能显示图标，但排除不匹配该推断 | 展示来源与策略来源不同，不能静默把猜测当可信归属。[S13][S36][W10] |
| 在Codex／Zed编辑时双击历史 | 条件满足时恢复剪贴板并尝试原生粘贴 | LocalClip隐藏或发送事件都不足以证明接收；当前可靠性仍未确认。[S04][D01] |
| 搜索包含“物理”的截图 | 没有图片文字索引 | OCR是明确功能差距，但原版已排除。[S24][W03] |
| 在第二个屏幕打开面板 | 按鼠标所在屏幕定位 | 当前工作窗口和鼠标所在屏幕可能不同；本轮没有实际对比。[S09][W01] |

## 5. 建议推进顺序

### P0：先保障现有流程可信

1. **解决直接粘贴可靠性。** 已有代码路径；用户选择测试时，应核对反馈编辑器的实际接收和焦点。发出事件与实际插入仍须分开，不能为消除提示而撤掉安全检查。
2. **明确分类保留规则。** 决定分类本身是否意味着长期保留，还是仍需收藏，再统一期限、容量、归属和派生数据。需要明确产品选择，不建议自动迁移或兼容层。
3. **明确并改进应用排除覆盖。** 当前只信任声明来源，普通未声明复制不受应用排除保护。改动应明确归属置信度，不能把所有复制强行归到前台应用而错误过滤。
4. **解决响应和闪烁的证据缺口。** 选择与布局已有优化，但没有本版端到端样本。分析大库写入时应保留原子保存保证。

### P1：补齐日常操作

1. 向外部拖出真实文本、图片和文件，必要时把图片提供为文件。
2. 多选及一致的批量分类、删除、复制和合并粘贴。
3. 分类删除、排序、自选颜色及键盘切换，同时保留类型与自定义分类同行布局。
4. 数字1–9快捷粘贴、正确的纯文本修饰键、搜索聚焦／结果导航、默认纯文本设置。
5. 分类／类型／来源联合筛选，完整富文本／文件预览，以及打开和定位动作。
6. 可调高度／紧凑模式、定时暂停、屏幕共享隐私及明确的撤销规则。

这些不全属于原始F01–F11契约，表示后续有价值的本地对等工作，不能倒推“每个Paste功能缺失都会阻止原版交付”。

### P2：本地进阶能力

保存内容编辑、自定义标题、直接新建记录、OCR、颜色处理、筛选标签／日期范围、跳回上下文、预览完善及快捷指令集成。其中部分原版明确排除，需要先决定扩展范围。

### P3：独立生态扩展

iCloud同步／恢复、移动应用／扩展／小组件、共享分类与团队、MCP和AI。这些涉及新权限、信任边界或平台，应与当前本地流程修复分开。Paste的MCP服务运行在本地，但连接的AI客户端可能把取得的内容发给其服务商；“本地服务”不能等同于整个AI流程都不离开设备。见[MCP帮助][W15]。

## 6. 性能与验收对比

本次没有新增测试或基准，因此不能给出Paste与LocalClip的性能排名。

最近已有的**历史服务层测量，来自文件支持之前的版本**，只能用于分析瓶颈：

| 实际计时边界 | 样本数 | P95 | 不能证明什么 |
|---|---:|---:|---|
| 搜索调用到返回 | 200 | 26.055917ms | 搜索输入到结果绘制 |
| 第一页查询到返回 | 200 | 1.655458ms | 快捷键到面板可交互 |
| 新文本入库到持久提交 | 200 | 122.093375ms | 复制到历史卡片可见 |
| 新编码图片入库到提交 | 20 | 141.462542ms | 图片复制到缩略图可见 |
| 接近配额时入库到原子替换 | 30 | 550.153458ms | 当前GUI响应或统一500ms预算达标 |

原始样本见[服务结果][D04]，方法与历史失败见[性能文档][D03]。以上时间不包含轮询、输入、防抖及GUI绘制。接近配额的服务路径本身已超过500ms，不能用更快的第一页查询时间证明复制到可见达标。

历史压力测试中，200ms间隔保存100/100；50ms间隔观察并保存27/100，73次变化在观察前已被覆盖。这些是隔离命名剪贴板上的生产服务测试，不是当前GUI，也不是受控Paste对比。见[压力样本][D05]。

当前交付记录保留**原任务完成17/22**，T16、T18、T19、T20、T21未完成。历史功能结果为发现52项、通过50项、两项条件基准跳过；不能认证后续文件、分类、拖拽、目标焦点及界面变更。AC16端到端延迟和完整首版验收仍未完成。见[任务清单][D06]、[交付清单][D01]和[验收结果][D02]。

## 7. 不应误列为缺失的能力

- 底部全宽、基础半透明／降低高度、触控板／滚轮浏览、Escape、失焦关闭和快捷键显隐切换都有源码实现。
- 单实例接替、来源图标、自定义分类新建／重命名、同行标签、拖入分类、Delete/Backspace和登录启动已有实现。应做适当实测，不能重复实现。
- 支持的原格式、多项顺序、中文／代码／URL字面搜索、原格式／纯文本输出、收藏保留、标记过滤及失败保旧的原子存储均已存在。
- 多分类归属与Paste单归属不同，但归属更多不天然更差。
- 离线存储及不联网生成链接预览属于产品选择，有隐私收益。
- 当前缺少升级兼容／迁移代码来自用户明确指令，不能为模仿商业产品自行增加。
- **每条片段自定义快捷键并非已确认的Paste差距**：官方帮助说明Paste目前也不提供。见[数字快捷粘贴帮助][W19]。
- 任意备份导出格式、加密／锁定Pinboard、网站域名／正则排除、所有专有UTI的无损采集，都不是本证据集已证实的Paste能力，不能虚构为对等要求。

## 8. 静态逆向证据

### 应用身份与旧证据复用

本机主程序哈希与此前REA Mach-O分析一致；当前解析的英文本地化字典与旧证据一致；Core Data模型和两个已检查的Stack nib也与记录哈希一致。因此仅复用这些已核验载体的证据，不代表整个应用包都已校验，也不证明是未经修改的官方原版。见[身份记录][R01]。

当前签名元数据报告授权机构不可用、没有TeamIdentifier、Info.plist未绑定。这不足以建立官方来源，也不能单独证明恶意行为。功能基线以官方文档为主；旧签名观察是历史记录，不作为当前可信性结论。见[当前签名元数据][R03]。

| 证据ID | 载体／观察 | 能支持的结论与限制 |
|---|---|---|
| `ev_2bc1bc9067fd19a93ab89c958ba765ff233e23b57166e7bf11c3319dedbda7e7` | [Mach-O分析][R04] | 存在AX／CGEvent粘贴API及CloudKit、CoreData、CoreSpotlight、LinkPresentation、QuickLook、AppIntents导入；证明依赖，不证明执行和算法。 |
| `ev_68ef56cdde77ea52119da39a6e391d1873b4bd73c9f5938e0884c7727c1dfa69` | [模型资源][R05] | 有记录／原始剪贴板、标题／自定义标题、列表／顺序和云相关声明；未恢复事务、容量或同步行为。 |
| `ev_26ab9ac5354fa1308d6183766c5861e509536f1459a000fd4bca83f693afa42e` | [英文本地化][R06] | 复用标签佐证包内能力；标签本身不等于功能已运行。 |
| `ev_3da538c1f518a67a8d2299f1eaf38ee83afe8709fc5c9b7aa86a9574196ca0e1` | [Stack界面资源][R07] | 声明Stack控制器和方向切换动作；不是运行测试。 |
| `ev_d639022eb3803d7bb490f9fae5d87d0850134ef3e649e4e43692d70dac64b37f` | [当前中文本地化][R02] | 含编辑、重命名、共享、全选、旋转图片、分类管理、设置、扫描及预览标签；完整REA证据已保存。 |

REA会话与提供者能力见[会话能力][R08]；打开／关闭过程见[会话记录][R09]。检查完成后已关闭原生会话。

本环境Ghidra、Hopper、IDA深度分析提供者不可用。本轮没有反编译、运行时挂钩或网络追踪。这不妨碍证明LocalClip源码缺口，但不能声称已恢复Paste精确内部算法。

## 9. 尚未确认的问题与覆盖结论

| 问题 | 结果 | 原因 |
|---|---|---|
| 当前LocalClip实现和缺失了什么？ | 源码层面已回答 | 已检查领域模型、存储、系统提供者、界面、构建信息及限定范围的缺失搜索；附链接和哈希快照 |
| Paste当前公开支持什么？ | 已覆盖文档能力目录 | 已交叉核对帮助、专题页面、更新和隐私声明 |
| 本机Paste6.0.3是否有所有最新功能？ | 未确认 | 当前官网没有绑定本机版本，未运行本机探针 |
| 当前LocalClip在Codex／Zed／Finder是否可靠？ | 未确认 | 按用户停止测试要求，没有新增实际接收测试 |
| LocalClip速度和流畅度是否达到Paste？ | 未确认 | 没有相同数据、交互计时或当前GUI样本 |
| Paste如何精确归因来源并执行排除？ | 未确认 | API导入和标签不足以还原策略 |
| Paste是否完整保留原生PDF／RTFD／专有格式？ | 未确认 | 通用预览／采集说明未定义每种表示 |
| Paste物理容量、去重和失败恢复规则是什么？ | 未确认 | 不能根据模型名字或本地存储汇总推断 |
| 本机Paste是否经过官方原版核验？ | 未确认 | 没有与可信官方包比对；当前签名未建立可信授权机构 |
| Paste有通用导出、应用级加密或任意排除规则吗？ | 未确认 | 未建立证据，不计入确定劣势 |

本报告的“完整”指已覆盖文档中的剪贴板采集、复用、浏览、组织、搜索、预览／编辑、隐私／设置及生态维度，不代表恢复了私有内部实现或所有运行组合。明确差距与未确认对比保持区分。

原报告一致性检查确认76个唯一编号、有效本地证据路径及完整引用。独立只读源码审查核对了分类、拖拽、粘贴及验收边界，并已采纳其响应式顶部布局措辞修正。本次中文修订另行核对编号、链接、关键数值与源码哈希；这属于报告检查，不是产品测试。见[校验记录](/Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/report-validation.json)。

## 10. 证据与来源索引

### LocalClip源码定位

以下均为实际检查的文件；完整行号范围和缺失搜索边界见配套源码审计。

- [S12：领域与格式契约][S12]
- [S02：分类归属、可见性和容量][S02]
- [S03：到期清理][S03]
- [S04：复制／粘贴和Finder协调器][S04]
- [S05：原焦点和原生事件边界][S05]
- [S06：内部拖拽令牌与提供者][S06]
- [S07：单选状态及元数据调度][S07]
- [S08：单记录粘贴请求][S08]
- [S09：面板尺寸及关闭][S09]
- [S10：历史界面][S10]
- [S11：采集协调器][S11]
- [S13：剪贴板采集／恢复／来源／标记][S13]
- [S14：文件引用][S14]
- [S15：设置模型][S15]
- [S16：滚动处理][S16]
- [S17：显隐快捷键][S17]
- [S18：键盘分发][S18]
- [S19：来源观察器][S19]
- [S20：搜索框][S20]
- [S21：删除选中项][S21]
- [S22：默认／复制／双击动作][S22]
- [S23：设置界面][S23]
- [S24：图片缩略图][S24]
- [S25：分类存储操作][S25]
- [S26：分类投放和归属][S26]
- [S27：分类颜色][S27]
- [S28：分类模型][S28]
- [S29：搜索存储][S29]
- [S30：搜索请求][S30]
- [S31：界面互斥筛选][S31]
- [S32：文本提取][S32]
- [S33：平台和产品目标][S33]
- [S34：只读详情][S34]
- [S35：摘要及变更契约][S35]
- [S36：采集策略][S36]
- [S37：菜单栏创建][S37]
- [S38：登录项服务][S38]
- [S39：SQLite表结构][S39]
- [S40：原子提交策略][S40]
- [S41：应用构建／签名脚本][S41]
- [S42：单实例处理][S42]

### Paste官方来源

所有页面访问日期：**2026-10-10**。这些链接支持对应表格行，属于公开产品声明，不是本机执行观察。没有收录整篇文章或用户数据。

| 编号 | 官方来源 |
|---|---|
| W01 | [Mac使用说明][W01] |
| W02 | [Pinboard组织管理][W02] |
| W03 | [搜索与筛选][W03] |
| W04 | [键盘快捷键][W04] |
| W05 | [粘贴前编辑记录][W05] |
| W06 | [Paste Stack使用说明][W06] |
| W07 | [采集内容与边界][W07] |
| W08 | [纯文本粘贴][W08] |
| W09 | [历史保留期限][W09] |
| W10 | [排除应用][W10] |
| W11 | [直接粘贴到其他应用][W11] |
| W12 | [共享Pinboard][W12] |
| W13 | [智能剪贴板][W13] |
| W14 | [更新记录][W14] |
| W15 | [Paste MCP][W15] |
| W16 | [数据存储位置][W16] |
| W17 | [登录启动排查][W17] |
| W18 | [Intel／Apple Silicon及当前最低系统][W18] |
| W19 | [数字快捷粘贴][W19] |
| W20 | [iPhone使用说明][W20] |
| W21 | [iPad使用说明][W21] |
| W23 | [链接预览][W23] |
| W24 | [macOS快捷指令集成][W24] |
| W25 | [隐私政策][W25] |

当前新增能力须与本机6.0.3分开：官方更新记录中，智能剪贴板为 **2026-09-28**，MCP为 **2026-06-02**，跳回历史为 **2026-04-29**，多个Pinboard筛选为 **2026-03-24**，Power Search为 **2025-12-09**。这些日期证明公开发布说明，不证明功能存在于检查的本机包中。见[更新记录][W14]。

智能剪贴板文档要求 **macOS26+及Apple Intelligence**，并涉及额外屏幕上下文权限，不能视为所有LocalClip macOS15基线机器均可使用的能力。见[智能剪贴板帮助][W13]。

隐私政策除剪贴板数据处理，还描述遥测和崩溃服务。私有iCloud或本地MCP不能概括成“整个Paste应用从不联网”。LocalClip没有云、链接预览和AI客户端是既定产品边界。见[隐私政策][W25]和[MCP帮助][W15]。

[W01]: https://pasteapp.io/help/paste-on-mac
[W02]: https://pasteapp.io/help/organize-with-pinboards
[W03]: https://pasteapp.io/help/search-and-filters
[W04]: https://pasteapp.io/help/keyboard-shortcuts
[W05]: https://pasteapp.io/help/edit-items-before-pasting
[W06]: https://pasteapp.io/help/using-paste-stack
[W07]: https://pasteapp.io/help/what-paste-captures
[W08]: https://pasteapp.io/help/paste-as-plain-text
[W09]: https://pasteapp.io/help/control-history-retention
[W10]: https://pasteapp.io/help/exclude-apps
[W11]: https://pasteapp.io/help/paste-directly-to-other-applications
[W12]: https://pasteapp.io/help/shared-pinboards
[W13]: https://pasteapp.io/help/intelligent-clipboard
[W14]: https://pasteapp.io/updates
[W15]: https://pasteapp.io/help/paste-mcp
[W16]: https://pasteapp.io/help/where-paste-stores-your-data
[W17]: https://pasteapp.io/help/paste-doesn-t-launch-on-system-startup
[W18]: https://pasteapp.io/help/intel-to-apple-silicon
[W19]: https://pasteapp.io/help/quick-paste-with-numbered-shortcuts
[W20]: https://pasteapp.io/help/paste-on-iphone
[W21]: https://pasteapp.io/help/paste-on-ipad
[W23]: https://pasteapp.io/blog/link-previews
[W24]: https://pasteapp.io/blog/paste-with-shortcuts-for-macos-monterey
[W25]: https://pasteapp.io/privacy

[S02]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Storage/HistoryStore.swift:71
[S03]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Storage/HistoryStore.swift:407
[S04]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/Features/PasteCoordinator.swift:17
[S05]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/System/MacApplicationClient.swift:26
[S06]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryViewModel.swift:320
[S07]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryViewModel.swift:16
[S08]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:256
[S09]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/AppDelegate.swift:175
[S10]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryView.swift:28
[S11]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/Features/CaptureCoordinator.swift:25
[S12]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:21
[S13]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/System/MacPasteboardClient.swift:21
[S14]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:45
[S15]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:128
[S16]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryScrollWheel.swift:71
[S17]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/AppDelegate.swift:157
[S18]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/AppDelegate.swift:320
[S19]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/System/SourceApplicationObserver.swift:15
[S20]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/SearchField.swift:35
[S21]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryViewModel.swift:288
[S22]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryViewModel.swift:224
[S23]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/SettingsView.swift:16
[S24]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/Features/ThumbnailRenderer.swift:8
[S25]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Storage/HistoryStore.swift:38
[S26]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryView.swift:159
[S27]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryView.swift:144
[S28]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:177
[S29]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Storage/HistoryStore.swift:258
[S30]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:191
[S31]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryView.swift:131
[S32]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/Features/ContentDecoder.swift:5
[S33]: /Users/ronny/VscodeProjects/rea/macos-app/Package.swift:4
[S34]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/HistoryView.swift:308
[S35]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:152
[S36]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Domain/Domain.swift:143
[S37]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/UI/AppDelegate.swift:141
[S38]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/System/LoginItemService.swift:6
[S39]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Storage/Schema.swift:6
[S40]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipCore/Storage/CommitStrategy.swift:59
[S41]: /Users/ronny/VscodeProjects/rea/macos-app/scripts/build-app.sh
[S42]: /Users/ronny/VscodeProjects/rea/macos-app/Sources/LocalClipMac/System/SingleInstanceService.swift

[D01]: /Users/ronny/VscodeProjects/rea/macos-app/evidence/automated/delivery/delivery-manifest.json
[D02]: /Users/ronny/VscodeProjects/rea/macos-app/docs/acceptance-results.md
[D03]: /Users/ronny/VscodeProjects/rea/macos-app/docs/performance.md
[D04]: /Users/ronny/VscodeProjects/rea/macos-app/evidence/performance/20261010T021901Z-prefetch/service-results.json
[D05]: /Users/ronny/VscodeProjects/rea/macos-app/evidence/performance/20261010T024249Z-system/stress.json
[D06]: /Users/ronny/VscodeProjects/rea/paste-report/development-plan/tasks.md
[R01]: /Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/identity-and-reuse.json
[R02]: /Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/rea-zh-labels.json
[R03]: /Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/paste-signature-current.txt
[R04]: /Users/ronny/VscodeProjects/rea/paste-report/evidence/rea-macho.json
[R05]: /Users/ronny/VscodeProjects/rea/paste-report/evidence/rea-model.json
[R06]: /Users/ronny/VscodeProjects/rea/paste-report/evidence/rea-labels.json
[R07]: /Users/ronny/VscodeProjects/rea/paste-report/evidence/rea-interface.json
[R08]: /Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/rea-session.json
[R09]: /Users/ronny/VscodeProjects/rea/paste-report/comparison-2026-10-10/evidence/rea-open-close.json
