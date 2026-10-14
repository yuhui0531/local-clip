#!/usr/bin/env python3
"""保存真实测试结果与跳过门控，不能把框架总数冒充实际执行数，by AI.Coding。"""
import json
import os
from pathlib import Path
import re
import sys

output, exit_code = Path(sys.argv[1]), int(sys.argv[2])
log = (output / "swift-test.log").read_text(errors="replace")
tests = Path(__file__).resolve().parents[1] / "Tests"
gates = []
for source in sorted(tests.rglob("*.swift")):
    for number, line in enumerate(source.read_text().splitlines(), 1):
        if ".enabled(if:" in line or "LOCALCLIP_" in line:
            gates.append({"file": str(source.relative_to(tests)), "line": number, "gate": line.strip()})
summary = {
    "exitCode": exit_code,
    "passedFunctions": re.findall(r"^✔ Test (?!run with )(.+?) passed after", log, re.M),
    "failedFunctions": re.findall(r"^✘ Test (?!run with )(.+?) failed after", log, re.M),
    "skippedFunctions": re.findall(r"^➜ Test (.+?) skipped\.", log, re.M),
    "frameworkSummary": [line for line in log.splitlines() if "Test run with" in line],
    "enabledGates": {key: value for key, value in os.environ.items() if key.startswith("LOCALCLIP_") and value in ("0", "1")},
    "skipReason": "Environment-gated tests were not enabled; exact conditions are in gateInventory. Skips are not passes.",
    "gateInventory": gates,
}
(output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
print(f"Evidence: {output}; passed functions={len(summary['passedFunctions'])}, failed functions={len(summary['failedFunctions'])}, skipped functions={len(summary['skippedFunctions'])}")
