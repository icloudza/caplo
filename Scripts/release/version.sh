#!/bin/bash
# 由发布标签换算版本信息，输出 KEY=VALUE 行（可直接追加到 ${GITHUB_ENV}）。
#
#   Scripts/release/version.sh v1.4.2        → VERSION=1.4.2  BUILD=100400299 PRERELEASE=false
#   Scripts/release/version.sh v1.5.0-beta.2 → VERSION=1.5.0-beta.2 BUILD=100500002 PRERELEASE=true
#
# CFBundleVersion（Sparkle 用它比较新旧）= (主*1000+次)*1000+修订 再 *100 + 序号：
# 正式版序号 99，beta.N 为 N（1–49），rc.N 为 50+N（1–48）。同一版本号的 beta < rc < 正式版，
# 同一提交先打 beta 再打正式版也能被识别为更新。CFBundleShortVersionString 只取 X.Y.Z。
set -euo pipefail

tag=${1:?用法：version.sh <标签，例如 v1.4.2>}
version=${tag#v}
if [[ ! $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(beta|rc)\.([0-9]+))?$ ]]; then
    echo "标签格式应为 vX.Y.Z、vX.Y.Z-beta.N 或 vX.Y.Z-rc.N，收到：$tag" >&2
    exit 1
fi
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
channel=${BASH_REMATCH[5]:-} number=${BASH_REMATCH[6]:-}
if (( minor > 999 || patch > 999 )); then echo "次版本号与修订号不能超过 999" >&2; exit 1; fi

case $channel in
    "") sequence=99 ;;
    beta) (( number >= 1 && number <= 49 )) || { echo "beta 序号范围 1–49" >&2; exit 1; }; sequence=$number ;;
    rc) (( number >= 1 && number <= 48 )) || { echo "rc 序号范围 1–48" >&2; exit 1; }; sequence=$((50 + number)) ;;
esac

echo "VERSION=$version"
echo "MARKETING_VERSION=$major.$minor.$patch"
echo "BUILD_NUMBER=$(( ((major * 1000 + minor) * 1000 + patch) * 100 + sequence ))"
echo "PRERELEASE=$([[ -n $channel ]] && echo true || echo false)"
