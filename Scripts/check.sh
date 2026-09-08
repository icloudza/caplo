#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path Packages/CaploKit

# 令牌守卫：业务界面不得直接构造灰度 / HSB 颜色，颜色只能来自 CaploColor。
if grep -rnE "Color\(white:|Color\(hue:" Packages/CaploKit/Sources/Features; then
  echo "业务界面出现颜色字面量，请改用 CaploColor 令牌。" >&2
  exit 1
fi
# 窗口回归：实际创建全部窗口并跑完 AppKit 显示周期，约束死循环等异常直接失败。
swift run --package-path Packages/CaploKit PreviewGallery build/previews --windows
# 无签名构建仅修改应用目标的身份，避免污染日常权限；不能全局覆盖 PRODUCT_NAME，否则会改坏包内资源 bundle 名称。
xcodebuild \
  -project Caplo.xcodeproj \
  -scheme Caplo \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CAPLO_APP_IDENTIFIER=com.caplo.buildcheck \
  CAPLO_APP_NAME=CaploBuildCheck \
  build
