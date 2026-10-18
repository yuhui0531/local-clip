#!/bin/bash
# 制作 macOS 安装磁盘映像与 ZIP，校验既有发布构建而不覆盖签名，by AI.Coding。
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
dist_dir="$root/dist"
app_path="$dist_dir/LocalClip.app"
plist_path="$root/Resources/Info.plist"

if [ ! -d "$app_path" ]; then
    echo "==> LocalClip.app 未找到，正在调用 build-app.sh 进行发布构建..."
    bash "$script_dir/build-app.sh" release
fi

# 已有 App 必须来自当前输入的 release 构建；不静默重建覆盖预签名产物。
expected="release $(python3 "$script_dir/build-inputs.py")"
[ -f "$dist_dir/.localclip-build-inputs" ] && [ "$(cat "$dist_dir/.localclip-build-inputs")" = "$expected" ] || {
    echo "安装包不是当前源码的发布构建，请先运行 build-app.sh release" >&2; exit 1;
}
for key in CFBundleShortVersionString CFBundleVersion; do
    [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist_path")" = "$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist")" ] || {
        echo "安装包版本与源码不一致，请重新构建" >&2; exit 1;
    }
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
# tag 与安装包只用版本号（如 v0.3.17），构建号仍写在 Info.plist 与 Release 标题中，by AI.Coding。
full_version="v${version}"

dmg_name="LocalClip-${full_version}.dmg"
zip_name="LocalClip-${full_version}.zip"
dmg_path="$dist_dir/$dmg_name"
zip_path="$dist_dir/$zip_name"

echo "==> 准备打包 LocalClip 版本: $full_version"
mkdir -p "$dist_dir"

# 1. 制作 DMG 磁盘映像
echo "==> 制作 DMG 磁盘映像: $dmg_name"
rm -f "$dmg_path"
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

cp -R "$app_path" "$staging_dir/"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
    -volname "LocalClip" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

# 2. 制作便携 ZIP
echo "==> 制作便携 ZIP 归档: $zip_name"
rm -f "$zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"

# 3. 生成统一别名
ln -sf "$dmg_name" "$dist_dir/LocalClip.dmg"
ln -sf "$zip_name" "$dist_dir/LocalClip.zip"

# 4. 生成校验和
echo "==> 生成 SHA-256 校验和..."
(
    cd "$dist_dir"
    shasum -a 256 "$dmg_name" "$zip_name" > checksums.txt
)

echo "==> 安装包制作成功！"
ls -lh "$dmg_path" "$zip_path" "$dist_dir/checksums.txt"
