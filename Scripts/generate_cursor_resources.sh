#!/bin/bash
set -euo pipefail
# 从原始 Capptivo / Recordly SVG 生成纹理。librsvg 支持部分资源中的嵌套 mask/use；
# AppKit 对这些文件可能生成全透明图片，不能用它静默替代。
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "需要 librsvg 提供的 rsvg-convert。" >&2; exit 1; }
cursor_root=Packages/CaploKit/Sources/RenderKit/Resources
mkdir -p "$cursor_root/Cursors"
for cursor_source in "$cursor_root"/CursorSources/*.svg; do
    cursor_name=$(basename "$cursor_source" .svg)
    rsvg-convert --height 256 --output "$cursor_root/Cursors/$cursor_name.png" "$cursor_source"
done
