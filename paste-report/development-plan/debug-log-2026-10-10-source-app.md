# 来源全未知排查（0.1.10）

PROJECT_ROOT：/Users/ronny/VscodeProjects/rea
CHANGE_DIR：/Users/ronny/VscodeProjects/rea/paste-report/development-plan

- [x] 阅读MacPasteboardClient、CaptureCoordinator、SourceAttribution/SettingsSnapshot、HistoryView/SettingsView及design 1.2。
- [x] 假设1：图标遗漏。检查结果：卡片已有bundleID→本机APP图标逻辑，但未知来源bundleID为空，没有进入该分支。
- [x] 假设2：归因策略过严。置信度高；适配器仅调用SourceAttribution.declared，没有任何前台fallback，符合旧计划，却无法满足用户现在要求的日常来源展示。未检查用户剪贴板，不宣称所有真实应用都缺标记。
- [x] 质疑链：原计划把展示身份与可靠排除绑定，需求纠正后应分开。已向用户说明具体差异及背景；本次使用用户直接纠正的展示要求，无额外确认。
- [x] 修复：无声明时前台观察；切应用停用时绑定变化计数；冲突/非法声明仍未知。basis=frontmost持久记录且详情/提示说明；basis=declared仍是唯一排除依据。公开AppKit读取APP名称/图标并缓存，不用私有API或读取Paste数据。未补填旧历史。
- [x] 出口自检：对症、范围限于来源展示、复用原schema/去重/搜索/恢复、无新增双存储或权限、不做可靠来源保证、中文注释与方法说明已补。敏感检查依旧先于正文/预览/索引，自写精确count/指纹机制不变。
- [x] Release构建/严格签名：退出0，16.991秒；两次编译失败修复并保留原日志。
- [ ] 单元/真实SQLite/目标应用/性能与实际来源图标验收：按用户停止自动测试要求，均未执行。

根因链：只承认声明→无声明bundleID为空→显示未知→类型图标替代APP图标。修复后只为新复制提供前台推断，已有未知记录不可准确回填；后台写入和快速切换仍有推断误差。没有证明Paste内部采用何种来源接口。

命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`。
证据：[构建结果](../../macos-app/evidence/automated/20261010-source-app/build-result.json)、[构建日志](../../macos-app/evidence/automated/20261010-source-app/release-build.log)、[源码快照](../../macos-app/evidence/automated/20261010-source-app/build-source-hashes.json)。
