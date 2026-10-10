# 开发交接入口：macOS 剪贴板管理器

日期：2026-10-09。用途：供新的 coding agent 在没有本次对话上下文的情况下实施首版本地应用。

本目录是开发计划，不是已经实现或测试通过的应用。工程任务完成度为 0/22。用户本轮授权制定计划；实际编码在接到开发指令后开始。

## 1. 阅读顺序与需求优先级

1. [修订后 PRD](../PRD-macOS剪贴板管理器-2026-10-09.md)：F01–F11、AC01–AC27 是首版行为基线。
2. [design.md](design.md)：技术选型、开发默认值、数据和接口契约、关键失败处理。
3. [tasks.md](tasks.md)：22 个可领取任务、依赖、交付文件、完成条件。
4. [acceptance.md](acceptance.md)：需求映射、测试数据、真实应用验证、证据要求。

用户最新明确指令 > PRD 行为 > 本计划技术决策 > 原复刻建议。PRD 没有确定的技术参数采用本计划的开发基线，在 T00 登记；不能把它们标成用户已评审通过或实测结论。发生行为冲突时先记录具体冲突，不静默修改 PRD。

本计划绑定的 PRD SHA-256：

`8045343ff184d857b932cbc7bbf6c8da8c6f8ff670ac21aed14ec87a0b760fa3`

PRD 若已变更，先逐项比较变更影响并更新任务/验收映射，再继续受影响任务。不重新复制一份 PRD 作为第二个需求来源；当前 PRD 直接承担 spec 的作用。

## 2. 已核实的工程起点

- 项目根目录：`/Users/ronny/VscodeProjects/rea`。
- 计划目录：`/Users/ronny/VscodeProjects/rea/paste-report/development-plan`。
- 2026-10-09 检查时，根目录只有 `paste-report/`，没有应用代码、Package.swift、Xcode 工程或 Git 仓库。
- `xcode-select -p` 返回 `/Library/Developer/CommandLineTools`；`xcrun swift --version` 返回 Apple Swift 6.2.4，目标为 arm64-apple-macosx15.0。未发现 `/Applications/Xcode.app`。
- 已发现 TextEdit、Safari、Google Chrome、Visual Studio Code、Pages 和 Microsoft Word 的应用包。存在不等于已完成兼容性测试；其具体版本由实施时记录。
- 原 REA 报告只用于架构参考。不得读取、复制或迁移用户的 Paste 数据库、历史正文、二进制或资源来实现新应用。
- 已检查的最佳实践目录没有 Swift/macOS 专用文档；不套用 Java、Vue 或 Python 工程规则。

迁移到其他机器后重新执行 T00，不沿用上面的环境检查结果。

## 3. 明确的实施基线

| 项目 | 本计划决定 |
|---|---|
| 首版运行目标 | macOS 15 及以上、Apple Silicon；Intel/更旧系统不纳入本次兼容性承诺 |
| 工具链 | Swift 6.2，使用实施机器实际安装的补丁版本并记录；SwiftPM 构建和测试 |
| 工程目录 | 新建根目录下的 `macos-app/` |
| 临时工程名 | LocalClip；开发 bundle ID 为 `local.localclip.dev`，不使用 Paste 的标识 |
| 界面 | AppKit 菜单栏、NSPanel、焦点控制；SwiftUI 设置和列表内容；系统与协调层放在可测试的 LocalClipMac 库 |
| 存储 | 系统 SQLite，单一 HistoryStore；原始表示以去重 BLOB 保存，首版不另建外部附件存储 |
| 搜索 | 本地字面子串匹配，中文短词路径必备；先不依赖 FTS5 或 Spotlight |
| 发布形态 | 可运行的本地开发 `.app` 与源码交接；商店发布、公证、正式签名账号不在本轮计划内 |
| 后续功能 | 多分类、连续粘贴、文件引用、同步、OCR、AI 不进入首版任务 |

选择单一数据库是为了把新条目写入、去重、收藏和淘汰放在同一个一致性边界内。大图片和容量回收必须先通过 T03 原型验证；这是设计选择，不是对 Paste 内部实现的断言。

## 4. 第一轮应该执行什么

按 `T00 → T01 → T02 → T03` 开始。

- T00 固定环境、格式、来源归因和实际目标应用矩阵。
- T01 建立能构建、能测试、能启动的 `.app` 工程。
- T02 定义全模块共同使用的值类型、错误和接口。
- T03 验证实际容量上限与失败保留旧数据的存储方案。

T03 失败时仍可进行基于接口的采集或 UI 工作，但不得宣布存储方案已完成，也不得跳过 AC17、AC25、AC26。先修复可行性问题再合入存储主流程。

## 5. 交给 coding agent 的启动提示词

> 请基于 `/Users/ronny/VscodeProjects/rea/paste-report/development-plan/` 开发 macOS 剪贴板管理器首版本地应用。先读 README.md、关联 PRD、design.md、tasks.md 和 acceptance.md，再从第一个未完成且依赖满足的任务开始。
>
> 工程位于 `/Users/ronny/VscodeProjects/rea/macos-app/`，若不存在则按 T01 创建。只实施 F01–F11；不要增加同步、OCR、AI、用户标题或多分类。遵守本机 AGENTS.md；本工作区的 shell 命令使用 `rtk`，原样执行用 `rtk proxy`。
>
> 任务完成时写明修改文件、执行命令、测试结果、证据路径与剩余限制，并更新 tasks.md。单元测试、文件系统集成测试、真实剪贴板测试和真实目标应用验收分别记录；没有执行的检查标记未执行。不要读取用户 Paste 历史，不替用户授予系统权限，不自动发布应用。
>
> 技术细节按 design.md 的基线执行。若前置条件不可用，只阻塞依赖它的任务，继续其他任务；若需要改变 PRD 行为，给出具体差异及原因，不能静默降低要求。以全部首版任务完成和真实验收证据齐备作为交付条件，不以“窗口能打开”作为完成。

## 6. 状态更新约定

任务开始标注负责人、当前状态、开始时间；完成后勾选并更新计数。部分测试受环境限制时保留任务未完成，记录已经完成的部分及阻塞证据。

任务表的工作量是按熟悉 Swift/macOS 的开发者、环境就绪条件下估算的工作量，不是日历承诺，也不是 agent 运行时长。其他 agent 可接续同一清单，无需重新规划。
