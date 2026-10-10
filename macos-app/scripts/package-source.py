#!/usr/bin/env python3
"""Package reproducible source and evidence, excluding generated databases/binaries."""
from pathlib import Path
import hashlib
import json
import tarfile

APP = Path(__file__).resolve().parents[1]
PROJECT = APP.parent
DESTINATION = APP / "dist/LocalClip-source.tar.gz"
DATABASE_DIRECTORIES = {"fixture-store", "working-store", "quota-store", "store", "isolated-data"}
PROBE_BINARIES = {"probe", "sql-probe", "rowid-probe"}


def included(path: Path) -> bool:
    relative = path.relative_to(APP)
    if any(part.startswith(".") or part.endswith(".app") or part in DATABASE_DIRECTORIES for part in relative.parts):
        return False
    if path.name in PROBE_BINARIES or ".sqlite" in path.name:
        return False
    # An archive cannot contain its own hash. The external delivery manifest is separate.
    return relative.as_posix() != "evidence/automated/delivery/delivery-manifest.json"


def main() -> None:
    files = [APP / "Package.swift", APP / "README.md"]
    for folder in ("Sources", "Tests", "Resources", "Fixtures", "scripts", "docs", "evidence"):
        files.extend(path for path in (APP / folder).rglob("*") if path.is_file() and included(path))
    files.append(PROJECT / "paste-report/PRD-macOS剪贴板管理器-2026-10-09.md")
    files.extend(path for path in (PROJECT / "paste-report/development-plan").rglob("*") if path.is_file())
    DESTINATION.parent.mkdir(exist_ok=True)
    with tarfile.open(DESTINATION, "w:gz") as archive:
        for path in sorted(set(files)):
            archive.add(path, arcname="LocalClip-source/" + path.relative_to(PROJECT).as_posix(), recursive=False)
    print(json.dumps({"path": str(DESTINATION), "files": len(set(files)), "bytes": DESTINATION.stat().st_size,
                      "sha256": hashlib.sha256(DESTINATION.read_bytes()).hexdigest(),
                      "excluded": "generated SQLite stores, test app/probe binaries, external self-hash manifest"}))


if __name__ == "__main__":
    main()
