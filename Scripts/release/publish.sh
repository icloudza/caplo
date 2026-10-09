#!/bin/bash
# 把 build.sh 的产物发布到 Cloudflare R2：签名安装包 → 生成并签名 appcast → 上传。
#
# 用法：Scripts/release/publish.sh <标签> [--dry-run]
#   --dry-run 只在 build/release/site/ 生成要上传的文件，不联网上传，用于本地核对。
#
# 环境变量：
#   SPARKLE_PRIVATE_KEY     EdDSA 私钥（generate_keys -x 导出的内容）
#   SPARKLE_PUBLIC_KEY      与私钥成对的公钥（应用 Info.plist 里的 SUPublicEDKey），用于上传前核对
#   DOWNLOAD_BASE_URL       下载域名，例如 https://download.caplo.app（R2 存储桶绑定的自定义域名，不带结尾斜杠）
#   SITE_URL                可选，官网地址
#   R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET   上传时必填
#
# 存储桶布局：
#   releases/<版本>/Caplo-<版本>.dmg   每个版本一份，永久缓存
#   Caplo.dmg                          最新正式版（官网"下载"按钮）
#   latest.json                        最新正式版信息（官网显示版本号、大小）
#   releases.json                      全部正式版的更新说明（官网"更新日志"页）
#   appcast.xml                        应用内在线更新（最后上传，保证它指向的安装包已经就位）
# 预发布（beta / rc）只上传 releases/，不改动后三项。
set -euo pipefail
cd "$(dirname "$0")/../.."

tag=${1:?用法：publish.sh <标签> [--dry-run]}
dry_run=false
[[ ${2:-} == --dry-run ]] && dry_run=true
eval "$(Scripts/release/version.sh "$tag")"
: "${SPARKLE_PRIVATE_KEY:?缺少 SPARKLE_PRIVATE_KEY}"
: "${DOWNLOAD_BASE_URL:?缺少 DOWNLOAD_BASE_URL}"
base=${DOWNLOAD_BASE_URL%/}

out=build/release
dmg=$out/Caplo-$VERSION.dmg
[[ -f $dmg ]] || { echo "找不到 ${dmg}，先运行 build.sh" >&2; exit 1; }
tools=$(Scripts/release/sparkle-tools.sh)
site=$out/site
rm -rf "$site"
mkdir -p "$site/releases/$VERSION"
cp "$dmg" "$site/releases/$VERSION/"
key=$PWD/$site/.ed-key
# 私钥只在本次运行的临时文件里存在，结束即删。
trap 'rm -f "$key"' EXIT
(umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key")

echo "▶ 签名安装包"
signature=$("$tools/sign_update" --ed-key-file "$key" "$dmg" | python3 Scripts/release/appcast.py --parse-signature)

if [[ $PRERELEASE == false ]]; then
    echo "▶ 生成 appcast.xml、latest.json 与 releases.json"
    Scripts/release/notes.sh "$tag" > "$out/notes.md"
    python3 Scripts/release/appcast.py --version "$VERSION" --build "$BUILD_NUMBER" --dmg "$dmg" \
        --url "$base/releases/$VERSION/Caplo-$VERSION.dmg" --notes "$out/notes.md" --signature "$signature" \
        --site "${SITE_URL:-}" --out "$site"
    python3 Scripts/release/releases.py --tag "$tag" --out "$site"
    cp "$dmg" "$site/Caplo.dmg"
    "$tools/sign_update" --ed-key-file "$key" "$site/appcast.xml"
    "$tools/sign_update" --verify --ed-key-file "$key" "$site/appcast.xml"
fi
# 用应用里内置的公钥反验安装包签名：私钥与公钥不是一对时所有用户都会拒绝这次更新，必须在上传前拦下。
: "${SPARKLE_PUBLIC_KEY:?缺少 SPARKLE_PUBLIC_KEY（用来核对私钥与应用内公钥是否一对）}"
swift Scripts/release/verify-signature.swift "$SPARKLE_PUBLIC_KEY" "$signature" "$dmg" \
    || { echo "安装包签名与 SPARKLE_PUBLIC_KEY 不匹配：私钥和公钥不是同一对。" >&2; exit 1; }
rm -f "$key"

if $dry_run; then
    echo "✓ 已生成（未上传）：$site"
    find "$site" -type f | sort
    exit 0
fi

: "${R2_ACCOUNT_ID:?缺少 R2_ACCOUNT_ID}" "${R2_ACCESS_KEY_ID:?缺少 R2_ACCESS_KEY_ID}" "${R2_SECRET_ACCESS_KEY:?缺少 R2_SECRET_ACCESS_KEY}" "${R2_BUCKET:?缺少 R2_BUCKET}"
command -v aws >/dev/null || brew install awscli >/dev/null
export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=auto
# 新版 AWS CLI 默认附带的校验和头 R2 不全支持，按 Cloudflare 的建议只在必需时计算。
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
endpoint=https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com
put() { # 本地文件 远端路径 类型 缓存策略 [其他参数]
    local file=$1 path=$2 type=$3 cache=$4
    shift 4
    echo "▶ 上传 $path"
    aws s3 cp "$file" "s3://$R2_BUCKET/$path" --endpoint-url "$endpoint" --only-show-errors \
        --content-type "$type" --cache-control "$cache" "$@"
}

put "$dmg" "releases/$VERSION/Caplo-$VERSION.dmg" application/x-apple-diskimage "public, max-age=31536000, immutable"
if [[ $PRERELEASE == false ]]; then
    put "$dmg" Caplo.dmg application/x-apple-diskimage "public, max-age=300" \
        --content-disposition "attachment; filename=\"Caplo-$VERSION.dmg\""
    put "$site/latest.json" latest.json application/json "public, max-age=60"
    put "$site/releases.json" releases.json application/json "public, max-age=60"
    put "$site/appcast.xml" appcast.xml application/xml "public, max-age=60"
fi

# 从公网取回 appcast 核对版本：自定义域名没绑好或缓存规则不对时在这里暴露出来。
if [[ $PRERELEASE == false ]]; then
    for attempt in 1 2 3 4 5 6; do
        if curl -fsSL "$base/appcast.xml?check=$BUILD_NUMBER" | grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>"; then
            echo "✓ $base/appcast.xml 已是 $VERSION"
            exit 0
        fi
        sleep 10
    done
    echo "⚠︎ 公网暂未取到新的 appcast.xml，请检查 $base 的域名绑定与缓存规则。" >&2
    exit 1
fi
echo "✓ 预发布已上传：$base/releases/$VERSION/Caplo-$VERSION.dmg"
