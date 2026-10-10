# 图片拖动闪退诊断记录

PROJECT_ROOT：/Users/ronny/VscodeProjects/rea
CHANGE_DIR：/Users/ronny/VscodeProjects/rea/paste-report/implementation-plan-2026-10-10（已有用户授权实施目录）

症状：0.2.2开始拖动图片时退出，三个系统报告一致。根因置信度高：报告主线程固定落在Swift合成ImageWriter.init trap，便利初始化路径动态调用子类未实现init；本机AppKit头文件确认init是指定初始化器。真正问题是初始化方式，保留图片拖动和文件promise；并非取消用户需求或换存储方案。

修正：ContentExportProvider.swift用super.init()后赋fileType和delegate，owner强引用保持delegate。没有兼容／迁移代码。界面由HistoryView.swift／HistoryScrollWheel.swift优化；Debug隔离验证由VisualProbe.swift和main.swift提供。

验证：实际AppKit6个writer创建完成；PNG原始载荷可解码，真实promise delegate在磁盘写出完全一致的PNG。实际SwiftUI三个尺寸／主题像素检查通过，Release0.2.3（19）构建／签名／资源／架构通过。测试fixture最初因预先暂停导致入库被正常策略拒绝，改为合成入库后暂停；私有receiver未回调，改验delegate并明确证据边界；最小卡片排版根据实际图像修正后重渲染。未放宽生产鼠标状态检查。

阻塞：CUA.drag只发送down/up且buttons=0，没有leftMouseDragged，原生会话未开始，不能声称真实鼠标或Finder兑现通过。Release启动误用了Debug专用目录变量，UI读取超时；已停止相关进程，该启动不能算隔离验收。详细原始证据与命令：macos-app/evidence/delivery/local-experience/ui-023/verification.md。未运行其余完整验收或性能基准。
