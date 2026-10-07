import Foundation
import EditingCore

/// 指针事件文件的编解码：录制器每 10 秒一段、每段一份。
///
/// 60 Hz 采样的明文 JSON 两小时就有 36 MB；新文件是 LZFSE 无损压缩的同一份 JSON，约小 12 倍，
/// 解压只要几毫秒（解析 JSON 本身才是大头）。文件只在片段提交时写一次，压缩不碰实时保存路径。
/// 读取按内容判断：明文 JSON 以 `[` 开头，其余按 LZFSE 解压——旧工程与测试夹具的明文文件照常读。
/// `edits.json` 不压缩：它随每次编辑重写，压缩要让每次保存再多花一倍时间，而它本来只有几 MB。
public enum PointerEventFile {
    /// 新片段事件文件的扩展名（`Events/000000.json.lzfse`）。
    public static let pathExtension = "json.lzfse"

    public static func data(for events: [PointerSample]) throws -> Data {
        try (JSONEncoder().encode(events) as NSData).compressed(using: .lzfse) as Data
    }

    public static func events(from data: Data) throws -> [PointerSample] {
        let whitespace = Set(" \n\r\t".utf8)
        let plain = data.first { !whitespace.contains($0) } == UInt8(ascii: "[")
        let json = plain ? data : try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode([PointerSample].self, from: json)
    }
}
