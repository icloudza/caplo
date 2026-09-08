// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaploKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Features", targets: ["Features"]),
        .executable(name: "PreviewGallery", targets: ["PreviewGallery"])
    ],
    targets: [
        .target(name: "PlatformSupport"),
        .target(name: "CaploDesignSystem", dependencies: ["PlatformSupport"], resources: [.process("Resources")]),
        .target(name: "EditingCore"),
        .target(name: "ProjectKit", dependencies: ["EditingCore"]),
        .target(name: "CaptureKit", dependencies: ["ProjectKit", "EditingCore"]),
        // 第三方 C 库（BSD）：RNNoise 降噪（2017 小模型），只给编辑器离线语音处理用；许可证随源码放在目标目录。
        .target(name: "CRNNoise", exclude: ["COPYING"]),
        .target(name: "ExportKit", dependencies: ["ProjectKit", "RenderKit", "EditingCore", "CRNNoise"]),
        .target(name: "RenderKit", dependencies: ["EditingCore"], resources: [.process("Resources")]),
        .target(name: "Features", dependencies: ["CaploDesignSystem", "EditingCore", "RenderKit", "CaptureKit", "ProjectKit", "ExportKit"]),
        .executableTarget(name: "PreviewGallery", dependencies: ["Features", "ProjectKit", "EditingCore", "ExportKit", "CaploDesignSystem"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "ProjectKit", "EditingCore", "CaploDesignSystem", "ExportKit", "RenderKit"]),
        .testTarget(name: "EditingCoreTests", dependencies: ["EditingCore"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit", "ProjectKit", "ExportKit", "RenderKit", "EditingCore"]),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit", "EditingCore"])
    ],
    swiftLanguageModes: [.v6]
)
