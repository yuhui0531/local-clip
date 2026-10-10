# LocalClip 本地体验任务清单

日期：2026-10-10。基线：0.1.14（构建15）。状态：**开发与交付22/22；全部功能验收由用户自测**。

必须遵守[实施计划](/Users/ronny/VscodeProjects/rea/paste-report/implementation-plan-2026-10-10/README.md)。**禁止兼容与迁移代码。完成后直接交付Release `.app`，不等待产品测试或用户验收。**

这里的任务状态只表示本轮新增或改进的实现，不重新计算原首版22项任务。旧测试证据不认证本轮版本。

## 执行记录格式

每项开始时填负责人和状态；完成后填写实际修改文件、编译／产物检查命令、退出结果、证据路径和限制，再勾选。没有执行的功能验证统一标为“用户待自测”。当前实现与交付完成；每项实际文件与证据记录如下，勾选不代表产品验收通过。

## 任务

- [x] **M00 固定当前行为与无兼容边界**
  - 依赖：无。
  - 目标：核对当前工程；把分类保护、多归属、批量输出、来源排除、新目录、用户自测和非目标固定为统一契约。
  - 文件：本计划、Domain.swift、AppDelegate.swift及当前交付说明。
  - 完成条件：未重建骨架；旧目录不读取；没有迁移／旧接口方案；实现范围与76项覆盖表一致。

  - 执行：Codex；实现完成。实际修改：Domain.swift、AppDelegate.swift、实施计划README.md。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M01 当前模型与新数据目录**
  - 依赖：M00。
  - 目标：schema3一次创建，增加分类颜色／排序、归属位置、结构化设置；默认使用LocalClip-LocalEdition；首次提示新库并暂停采集。
  - 文件：Domain.swift、Schema.swift、HistoryStore.swift、AppDelegate.swift。
  - 完成条件：只读当前schema；错误版本拒绝写入；没有ALTER、旧字段回填或旧库自动重建；旧LocalClip-Development原样保留。

  - 执行：Codex；实现完成。实际修改：Domain.swift、Schema.swift、HistoryStore.swift、AppDelegate.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M02 来源展示和排除区间**
  - 依赖：M01。
  - 目标：明确声明／推断／未知来源；增加用户可选的排除应用前台暂停规则，正文读取前执行；保留未知默认保存和敏感优先规则。
  - 文件：SourceApplicationObserver.swift、MacPasteboardClient.swift、CaptureCoordinator.swift、SettingsView.swift。
  - 完成条件：不会把前台猜测当可信声明；设置解释区间行为；图标读取不进入采集主线程重负载路径。

  - 执行：Codex；实现完成。实际修改：MacPasteboardClient.swift、CaptureCoordinator.swift、SettingsView.swift（来源声明／推断和缓存图标继续使用SourceApplicationObserver.swift）。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M03 分类保护、期限和容量一致性**
  - 依赖：M01。
  - 目标：统一收藏或任一分类保护；期限、淘汰、清普通历史、可见性和载荷读取同规则。
  - 文件：HistoryStore.swift、CommitStrategy.swift、HistoryViewModel.swift。
  - 完成条件：保护内容仍计容量；无可释放空间时拒绝而不是先删旧；移除最后保护的到期后果可预览；派生清理一致。

  - 执行：Codex；实现完成。实际修改：HistoryStore.swift、CommitStrategy.swift、HistoryViewModel.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M04 分类完整管理和顺序**
  - 依赖：M03。
  - 目标：新建／改名／删除／配色、分类及内部记录排序，多分类归属保留；类型分类与自定义分类仍同行。
  - 文件：HistoryStore.swift、HistoryView.swift、HistoryViewModel.swift。
  - 完成条件：删除分类不静默删有效历史；颜色／顺序持久化；归属变化不刷新复制时间或指纹。

  - 执行：Codex；实现完成。实际修改：HistoryStore.swift、HistoryView.swift、HistoryViewModel.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M05 多选与键盘选择**
  - 依赖：M01。
  - 目标：ID选择集合、Command／Shift选择、范围、首尾、结果全选及分页；文本编辑焦点有独立处理。
  - 文件：HistoryViewModel.swift、HistoryView.swift、SearchField.swift、AppDelegate.swift。
  - 完成条件：查询变化、到期和删除同步选择；卡片切换不读取完整载荷；搜索框Cmd-A仍选文字。

  - 执行：Codex；实现完成。实际修改：HistoryViewModel.swift、HistoryView.swift、SearchField.swift、AppDelegate.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M06 批量操作与会话撤销**
  - 依赖：M03、M04、M05。
  - 目标：批量分类／收藏／删除，一次候选提交；删除即时失效；增加30秒、50MiB以内的内存撤销。
  - 文件：HistoryStore.swift、HistoryViewModel.swift、HistoryView.swift、AppDelegate.swift。
  - 完成条件：无磁盘回收站；超预算提示无法撤销；旧任务不回显；恢复重新过容量规则，失败不伪成功。

  - 执行：Codex；实现完成。实际修改：HistoryStore.swift、HistoryViewModel.swift、HistoryView.swift、AppDelegate.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M07 多条输出与纯文本**
  - 依赖：M05。
  - 目标：按可见顺序组合文本／富文本，混合内容有序输出；默认纯文本、Shift-Return和数字动作共享格式契约。
  - 文件：Domain.swift、PasteCoordinator.swift、ContentDecoder.swift、MacPasteboardClient.swift。
  - 完成条件：不拼原始RTF字节、不改历史载荷、不静默丢弃项目；生成输出在后台，写板仍核对凭据。

  - 执行：Codex；实现完成。实际修改：Domain.swift、新OutputComposer.swift、新RichContent.swift、PasteCoordinator.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M08 通用直接粘贴与反馈**
  - 依赖：M07。
  - 目标：统一目标／焦点恢复状态机、有界等待、权限／身份／凭据复查、单次发送；无textarea角色门槛，无逐应用补丁。
  - 文件：MacApplicationClient.swift、PasteCoordinator.swift、AppDelegate.swift、HistoryViewModel.swift。
  - 完成条件：正常发送后不弹“确认输入框”浮层；失败原因准确；不会因目标变化发送到其他应用；事件发送与实际接收分开。

  - 执行：Codex；实现完成。实际修改：MacApplicationClient.swift、PasteCoordinator.swift、Domain.swift、HistoryViewModel.swift、AppDelegate.swift；现有测试适配器同步新契约（未运行）。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M09 外部拖放和图片文件**
  - 依赖：M05、M07。
  - 目标：内部token与公开内容provider分离，支持多项拖出，按需图片文件，临时租约和占用预算。
  - 文件：新ContentExportProvider.swift、HistoryViewModel.swift、HistoryView.swift、Info.plist。
  - 完成条件：外部提供真实内容；删除／取消复查；临时文件不提前删；失败不删旧历史；拖拽过程不误失焦关闭。

  - 执行：Codex；实现完成。实际修改：新ContentExportProvider.swift、新ClipExportAccess.swift、HistoryStore.swift、CommitStrategy.swift、HistoryViewModel.swift、HistoryView.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M10 Finder与打开／定位操作**
  - 依赖：M07、M09。
  - 目标：文件引用失效说明、Finder多文件预检／复制、准确部分失败结果，以及打开链接／文件、Finder定位和打开方式。
  - 文件：PasteCoordinator.swift、HistoryView.swift及系统文件操作边界。
  - 完成条件：不覆盖原目录文件，不把URL引用当文件备份；权限由用户授予；复合记录不自动打开全部对象。

  - 执行：Codex；实现完成。实际修改：FinderFileService.swift、PasteCoordinator.swift、HistoryViewModel.swift、HistoryView.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M11 联合筛选与键盘搜索**
  - 依赖：M01、M05。
  - 目标：类型／来源／日期／多分类组合、可移除标签、本地元数据建议和Cmd-F／Tab／Return流程。
  - 文件：Domain.swift、HistoryStore.swift、HistoryViewModel.swift、HistoryView.swift、SearchField.swift。
  - 完成条件：类型不再清分类；字面搜索保留；分页签名覆盖所有条件；无OCR、标题或AI查询。

  - 执行：Codex；实现完成。实际修改：Domain.swift、HistoryStore.swift、HistoryViewModel.swift、HistoryView.swift、SearchField.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M12 跳回历史和分类上下文**
  - 依赖：M11、M04。
  - 目标：从结果定位原历史／分类及条目，支持Cmd-G和菜单入口。
  - 文件：HistoryStore.swift、HistoryViewModel.swift、HistoryView.swift。
  - 完成条件：按ID定位而非陈旧偏移；删除／到期后跳转失败不会重新展示记录。

  - 执行：Codex；实现完成。实际修改：HistoryViewModel.swift、HistoryView.swift、AppDelegate.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M13 富格式、图片和文件预览**
  - 依赖：M07、M10。
  - 目标：富文本显示、完整图片、文件Quick Look和Space入口；HTML仅本地渲染。
  - 文件：HistoryView.swift、ContentDecoder.swift及新增必要的原生预览桥。
  - 完成条件：不执行HTML脚本或加载远端资源；详情按需读；PDF文件预览不被记录为原生PDF／RTFD采集支持。

  - 执行：Codex；实现完成。实际修改：新RichContent.swift、HistoryViewModel.swift、HistoryView.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M14 全宽可调面板与稳定布局**
  - 依赖：M04、M05、M11、M13。
  - 目标：底部全宽、高度调节／紧凑卡片、多屏定位、半透明和操作栏稳定；保持类型与自定义标签同行。
  - 文件：AppDelegate.swift、HistoryView.swift、HistoryBackdrop.swift、HistoryScrollWheel.swift。
  - 完成条件：先定frame后布局；不变任意浮动窗口；滚轮／Escape／失焦／显隐切换和拖拽保护仍存在；不凭代码宣称不闪烁。

  - 执行：Codex；实现完成。实际修改：AppDelegate.swift、HistoryView.swift、HistoryViewModel.swift（保留现有HistoryBackdrop.swift与HistoryScrollWheel.swift）。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M15 设置与快捷键完整化**
  - 依赖：M01、M07、M14。
  - 目标：数字快捷粘贴、分类切换、新分类、默认格式、永久历史、定时暂停、音效、菜单栏图标和面板高度设置。
  - 文件：SettingsView.swift、CaptureCoordinator.swift、HotKeyService.swift、AppDelegate.swift、Schema.swift。
  - 完成条件：永不过期不等于无限容量；暂停不补采；快捷键冲突明确；隐藏图标后仍可唤起；登录项审批仍由用户控制。

  - 执行：Codex；实现完成。实际修改：SettingsView.swift、CaptureCoordinator.swift、AppDelegate.swift、Domain.swift、Schema.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M16 显示隐私与共享边界**
  - 依赖：M14、M15。
  - 目标：手动隐藏／模糊，核对macOS15公开共享限制并在支持范围内接入设置。
  - 文件：AppDelegate.swift、HistoryView.swift、SettingsView.swift、交付限制说明。
  - 完成条件：不申请录屏权限监看屏幕，不用失焦冒充共享检测；不能保证的捕获方式明确记录；不虚构“所有录屏都不可见”。

  - 执行：Codex；实现完成。实际修改：AppDelegate.swift、新RichContent.swift、HistoryViewModel.swift、SettingsView.swift、交付说明；依据当前SDK的NSWindow.h公开sharingType字段。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M17 浏览和写入路径优化**
  - 依赖：M06、M09、M11、M14。
  - 目标：轻选择、稳定差分、批量SQL／提交、取消旧异步任务、后台预览和临时文件处理；可选无内容计时。
  - 文件：HistoryViewModel.swift、HistoryView.swift、ThumbnailRenderer.swift、HistoryStore.swift、CommitStrategy.swift。
  - 完成条件：不取消完整校验／同步／物理计量，不先删旧；无本轮P95或FPS测量声明；历史样本不冒充优化后实测。

  - 执行：Codex；实现完成。实际修改：新StageTiming.swift、HistoryStore.swift、HistoryViewModel.swift、HistoryView.swift、CaptureCoordinator.swift、PasteCoordinator.swift、延迟拖放桥。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M18 采集与删除闭环收敛**
  - 依赖：M02、M03、M06、M08、M09、M17。
  - 目标：统一所有入库／恢复／临时输出／删除入口的策略、revision、标记和生命周期。
  - 文件：CaptureCoordinator.swift、MacPasteboardClient.swift、HistoryStore.swift、ThumbnailRenderer.swift。
  - 完成条件：敏感先过滤、未知基线、自身写入精确过滤、多项顺序、相同字不同格式不错误去重；不宣称200ms轮询捕获所有50ms变化。

  - 执行：Codex；实现完成。实际修改：HistoryStore.swift、ClipExportAccess.swift、CaptureCoordinator.swift、MacPasteboardClient.swift、HistoryViewModel.swift、ContentExportProvider.swift。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M19 用户自测清单与限制**
  - 依赖：M00；最终整理依赖M18。
  - 目标：简短中文自测说明，涵盖真实接收、Finder、长历史、多选、分类保护、预览、权限和新目录。
  - 文件：本目录用户自测说明及macos-app/docs当前交付说明。
  - 完成条件：没有虚假通过；不要求用户执行开发脚本；明确旧记录不会自动迁入；旧AC未执行项保留。

  - 执行：Codex；实现完成。实际修改：user-checklist.md、macos-app/docs/local-experience-delivery.md；旧AC／兼容／性能／限制／接口文档增加版本边界说明。
  - 编译／证据：Release增量构建已通过；统一最终命令、退出结果与文件身份在M20记录，证据目录`macos-app/evidence/delivery/local-experience/`。功能、真实应用及性能：用户待自测（本轮未执行）。

