#!/bin/bash
# 构建可分发的 Caplo.dmg：归档 → Developer ID 导出 → 公证并装订应用 → 制作 DMG → 签名、公证并装订 DMG。
# 产物在 build/release/：Caplo.app、Caplo-<版本>.dmg。
#
# 用法：Scripts/release/build.sh <标签，例如 v1.4.2>
#
# 环境变量：
#   APPLE_TEAM_ID         必填，开发者团队 ID（10 位）
#   SIGNING_IDENTITY      可选，默认 "Developer ID Application"（钥匙串里只有一张时足够）
#   NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID
#                         App Store Connect API 密钥（.p8 路径、密钥 ID、Issuer ID），用于公证；
#                         本地试跑可以不给，此时跳过公证（产物不能分发）
#   UPDATE_FEED_URL       appcast 地址，写进 Info.plist 的 SUFeedURL
#   SPARKLE_PUBLIC_KEY    EdDSA 公钥，写进 SUPublicEDKey
#                         两者缺一则应用里不启动在线更新；正式发布（非预发布）两者必填
set -euo pipefail
cd "$(dirname "$0")/../.."

tag=${1:?用法：build.sh <标签>}
eval "$(Scripts/release/version.sh "$tag")"
: "${APPLE_TEAM_ID:?缺少 APPLE_TEAM_ID}"
identity=${SIGNING_IDENTITY:-Developer ID Application}
feed=${UPDATE_FEED_URL:-}
public_key=${SPARKLE_PUBLIC_KEY:-}
if [[ $PRERELEASE == false && ( -z $feed || -z $public_key ) ]]; then
    echo "正式版必须提供 UPDATE_FEED_URL 与 SPARKLE_PUBLIC_KEY，否则用户装上后收不到后续更新。" >&2
    exit 1
fi

out=build/release
rm -rf "$out"
mkdir -p "$out"
archive=$out/Caplo.xcarchive
app=$out/Caplo.app
dmg=$out/Caplo-$VERSION.dmg

echo "▶ 归档 Caplo ${VERSION}（构建号 ${BUILD_NUMBER}）"
# 独立 DerivedData：不与日常调试构建共用，也不顶掉本机已安装的 Caplo.app。
xcodebuild archive \
    -project Caplo.xcodeproj -scheme Caplo -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive" -derivedDataPath "$out/DerivedData" \
    MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CAPLO_UPDATE_FEED_URL="$feed" CAPLO_UPDATE_PUBLIC_KEY="$public_key" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    | tee "$out/archive.log" | grep -E "^(error|warning: .*Caplo|\*\* )" || true
[[ -d $archive ]] || { echo "归档失败，详见 $out/archive.log" >&2; exit 1; }

echo "▶ 以 Developer ID 导出"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$APPLE_TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$identity</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" \
    > "$out/export.log" 2>&1 || { tail -30 "$out/export.log" >&2; exit 1; }
mv "$out/export/Caplo.app" "$app"

# Sparkle 里的辅助程序（安装器、下载服务、Autoupdate、Updater.app）必须同样以 Developer ID + 加固运行时签名，
# 否则公证拒收。按 Sparkle 文档由内到外逐个重签，最后重签应用本身（保留应用的权限声明）。
echo "▶ 重签 Sparkle 组件"
sparkle=$app/Contents/Frameworks/Sparkle.framework
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
for item in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/XPCServices/Downloader.xpc"; do
    [[ -e $item ]] && sign --preserve-metadata=entitlements "$item"
done
for item in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
    [[ -e $item ]] && sign "$item"
done
sign "$sparkle"
sign --preserve-metadata=entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# 发布包里必须真带着更新配置（构建设置没传进去时 Info.plist 是空串，应用会静默地不检查更新）。
info=$app/Contents/Info.plist
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info") == "$MARKETING_VERSION" ]]
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info") == "$BUILD_NUMBER" ]]
if [[ -n $feed ]]; then
    [[ $(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$info") == "$feed" ]] || { echo "Info.plist 的 SUFeedURL 不对" >&2; exit 1; }
fi

notarize() {
    local file=$1 result=$out/notary-$(basename "$1").json
    echo "▶ 公证 $(basename "$file")（通常 2–10 分钟）"
    xcrun notarytool submit "$file" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --timeout 1h --output-format json > "$result" || true
    local status id
    status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$result" 2>/dev/null || true)
    id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$result" 2>/dev/null || true)
    if [[ $status != Accepted ]]; then
        echo "公证未通过（状态：${status:-无}）" >&2
        cat "$result" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
        exit 1
    fi
}

notarizing=false
if [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER_ID:-} ]]; then
    notarizing=true
    # 先公证并装订应用本身：用户从 DMG 拖出来离线首次打开、以及 Sparkle 更新后都能直接通过门禁。
    ditto -c -k --keepParent "$app" "$out/Caplo-notarize.zip"
    notarize "$out/Caplo-notarize.zip"
    xcrun stapler staple "$app"
    rm "$out/Caplo-notarize.zip"
else
    echo "⚠︎ 未提供公证密钥：跳过公证，产物仅供本地验证，不能分发。" >&2
fi

echo "▶ 制作 DMG"
# dmgbuild 直接写窗口布局（背景、图标位置、卷图标），不用操控访达，CI 上也稳定。装在临时虚拟环境里，不污染系统 Python。
venv="${out}/dmgbuild-venv"
python3 -m venv "${venv}"
"${venv}/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
"${venv}/bin/dmgbuild" -s Scripts/release/dmg/dmg-settings.py -D app="${app}" \
    -D background="${PWD}/Scripts/release/dmg/background.tiff" "Caplo" "${dmg}" > "${out}/dmgbuild.log" 2>&1 \
    || { cat "${out}/dmgbuild.log" >&2; exit 1; }
rm -rf "${venv}"
codesign --force --timestamp --sign "$identity" "$dmg"

if $notarizing; then
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type execute --verbose=2 "$app"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

echo "✓ ${dmg}（$(du -h "$dmg" | cut -f1)）"
