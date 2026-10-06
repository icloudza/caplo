import SwiftUI
import AppKit

/// 区域板：按画面真实比例画一块小底板，在上面直接拖位置、拉框。
/// 二维的量拆成"水平位置 / 垂直位置 / 宽度 / 高度"四条卡尺，要在脑子里拼回一个框；在底板上拖一下就是那个框。
///
/// 三种形态（坐标一律是画面归一化坐标、左上原点，`region` 以 CGRect 传入传出）：
/// - `point`：一个点，`region.origin` 就是它（文字位置）。
/// - `window`：固定大小的取景框，只能移动，`region` 的中心是它的中心（镜头位置；框的大小 = 1 / 倍率）。
/// - `box`：可移动、拉四角改大小的框（遮罩、裁剪），边长不小于 `minimumSide`。
///
/// 交互：拖动移动（在框外按下先把框移到指针处）；`box` 拖四角改大小、对角不动；
/// 中心靠近画面中线、边靠近画面边缘时吸附并画参考线；双击恢复默认；获得焦点后方向键移动 1%、⇧ 移动 10%。
public struct RegionPad: View {
    public enum Shape: Equatable {
        case point
        case window(width: Double, height: Double)
        case box(minimumSide: Double)
    }

    private let title: String
    private let shape: Shape
    private let aspect: Double
    @Binding private var region: CGRect
    private let defaultRegion: CGRect?
    private let readout: (CGRect) -> String
    private let editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var gesture: Gesture?
    @State private var guides: (vertical: Double?, horizontal: Double?) = (nil, nil)

    private enum Gesture { case move(start: CGRect, grab: CGPoint), resize(anchor: CGPoint) }
    private let maximumHeight: CGFloat = 150
    private let snap = 0.025

