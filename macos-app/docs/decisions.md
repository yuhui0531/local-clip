# 实施基线

PROJECT_ROOT=/Users/ronny/VscodeProjects/rea，CHANGE_DIR=paste-report/development-plan。
已读 README、PRD、design、tasks、acceptance、RTK。无现有应用代码、SYSTEM-SPEC 或历史 docs/specs。

采用既定 SwiftPM / Swift 6.2 / macOS 15+ arm64 / AppKit / SwiftUI / SQLite。
32项、50MiB、40MP预览界限、200ms采集、默认30天/500MiB、默认复制与登录启动关闭均采用计划。
来源只认声明 org.nspasteboard.source，不用前台应用推断。未知默认记录，排除不覆盖未知。
不引入远程依赖，不访问剪贴板中的链接。候选提交先保证正确性；没有预算证明时不启用普通事务快路径。

> 已被取代：数据库schema v4起写入改为原库单事务，见[architecture.md](architecture.md)。
性能优化的明确差异：候选复制从每次SQLite backup改为APFS clonefile优先，unsupported回退backup；完整候选quick_check/FK、FULL事务、同步与原子替换不变。重开按设计核对revision/operationID，避免重复完整扫描。SQLite可用时启用192MiB mmap以减少扫描复制；不是常驻分配承诺。

字面全文查询的内存派生快照绑定storeRevision：NFC+ASCII标准化后用UTF8 Data字面匹配，仅为内存加速，不是第二份持久存储。缺文本缓存时从完整原始正文恢复。变更立即丢弃旧快照；分页、queryID、详情generation与缩略图revision共同阻止删除内容复活。

用户要求Paste类似界面，采用底部横向卡片代替设计建议的列表/详情分栏，见interface.md。没有访问Paste资源。正式App首次隐私选择持久完成前采集关闭；该安全启动门不改变用户确认后的默认采集行为。

追加修复：所有直接粘贴回退重新检查receipt；容量失败只拒绝当前无法容纳条目，全局暂停依据canCapture真实候选dry-run；到期可见内容使用最近截止时刻任务，移除卡/详情后刷新并作废旧分页。用户再次打开应用走同一showHistory入口。

GC性能修复使用rowid孤儿候选子查询：覆盖digest索引找候选，只读取真实待删正文；NOT EXISTS引用规则保持，包括schema允许的NULL孤儿。没有启用普通事务快路径或跳过quick_check/FK/FULL同步。
