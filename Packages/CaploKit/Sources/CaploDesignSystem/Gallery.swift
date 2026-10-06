import SwiftUI

/// 组件画廊：离屏渲染用于评审令牌与控件的各种状态，不进入产品界面。
public struct DesignSystemGallery: View {
    @State private var chip = "16:9"
    @State private var segment = "左分屏"
    @State private var swatch: String? = "violet"
    @State private var slider = 40.0
    @State private var slider2 = 0.0
    @State private var toggleOn = true
    @State private var toggleOff = false
    @State private var rail = "canvas"
    @State private var seconds = 0.6
    @State private var opacity = 0.45
    @State private var angle = -30.0
    @State private var zoom = 1.5
    @State private var point = CGRect(x: 0.5, y: 0.36, width: 0, height: 0)
    @State private var box = CGRect(x: 0.18, y: 0.22, width: 0.42, height: 0.36)

    public init() {}

    private let swatches: [Swatch] = [
        Swatch(id: "violet", name: "鸢尾", colors: [Color(red: 0.06, green: 0.12, blue: 0.29), Color(red: 0.18, green: 0.44, blue: 0.88)]),
        Swatch(id: "lagoon", name: "湖水", colors: [Color(red: 0.12, green: 0.44, blue: 0.55), Color(red: 0.56, green: 0.83, blue: 0.78)]),
        Swatch(id: "ember", name: "余烬", colors: [Color(red: 0.91, green: 0.42, blue: 0.29), Color(red: 0.96, green: 0.76, blue: 0.55)]),
        Swatch(id: "ink", name: "墨", colors: [Color(red: 0.11, green: 0.12, blue: 0.23), Color(red: 0.29, green: 0.34, blue: 0.5)]),
        Swatch(id: "solid-accent", name: "纯色强调", colors: [CaploColor.accent]),
        Swatch(id: "solid-zoom", name: "纯色蓝", colors: [CaploColor.zoom]),
        Swatch(id: "solid-white", name: "纯白", colors: [Color.white]),
    ]

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            IconRail([
                RailItem(id: "canvas", title: "布局", symbol: "rectangle.on.rectangle", shortcut: "1"),
                RailItem(id: "cursor", title: "光标", symbol: "cursorarrow", shortcut: "2"),
                RailItem(id: "focus", title: "聚焦", symbol: "viewfinder", shortcut: "3"),
                RailItem(id: "camera", title: "人像", symbol: "person.crop.square", shortcut: "4"),
                RailItem(id: "audio", title: "音频", symbol: "waveform", shortcut: "5"),
                RailItem(id: "crop", title: "裁剪", symbol: "crop", shortcut: "6"),
                RailItem(id: "mask", title: "遮罩", symbol: "rectangle.dashed", shortcut: "7"),
            ], selection: $rail, disabled: ["mask"])
            PanelContainer("画面布局") {
                PanelSection("画面比例") {
                    ChipGroup(["原始", "16:9", "1:1", "4:3", "9:16"], selection: $chip) { $0 }
                    SegmentedBar(["叠加", "全屏", "左分屏", "右分屏"], selection: $segment) { $0 }
                    SelectField(value: "抖音 · 竖屏 9:16", placeholder: "按平台选择…", accessibilityName: "平台比例", sections: [
                        SelectField.Section("横屏", items: [
                            SelectField.Item(id: "youtube", title: "YouTube · 横屏 16:9") {},
                            SelectField.Item(id: "bilibili", title: "哔哩哔哩 · 横屏 16:9") {},
                        ]),
                        SelectField.Section("竖屏", items: [SelectField.Item(id: "douyin", title: "抖音 · 竖屏 9:16", checked: true) {}]),
                    ])
                }
                PanelSection("样式", info: "边距与内边距均相对画布短边") {
                    LabeledCaliper("边距", value: $slider, configuration: CaliperConfiguration(track: .scroll, range: 0...100, step: 1, major: 10, mid: 5, pxPerUnit: 6, defaultValue: 40))
                    LabeledSlider("内边距", value: $slider2, in: 0...100, defaultValue: 0)
                    Toggle(isOn: $toggleOn) { SettingLabel("阴影", systemImage: "square.3.layers.3d") }.toggleStyle(StudioToggleStyle())
                    Toggle(isOn: $toggleOff) { SettingLabel("固定聚焦区域", systemImage: "pin") }.toggleStyle(StudioToggleStyle()).disabled(true)
                }
                PanelSection("背景") {
                    SwatchGrid(swatches, selection: $swatch)
                }
                // 卡尺之外的参数控件：秒用步进器，比例用胶囊滑条，角度用旋钮，工具栏缩放用细滑条，二维位置与区域用底板。
                PanelSection("参数控件") {
                    ValueStepper("推近时长", value: $seconds, in: 0.05...2, step: 0.05, defaultValue: 0.6, format: { String(format: "%.2f 秒", $0) })
                    FillSlider("不透明度", value: $opacity, in: 0...1, defaultValue: 0.45, detents: [0.5], format: { String(format: "%.0f%%", $0 * 100) })
                    AngleDial("角度", value: $angle)
                    // 工具栏用的细滑条（时间线缩放）：图标 + 细轨 + 小圆钮。
                    ThinSlider("时间线缩放", systemImage: "arrow.left.and.right", value: $zoom, in: -2...4).frame(width: 120)
                    RegionPad("位置", shape: .point, aspect: 16.0 / 9, region: $point,
                              readout: { String(format: "水平 %.0f%% · 垂直 %.0f%%", $0.minX * 100, $0.minY * 100) })
                    RegionPad("区域", shape: .box(minimumSide: 0.05), aspect: 16.0 / 9, region: $box,
                              readout: { String(format: "宽 %.0f%% · 高 %.0f%%", $0.width * 100, $0.height * 100) })
                }
                PanelSection("按钮") {
                    HStack(spacing: CaploMetrics.Spacing.s) {
                        Button("导出") {}.buttonStyle(StudioButtonStyle(.primary, size: .large))
                        Button("重置布局") {}.buttonStyle(StudioButtonStyle(.secondary))
                        Button("删除") {}.buttonStyle(StudioButtonStyle(.destructive))
                    }
                    HStack(spacing: CaploMetrics.Spacing.s) {
                        Button("小按钮") {}.buttonStyle(StudioButtonStyle(.secondary, size: .small))
                        Button("安静") {}.buttonStyle(StudioButtonStyle(.quiet, size: .small))
                        Button("禁用") {}.buttonStyle(StudioButtonStyle(.primary, size: .small)).disabled(true)
                        Button { } label: { Image(systemName: "gearshape") }.buttonStyle(StudioIconButtonStyle())
                        Button { } label: { Image(systemName: "eye") }.buttonStyle(StudioIconButtonStyle(active: true))
                    }
                }
            }
            VStack(alignment: .leading, spacing: CaploMetrics.Spacing.l) {
                Text("录制条").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                FloatingBar {
                    Button { } label: { Image(systemName: "xmark") }.buttonStyle(StudioIconButtonStyle(size: .small))
                    Image(systemName: "display").font(.system(size: 14, weight: .medium)).foregroundStyle(CaploColor.textSecondary)
                        .frame(width: CaploMetrics.ControlHeight.medium, height: CaploMetrics.ControlHeight.medium)
                    IconDropdown(symbol: "gearshape", accessibilityName: "录制设置") { [.item("主显示器", checked: true, action: {})] }
                    SourceDropdown(symbol: "video", offSymbol: "video.slash", title: "摄像头 关", isOff: true, accessibilityName: "摄像头") { [.item("关闭", checked: true, action: {})] }
                    SourceDropdown(symbol: "mic", title: "内建麦克风", accessibilityName: "麦克风") { [.item("内建麦克风", checked: true, action: {})] }
                    SourceDropdown(symbol: "speaker.wave.2", title: "系统声音", accessibilityName: "系统声音") { [.item("全部系统声音", checked: true, action: {})] }
                    FloatingBarDivider()
                    RecordButton {}
                }
                FloatingBar {
                    Circle().fill(CaploColor.record).frame(width: 8, height: 8)
                    Text("00:12.4").font(CaploFont.timer).foregroundStyle(CaploColor.textPrimary)
                    FloatingBarDivider()
                    Button { } label: { Image(systemName: "pause.fill") }.buttonStyle(StudioIconButtonStyle())
                    Button { } label: { Image(systemName: "stop.fill").foregroundStyle(CaploColor.record) }.buttonStyle(StudioIconButtonStyle())
                }
                Text("语义色").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                HStack(spacing: CaploMetrics.Spacing.s) {
                    ForEach([("accent", CaploColor.accent), ("zoom", CaploColor.zoom), ("record", CaploColor.record), ("audio", CaploColor.audio), ("warning", CaploColor.warning)], id: \.0) { name, color in
                        VStack(spacing: CaploMetrics.Spacing.xs) {
                            RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).fill(color).frame(width: 56, height: 36)
                            Text(name).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                        }
                    }
                }
                Text("表面").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                HStack(spacing: CaploMetrics.Spacing.s) {
                    ForEach([("window", CaploColor.surfaceWindow), ("panel", CaploColor.surfacePanel), ("raised", CaploColor.surfaceRaised), ("well", CaploColor.surfaceCanvasWell)], id: \.0) { name, color in
                        VStack(spacing: CaploMetrics.Spacing.xs) {
                            RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).fill(color).frame(width: 56, height: 36)
                                .overlay(RoundedRectangle(cornerRadius: CaploMetrics.Radius.control).strokeBorder(CaploColor.separator))
                            Text(name).font(CaploFont.caption).foregroundStyle(CaploColor.textSecondary)
                        }
                    }
                }
                Text("文字层级").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正文 13 · 主要文字").font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                    Text("分区标题 12 · 次级").font(CaploFont.sectionTitle).foregroundStyle(CaploColor.textSecondary)
                    Text("说明 11 · 三级").font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                    Text("数值 12 · 00:12.40 / 1.80×").font(CaploFont.value).foregroundStyle(CaploColor.textSecondary)
                }
            }
            .padding(CaploMetrics.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CaploColor.surfaceCanvasWell)
        }
        .background(CaploColor.surfaceWindow)
    }
}
