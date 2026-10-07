#!/bin/bash
# 一次性配置：把发布所需的证书、密钥与 Cloudflare R2 信息写进 GitHub 仓库的 Secrets / Variables。
# 在自己的 Mac 上运行（需要 gh 已登录：gh auth login）。每一项直接回车即跳过，可以分多次运行。
# 输入的密码与密钥只经由 gh 加密上传，不写入仓库、不留在本机文件里。
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v gh >/dev/null || { echo "需要 GitHub CLI：brew install gh && gh auth login" >&2; exit 1; }
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "配置仓库：$repo"
echo

ask() { local prompt=$1 var; read -r -p "${prompt}：" var; printf '%s' "$var"; }
ask_secret() { local prompt=$1 var; read -r -s -p "${prompt}：" var; echo >&2; printf '%s' "$var"; }
secret() { printf '%s' "$2" | gh secret set "$1" --repo "$repo" > /dev/null && echo "  ✓ Secret $1"; }
# 拖进终端的路径：去掉首尾空格与引号，还原反斜杠转义的空格。
clean_path() { local p=$1; p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}; p=${p%\'}; p=${p#\'}; p=${p%\"}; p=${p#\"}; printf '%s' "${p//\\ / }"; }
variable() { gh variable set "$1" --repo "$repo" --body "$2" > /dev/null && echo "  ✓ Variable $1 = $2"; }

echo "【1/4】Developer ID 证书（钥匙串访问 → 我的证书 → 右键\"Developer ID Application: …\" → 导出为 .p12）"
p12=$(ask ".p12 文件路径（拖进终端即可）")
p12=$(clean_path "$p12")
if [[ -n $p12 ]]; then
    [[ -f $p12 ]] || { echo "找不到 $p12" >&2; exit 1; }
    password=$(ask_secret "导出 .p12 时设置的密码")
    secret MACOS_CERTIFICATE_P12 "$(base64 -i "$p12")"
    secret MACOS_CERTIFICATE_PASSWORD "$password"
    team=$(ask "团队 ID（证书名括号里的 10 位，例如 KTP97H9YFF）")
    [[ -n $team ]] && secret APPLE_TEAM_ID "$team"
fi
echo

echo "【2/4】公证用的 App Store Connect API 密钥（App Store Connect → 用户和访问 → 集成 → 团队密钥，权限选\"开发者\"）"
p8=$(ask ".p8 文件路径（只能下载一次，请妥善保存）")
p8=$(clean_path "$p8")
if [[ -n $p8 ]]; then
    [[ -f $p8 ]] || { echo "找不到 $p8" >&2; exit 1; }
    secret NOTARY_KEY "$(cat "$p8")"
    key_id=$(ask "密钥 ID")
    [[ -n $key_id ]] && secret NOTARY_KEY_ID "$key_id"
    issuer=$(ask "Issuer ID（密钥列表上方的 UUID）")
    [[ -n $issuer ]] && secret NOTARY_ISSUER_ID "$issuer"
fi
echo

echo "【3/4】在线更新签名密钥（EdDSA）。私钥存进本机钥匙串（账户名 caplo），并上传为 Secret；公钥写进 Variable。"
echo "      已有密钥会直接复用，不会覆盖。私钥务必备份：丢失后已安装的用户将无法再收到更新。"
answer=$(ask "现在生成 / 读取并上传？(y/N)")
if [[ $answer == [yY] ]]; then
    tools=$(Scripts/release/sparkle-tools.sh)
    "$tools/generate_keys" --account caplo > /dev/null
    public_key=$("$tools/generate_keys" --account caplo -p)
    exported=$(mktemp)
    trap 'rm -f "$exported"' EXIT
    rm -f "$exported"
    "$tools/generate_keys" --account caplo -x "$exported" > /dev/null
    secret SPARKLE_PRIVATE_KEY "$(cat "$exported")"
    rm -f "$exported"
    variable SPARKLE_PUBLIC_KEY "$public_key"
fi
echo

echo "【4/4】Cloudflare R2（Cloudflare 控制台 → R2 → 管理 API 令牌 → 创建，权限\"对象读和写\"，限定到发布用的存储桶）"
account=$(ask "账户 ID（R2 概览页右侧）")
[[ -n $account ]] && secret R2_ACCOUNT_ID "$account"
access=$(ask "访问密钥 ID（Access Key ID）")
[[ -n $access ]] && secret R2_ACCESS_KEY_ID "$access"
secret_key=$(ask_secret "机密访问密钥（Secret Access Key）")
[[ -n $secret_key ]] && secret R2_SECRET_ACCESS_KEY "$secret_key"
bucket=$(ask "存储桶名称")
[[ -n $bucket ]] && variable R2_BUCKET "$bucket"
base=$(ask "存储桶绑定的下载域名，例如 https://download.caplo.app")
[[ -n $base ]] && variable DOWNLOAD_BASE_URL "${base%/}"
site=$(ask "官网地址（可选），例如 https://caplo.app")
[[ -n $site ]] && variable SITE_URL "${site%/}"
echo

echo "当前配置："
gh secret list --repo "$repo"
gh variable list --repo "$repo"