- [x] **M20 Release构建及产物检查**
  - 依赖：M15、M16、M18、M19。
  - 目标：完整Release .app，检查资源、架构、Info.plist和签名；生成当前构建／源码身份记录。
  - 文件：scripts/build-app.sh、Resources/Info.plist、dist/LocalClip.app、evidence/delivery/local-experience/。
  - 完成条件：真实构建退出0；资源齐全；主程序与版本一致；不跑产品测试、不自动启动、不安装、不发布。

  - 执行：Codex；最终Release构建完成，命令`rtk proxy bash macos-app/scripts/build-app.sh release`退出0，25.18秒；产物为0.2.0（16）。
  - 实际修改／产物：Resources/Info.plist、dist/LocalClip.app；证据`macos-app/evidence/delivery/local-experience/release-build.log`与`artifact-checks.json`。
  - 静态检查：plutil-lint、codesign --verify --deep --strict、file、lipo、otool及Info.plist读取均退出0；arm64、最低macOS15.0、ad hoc签名、图标资源齐全。工具链Swift6.2.4，SDK26.2，构建主机macOS15.7.5（24G624）。SwiftPM用户级配置／安全缓存只读警告，不影响本地构建。未启动应用或运行产品测试。

- [x] **M21 源码归档与直接交付**
  - 依赖：M20。
  - 目标：完整源码包、复现命令、最终tasks状态和简短中文交付消息，直接提供.app路径。
  - 文件：dist/LocalClip-source.tar.gz、本任务清单、交付说明及哈希记录。
  - 完成条件：归档不含用户／测试数据库、缓存或Paste资源；明确“开发打包完成，用户验收待执行”；不以未自测为由扣留.app或再次询问是否继续。

  - 执行：Codex；源码白名单归档与文件身份记录完成。实际修改：scripts/package-source.py、README.md、当前交付说明、tasks.md；产物`macos-app/dist/LocalClip-source.tar.gz`。
  - 归档命令`rtk proxy python3 macos-app/scripts/package-source.py`；结果和完整成员清单见`evidence/delivery/local-experience/source-archive.json`、`source-archive-members.txt`、`delivery-manifest.json`。
  - 未包含数据库、缓存、历史验收内容、应用／探针二进制或Paste资源。只归档源码、原有测试源码、资源、脚本与当前计划／说明；测试源码保留并同步当前接口，本轮未编译或运行测试目标。源码归档不认证功能正确性；应用、源码与说明直接交付，用户待自测。

## 任务证据模板

```text
任务：Mxx
状态：未开始／进行中／实现完成／受阻
实际修改文件：
编译或产物检查命令：
退出码与结果：
记录／产物路径：
功能、真实应用及性能验收：用户待自测（本轮未执行）
限制／与计划差异：
```

只有M20记录构建与产物检查；其他任务不需要重复全量构建或增加测试流程。必要的增量编译可随实现执行，失败应修复后继续。

## 本轮执行约束更新

2026-10-10：用户明确按全新开发处理，旧剪贴板历史无需保留。当前仍采用schema3与LocalClip-LocalEdition；不编写兼容、迁移、回填或旧接口包装。所有功能／真实目标应用／性能验收均由用户自测。

M00–M19：负责人Codex，实现完成，Release增量编译通过。M20/M21完成最终构建／静态产物检查／白名单归档；源码未经过本轮产品测试。
