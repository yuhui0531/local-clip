#!/bin/bash
# 对最终发布 ZIP 生成清单和 Ed25519 签名，缺密钥或不匹配必须中止发布，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${LOCALCLIP_BUILD_PATH:-$root/.build}"
bin="$(swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c release --show-bin-path)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/dist/LocalClip.app/Contents/Info.plist")"
"$bin/LocalClipUpdateTool" manifest "$root/dist/LocalClip.app" "$root/dist/LocalClip-v${version}.zip" "$root/dist"
