# 2026-10-10 原生粘贴被文本角色限制拦截（0.1.5）

项目根目录 `/Users/ronny/VscodeProjects/rea`；变更目录 `paste-report/development-plan`。关联用户已授权的双击自动粘贴扩展，本次无需重规划或要求用户再次确认范围。

## 排查与依据

- [x] 阅读用户截图：提示为“已复制，目标控件不是可识别的文本输入框，请手动粘贴”，用户说明正在使用文本编辑器。
- [x] 搜索该固定文字，唯一拒绝分支为 `MacApplicationClient.isPasteFocusReady` 的 AX 角色白名单。
- [x] 核对调用链：复制原格式→关闭面板→等待原焦点→角色不匹配返回 false→超时回退；因此这次截图显示的是发送前主动拦截，不是接收失败的证明。
- [x] 质疑根因：原生 Command-V 应由目标应用处理；实现误把 textarea 示例当成适用范围。编辑器、自绘控件、富文档、图片画布等不能靠 TextArea/TextField/ComboBox 或 AXIsEditable 判断是否支持粘贴。这是实现门槛错误，用户也明确要求更广目标范围；置信度高。
- [x] 移除文本角色白名单及 AXIsEditable/AXValue 条件，核对生产 Sources 中无其他同类粘贴筛选。原应用身份、原 AX 焦点相等、权限、明确禁用状态、剪贴板收据与发送前复核保留。
- [x] 完成 Release 构建、ad hoc 签名及严格签名检查；未运行目标接收、功能或性能测试。

## 修复与边界

双击原格式恢复后，向原应用原焦点发送一次 Command-V。无应用名单或文本角色限制；目标应用自行决定接收格式、位置和行为。Finder 文件对象仍按原有目录核对/副本复制流程处理。去掉提示中的“输入框”假设，改用“目标应用/原目标焦点”。正常发送保持静默，仅失败或回退提示。

原 AX 焦点不能读取、已变化、目标退出/切换、明确禁用、缺权限或剪贴板变化时仍安全回退，不猜测新的目标位置。移除角色错误门槛不等于已证明所有应用兼容；当前文本编辑器的实际接收仍由用户验证。本次没有启动/重启应用、操作鼠标键盘、查询输入框正文或读取用户历史。

修改文件：`macos-app/Sources/LocalClipMac/{System/MacApplicationClient.swift,Features/PasteCoordinator.swift,UI/HistoryViewModel.swift,UI/HistoryView.swift}`、`macos-app/Resources/Info.plist`、README/docs与开发计划追加记录。

```sh
rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release
```

证据：[用户截图](../../macos-app/evidence/automated/20261010-generic-paste-target/user-reported-editor-rejection.png)、[构建结果](../../macos-app/evidence/automated/20261010-generic-paste-target/build-result.json)、[构建日志](../../macos-app/evidence/automated/20261010-generic-paste-target/release-build.log)、[源码快照](../../macos-app/evidence/automated/20261010-generic-paste-target/build-source-hashes.json)。

出口自检：对症性（移除错误分类门槛）、冗余性（直接删去分类代码）、范围（粘贴判断/措辞）、过度修改（无额外机制）、中文注释、复杂度（减少判断）均通过源码自检，不冒充运行测试。
