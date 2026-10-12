# 单实例接替实现记录（0.1.9）

用户要求：新打开实例自动关闭旧实例，同一时间只启用一个LocalClip。

实现：SingleInstanceService在历史库、采集和快捷键之前执行。按bundle ID筛选同一用户的GUI进程，请求旧实例正常退出并确认isTerminated；启动时间/PID决定并发启动中最新实例。随后用fcntl/F_SETLK取得进程生命周期的独占POSIX记录锁，O_CLOEXEC防止重开继承锁；不删除空控制文件，不在退出回调提前释放。旧版不持锁时也必须先等待退出。最多等待6秒，失败提示且新实例退出。没有强杀旧进程。

macOS可能复用运行进程处理重新打开：AppDelegate通过NSWorkspace.OpenConfiguration.createsNewApplicationInstance显式启动同应用新实例，参数--show-history，成功后旧实例退出。新实例完成模型启动后展示面板。第一次升级仍需open -n启动新版，旧进程不具备这个处理逻辑。菜单与快捷键不触发重新启动。

范围：同bundle ID的GUI应用副本共用接替机制，包含Debug GUI；Debug CLI探针不经过AppDelegate。接替中有短暂等待进程，不启用第二套历史服务。已运行新版之后再强制启动旧代码的行为不由新版控制。

验证：仅源码/本机SDK接口检查和Release构建/签名；没有启动应用或操作用户进程，没有执行单实例/真实应用/性能测试。构建退出0，16.506秒。首次错误：Darwin.flock在Swift SDK为结构体，改用fcntl记录锁；原失败日志保留。

构建命令：`rtk proxy env LOCALCLIP_BUILD_PATH=/Users/ronny/VscodeProjects/rea/macos-app/.build-release-prefetch-20261010 bash macos-app/scripts/build-app.sh release`。

首次升级运行命令（未执行）：`rtk proxy open -n /Users/ronny/VscodeProjects/rea/macos-app/dist/LocalClip.app --args --show-history`。

证据：成功构建、构建日志、初次失败、源码快照。
