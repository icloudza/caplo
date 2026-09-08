#!/bin/bash
# 由 Design/AppIcon/Caplo-AppIcon-<variant>.svg 渲染 macOS AppIcon 资源目录。
# 用法: Scripts/generate_app_icon.sh [dark|light]   (默认 dark)
# 依赖: rsvg-convert (brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="${1:-dark}"
SRC="Design/AppIcon/Caplo-AppIcon-${VARIANT}.svg"
OUT="App/Assets.xcassets/AppIcon.appiconset"
[ -f "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert: brew install librsvg" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# macOS 规范要求的 10 个尺寸: 16/32/128/256/512 pt 各 @1x @2x
render() { # <pt> <scale>
  local pt=$1 scale=$2 px=$(( $1 * $2 ))
  rsvg-convert -w "$px" -h "$px" "$SRC" -o "$OUT/icon_${pt}x${pt}@${scale}x.png"
}
for pt in 16 32 128 256 512; do render "$pt" 1; render "$pt" 2; done

python3 - "$OUT" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        images.append({"filename": f"icon_{pt}x{pt}@{scale}x.png", "idiom": "mac",
                       "scale": f"{scale}x", "size": f"{pt}x{pt}"})
(out / "Contents.json").write_text(json.dumps(
    {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
PY

# 顶层 Contents.json
cat > App/Assets.xcassets/Contents.json <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "已生成 ${VARIANT} 图标 -> $OUT"
ls "$OUT"
