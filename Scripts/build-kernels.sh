#!/bin/zsh
# 预编译 Core Image 的 Metal 内核：Packages/CaploKit/Shaders/*.metal → RenderKit 资源里的 CaploKernels.metallib。
# 改了 .metal 之后手动跑一次并提交生成的 .metallib（SwiftPM 不编译 Metal）。
set -euo pipefail
cd "$(dirname "$0")/../Packages/CaploKit"
# 可缝合内核要链接 CoreImage 的取样等运行时函数：用 metal 驱动一步编译并链接（metallib 工具不接受 -framework）。
xcrun -sdk macosx metal -std=macos-metal2.4 -mmacosx-version-min=15.0 -O2 -framework CoreImage \
    Shaders/CaploKernels.metal -o Sources/RenderKit/Resources/CaploKernels.metallib
echo "已生成 Sources/RenderKit/Resources/CaploKernels.metallib"
