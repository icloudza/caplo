import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
import ProjectKit
import ExportKit
import EditingCore
import RenderKit
@testable import Features

/// 背景图库：内置壁纸按 4K 生成成 HEIC 进工程；本机壁纸缩到 3840 宽再进工程；目录扫描只认图片文件并去重。
@Test func backgroundLibraryImportsArtworkAndDownscalesSystemWallpapers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectStorage.create(in: root, name: "壁纸")

    // 内置壁纸原样复制：仍是 WebP，尺寸 3840×2160，渲染链路能直接读。
    let bundled = try #require(WallpaperCatalog.wallpapers(in: .silk).first)
    let bundledPath = try BackgroundLibrary.importBundled(bundled, into: project)
    #expect(bundledPath.hasSuffix(".webp"))
    let bundledImage = try #require(CIImage(contentsOf: try ProjectStorage.backgroundURL(bundledPath, in: project)))
    #expect(bundledImage.extent.size == CGSize(width: 3840, height: 2160))

    // 模拟一张 6000×3000 的系统壁纸：导入后长边缩到 3840，比例不变。
    let hugeSource = root.appendingPathComponent("Huge.png")
    let context = try #require(CGContext(data: nil, width: 6000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 6000, height: 3000))
    let huge = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(hugeSource as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, huge, nil); #expect(CGImageDestinationFinalize(destination))
    let systemPath = try BackgroundLibrary.importSystemWallpaper(hugeSource, into: project)
    let imported = try #require(CIImage(contentsOf: try ProjectStorage.backgroundURL(systemPath, in: project)))
    #expect(imported.extent.width == 3840 && imported.extent.height == 1920)
    // 合成用的背景图：一次解成位图、最长边不超过 3840；6000 宽的原图直接交给它也会被缩下来。
    var layout = CanvasLayout(); layout.backgroundImage = try ProjectStorage.importBackground(from: hugeSource, into: project)
    let composited = try #require(ProjectMedia.backgroundImage(for: layout, in: project))
    #expect(composited.extent.width == 3840 && composited.extent.height == 1920)
    #expect(composited.cgImage != nil)

    // 目录扫描：只列图片文件，同名去重，隐藏文件与描述文件不算。
    let folder = root.appendingPathComponent("Pictures", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: hugeSource, to: folder.appendingPathComponent("Sonoma.png"))
    try Data().write(to: folder.appendingPathComponent("Sonoma.madesktop"))
    try Data().write(to: folder.appendingPathComponent(".hidden.png"))
    let other = root.appendingPathComponent("More", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: hugeSource, to: other.appendingPathComponent("Sonoma.png"))
    try FileManager.default.copyItem(at: hugeSource, to: other.appendingPathComponent("Big Sur.jpg"))
    let listed = BackgroundLibrary.listWallpapers(in: [folder, other])
    #expect(listed.map(\.name) == ["Sonoma", "Big Sur"])
    #expect(BackgroundLibrary.listWallpapers(in: [root.appendingPathComponent("missing")]).isEmpty)
    let thumbnail = try #require(BackgroundLibrary.decode(hugeSource, maximumPixelSize: 256))
    #expect(thumbnail.width == 256 && thumbnail.height == 128)
}

/// 本机壁纸只挑最多四张、同一设计的不同配色只取一张，先给的目录优先。
@Test func featuredSystemWallpapersDedupeColorVariantsAndCapAtFour() {
    func item(_ name: String) -> BackgroundLibrary.SystemWallpaper { .init(id: name, name: name, url: URL(fileURLWithPath: "/tmp/\(name).heic")) }
    let listed = ["Big Sur", "Catalina", "Monterey Graphic", "iMac Blue", "iMac Green", "iMac Orange", "Mac Pink", "Radial Sky Blue", "Sonoma"].map(item)
    let featured = BackgroundLibrary.featured(listed, limit: 4)
    #expect(featured.map(\.name) == ["Big Sur", "Catalina", "Monterey Graphic", "iMac Blue"])
    #expect(BackgroundLibrary.featured(["iMac Blue", "iMac Green", "Mac Yellow", "Mac Pink"].map(item), limit: 4).map(\.name) == ["iMac Blue", "Mac Yellow"])
    #expect(BackgroundLibrary.featured([], limit: 4).isEmpty)
}
