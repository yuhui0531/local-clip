# 历史切换、闪烁与键盘删除排查（0.1.12）

PROJECT_ROOT：/Users/ronny/VscodeProjects/rea
CHANGE_DIR：/Users/ronny/VscodeProjects/rea/paste-report/development-plan

- [x] 阅读HistoryViewModel.select/change、HistoryView/ClipCard、AppDelegate.showHistory/pinPanel/installKeyboard、SearchField、HistoryScrollWheel、DerivedContentService与HistoryStore.detail/readPayload。
- [x] 假设：切换成本来自原始读取。代码确认每次选择invalidateDetail→store.detail→readPayload全格式字节校验/哈希→图片派生→再detail校验。派生与卡片也再次detail复查。置信度高；实际占比未测。
- [x] 质疑：完整恢复需要校验，不代表高亮/分类菜单需要载荷。分离metadata与恢复不降低原始内容要求。改metadata，仅详情展开/恢复读取完整内容，图片展示复查轻量可见性。
- [x] 假设：整排刷新与滚动动画影响流畅性。ClipCard观察整个模型，详情/状态发布影响全部卡片；每次选择scrollTo动画。改Equatable纯显示比较、去掉每卡片模型订阅，仅越界定位，无叠加动画；同次采集单路刷新。
- [x] 假设：右侧闪烁与尺寸/条件视图相关。窗口先1400pt挂载再全宽、右侧动作从空态到有选中项整体替换、spinner挤占位置、磨砂跟随key状态。改最终尺寸创建与显示前布局、保留操作栏与spinner空间、active behindWindow背景。置信度中；未复现GUI，不认定它们是唯一根因。
- [x] 键盘：51/117及native delete命令复用deleteSelected；非空搜索/marked text保留编辑，按键重复不连发；原确认保留。确认后仅撤销目标，提交前后作废旧查询，失败重查；不独立直接删库。
- [x] 布局：490→380pt，250×263→250×200pt，工具栏/分类条/预览压缩；背景alpha0.78，内容不降透明度，系统降低透明度使用1。
- [x] 自检：对症、修改仅浏览/选择/背景/删除事件；复用SQLite候选事务、原格式恢复与查询版本；没有额外数据库/权限/网络。中文注释已补，不用假定运行测试结果认证性能。metadata纯文本资格按每项文本表示判断，最终转换仍检查原载荷。
- [x] Release构建/严格签名：退出0，21.097秒；初次Equatable隔离失败日志保留，nonisolated比较纯值后通过。
- [ ] 功能/真实SQLite故障/GUI/视觉/性能测试：按用户此前停止自动测试要求，均未执行。无新的性能样本、P95、FPS或CPU/内存数据。仍待用户实测。

证据：[构建结果](../../macos-app/evidence/automated/20261010-panel-performance/build-result.json)、[源码快照](../../macos-app/evidence/automated/20261010-panel-performance/build-source-hashes.json)。
