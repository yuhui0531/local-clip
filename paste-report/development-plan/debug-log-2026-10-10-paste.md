# 2026-10-10 双击粘贴失败排查（0.1.3）

项目根目录：`/Users/ronny/VscodeProjects/rea`；应用目录：`macos-app`；本次变更记录归入现有 `paste-report/development-plan`，不重新规划工程。

## 用户现象与结论边界

用户报告：在 Codex、Zed 中双击记录后 LocalClip 消失，文本域没有反应；Paste 在相同场景能粘贴。此为用户实际反馈，尚无当前版本的目标接收截图或运行时 AX 状态。本次按用户“自行测试”要求，仅进行代码、SDK、签名/进程元数据检查和 Release 构建，不操作输入框、不读取剪贴板正文、不读取 Paste 历史。

确认三个实现缺陷：把 AXValue setter 能力误作原生粘贴门槛；仅等待前台应用、没有等待输入控件焦点恢复；回退提示在面板关闭后不可见。它们可以解释类似无反应现象，但缺少这次失败的具体阶段日志，不能断言每次都由同一缺陷引起，也不能声称新版已经在 Codex/Zed 实际接收成功。

## 依据与修复

1. 原 `MacApplicationClient` 要求 `AXUIElementIsAttributeSettable(AXValue)` 为 true。系统 SDK `AXAttributeConstants.h` 对 AXValue 明确说明：存在其他直接操作方式时，不必可写。原生 Command-V 不通过 AXValue 替换输入框，因此该门槛错误。移除 setter 条件，仍核对原应用完整身份、同一 AX 控件、输入角色、禁用/只读标记；可选属性缺失不当作 false。判断修复置信度高；Codex/Zed 当次具体 AX 返回值未采集。
2. 原历史面板激活 LocalClip，并立即在原应用前台后发全局 HID 事件。前台身份不能证明键盘焦点已经回到原输入框。改用 AppKit 非激活 key 面板，保留外部应用；关闭后等待同一输入控件连续就绪至少 40ms（总期限 700ms）。原应用已在前台时不重复激活。最后再次核对身份、权限、焦点、剪贴板收据，通过 `CGEvent.postToPid` 向该目标进程发送一次 Command-V，避免全局路由仍落到旧面板。禁止重试发送、任意输入框搜索或抢第三方焦点。SDK `CGEvent.h` 提供该进程投递 API；未实测这次失败是否属于该路由时序。
3. 原回退结果只更新隐藏面板的状态文字。现在显示不激活、不接收鼠标、不抢输入焦点的短暂提示，区分权限、焦点、目标或剪贴板变化及“指令已发送”。发送提示要求用户确认输入框，不能当作接收成功。
4. 排查开始时的 0.1.2 Release 与此前获授权的测试包 ad hoc designated requirement 分别为不同 cdhash，见签名/进程元数据；新 0.1.3 身份另记录在 current-signing-metadata.json。因此旧包授权不能作为当前包权限已有效的证据；但没有在用户运行进程查询 AXIsProcessTrusted，权限原因仍未确认。用户触发粘贴且运行时检查无权限时，调用系统授权提示，授权必须由用户在系统界面完成。

日志只写固定阶段/原因、目标 PID 和是否记住焦点；不记录输入框内容、剪贴板正文、文件路径或 URL。查询方法：

```sh
rtk proxy log show --last 10m --style compact --predicate 'subsystem == "local.localclip.dev" AND category == "Paste"'
```

## 修改与证据

- `LocalClipCore/Domain/Domain.swift`：焦点就绪/失败原因/系统权限提示契约及默认实现。
- `LocalClipMac/System/MacApplicationClient.swift`：焦点书签、可接收输入判断、准确失败原因、受限日志、按 PID 投递与最终复核。
- `LocalClipMac/Features/PasteCoordinator.swift`：权限检查前置、原焦点稳定等待、收据与身份持续复核。
- `LocalClipMac/UI/{AppDelegate.swift,HistoryViewModel.swift}`：非激活历史面板与可见阶段反馈。
- `Resources/Info.plist`：0.1.3（构建4）。

路径均相对 `macos-app/Sources/`，Info.plist 相对 `macos-app/`。

[签名与已有进程元数据](../../macos-app/evidence/automated/20261010-paste-diagnosis/signing-process-metadata.json)；[构建结果](../../macos-app/evidence/automated/20261010-paste-diagnosis/build-result.json)；[构建日志](../../macos-app/evidence/automated/20261010-paste-diagnosis/release-build.log)；[构建源码快照](../../macos-app/evidence/automated/20261010-paste-diagnosis/build-source-hashes.json)。第一次构建的 Swift 6 C 常量并发标注错误日志保留，已通过 `@preconcurrency import ApplicationServices` 修复，AX 调用仍限定主线程。

```sh
rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release
```

仅编译、打包、ad hoc 签名及严格签名检查；未运行功能/真实目标/性能测试。当前用户进程没有被停止或重启；需用户退出旧 LocalClip 后重新打开 `macos-app/dist/LocalClip.app`。Codex/Zed 的实际插入、格式及权限分支仍待用户验证。
