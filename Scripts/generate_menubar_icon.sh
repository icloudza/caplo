#!/bin/bash
# 由 Design/MenuBarIcon/*.svg 渲染菜单栏模板图到 CaploDesignSystem 的资源目录。
# 依赖: rsvg-convert (brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert: brew install librsvg" >&2; exit 1; }

CATALOG="Packages/CaploKit/Sources/CaploDesignSystem/Resources/Brand.xcassets"
mkdir -p "$CATALOG"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$CATALOG/Contents.json"

emit() { # <imageset 名> <svg>
  local name=$1 svg=$2 dir="$CATALOG/$1.imageset"
  mkdir -p "$dir"
  rsvg-convert -w 18 -h 18 "$svg" -o "$dir/$name@1x.png"
  rsvg-convert -w 36 -h 36 "$svg" -o "$dir/$name@2x.png"
  cat > "$dir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "$name@1x.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "$name@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
}
emit MenuBarIcon Design/MenuBarIcon/Caplo-MenuBar.svg
echo "已生成菜单栏模板图 -> $CATALOG"
