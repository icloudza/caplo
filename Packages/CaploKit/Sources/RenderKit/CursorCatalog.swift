import AppKit
import CoreImage
import EditingCore

/// 主题预览与成片共用去透明边后的纹理，避免缩略图与实际大小不一致。
public enum CursorCatalog {
    public static func themeImage(_ theme: String) -> NSImage? {
        guard let style = PointerEffects.Style(rawValue: theme),
              let asset = CursorAssets.asset(style: style, shape: .arrow),
              let cg = CIContext().createCGImage(asset.image, from: asset.image.extent) else { return nil }
        return NSImage(cgImage: cg, size: asset.image.extent.size)
    }
}
