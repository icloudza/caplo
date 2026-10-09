#!/bin/bash
# 输出某个发布标签的更新说明（纯文本 / 简化 Markdown），GitHub Release 与应用内更新窗口共用。
# 取用顺序：
#   1. ReleaseNotes/<版本>.md（推荐：随代码评审、可反复修改）
#   2. 附注标签的说明（git tag -a v1.4.2 -F 说明.md）
#   3. 上一个标签以来的提交标题
# 双语写法：列表项写中文，下一行缩进写英文。应用内更新窗口把缩进续行排成第二行；
# GitHub 的 Markdown 会把续行并进同一行，加 --github 时改用 <br> 接上。
set -euo pipefail
cd "$(dirname "$0")/../.."

tag=${1:?用法：notes.sh <标签> [--github]}
version=${tag#v}

raw_notes() {
    if [[ -f ReleaseNotes/$version.md ]]; then
        cat "ReleaseNotes/$version.md"
        return
    fi

    if [[ $(git cat-file -t "$tag") == tag ]]; then
        # 去掉第一行标题（通常就是版本号）与可能的签名块，只留正文；没有正文就用标题。
        body=$(git tag -l --format='%(contents:body)' "$tag" | sed '/-----BEGIN PGP SIGNATURE-----/,$d')
        subject=$(git tag -l --format='%(contents:subject)' "$tag")
        if [[ -n ${body//[[:space:]]/} ]]; then echo "$body"; return; fi
        if [[ -n $subject && $subject != "$tag" && $subject != "$version" ]]; then echo "$subject"; return; fi
    fi

    previous=$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)
    range=${previous:+$previous..}$tag
    git log --no-merges --pretty='- %s' "$range"
}

if [[ ${2:-} == --github ]]; then
    # 缩进且不是子列表的续行，接到上一个列表项末尾。
    raw_notes | awk '
        /^[ \t]+[^ \t*-]/ && last ~ /^[-*] / { sub(/^[ \t]+/, ""); last = last "<br>" $0; next }
        { if (NR > 1) print last; last = $0 }
        END { if (NR) print last }'
else
    raw_notes
fi
