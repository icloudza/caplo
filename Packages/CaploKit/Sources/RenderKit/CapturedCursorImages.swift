import Foundation
import CoreImage
import EditingCore

/// 按内容标识缓存原始位图，避免播放时反复解码；预览和导出共用相同解码规则。
final class CapturedCursorImages: @unchecked Sendable {
    static let shared = CapturedCursorImages()
    private let cache = NSCache<NSString, CIImage>()
    private init() { cache.totalCostLimit = 32 * 1_048_576; cache.countLimit = 256 }
    func image(_ cursor: CapturedCursor) -> CIImage? {
        let key = cursor.id as NSString
        if let image = cache.object(forKey: key) { return image }
        guard cursor.isValid, let image = CIImage(data: cursor.png),
              image.extent.width == Double(cursor.width), image.extent.height == Double(cursor.height) else { return nil }
        cache.setObject(image, forKey: key, cost: cursor.width * cursor.height * 4)
        return image
    }
}
