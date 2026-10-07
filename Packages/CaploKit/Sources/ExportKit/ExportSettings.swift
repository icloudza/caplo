import Foundation
import UniformTypeIdentifiers
import EditingCore

/// 导出设置：格式、分辨率、帧率、画质、声音与导出后的动作。导出窗口编辑它，记在偏好里下次沿用。
///
/// 分辨率按**短边**计（720 / 1080 / 1440 / 2160），长边随画面比例伸展：16:9 的 1080p 是 1920×1080，
/// 9:16 是 1080×1920，1:1 是 1080×1080——横竖屏都得到各平台的标准尺寸。
public struct ExportSettings: Codable, Equatable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable, Identifiable {
        case h264, hevc, proRes, gif
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .h264: "MP4 · H.264"
            case .hevc: "MP4 · HEVC（H.265）"
            case .proRes: "MOV · ProRes 422"
            case .gif: "GIF 动图"
            }
        }
        public var detail: String {
            switch self {
            case .h264: "兼容性最好：任何播放器、网站、聊天软件都能直接播放。"
            case .hevc: "同样画质体积小约 40%；需要较新的设备与播放器，部分网站会转码。"
            case .proRes: "几乎无损、体积很大，交给 Final Cut Pro、达芬奇等后期软件继续剪辑。"
            case .gif: "无声、循环播放，适合放进文档、Issue 与聊天里演示一个小操作；体积随画面变化。"
            }
        }
        public var fileExtension: String {
            switch self { case .h264, .hevc: "mp4"; case .proRes: "mov"; case .gif: "gif" }
        }
        public var contentType: UTType {
            switch self { case .h264, .hevc: .mpeg4Movie; case .proRes: .quickTimeMovie; case .gif: .gif }
        }
        /// 有没有"画质"可选：ProRes 由编码器按档位定码率，GIF 按调色板压缩。
        public var hasQuality: Bool { self == .h264 || self == .hevc }
        public var hasAudio: Bool { self != .gif }
    }

    public enum Resolution: Int, Codable, CaseIterable, Sendable, Identifiable {
        case p480 = 480, p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
        public var id: Int { rawValue }
        public var title: String { self == .p2160 ? "4K" : "\(rawValue)p" }
        /// 视频格式可选 720p…4K；GIF 每帧都是整张位图，4K 动图动辄上百兆，只给到 1080p，另加 480p。
        public static func options(for format: Format) -> [Resolution] {
            format == .gif ? [.p480, .p720, .p1080] : [.p720, .p1080, .p1440, .p2160]
        }
    }

    public enum Quality: String, Codable, CaseIterable, Sendable, Identifiable {
        case standard, high, maximum
        public var id: String { rawValue }
        public var title: String {
            switch self { case .standard: "标准"; case .high: "高"; case .maximum: "极高" }
        }
        /// H.264 每像素每帧的比特数。屏幕内容大块平坦、边缘锐利：0.14 给文字留足余量（1080p60 约 17 Mbps）；
        /// 标准档体积约减半、静态界面看不出差别，极高档给大量滚动与细小文字。
        var bitsPerPixel: Double {
            switch self { case .standard: 0.08; case .high: 0.14; case .maximum: 0.22 }
        }
    }

    public var format: Format = .h264
    public var resolution: Resolution = .p1080
    /// 视频帧率；nil 表示与录制相同。
    public var frameRate: Int?
    /// GIF 帧率：动图不需要也不该用视频的帧率，15 帧观感已经连贯、体积只有 30 帧的一半。
    public var gifFrameRate = 15
    public var quality: Quality = .high
    public var includesAudio = true
    /// AAC 码率（比特 / 秒）。ProRes 不用它，声音按 24 位 PCM 写。
    public var audioBitRate = 256_000
    /// 导出完成后在访达中显示。它是一项独立偏好（`export.revealsInFinder`，设置页与导出窗口共用），
    /// 不随"记住这些设置"的开关变化，所以不进编码。
    public var revealsInFinder = true

    public init() {}

    public static let audioBitRates = [128_000, 192_000, 256_000, 320_000]
    public static let gifFrameRates = [10, 15, 20, 30]

    /// 换格式时把不适用的选项拉回可用范围（例如从 4K 视频换成 GIF 时退到 1080p）。
    public mutating func normalize() {
        let allowed = Resolution.options(for: format)
        if !allowed.contains(resolution) { resolution = allowed.last { $0.rawValue <= resolution.rawValue } ?? allowed[0] }
        if !Self.gifFrameRates.contains(gifFrameRate) { gifFrameRate = 15 }
        if !Self.audioBitRates.contains(audioBitRate) { audioBitRate = 256_000 }
    }

    /// 成片像素尺寸。
    public func outputSize(ratio: CanvasRatio) -> (width: Int, height: Int) {
        ratio.outputSize(shortEdge: resolution.rawValue)
    }

    /// 实际输出帧率：GIF 用它自己的帧率；视频按选择（不超过录制帧率），4K 封顶 60（H.264 / HEVC 硬件编码 4K 只到 60 帧）。
    public func outputFrameRate(recorded: Double) -> Double {
        if format == .gif { return Double(gifFrameRate) }
        let source = max(24, min(120, recorded.isFinite ? recorded : 30))
        let wanted = frameRate.map { min(Double($0), source) } ?? source
        return resolution.rawValue >= 2160 ? min(60, wanted) : wanted
    }

    /// 视频帧率的可选项：0 表示"与录制相同"，其余是比录制低的常用帧率。
    public static func frameRateOptions(recorded: Double) -> [Int] {
        let source = Int(max(24, min(120, recorded.isFinite ? recorded : 30)).rounded())
        return [0] + [60, 30, 24].filter { $0 < source }
    }

    /// 视频码率（比特 / 秒）。ProRes 与 GIF 不由我们指定，返回 nil。
    public func videoBitRate(width: Int, height: Int, frameRate: Double) -> Int? {
        guard format.hasQuality else { return nil }
        // HEVC 在同样观感下码率约为 H.264 的六成。
        let factor = format == .hevc ? 0.6 : 1
        let raw = Double(width * height) * max(1, frameRate) * quality.bitsPerPixel * factor
        return Int(min(150_000_000, max(2_000_000, raw)))
    }

    /// 预计文件大小（字节）：视频按码率、ProRes 按 Apple 白皮书的 422 档（1080p30 约 147 Mbps，按像素与帧率折算），
    /// 声音按 AAC 码率或 PCM。GIF 体积随画面内容变化太大，返回 nil。
    public func estimatedBytes(ratio: CanvasRatio, recordedFrameRate: Double, duration: Double) -> Int64? {
        guard format != .gif, duration.isFinite, duration > 0 else { return nil }
        let size = outputSize(ratio: ratio), rate = outputFrameRate(recorded: recordedFrameRate)
        let video: Double
        if let bitRate = videoBitRate(width: size.width, height: size.height, frameRate: rate) { video = Double(bitRate) }
        else { video = Double(size.width * size.height) * rate * (147_000_000 / (1920 * 1080 * 29.97)) }
        let audio: Double = includesAudio ? (format == .proRes ? 48_000 * 24 * 2 : Double(audioBitRate)) : 0
        return Int64((video + audio) * duration / 8)
    }

    // MARK: 记在偏好里

    static let defaultsKey = "export.settings"
    static let folderKey = "export.folder"
    static let rememberKey = "export.remember"
    public static let revealKey = "export.revealsInFinder"

    /// 记住的设置；没记过、或用户关掉了"记住"、或旧版本字段对不上，就用默认值。
    public static func remembered(in defaults: UserDefaults = .standard) -> ExportSettings {
        var value = ExportSettings()
        if remembersChoices(in: defaults), let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(ExportSettings.self, from: data) { value = decoded }
        value.revealsInFinder = defaults.object(forKey: revealKey) as? Bool ?? true
        value.normalize()
        return value
    }
    public func remember(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    /// 忘掉记住的参数：下次导出窗口回到默认值（保存位置另算，见 `defaultFolder`）。
    public static func forget(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: defaultsKey) }
    public static func hasRememberedSettings(in defaults: UserDefaults = .standard) -> Bool { defaults.data(forKey: defaultsKey) != nil }

    /// 导出窗口里"记住这些设置"的勾选状态，默认勾上。
    public static func remembersChoices(in defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: rememberKey) as? Bool ?? true }
    public static func setRemembersChoices(_ value: Bool, in defaults: UserDefaults = .standard) { defaults.set(value, forKey: rememberKey) }

    // MARK: 保存位置

    /// 导出窗口打开时的保存位置：设置页里选过的文件夹（还在的话），否则系统"影片"文件夹。
    /// 导出窗口里随时可以另选；勾着"记住这些设置"导出时，那次的文件夹会成为新的默认位置。
    public static func defaultFolder(in defaults: UserDefaults = .standard) -> URL {
        var directory: ObjCBool = false
        if let path = defaults.string(forKey: folderKey), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return moviesFolder
    }
    /// 设置默认保存位置；nil 恢复为"影片"文件夹。
    public static func setDefaultFolder(_ url: URL?, in defaults: UserDefaults = .standard) {
        if let url { defaults.set(url.standardizedFileURL.path, forKey: folderKey) } else { defaults.removeObject(forKey: folderKey) }
    }
    public static func hasCustomFolder(in defaults: UserDefaults = .standard) -> Bool { defaults.string(forKey: folderKey) != nil }
    public static var moviesFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// 文件名里不能出现的字符换成"-"，两端空白去掉；空名返回 nil。
    /// 手打的视频扩展名去掉（导出时按格式再加，免得出现"演示.mp4.mp4"）；
    /// 长度按 UTF-8 不超过 200 字节截断（系统上限 255，留出扩展名与"副本"后缀的余地），截在完整的字上。
    public static func sanitizedFileName(_ name: String) -> String? {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()
        if let suffix = [".mp4", ".mov", ".m4v", ".gif"].first(where: { lowered.hasSuffix($0) && lowered.count > $0.count }) {
            cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? nil : cleaned
    }

    /// 一行概括（设置页显示当前记住的参数）。
    public var summary: String {
        var parts = [format.title, resolution.title]
        if format == .gif { parts.append("\(gifFrameRate) fps") } else { parts.append(frameRate.map { "\($0) fps" } ?? "原始帧率") }
        if format.hasQuality { parts.append("画质" + quality.title) }
        if format.hasAudio { parts.append(includesAudio ? (format == .proRes ? "PCM 声音" : "AAC \(audioBitRate / 1000) kbps") : "无声") }
        return parts.joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey {
        case format, resolution, frameRate, gifFrameRate, quality, includesAudio, audioBitRate
    }
    /// 逐项缺省：以后加字段，旧偏好照样读得出来，不会整份作废。
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? box.decodeIfPresent(Format.self, forKey: .format)) ?? .h264
        resolution = (try? box.decodeIfPresent(Resolution.self, forKey: .resolution)) ?? .p1080
        frameRate = try? box.decodeIfPresent(Int.self, forKey: .frameRate)
        gifFrameRate = (try? box.decodeIfPresent(Int.self, forKey: .gifFrameRate)) ?? 15
        quality = (try? box.decodeIfPresent(Quality.self, forKey: .quality)) ?? .high
        includesAudio = (try? box.decodeIfPresent(Bool.self, forKey: .includesAudio)) ?? true
        audioBitRate = (try? box.decodeIfPresent(Int.self, forKey: .audioBitRate)) ?? 256_000
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(format, forKey: .format); try box.encode(resolution, forKey: .resolution)
        try box.encodeIfPresent(frameRate, forKey: .frameRate); try box.encode(gifFrameRate, forKey: .gifFrameRate)
        try box.encode(quality, forKey: .quality); try box.encode(includesAudio, forKey: .includesAudio)
        try box.encode(audioBitRate, forKey: .audioBitRate)
    }
}
