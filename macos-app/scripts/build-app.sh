#!/bin/bash
# 从任意目录可复现打包；不安装、不启动、不发布，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
inputs="$(python3 "$root/scripts/build-inputs.py")"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.cache/swift"
scratch="${LOCALCLIP_BUILD_PATH:-$root/.build}"
swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c "$configuration"
bin="$(swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c "$configuration" --show-bin-path)"
bundle="$root/dist/LocalClip.app"
# 一旦开始改写产物即撤销旧来源记录，失败构建不能沿用之前的 release 标记。
rm -f "$root/dist/.localclip-build-inputs"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers"
# 辅助进程随应用发布并独立签名，运行时复制到更新缓存，by AI.Coding。
cp "$bin/LocalClipUpdater" "$bundle/Contents/Helpers/LocalClipUpdater.new"
mv -f "$bundle/Contents/Helpers/LocalClipUpdater.new" "$bundle/Contents/Helpers/LocalClipUpdater"
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
  codesign --force --options runtime --timestamp --sign "$LOCALCLIP_SIGN_IDENTITY" "$bundle/Contents/Helpers/LocalClipUpdater"
  codesign --force --options runtime --timestamp --sign "$LOCALCLIP_SIGN_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle/Contents/Helpers/LocalClipUpdater"
  codesign --force --sign - "$bundle"
fi
codesign --verify --deep --strict "$bundle"
# 只为输入未在构建中变化的完整包登记来源；登记在 bundle 外，不改变已有签名。
[ "$inputs" = "$(python3 "$root/scripts/build-inputs.py")" ] || { echo "构建期间源码已变化，请重新构建" >&2; exit 1; }
printf '%s %s\n' "$configuration" "$inputs" > "$root/dist/.localclip-build-inputs.new"
mv -f "$root/dist/.localclip-build-inputs.new" "$root/dist/.localclip-build-inputs"
printf '%s\n' "$bundle"
