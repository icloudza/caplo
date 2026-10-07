#!/bin/bash
# CI 用：把 Developer ID 证书导入一个临时钥匙串，并写出公证密钥文件。发布与发布前检查两个工作流共用。
# 需要环境变量 CERTIFICATE_P12（base64）、CERTIFICATE_PASSWORD、NOTARY_KEY（.p8 内容）、RUNNER_TEMP、GITHUB_ENV。
set -euo pipefail

keychain="${RUNNER_TEMP}/release.keychain-db"
password=$(openssl rand -base64 24)
echo "${CERTIFICATE_P12}" | base64 --decode > "${RUNNER_TEMP}/certificate.p12"
security create-keychain -p "${password}" "${keychain}"
security set-keychain-settings -lut 21600 "${keychain}"
security unlock-keychain -p "${password}" "${keychain}"
security import "${RUNNER_TEMP}/certificate.p12" -P "${CERTIFICATE_PASSWORD}" -A -t cert -f pkcs12 -k "${keychain}"
rm "${RUNNER_TEMP}/certificate.p12"
# Developer ID 中间证书：导出的 .p12 通常只含叶证书，缺了它 codesign 无法建立证书链。
curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "${RUNNER_TEMP}/DeveloperIDG2CA.cer"
security import "${RUNNER_TEMP}/DeveloperIDG2CA.cer" -k "${keychain}" || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${password}" "${keychain}" > /dev/null
security list-keychains -d user -s "${keychain}" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "${keychain}"

printf '%s' "${NOTARY_KEY}" > "${RUNNER_TEMP}/notary.p8"
echo "NOTARY_KEY_PATH=${RUNNER_TEMP}/notary.p8" >> "${GITHUB_ENV}"
