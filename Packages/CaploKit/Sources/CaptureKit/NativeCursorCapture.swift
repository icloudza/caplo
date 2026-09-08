import AppKit
import EditingCore

/// 捕获系统光标位图、像素热点与 Retina 比例。
/// 使用公开 API；读不到系统光标时不以本应用光标冒充其他应用的实际光标。
@MainActor
enum NativeCursorCapture {
    static func capture(_ cursor: NSCursor) -> CapturedCursor? {
        let image = cursor.image, size = cursor.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        var rect = NSRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), cg.width <= 512, cg.height <= 512 else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let scale = Double(cg.width) / size.width
        let asset = CapturedCursor(png: png, width: cg.width, height: cg.height,
                                   hotspotX: cursor.hotSpot.x * scale, hotspotY: cursor.hotSpot.y * Double(cg.height) / size.height, scale: scale)
        return asset.isValid ? asset : nil
    }
}
