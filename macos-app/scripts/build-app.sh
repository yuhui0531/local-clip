#!/bin/bash
# 从任意目录可复现打包；不安装、不启动、不发布，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.cache/swift"
scratch="${LOCALCLIP_BUILD_PATH:-$root/.build}"
swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c "$configuration"
bin="$(swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c "$configuration" --show-bin-path)"
bundle="$root/dist/LocalClip.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# 用新inode替换主程序，避免用户仍在运行上一版时覆盖其已映射的执行文件。
cp "$bin/LocalClip" "$bundle/Contents/MacOS/LocalClip.new"
mv -f "$bundle/Contents/MacOS/LocalClip.new" "$bundle/Contents/MacOS/LocalClip"
cp "$root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$root/Resources/LocalClip.icns" "$bundle/Contents/Resources/LocalClip.icns"
for resource in "$bin"/*.bundle; do
  [ ! -d "$resource" ] || cp -R "$resource" "$bundle/Contents/Resources/"
done
# 设置 LOCALCLIP_SIGN_IDENTITY（如 "Developer ID Application: …"）可用稳定证书签名，
# 更新后辅助功能授权不失效；未设置时保持 ad hoc 签名，by AI.Coding。
if [ -n "${LOCALCLIP_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$LOCALCLIP_SIGN_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
