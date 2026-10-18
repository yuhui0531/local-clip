#!/usr/bin/env python3
# 只计算发布构建输入指纹，阻止已有旧/Debug 包冒用新版本名，by AI.Coding。
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
files = [root / "Package.swift", root / "scripts/build-app.sh", Path(__file__).resolve()]
for directory in ("Sources", "Resources"):
    files.extend(path for path in (root / directory).rglob("*") if path.is_file())
digest = hashlib.sha256()
for path in sorted(files):
    digest.update(str(path.relative_to(root)).encode() + b"\0")
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
