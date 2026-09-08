import Foundation

/// 用户绘制的光标样式：四组各十款，PNG 由 96 点 SVG 光栅化为 384 像素（4×）放在资源包，热点按 96 网格归一化。
/// 箭头 / 简约组热点在尖端，手形组在指尖（按光栅最高点求得），圆圈组在圆心，笔类在笔尖。
public struct CursorStyle: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable { case arrow, pointer, minimal, circle }
    public let id: String
    public let group: Group
    public let title: String
    /// 热点（0…1，相对整张 96 点画布，y 向下）。
    public let hotspotX: Double
    public let hotspotY: Double
    public var resource: String { "cursor-" + id }

    public static let all: [CursorStyle] = [
        CursorStyle(id: "1-01", group: .arrow, title: "曜石经典", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-02", group: .arrow, title: "极简雪白", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-03", group: .arrow, title: "圆角奶油", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-04", group: .arrow, title: "电光蓝", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-05", group: .arrow, title: "落日软糖", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-06", group: .arrow, title: "极光棱镜", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-07", group: .arrow, title: "复古像素", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-08", group: .arrow, title: "薄荷果冻", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-09", group: .arrow, title: "双色错印", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "1-10", group: .arrow, title: "香槟金属", hotspotX: 0.1875, hotspotY: 0.1042),
        CursorStyle(id: "2-01", group: .minimal, title: "圆润曜黑", hotspotX: 0.2396, hotspotY: 0.1458),
        CursorStyle(id: "2-02", group: .minimal, title: "纯白短箭", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-03", group: .minimal, title: "纤线黑曜", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-04", group: .minimal, title: "双线雪白", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-05", group: .minimal, title: "莓蓝软糖", hotspotX: 0.2396, hotspotY: 0.1458),
        CursorStyle(id: "2-06", group: .minimal, title: "霓虹像素", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-07", group: .minimal, title: "冰透极光", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-08", group: .minimal, title: "琥珀微光", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-09", group: .minimal, title: "彩虹叠影", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "2-10", group: .minimal, title: "酸橙飞翼", hotspotX: 0.1875, hotspotY: 0.125),
        CursorStyle(id: "3-01", group: .pointer, title: "经典黑手", hotspotX: 0.3075, hotspotY: 0.0781),
        CursorStyle(id: "3-02", group: .pointer, title: "经典白手", hotspotX: 0.3078, hotspotY: 0.0755),
        CursorStyle(id: "3-03", group: .pointer, title: "纤线手套", hotspotX: 0.366, hotspotY: 0.0729),
        CursorStyle(id: "3-04", group: .pointer, title: "双线手套", hotspotX: 0.3666, hotspotY: 0.0495),
        CursorStyle(id: "3-05", group: .pointer, title: "橘子软糖", hotspotX: 0.3076, hotspotY: 0.0833),
        CursorStyle(id: "3-06", group: .pointer, title: "薄荷像素", hotspotX: 0.3529, hotspotY: 0.0938),
        CursorStyle(id: "3-07", group: .pointer, title: "冰彩全息", hotspotX: 0.3665, hotspotY: 0.0729),
        CursorStyle(id: "3-08", group: .pointer, title: "金橙微光", hotspotX: 0.3075, hotspotY: 0.0781),
        CursorStyle(id: "3-09", group: .pointer, title: "彩虹叠影", hotspotX: 0.3078, hotspotY: 0.0781),
        CursorStyle(id: "3-10", group: .pointer, title: "奶油陶瓷", hotspotX: 0.308, hotspotY: 0.0807),
        CursorStyle(id: "4-01", group: .circle, title: "透明玻璃", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-02", group: .circle, title: "磨砂圆片", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-03", group: .circle, title: "石墨圆片", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-04", group: .circle, title: "白瓷圆片", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-05", group: .circle, title: "细线圆环", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-06", group: .circle, title: "蓝灰圆环", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-07", group: .circle, title: "中心定位", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-08", group: .circle, title: "精细十字", hotspotX: 0.5, hotspotY: 0.5),
        CursorStyle(id: "4-09", group: .circle, title: "石墨铅笔", hotspotX: 0.2396, hotspotY: 0.2188),
        CursorStyle(id: "4-10", group: .circle, title: "白色标记笔", hotspotX: 0.2292, hotspotY: 0.2292),
    ]
    public static func styles(in group: Group) -> [CursorStyle] { all.filter { $0.group == group } }
    public static func style(id: String) -> CursorStyle? { all.first { $0.id == id } }
}
