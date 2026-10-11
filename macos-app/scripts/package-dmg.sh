#!/bin/bash
# 制作 macOS 安装磁盘映像 (DMG) 与 ZIP 压缩包
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

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path" 2>/dev/null || echo "1.0.0")"
build_number="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist_path" 2>/dev/null || echo "1")"
full_version="v${version}-${build_number}"

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
