import CoreImage
import Foundation

/// 预编译的 Core Image Metal 内核（源码在 Shaders/CaploKernels.metal，由 Scripts/build-kernels.sh 生成 metallib 放进资源）。
///
/// 运行时编译的 Core Image 内核语言（CIKL）早已弃用，在要兼容的新系统上有被移除的风险；现在优先用这里的 Metal 版，
/// 读不到库或建不出内核时才退回各处保留的 CIKL 源码。两版逐像素一致（2026-10-07 对照：三个内核最大差 0）。
enum MetalKernels {
    private static let library: Data? = Bundle.module.url(forResource: "CaploKernels", withExtension: "metallib").flatMap { try? Data(contentsOf: $0) }

    static func kernel(_ name: String) -> CIKernel? {
        library.flatMap { try? CIKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    static func colorKernel(_ name: String) -> CIColorKernel? {
        library.flatMap { try? CIColorKernel(functionName: name, fromMetalLibraryData: $0) }
    }
}
