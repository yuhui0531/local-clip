#!/bin/bash
# 专用命名剪贴板压力和空闲测量，完全隔离general与用户历史，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
: "${LOCALCLIP_BENCHMARK_FIXTURE:?set to a completed performance run directory}"
run="$(date -u +%Y%m%dT%H%M%SZ)-system"
output="$root/evidence/performance/$run"
mkdir -p "$output"
export LOCALCLIP_SYSTEM_BENCHMARK=1 LOCALCLIP_BENCHMARK_OUTPUT="$output"
bash "$root/scripts/test.sh" -c release --filter SystemBenchmarkTests "$@" 2>&1 | tee "$output/benchmark.log"
printf '%s\n' "$output"
