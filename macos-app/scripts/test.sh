#!/bin/bash
# 隔离 Swift 缓存并保存完整测试证据，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.cache/swift"
mkdir -p "$root/evidence/automated"
# 并行构建可在同一秒启动；唯一目录防止性能tee覆盖功能回归证据。
output="$(mktemp -d "$root/evidence/automated/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
# 框架路径只有此入口负责；Xcode与CLT采用各自实际存在的目录，by AI.Coding。
developer="$(xcode-select -p)"
frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
if [ ! -d "$frameworks" ]; then frameworks="$developer/Library/Developer/Frameworks"; fi
if [ ! -d "$frameworks" ]; then echo "Swift Testing framework directory unavailable" >&2; exit 1; fi
{
  sw_vers
  swift --version 2>&1
  printf 'Developer directory: %s\nFramework directory: %s\n' "$developer" "$frameworks"
} > "$output/environment.txt"
# 桌面测试共享前台焦点与CPU，并行会互相抢焦点、拖慢等待超时；开启交互测试时串行，by AI.Coding。
if [ "${LOCALCLIP_INTERACTIVE_TESTS:-}" = "1" ]; then set -- --no-parallel "$@"; fi
run_tests() {
  swift test -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" --disable-xctest --enable-swift-testing --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" "$@"
}

run_plan() {
  if [ "$#" -ne 0 ]; then
    run_tests "$@"
    return
  fi
  # 默认全量保留其他套件的并行度，真实写盘的采集用例单独运行，保留原等待上限，by AI.Coding。
  local suite='ExcludedDepartureCaptureTests' parallel_status=0 isolated_status=0
  run_tests --skip "$suite" || parallel_status=$?
  run_tests --skip-build --no-parallel --filter "$suite" || isolated_status=$?
  if [ "$parallel_status" -ne 0 ]; then return "$parallel_status"; fi
  return "$isolated_status"
}

set +e
run_plan "$@" 2>&1 | tee "$output/swift-test.log"

status=${PIPESTATUS[0]}
set -e
python3 "$root/scripts/summarize-tests.py" "$output" "$status"
exit "$status"
