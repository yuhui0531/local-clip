#!/usr/bin/env python3
"""发布需当前SHA的原生验收证据或明确豁免，不以默认CI通过替代，by AI.Coding。"""
import json
import os
import sys

try:
    record = json.loads(os.environ.get("LOCALCLIP_NATIVE_ACCEPTANCE", ""))
    valid = (isinstance(record, dict)
             and record.get("sha") == os.environ["GITHUB_SHA"]
             and record.get("disposition") in ("passed", "waived")
             and isinstance(record.get("evidence"), str) and bool(record["evidence"].strip())
             and isinstance(record.get("reviewer"), str) and bool(record["reviewer"].strip()))
    if not valid:
        raise ValueError("Incomplete native acceptance")
except (ValueError, KeyError, TypeError):
    sys.exit("Native GUI/permission/performance acceptance missing for this SHA. Record passed evidence or an explicit reviewed waiver in LOCALCLIP_NATIVE_ACCEPTANCE.")
summary = f"Native acceptance: {record['disposition']}\nReviewer: {record['reviewer']}\nEvidence/reason: {record['evidence']}\n"
if path := os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(path, "a") as target:
        target.write(summary)
print(summary)
