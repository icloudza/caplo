#!/bin/bash
# 输出某个发布标签的更新说明（纯文本 / 简化 Markdown），GitHub Release 与应用内更新窗口共用。
# 取用顺序：
#   1. ReleaseNotes/<版本>.md（推荐：随代码评审、可反复修改）
#   2. 附注标签的说明（git tag -a v1.4.2 -F 说明.md）
#   3. 上一个标签以来的提交标题
set -euo pipefail
cd "$(dirname "$0")/../.."

tag=${1:?用法：notes.sh <标签>}
version=${tag#v}

if [[ -f ReleaseNotes/$version.md ]]; then
    cat "ReleaseNotes/$version.md"
    exit 0
fi

if [[ $(git cat-file -t "$tag") == tag ]]; then
    # 去掉第一行标题（通常就是版本号）与可能的签名块，只留正文；没有正文就用标题。
    body=$(git tag -l --format='%(contents:body)' "$tag" | sed '/-----BEGIN PGP SIGNATURE-----/,$d')
    subject=$(git tag -l --format='%(contents:subject)' "$tag")
    if [[ -n ${body//[[:space:]]/} ]]; then echo "$body"; exit 0; fi
    if [[ -n $subject && $subject != "$tag" && $subject != "$version" ]]; then echo "$subject"; exit 0; fi
fi

previous=$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)
range=${previous:+$previous..}$tag
git log --no-merges --pretty='- %s' "$range"
