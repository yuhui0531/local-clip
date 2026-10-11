#!/usr/bin/env python3
"""仅归档明确的当前源码与交付材料，不扫描历史数据目录，by AI.Coding。"""
from pathlib import Path
import hashlib
import json
import tarfile

APP = Path(__file__).resolve().parents[1]
PROJECT = APP.parent
DESTINATION = APP / "dist/LocalClip-source.tar.gz"


def main() -> None:
    # 白名单只包含编译输入、原有测试源码和当前实施文档；不打包历史验收数据。
    files = [APP / "Package.swift", APP / "README.md", APP / "docs/local-experience-delivery.md", APP / "docs/code-features-delivery.md", APP / "docs/review-fixes.md", APP / "docs/scaling-drag-focus-checks.md", APP / "docs/progressive-history-loading.md", APP / "docs/category-drop-routing.md", PROJECT / "changes/active/localclip-review-fixes/debug-log-2026-10-11-category-drop-routing.md", PROJECT / "changes/active/localclip-review-fixes/debug-log-2026-10-11-progressive-loading-category-drop.md", PROJECT / "changes/active/localclip-review-fixes/debug-log-2026-10-11-scaling-drag-focus.md", PROJECT / "changes/active/localclip-review-fixes/debug-log-2026-10-11-review-fixes.md"]
    for folder in ("Sources", "Tests", "Resources", "scripts"):
        files.extend(path for path in (APP / folder).rglob("*") if path.is_file()
                     and not any(part.startswith(".") for part in path.relative_to(APP).parts)
                     and path.suffix not in {".sqlite", ".db", ".pyc"})
    extra_doc = PROJECT / "changes/active/localclip-review-fixes/debug-log-2026-10-11-newest-first-order.md"
    if extra_doc.is_file():
        files.append(extra_doc)
    files.extend((APP / "docs/review-fixes-r01-r12.md",
                  PROJECT / "changes/active/localclip-review-r01-r12/tasks.md"))
    plan = PROJECT / "paste-report/implementation-plan-2026-10-10"
    files.extend(plan / name for name in ("README.md", "tasks.md", "report-coverage.csv", "user-checklist.md", "debug-image-drag-2026-10-11.md", "debug-log-2026-10-11-code-file-paste.md"))
    DESTINATION.parent.mkdir(exist_ok=True)
    with tarfile.open(DESTINATION, "w:gz") as archive:
        for path in sorted(set(files)):
            archive.add(path, arcname="LocalClip-source/" + path.relative_to(PROJECT).as_posix(), recursive=False)
    print(json.dumps({"path": str(DESTINATION), "files": len(set(files)), "bytes": DESTINATION.stat().st_size,
                      "sha256": hashlib.sha256(DESTINATION.read_bytes()).hexdigest(),
                      "excluded": "用户及测试数据库、历史验收数据、缓存、应用与探针二进制、Paste资源"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
