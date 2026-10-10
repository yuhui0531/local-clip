#!/bin/bash
# 隔离 Swift 缓存并保存完整测试证据，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.cache/swift"
mkdir -p "$root/evidence/automated"
# 并行构建可在同一秒启动；唯一目录防止性能tee覆盖功能回归证据。
output="$(mktemp -d "$root/evidence/automated/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
swift test -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" --disable-xctest --enable-swift-testing --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" "$@" 2>&1 | tee "$output/swift-test.log"
