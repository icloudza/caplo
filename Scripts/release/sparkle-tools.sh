#!/bin/bash
# 下载与应用内 Sparkle 同版本的命令行工具（sign_update、generate_keys），输出 bin 目录路径。
# 版本取自 Package.resolved，工具与框架始终一致。
set -euo pipefail
cd "$(dirname "$0")/../.."

version=$(python3 - <<'PY'
import json
pins = json.load(open("Packages/CaploKit/Package.resolved"))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == "sparkle"))
PY
)
root=build/sparkle-tools/$version
if [[ ! -x $root/bin/sign_update ]]; then
    mkdir -p "$root"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" | tar -xJ -C "$root" bin
fi
echo "$PWD/$root/bin"
