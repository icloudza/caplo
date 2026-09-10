import AppKit
import ImageIO
import UniformTypeIdentifiers
import Observation
import ProjectKit
import RenderKit

/// 背景图库：内置壁纸（RenderKit 资源包里的无损 WebP）+ 本机已有的系统壁纸（只列本机上真实存在的全尺寸文件，不内置任何 Apple 图片）。
/// 缩略图在后台生成并缓存；内置壁纸选中时原样复制进工程包，本机壁纸按不超过 3840 宽转成 HEIC（16 位源自动写成 10 位），不把几十兆的原图直接复制进去。
@MainActor @Observable
final class BackgroundLibrary {
    static let shared = BackgroundLibrary()

    struct SystemWallpaper: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let url: URL
    }

    /// 本机壁纸只挑最多 4 张、彼此不同设计（同一设计的不同配色只取一张），用户下载过的全尺寸壁纸优先。
    private(set) var system: [SystemWallpaper] = []
    nonisolated static let systemLimit = 4
    private(set) var thumbnails: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var scanned = false
    nonisolated static let thumbnailSize = CGSize(width: 256, height: 144)
    nonisolated static let maximumEdge = DesktopWallpaper.maximumEdge

    /// 本机壁纸目录：系统自带的全尺寸 HEIC，以及"壁纸"设置下载到用户目录的全尺寸资源。
    static var systemDirectories: [URL] {
        [URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop", isDirectory: true)]
    }

    func scanSystemWallpapers() {
        guard !scanned else { return }
        scanned = true
        let directories = Self.systemDirectories
        Task.detached(priority: .utility) {
            let found = Self.featured(Self.listWallpapers(in: directories.reversed()), limit: Self.systemLimit)
            await MainActor.run { self.system = found }
        }
    }

    /// 同一设计（去掉末尾配色词后的名字）只留第一张，按给定顺序取前 `limit` 张。
    nonisolated static func featured(_ wallpapers: [SystemWallpaper], limit: Int) -> [SystemWallpaper] {
        var families: Set<String> = []
        var result: [SystemWallpaper] = []
        for wallpaper in wallpapers {
            let words = wallpaper.name.split(separator: " ")
            let family = (words.count > 1 && Self.colorWords.contains(words.last!.lowercased()) ? words.dropLast() : words[...]).joined(separator: " ")
            guard families.insert(family).inserted else { continue }
            result.append(wallpaper)
            if result.count == limit { break }
        }
        return result
    }
    nonisolated private static let colorWords: Set<String> = ["blue", "green", "orange", "pink", "purple", "silver", "yellow", "red", "grey", "gray", "black", "white"]

    nonisolated static func listWallpapers(in directories: [URL]) -> [SystemWallpaper] {
        var seen: Set<String> = []
        var result: [SystemWallpaper] = []
        for directory in directories {
            guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for url in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard ["heic", "jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name).inserted else { continue }
                result.append(SystemWallpaper(id: url.path, name: name, url: url))
            }
        }
        return result
    }

    /// 缓存里有就直接给；没有则后台生成一次，完成后通过可观察属性刷新视图。
    func thumbnail(for key: String, render: @escaping @Sendable () -> CGImage?) -> NSImage? {
        if let image = thumbnails[key] { return image }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        Task.detached(priority: .userInitiated) {
            let image = render()
            await MainActor.run {
                self.pending.remove(key)
                if let image { self.thumbnails[key] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
            }
        }
        return nil
    }

    /// 工程内当前背景图的预览：按路径缓存、后台解到 512 像素，面板重绘不再每次解整张原图。
    func preview(forProjectImage file: URL) -> NSImage? {
        thumbnail(for: "project." + file.path) { Self.decode(file, maximumPixelSize: 512) }
    }

    func thumbnail(for wallpaper: BundledWallpaper) -> NSImage? {
        guard let url = wallpaper.url else { return nil }
        return thumbnail(for: "bundled." + wallpaper.id) { Self.decode(url, maximumPixelSize: 256) }
    }

    func thumbnail(for wallpaper: SystemWallpaper) -> NSImage? {
        let url = wallpaper.url
        return thumbnail(for: "system." + wallpaper.id) { Self.decode(url, maximumPixelSize: 256) }
    }

    /// 内置壁纸：无损 WebP 原样复制进工程包，返回工程内相对路径。
    nonisolated static func importBundled(_ wallpaper: BundledWallpaper, into project: URL) throws -> String {
        guard let url = wallpaper.url else { throw ProjectError.invalid("内置壁纸缺失。") }
        return try ProjectStorage.importBackground(from: url, into: project)
    }

    /// 本机壁纸：解码时直接缩到不超过 3840 宽，动态壁纸取第一张（浅色）。
    /// 与新工程默认背景走同一份实现（`DesktopWallpaper`），两处不会一处改了另一处忘了。
    nonisolated static func importSystemWallpaper(_ url: URL, into project: URL) throws -> String {
        try DesktopWallpaper.importWallpaper(url, into: project)
    }

    nonisolated static func decode(_ url: URL, maximumPixelSize: Int) -> CGImage? {
        DesktopWallpaper.decode(url, maximumPixelSize: maximumPixelSize)
    }

    nonisolated static func importImage(_ image: CGImage, into project: URL) throws -> String {
        try DesktopWallpaper.importImage(image, into: project)
    }
}
