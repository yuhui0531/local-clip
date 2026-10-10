# 2026-10-10 历史面板失焦关闭（0.1.7）

项目 `/Users/ronny/VscodeProjects/rea`；变更记录 `paste-report/development-plan`。用户要求失去焦点后自动关闭。

- [x] 检查非激活NSPanel：不能用NSApp.isActive作为失焦依据，否则面板刚打开就可能关闭。
- [x] 监听本应用key窗口转移/关闭，等待60ms让新的第一响应窗口稳定后核对面板及其窗口关系；点击原目标应用的另一窗口也可走失焦关闭。
- [x] 外部应用身份变化时关闭并作废旧粘贴目标；关闭不抢回焦点、不写剪贴板、不改变采集。
- [x] 菜单跟踪期间暂缓检查，菜单结束后重查；详情呈现状态同步到model，详情接管key窗口时保留历史，详情关闭后重查。确认对话框期间允许完成/取消原操作；打开设置仍关闭历史。
- [x] 统一主动关闭入口同步隐藏详情；重新打开清理旧呈现状态；退出取消任务并释放所有观察者。
- [x] Release构建及ad hoc严格签名检查；未启动应用、操作桌面或执行真实焦点/菜单/详情测试。

修改 `macos-app/Sources/LocalClipMac/UI/{AppDelegate.swift,HistoryView.swift,HistoryViewModel.swift}`、`Resources/Info.plist`、README/docs/tasks。真实窗口系统行为与内部菜单/详情保护待用户自测，不能因构建通过宣布实际验收完成。

```sh
rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release
```

证据：[构建结果](../../macos-app/evidence/automated/20261010-focus-dismissal/build-result.json)、[构建日志](../../macos-app/evidence/automated/20261010-focus-dismissal/release-build.log)、[源码快照](../../macos-app/evidence/automated/20261010-focus-dismissal/build-source-hashes.json)。