    public init(_ title: String, shape: Shape, aspect: Double, region: Binding<CGRect>, defaultRegion: CGRect? = nil,
                readout: @escaping (CGRect) -> String, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title; self.shape = shape
        self.aspect = aspect.isFinite && aspect > 0.2 && aspect < 5 ? aspect : 16.0 / 9
        _region = region; self.defaultRegion = defaultRegion; self.readout = readout; editing = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CaploMetrics.Spacing.s) {
            HStack(spacing: CaploMetrics.Spacing.s) {
                Text(title).font(CaploFont.body).foregroundStyle(CaploColor.textPrimary)
                Spacer(minLength: 0)
                if let defaultRegion, !Self.close(region, defaultRegion) {
                    Button("重置") { commit(defaultRegion) }
                        .buttonStyle(.plain).font(CaploFont.caption).foregroundStyle(CaploColor.accent)
                        .accessibilityLabel("重置\(title)")
                }
                Text(readout(region)).font(CaploFont.value).foregroundStyle(CaploColor.textSecondary).lineLimit(1)
            }
            GeometryReader { proxy in
                let frame = padFrame(in: proxy.size)
                pad(frame: frame)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { dragChanged($0, frame: frame) }.onEnded { _ in dragEnded() })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { if let defaultRegion { commit(defaultRegion) } })
            }
            // 按画面比例等比适配可用宽度，竖屏比例时高度封顶、宽度跟着缩并居中。
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maximumHeight)
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .onMoveCommand { direction in
                guard enabled else { return }
                let step = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 0.01
                switch direction {
                case .left: commit(moved(region, dx: -step, dy: 0))
                case .right: commit(moved(region, dx: step, dy: 0))
                case .up: commit(moved(region, dx: 0, dy: -step))
                case .down: commit(moved(region, dx: 0, dy: step))
                default: break
                }
            }
            .hoverTip(hint)
        }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityRepresentation { accessibleSliders }
    }

    private var hint: String {
        switch shape {
        case .point: "拖动摆放位置，靠近中线会吸附，双击恢复默认"
        case .window: "拖动取景框，靠近中线会吸附，双击恢复默认"
        case .box: "拖动移动，拖四角改大小，双击恢复默认"
        }
    }

    // MARK: 绘制

    /// 底板就是整个几何区域：外层已按比例适配好尺寸。
    private func padFrame(in size: CGSize) -> CGRect { CGRect(origin: .zero, size: size) }

    private func pad(frame: CGRect) -> some View {
        let rect = displayRect(in: frame)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CaploColor.surfaceCanvasWell)
                .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
            // 三分线与中线：给"放在哪"一个参照。
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: frame.minX + frame.width * fraction, y: frame.minY)); path.addLine(to: CGPoint(x: frame.minX + frame.width * fraction, y: frame.maxY))
                    path.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * fraction)); path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * fraction))
                }
            }.stroke(CaploColor.textPrimary.opacity(0.06), lineWidth: CaploMetrics.hairline)
            guidePaths(frame: frame)
            // 底板描边先画：区域与把手压在它上面，贴边时不被描边盖住。
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? CaploColor.accent : CaploColor.separator, lineWidth: focused ? 1.5 : CaploMetrics.hairline)
                .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
            // 取景框与点的参考线会伸出画面，裁在底板里；`box` 始终在画面内，不裁，贴边时四角把手也完整可见。
            if case .box = shape {
                regionShape(rect, frame: frame)
            } else {
                regionShape(rect, frame: frame).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous).path(in: frame))
            }
        }
    }

    @ViewBuilder private func regionShape(_ rect: CGRect, frame: CGRect) -> some View {
        switch shape {
        case .point:
            let center = CGPoint(x: rect.minX, y: rect.minY)
            Path { path in
                path.move(to: CGPoint(x: center.x, y: frame.minY)); path.addLine(to: CGPoint(x: center.x, y: frame.maxY))
                path.move(to: CGPoint(x: frame.minX, y: center.y)); path.addLine(to: CGPoint(x: frame.maxX, y: center.y))
            }.stroke(CaploColor.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Circle().strokeBorder(CaploColor.accent, lineWidth: 2).frame(width: 14, height: 14)
                .offset(x: center.x - 7, y: center.y - 7)
            Circle().fill(CaploColor.accent).frame(width: 4, height: 4).offset(x: center.x - 2, y: center.y - 2)
        case .window, .box:
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CaploColor.accentSoft)
                .frame(width: max(2, rect.width), height: max(2, rect.height)).offset(x: rect.minX, y: rect.minY)
            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(CaploColor.accent, lineWidth: 1.5)
                .frame(width: max(2, rect.width), height: max(2, rect.height)).offset(x: rect.minX, y: rect.minY)
            if case .box = shape {
                ForEach(Array(corners(of: rect).enumerated()), id: \.offset) { _, corner in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(CaploColor.textPrimary)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(CaploColor.accent, lineWidth: 1))
                        .frame(width: 7, height: 7).offset(x: corner.x - 3.5, y: corner.y - 3.5)
                }
            } else {
                // 取景框中心一个小十字，看得出镜头对准哪里。
                Path { path in
                    path.move(to: CGPoint(x: rect.midX - 4, y: rect.midY)); path.addLine(to: CGPoint(x: rect.midX + 4, y: rect.midY))
                    path.move(to: CGPoint(x: rect.midX, y: rect.midY - 4)); path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 4))
                }.stroke(CaploColor.accent, lineWidth: 1.5)
            }
        }
    }

    private func guidePaths(frame: CGRect) -> some View {
        Path { path in
            if let x = guides.vertical { let px = frame.minX + frame.width * x; path.move(to: CGPoint(x: px, y: frame.minY)); path.addLine(to: CGPoint(x: px, y: frame.maxY)) }
            if let y = guides.horizontal { let py = frame.minY + frame.height * y; path.move(to: CGPoint(x: frame.minX, y: py)); path.addLine(to: CGPoint(x: frame.maxX, y: py)) }
        }.stroke(CaploColor.record.opacity(0.85), lineWidth: 1)
    }

    /// 归一化区域 → 底板上的像素矩形（`point` 时宽高为 0）。
    private func displayRect(in frame: CGRect) -> CGRect {
        let normalized = normalizedRegion(region)
        return CGRect(x: frame.minX + frame.width * normalized.minX, y: frame.minY + frame.height * normalized.minY,
                      width: frame.width * normalized.width, height: frame.height * normalized.height)
    }
    /// `window` 的大小由形态决定，与传进来的 `region` 尺寸无关，只认它的中心。
    private func normalizedRegion(_ value: CGRect) -> CGRect {
        switch shape {
        case .point: return CGRect(origin: value.origin, size: .zero)
        case .window(let width, let height):
            let w = min(1, max(0.02, width)), h = min(1, max(0.02, height))
            return CGRect(x: value.midX - w / 2, y: value.midY - h / 2, width: w, height: h)
        case .box: return value
        }
    }
    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    // MARK: 拖动

    private func dragChanged(_ event: DragGesture.Value, frame: CGRect) {
        guard enabled, frame.width > 1, frame.height > 1 else { return }
        let location = CGPoint(x: (event.location.x - frame.minX) / frame.width, y: (event.location.y - frame.minY) / frame.height)
        if gesture == nil {
            editing(true); focused = true
            let start = CGPoint(x: (event.startLocation.x - frame.minX) / frame.width, y: (event.startLocation.y - frame.minY) / frame.height)
            gesture = beginGesture(at: start, pixel: event.startLocation, frame: frame)
        }
        guard let gesture else { return }
        switch gesture {
        case .move(let start, let grab):
            let target = CGRect(x: start.minX + location.x - grab.x, y: start.minY + location.y - grab.y, width: start.width, height: start.height)
            region = snappedMove(target)
        case .resize(let anchor):
            region = resized(anchor: anchor, to: location)
        }
    }

    private func dragEnded() {
        guard gesture != nil else { return }
        gesture = nil; guides = (nil, nil); editing(false)
    }

    /// 按下的位置决定这一拖做什么：`box` 的四角改大小，框内移动；在框外按下先把框（或点）移到指针处，再接着移动。
    private func beginGesture(at point: CGPoint, pixel: CGPoint, frame: CGRect) -> Gesture {
        let current = normalizedRegion(region)
        if case .box = shape {
            let display = displayRect(in: frame)
            let pixels = corners(of: display)
            if let index = pixels.indices.min(by: { hypot(pixels[$0].x - pixel.x, pixels[$0].y - pixel.y) < hypot(pixels[$1].x - pixel.x, pixels[$1].y - pixel.y) }),
               hypot(pixels[index].x - pixel.x, pixels[index].y - pixel.y) <= 10 {
                let all = corners(of: current)
                return .resize(anchor: all[3 - index])   // 对角：0↔3、1↔2
            }
        }
        if shape != .point, current.contains(point) { return .move(start: region, grab: point) }
        // 框外（或点形态）：先让中心落到按下处。
        let centered: CGRect
        switch shape {
        case .point: centered = CGRect(origin: point, size: .zero)
        case .window, .box: centered = CGRect(x: point.x - region.width / 2, y: point.y - region.height / 2, width: region.width, height: region.height)
        }
        region = snappedMove(centered)
        return .move(start: region, grab: point)
    }

    /// 移动后的区域：中心靠近中线吸附；`box` 不出画面、边靠近画面边缘吸附；点与取景框的中心限制在画面内。
    private func snappedMove(_ target: CGRect) -> CGRect {
        var result = target
        var vertical: Double?, horizontal: Double?
        switch shape {
        case .point, .window:
            var center = shape == .point ? CGPoint(x: target.minX, y: target.minY) : CGPoint(x: target.midX, y: target.midY)
            center.x = min(1, max(0, center.x)); center.y = min(1, max(0, center.y))
            if abs(center.x - 0.5) < snap { center.x = 0.5; vertical = 0.5 }
            if abs(center.y - 0.5) < snap { center.y = 0.5; horizontal = 0.5 }
            result = shape == .point ? CGRect(origin: center, size: .zero)
                : CGRect(x: center.x - target.width / 2, y: center.y - target.height / 2, width: target.width, height: target.height)
        case .box:
            result.origin.x = min(1 - target.width, max(0, target.minX))
            result.origin.y = min(1 - target.height, max(0, target.minY))
            if abs(result.midX - 0.5) < snap { result.origin.x = 0.5 - result.width / 2; vertical = 0.5 }
            else if result.minX < snap { result.origin.x = 0; vertical = 0 }
            else if 1 - result.maxX < snap { result.origin.x = 1 - result.width; vertical = 1 }
            if abs(result.midY - 0.5) < snap { result.origin.y = 0.5 - result.height / 2; horizontal = 0.5 }
            else if result.minY < snap { result.origin.y = 0; horizontal = 0 }
            else if 1 - result.maxY < snap { result.origin.y = 1 - result.height; horizontal = 1 }
        }
        guides = (vertical, horizontal)
        return result
    }

    /// 拉角：对角固定，拖动的角跟着指针，边长不小于下限、不出画面。
    private func resized(anchor: CGPoint, to point: CGPoint) -> CGRect {
        guard case .box(let minimumSide) = shape else { return region }
        var x = min(1, max(0, point.x)), y = min(1, max(0, point.y))
        if x < snap { x = 0 } else if 1 - x < snap { x = 1 }
        if y < snap { y = 0 } else if 1 - y < snap { y = 1 }
        let left = x < anchor.x, top = y < anchor.y
        let width = max(minimumSide, abs(x - anchor.x)), height = max(minimumSide, abs(y - anchor.y))
        var rect = CGRect(x: left ? anchor.x - width : anchor.x, y: top ? anchor.y - height : anchor.y, width: width, height: height)
        rect.origin.x = min(1 - rect.width, max(0, rect.minX)); rect.origin.y = min(1 - rect.height, max(0, rect.minY))
        guides = (x == 0 || x == 1 ? x : nil, y == 0 || y == 1 ? y : nil)
        return rect
    }

    private func moved(_ value: CGRect, dx: Double, dy: Double) -> CGRect {
        switch shape {
        case .point: return CGRect(x: min(1, max(0, value.minX + dx)), y: min(1, max(0, value.minY + dy)), width: 0, height: 0)
        case .window:
            let center = CGPoint(x: min(1, max(0, value.midX + dx)), y: min(1, max(0, value.midY + dy)))
            return CGRect(x: center.x - value.width / 2, y: center.y - value.height / 2, width: value.width, height: value.height)
        case .box:
            return CGRect(x: min(1 - value.width, max(0, value.minX + dx)), y: min(1 - value.height, max(0, value.minY + dy)), width: value.width, height: value.height)
        }
    }

    private func commit(_ target: CGRect) {
        guard enabled, !Self.close(target, region) else { return }
        editing(true); region = target; editing(false)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.0005 && abs(a.minY - b.minY) < 0.0005 && abs(a.width - b.width) < 0.0005 && abs(a.height - b.height) < 0.0005
    }

    // MARK: 辅助功能：读屏时拆成几条原生滑块，键盘与 VoiceOver 都能逐项调整。

    @ViewBuilder private var accessibleSliders: some View {
        VStack {
            Slider(value: coordinate(\.x), in: 0...1) { Text("\(title)水平位置") }
            Slider(value: coordinate(\.y), in: 0...1) { Text("\(title)垂直位置") }
            if case .box(let minimumSide) = shape {
                Slider(value: dimension(\.width), in: minimumSide...1) { Text("\(title)宽度") }
                Slider(value: dimension(\.height), in: minimumSide...1) { Text("\(title)高度") }
            }
        }
    }
    private func coordinate(_ key: KeyPath<CGPoint, CGFloat>) -> Binding<Double> {
        let isX = key == \CGPoint.x
        return Binding(get: {
            let center = shape == .point ? region.origin : CGPoint(x: region.midX, y: region.midY)
            return Double(center[keyPath: key])
        }, set: { value in
            let current = shape == .point ? region.origin : CGPoint(x: region.midX, y: region.midY)
            commit(moved(region, dx: isX ? value - current.x : 0, dy: isX ? 0 : value - current.y))
        })
    }
    private func dimension(_ key: WritableKeyPath<CGSize, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(region.size[keyPath: key]) }, set: { value in
            var next = region
            next.size[keyPath: key] = value
            next.origin.x = min(1 - next.width, max(0, next.minX)); next.origin.y = min(1 - next.height, max(0, next.minY))
            commit(next)
        })
    }
}
