# 2026-10-10 历史滚动与Esc关闭（0.1.6）

项目根目录 `/Users/ronny/VscodeProjects/rea`；关联变更记录目录 `paste-report/development-plan`。

用户要求：触控板和鼠标滚轮均可左右浏览历史；Esc关闭面板；记录多时能选择较早内容。本轮继续按用户此前要求自行测试，不接管电脑或启动应用验收。

## 排查与修复

- [x] `HistoryView` 原来只有水平SwiftUI ScrollView，普通垂直鼠标滚轮没有横向转换，滚动条隐藏；仅页尾按钮显式读取下一页。
- [x] `AppDelegate.installKeyboard` 和 `SearchField` 都在取消命令之前检查中文组合输入，Esc可能只交给输入法；非激活面板事件还可能缺少event.window。
- [x] 增加仅限历史卡片视口的本地滚轮适配：横向触控板/鼠标事件继续交系统，保留惯性和自然方向；纵向滚轮及纵向触控板精确delta通过macOS15的ScrollPosition变为横向位移。离散滚轮按行换算；持续事件累加尚未渲染的偏移，真实几何限制首尾。背景显式覆盖视口且不命中点击，移除列表时卸载监听。
- [x] 保留SwiftUI ScrollView/LazyHStack与按条目ID的键盘选择定位；不改成一次渲染所有历史。几何同步使用引用状态，避免原生横向手势每帧更新整排卡片的SwiftUI状态。滚动条可见；接近页尾六张卡或尾部按钮出现时，调用原分页接口自动预读。分页保留queryID/storeRevision校验和loading防重复，不改变选择。
- [x] Esc在本地键盘监视中优先于修饰键/组合输入过滤；限当前面板/子窗口或无窗口事件但面板为key时。搜索框cancelOperation先关闭，窗口cancelOperation/keyDown兜底。Enter与方向键仍尊重中文组合输入，其他应用与设置窗口不被截获。
- [x] Release构建及ad hoc严格签名检查；未执行真实设备滚动、输入法、分页或性能验证。

根因链：只能横向原生滚动→普通鼠标发纵向事件→列表不动；页尾显式翻页增加访问障碍。Esc先检查marked text→取消关闭操作未执行。修复各自事件入口及分页触发，不更改存储/格式/粘贴行为。

修改：`macos-app/Sources/LocalClipMac/UI/{HistoryScrollWheel.swift,HistoryView.swift,AppDelegate.swift,SearchField.swift}`、`Resources/Info.plist`、README/docs及任务记录。

```sh
rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release
```

证据：[构建结果](../../macos-app/evidence/automated/20261010-history-scroll-escape/build-result.json)、[构建日志](../../macos-app/evidence/automated/20261010-history-scroll-escape/release-build.log)、[源码快照](../../macos-app/evidence/automated/20261010-history-scroll-escape/build-source-hashes.json)。源码自检确认事件仅限视口/面板，点击双击不被消费、边界有限、监听释放、分页沿用旧失效保护；未将这些检查当成实际设备验收。
