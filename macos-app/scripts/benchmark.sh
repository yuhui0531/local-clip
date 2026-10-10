#!/bin/bash
# 仅合成fixture及独立SQLite，保留性能原始样本，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
run="$(date -u +%Y%m%dT%H%M%SZ)-${LOCALCLIP_BENCHMARK_PHASE:-final}"
output="$root/evidence/performance/$run"
mkdir -p "$output"
export LOCALCLIP_BENCHMARK=1 LOCALCLIP_BENCHMARK_OUTPUT="$output"
sw_vers > "$output/environment.txt"
sysctl -n machdep.cpu.brand_string hw.memsize >> "$output/environment.txt" 2>&1 || printf '%s\n' 'sysctl unavailable in sandbox; hardware baseline in docs/environment.md' >> "$output/environment.txt"
xcrun swift --version >> "$output/environment.txt"
bash "$root/scripts/test.sh" -c release --filter BenchmarkTests "$@" 2>&1 | tee "$output/benchmark.log"
printf '%s\n' "$output"
