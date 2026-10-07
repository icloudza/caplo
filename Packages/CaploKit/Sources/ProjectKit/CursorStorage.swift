import Foundation
import EditingCore

/// 每个光标仅保存一次；工程复制和移动时一并携带，不依赖应用缓存。
public enum CursorStorage {
    private static func file(_ id: String, in root: URL) throws -> URL {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ProjectError.invalid(String(localized: "光标标识无效。")) }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent("Cursors/\(id).json").resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/Cursors/") else { throw ProjectError.invalid(String(localized: "光标路径无效。")) }
        return file
    }
    public static func save(_ asset: CapturedCursor, in root: URL) throws {
        guard asset.isValid else { throw ProjectError.invalid(String(localized: "光标图像无效。")) }
        let url = try file(asset.id, in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try JSONEncoder().encode(asset).write(to: url, options: .atomic) }
    }
    public static func load(ids: Set<String>, in root: URL) -> [String: CapturedCursor] {
        var result: [String: CapturedCursor] = [:], bytes = 0
        // 限制外部工程资源体积，坏图仅回退默认光标，不阻塞视频打开。
        for id in ids.sorted().prefix(2048) {
            guard let url = try? file(id, in: root),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_500_000,
                  bytes + size <= 64 * 1_048_576,
                  let data = try? Data(contentsOf: url), let asset = try? JSONDecoder().decode(CapturedCursor.self, from: data),
                  asset.isValid, asset.id == id else { continue }
            bytes += size; result[id] = asset
        }
        return result
    }
}
