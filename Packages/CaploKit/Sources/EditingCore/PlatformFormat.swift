import Foundation

/// 各视频平台推荐的成片比例。只是 `CanvasRatio` 的命名入口：工程里仍只保存比例，平台名不落盘。
/// 不按地区分组（产品面向全球用户），面板按画面方向分横 / 竖 / 方三组，组内按平台热度混排。
public struct PlatformFormat: Identifiable, Hashable, Sendable {
    public let id: String
    public let platform: String
    /// 该平台上的版式或栏目：横屏 / 竖屏 / 帖子 / Reels …
    public let usage: String
    public let ratio: CanvasRatio

    /// 面板与菜单里的显示名："抖音 · 竖屏 9:16"。
    public var title: String { "\(platform) · \(usage) \(ratio.rawValue)" }

    public static let all: [PlatformFormat] = [
        PlatformFormat("youtube.landscape", "YouTube", "横屏", .widescreen),
        PlatformFormat("youtube.shorts", "YouTube", "Shorts", .portrait),
        PlatformFormat("tiktok.portrait", "TikTok", "竖屏", .portrait),
        PlatformFormat("instagram.reels", "Instagram", "Reels", .portrait),
        PlatformFormat("instagram.feed", "Instagram", "帖子", .feed),
        PlatformFormat("instagram.square", "Instagram", "方形", .square),
        PlatformFormat("douyin.portrait", "抖音", "竖屏", .portrait),
        PlatformFormat("douyin.landscape", "抖音", "横屏", .widescreen),
        PlatformFormat("bilibili.landscape", "哔哩哔哩", "横屏", .widescreen),
        PlatformFormat("bilibili.portrait", "哔哩哔哩", "竖屏", .portrait),
        PlatformFormat("xiaohongshu.tall", "小红书", "竖版", .tall),
        PlatformFormat("xiaohongshu.portrait", "小红书", "全屏", .portrait),
        PlatformFormat("channels.tall", "视频号", "竖版", .channels),
        PlatformFormat("channels.landscape", "视频号", "横版", .widescreen),
        PlatformFormat("kuaishou.portrait", "快手", "竖屏", .portrait),
        PlatformFormat("weibo.landscape", "微博", "横屏", .widescreen),
        PlatformFormat("facebook.feed", "Facebook", "帖子", .feed),
        PlatformFormat("facebook.reels", "Facebook", "Reels", .portrait),
        PlatformFormat("x.landscape", "X", "横屏", .widescreen),
        PlatformFormat("linkedin.landscape", "LinkedIn", "横屏", .widescreen),
    ]

    public static func formats(in orientation: CanvasRatio.Orientation) -> [PlatformFormat] { all.filter { $0.ratio.orientation == orientation } }
    public static func format(id: String) -> PlatformFormat? { all.first { $0.id == id } }
    /// 该比例对应的第一个平台，让只经平台进入的比例（4:5、6:7）在面板上有名可显。
    public static func first(matching ratio: CanvasRatio) -> PlatformFormat? { all.first { $0.ratio == ratio } }

    private init(_ id: String, _ platform: String, _ usage: String, _ ratio: CanvasRatio) {
        self.id = id; self.platform = platform; self.usage = usage; self.ratio = ratio
    }
}
