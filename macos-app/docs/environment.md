# T00 实施环境

2026-10-09：macOS 15.7.5 (24G624)，Apple M2 Max，12核，32GB。
Swift 6.2.4 (swiftlang-6.2.4.1.4)，arm64-apple-macosx15.0。
CLT `/Library/Developer/CommandLineTools`，SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`。
无完整 Xcode；不宣称执行 XCUITest。当前机器属于 macOS 15，其他 15.x 补丁和 macOS 26 未执行。

项目原只有 paste-report，无应用工程或 Git。未找到磁盘 AGENTS.md；采用会话AGENTS与RTK；执行沟通按后续明确指令使用English，产品/文档保留中文。
PRD SHA256 与入口绑定值一致：8045343ff184d857b932cbc7bbf6c8da8c6f8ff670ac21aed14ec87a0b760fa3。
未读取 Paste.app 或用户 Paste 数据。所有测试均使用合成内容。
