#!/bin/bash
# 独立bundle ID的优化验收包，保留正式AppDelegate/视图/存储路径；禁止使用生产目录，by AI.Coding。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?Pass an isolated evidence directory}"
output="$(cd "$output" && pwd)"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.cache/swift"
scratch="$root/.build-gui-check"
swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c release -Xswiftc -DDEBUG
bin="$(swift build --disable-sandbox --cache-path "$root/.cache/packages" --package-path "$root" --scratch-path "$scratch" -c release -Xswiftc -DDEBUG --show-bin-path)"
bundle="$output/LocalClip-GUI-Check.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/LocalClip" "$bundle/Contents/MacOS/LocalClip.new"
mv -f "$bundle/Contents/MacOS/LocalClip.new" "$bundle/Contents/MacOS/LocalClip"
cp "$root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$root/Resources/LocalClip.icns" "$bundle/Contents/Resources/LocalClip.icns"
for resource in "$bin"/*.bundle; do
  [ ! -d "$resource" ] || cp -R "$resource" "$bundle/Contents/Resources/"
done
python3 - "$bundle" "$output" <<'PY'
import sys,plistlib,json
from pathlib import Path
bundle,output=map(Path,sys.argv[1:])
p=bundle/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
info['CFBundleIdentifier']='local.localclip.gui-check'
info['CFBundleName']='LocalClip GUI Check'
info['LSUIElement']=False
p.write_bytes(plistlib.dumps(info,sort_keys=False))
config={'root':str(output/'working-store'),'output':str(output),'board':'local.localclip.gui.scaling-check'}
(bundle/'Contents/Resources/IsolatedGUIProbe.json').write_text(json.dumps(config,indent=2))
PY
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
