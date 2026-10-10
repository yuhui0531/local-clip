# T03 存储可行性

实际执行：`rtk proxy bash macos-app/scripts/test.sh`。完整输出在 evidence/automated 各运行目录。

使用生产 CommitStrategy、临时真实 SQLite 文件、DELETE journal、synchronous FULL、foreign_keys ON、auto_vacuum FULL，均读回校验。
源库所有连接关闭后优先 APFS clonefile 生成独立候选；不支持 clone 时回退 SQLite backup。候选内变更与回收，完整 quick_check / FK校验后关闭、实际计量、fsync/F_FULLFSYNC、同卷 rename 提交、目录fsync。重开核对候选预期的 storeRevision 和 lastOperationID；提交点后的不可用单独报告，不能假称已回滚或重放新增。

实际500MiB场景：490MiB不可释放载荷、5MiB普通载荷，原库520,192,000字节；新增20MiB，即便只在候选删除普通载荷仍超配额。拒绝后原库字节和两条旧记录保持。
候选创建/写入/校验/替换前注入 diskFull：原库字节保持。六个生产断点对子进程实际 SIGKILL：提交点前完整旧态，提交点后完整新态；重开 integrity_check=ok。
共享载荷不重复保存，删除普通引用保留收藏引用。计量枚举实际常规文件，取逻辑长度与 allocated size 中较大值；纳入journal、SQLite页及待回收目录。枚举失败抛错，不当作零。单字节文件的实际分配块也已验证。APFS共享块不能精确拆成独占物理空间，因此采用保守计量，不声称磁盘全局去重后的独占块精确值。实际回收按前后计量差报告；候选+journal工作空间峰值单独报告。

正常事务快路径未启用：当前没有可证明的 journal 最坏预算，依计划统一使用候选路径。候选慢路径会进入性能报告，不删慢样本。可用盘预算检查为3×旧库+3×新增估计+8MiB；活跃候选是临时工作空间，失败后清理失败则计待回收。物理空间不足只拒绝，不先删除旧内容。
这里只证明该 APFS / macOS 环境的实际测试；不宣称硬件掉电测试或法证擦除。

最终功能证据：[完整回归](../evidence/automated/20261010-094103-6SMysd/swift-test.log)。AC17实际原库520,192,000字节，限制524,288,000字节；拒绝后哈希相同。12个真实子进程终止覆盖通用候选与生产HistoryStore两组各6断点，生产组包含必须淘汰普通记录的新内容，并检查收藏、BLOB、FK和配额；证明容量控制和失败保留旧内容同时成立。

canCapture：当前总量达到配额时，在一次可丢弃的真实候选中移除普通内容和派生缓存，计算受保护剩余库与pending是否仍占满。原库不变化、不提交、不递增revision、不发布事件。真实全满可释放库与收藏超额用例已验证；过大单条拒绝不阻断随后小条目。最终回归新增capacityProbePreservesReleasableFullStore和largeRejectionAllowsSmallNextCopy。
