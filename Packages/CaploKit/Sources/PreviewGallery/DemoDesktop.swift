import AppKit
import CoreImage

/// 官网演示视频里"被录下来的屏幕"：一整块 macOS 桌面——本机壁纸、半透明菜单栏（右侧有 Caplo 录制中图标）、
/// 带系统阴影与毛玻璃侧栏的任务清单窗口。窗口正文是不含文字的骨架（色块、灰条、彩色胶囊，参照 cap.so 的插画）：
/// 看的人注意力在镜头与操作上，不去读界面里的字；悬停、按下、输入这些界面反馈照常逐帧变化。
/// 按 1440 × 900 点（13 寸 MacBook Air 默认分辨率）绘制、2× 像素输出；坐标一律左上为原点、y 向下，和指针采样一致。
@MainActor
final class DemoDesktop {
    static let size = CGSize(width: 1440, height: 900)
    static let scale = 2.0
    static var pixelSize: CGSize { CGSize(width: size.width * scale, height: size.height * scale) }

    /// 一帧界面的全部可变状态；相邻两帧相等就不重画、不写帧。
    struct Frame: Equatable {
        enum Stage: Equatable { case initial, editing, added, started, finished }
        var stage = Stage.initial
        /// 新任务标题已敲下的键数（只在 editing 阶段有意义）；骨架里每敲一下，标题灰条长一截。
        var typed = 0
        var caret = false
        var hover: Target?
        var pressed = false
    }

    enum Target: Equatable { case newTask, row(Int), checkbox(Int), status(Int), title(Int) }

    /// 新任务标题一共敲几下。
    static let keystrokes = 6

    // MARK: 几何（点，左上原点）

    static let window = CGRect(x: 150, y: 96, width: 980, height: 660)
    static let sidebar = CGRect(x: window.minX + 8, y: window.minY + 8, width: 200, height: window.height - 16)
    static let contentLeft = sidebar.maxX + 16
    static let contentRight = window.maxX - 24
    static let rowTop = window.minY + 236
    static let rowHeight = 42.0

    static func rowRect(_ index: Int) -> CGRect {
        CGRect(x: contentLeft - 8, y: rowTop + Double(index) * rowHeight, width: contentRight - contentLeft + 16, height: rowHeight)
    }
    static func checkbox(_ index: Int) -> CGPoint { CGPoint(x: contentLeft + 17, y: rowRect(index).midY) }
    /// 状态列放得偏右：新建任务、改状态、勾选三处操作横向跨度超过 1.8 倍推近时一个点击簇的宽度（约 400 点），
    /// 相机才会在三处之间平移——挤在一个簇里，推近后镜头就不动了，看不出跟随。
    static func statusRect(_ index: Int) -> CGRect { CGRect(x: contentLeft + 460, y: rowRect(index).midY - 9, width: 56, height: 18) }
    static func titleField(_ index: Int) -> CGRect { CGRect(x: contentLeft + 28, y: rowRect(index).midY - 14, width: 240, height: 28) }
    /// 列表末尾的"＋ 新建"行内按钮；新任务插在它原来的位置，按钮顺延一行。
    static func newTaskRect(rows: Int) -> CGRect {
        let row = rowRect(rows)
        return CGRect(x: contentLeft - 2, y: row.midY - 14, width: 92, height: 28)
    }

    /// 一行任务：标题灰条的长度代替文字，状态用胶囊颜色区分（绿 = 完成、蓝 = 进行中、灰 = 未开始）。
    struct Row {
        enum Status { case todo, active, done }
        var title: Double; var status: Status; var owner: Double; var isNew = false
        var done: Bool { status == .done }
    }

    static func rows(_ frame: Frame) -> [Row] {
        var rows = [Row(title: 132, status: .done, owner: 30), Row(title: 158, status: .active, owner: 18), Row(title: 118, status: .done, owner: 34),
                    Row(title: 176, status: .todo, owner: 18), Row(title: 146, status: .done, owner: 30), Row(title: 104, status: .todo, owner: 26)]
        if frame.stage != .initial {
            let typed = frame.stage == .editing ? frame.typed : keystrokes
            let started = frame.stage == .started || frame.stage == .finished
            rows.append(Row(title: Double(typed) * 14, status: started ? .active : .todo, owner: 18, isNew: true))
        }
        if frame.stage == .finished { rows[1].status = .done }
        return rows
    }

    /// 指针下是哪个控件：决定悬停反馈，也决定录下来的指针形状（标题输入框里是 I 形）。
    static func target(at point: CGPoint, frame: Frame) -> Target? {
        let rows = rows(frame)
        if newTaskRect(rows: rows.count).insetBy(dx: -2, dy: -4).contains(point) { return .newTask }
        for index in rows.indices where rowRect(index).contains(point) {
            if hypot(point.x - checkbox(index).x, point.y - checkbox(index).y) < 14 { return .checkbox(index) }
            if statusRect(index).insetBy(dx: -6, dy: -6).contains(point) { return .status(index) }
            if rows[index].isNew, frame.stage == .editing, titleField(index).contains(point) { return .title(index) }
            return .row(index)
        }
        return nil
    }

    // MARK: 绘制

    private let base: CGImage
    private let context = CIContext()

    /// 壁纸、菜单栏、窗口阴影与侧栏这些不随状态变化的部分先画好一张底图，每帧只重画窗口正文。
    init(wallpaper: CGImage?) throws {
        let pixels = Self.pixelSize
        // 壁纸按铺满裁切（居中）；没有壁纸就用一张中性浅灰渐变顶替。
        var backdrop = CIImage(color: CIColor(red: 0.78, green: 0.82, blue: 0.86)).cropped(to: CGRect(origin: .zero, size: pixels))
        if let wallpaper {
            let image = CIImage(cgImage: wallpaper)
            let fill = max(pixels.width / image.extent.width, pixels.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            backdrop = scaled.transformed(by: CGAffineTransform(translationX: (pixels.width - scaled.extent.width) / 2, y: (pixels.height - scaled.extent.height) / 2))
                .cropped(to: CGRect(origin: .zero, size: pixels))
        }
        // 毛玻璃取材：同一张壁纸高斯模糊后再提一点饱和度，和系统材质的观感接近。
        let frosted = backdrop.clampedToExtent().applyingGaussianBlur(sigma: 60)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
            .cropped(to: backdrop.extent)
        guard let wall = context.createCGImage(backdrop, from: backdrop.extent),
              let glass = context.createCGImage(frosted, from: frosted.extent) else { throw PreviewFixture.FixtureError.failed }
        base = try Self.render { cg in
            Self.image(wall, in: CGRect(origin: .zero, size: Self.size))
            Self.menuBar(glass: glass)
            Self.windowChrome(cg, glass: glass)
        }
    }

    func image(_ frame: Frame) throws -> CGImage {
        try Self.render { _ in
            Self.image(base, in: CGRect(origin: .zero, size: Self.size))
            Self.content(frame)
        }
    }

    /// 在左上原点、y 向下的 1440 × 900 点坐标系里作画，输出 2× 位图。
    private static func render(_ body: (CGContext) throws -> Void) throws -> CGImage {
        let pixels = pixelSize
        guard let cg = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw PreviewFixture.FixtureError.failed }
        cg.translateBy(x: 0, y: pixels.height); cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        try body(cg)
        guard let image = cg.makeImage() else { throw PreviewFixture.FixtureError.failed }
        return image
    }

    private static func image(_ image: CGImage, in rect: CGRect) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// 毛玻璃：模糊壁纸裁到形状里，再叠一层白。
    private static func glass(_ glass: CGImage, path: NSBezierPath, tint: Double) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image(glass, in: CGRect(origin: .zero, size: size))
        NSColor(white: 1, alpha: tint).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    private static let ink = rgb(29, 29, 31), secondary = rgb(134, 134, 142), hairline = rgb(0, 0, 0, 0.08), blue = rgb(0, 122, 255)
    /// 骨架三档灰：深（标题、未完成任务）、中（次要文字）、淡（标签、日期）。
    private static let strong = rgb(0, 0, 0, 0.58), soft = rgb(0, 0, 0, 0.16), faint = rgb(0, 0, 0, 0.09)

    @discardableResult
    private static func text(_ string: String, x: Double, centerY: Double, size: Double, weight: NSFont.Weight = .regular, color: NSColor = ink, alignRight: Bool = false, monospacedDigits: Bool = false) -> Double {
        let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: CGPoint(x: alignRight ? x - measured.width : x, y: centerY - measured.height / 2), withAttributes: attributes)
        return measured.width
    }

    /// SF Symbol 按给定颜色画在以 `center` 为中心的位置，返回宽度。
    @discardableResult
    private static func symbol(_ name: String, center: CGPoint, size: Double, weight: NSFont.Weight = .regular, color: NSColor = ink) -> Double {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) else { return 0 }
        let rect = CGRect(x: center.x - base.size.width / 2, y: center.y - base.size.height / 2, width: base.size.width, height: base.size.height)
        let tinted = NSImage(size: base.size, flipped: false) { bounds in
            base.draw(in: bounds); color.set(); bounds.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return base.size.width
    }

    private static func capsule(_ rect: CGRect, radius: Double? = nil, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius ?? rect.height / 2, yRadius: radius ?? rect.height / 2).fill()
    }

    // MARK: 菜单栏

    private static func menuBar(glass glassImage: CGImage) {
        let bar = CGRect(x: 0, y: 0, width: size.width, height: 24)
        glass(glassImage, path: NSBezierPath(rect: bar), tint: 0.42)
        // 两端各留 26 点：导出时录屏带圆角，贴边的苹果标志和时间会被圆角削掉一角。
        let inset = 26.0
        var x = inset
        symbol("apple.logo", center: CGPoint(x: x + 7, y: 12), size: 14, weight: .medium)
        x += 30
        x += text("清单", x: x, centerY: 12, size: 13, weight: .bold) + 20
        for item in ["文件", "编辑", "显示", "窗口", "帮助"] { x += text(item, x: x, centerY: 12, size: 13) + 20 }
        // 右侧从右往左：时间、控制中心、聚焦搜索、Wi-Fi、电池、Caplo 录制中图标；图标之间 18 点。
        var right = size.width - inset
        right -= text("10月7日 周二 上午9:41", x: right, centerY: 12, size: 13, alignRight: true) + 18
        for (name, width) in [("switch.2", 16.0), ("magnifyingglass", 15), ("wifi", 17)] {
            symbol(name, center: CGPoint(x: right - width / 2, y: 12), size: 13.5, weight: .medium)
            right -= width + 18
        }
        right -= battery(right: right) + 18
        // 状态栏图标的字形高约 15 点（与 Wi-Fi、电池同一视觉大小），18 点的整格画出来会显得大一号。
        if let icon = recordingIcon() {
            let rect = CGRect(x: right - 15, y: 4.5, width: 15, height: 15)
            let tinted = NSImage(size: rect.size, flipped: false) { bounds in
                icon.draw(in: bounds); ink.set(); bounds.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// macOS 菜单栏电池：半透明描边外壳 + 实心电量 + 右侧正极小凸起（SF Symbol 的电池是整块实心，和系统菜单栏不像）。返回占用宽度。
    private static func battery(right: Double) -> Double {
        let body = CGRect(x: right - 25.5, y: 6.5, width: 23, height: 11)
        let shell = NSBezierPath(roundedRect: body, xRadius: 3.2, yRadius: 3.2)
        ink.withAlphaComponent(0.4).setStroke(); shell.lineWidth = 1; shell.stroke()
        capsule(CGRect(x: body.minX + 2, y: body.minY + 2, width: (body.width - 4) * 0.82, height: body.height - 4), radius: 1.6, fill: ink)
        capsule(CGRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4), radius: 0.75, fill: ink.withAlphaComponent(0.4))
        return 25.5
    }

    /// 菜单栏里的 Caplo 录制中图标：直接读设计系统资源目录里的 PNG（离屏工具，不经过资源包）。
    private static func recordingIcon() -> NSImage? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CaploDesignSystem/Resources/Brand.xcassets/MenuBarIconRecording.imageset/MenuBarIconRecording@2x.png")
        return NSImage(contentsOf: url)
    }

    // MARK: 窗口外框

    private static func windowChrome(_ cg: CGContext, glass glassImage: CGImage) {
        let shape = NSBezierPath(roundedRect: window, xRadius: 14, yRadius: 14)
        // 系统窗口阴影：一层大而淡的环境阴影 + 一层贴边的接触阴影（阴影偏移以像素计、y 向上为正，与 CTM 无关）。
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -36), blur: 110, color: NSColor(white: 0, alpha: 0.38).cgColor)
        NSColor.white.setFill(); shape.fill()
        cg.restoreGState()
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor(white: 0, alpha: 0.22).cgColor)
        NSColor.white.setFill(); shape.fill()
        cg.restoreGState()
        rgb(0, 0, 0, 0.14).setStroke(); shape.lineWidth = 0.5; shape.stroke()

        // 浮起的毛玻璃侧栏，透出窗口后面的壁纸。
        let side = NSBezierPath(roundedRect: sidebar, xRadius: 10, yRadius: 10)
        glass(glassImage, path: side, tint: 0.66)
        rgb(0, 0, 0, 0.06).setStroke(); side.lineWidth = 0.5; side.stroke()
        for (index, color) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
            let dot = NSBezierPath(ovalIn: CGRect(x: sidebar.minX + 12 + Double(index) * 20, y: sidebar.minY + 12, width: 12, height: 12))
            color.setFill(); dot.fill()
            rgb(0, 0, 0, 0.12).setStroke(); dot.lineWidth = 0.5; dot.stroke()
        }
        // 侧栏骨架：彩色图标块 + 灰条，计数是更短的淡灰条；"项目"一组用彩色圆点，第一项选中。
        var y = sidebar.minY + 58
        for (color, width, count) in [(blue, 52.0, 10.0), (rgb(255, 184, 0), 36, 8), (rgb(255, 69, 58), 44, 12), (rgb(142, 142, 147), 48, 0)] {
            capsule(CGRect(x: sidebar.minX + 15, y: y - 7, width: 14, height: 14), radius: 4, fill: color)
            capsule(CGRect(x: sidebar.minX + 38, y: y - 4, width: width, height: 8), fill: soft)
            if count > 0 { capsule(CGRect(x: sidebar.maxX - 12 - count, y: y - 3, width: count, height: 6), fill: faint) }
            y += 30
        }
        y += 14
        capsule(CGRect(x: sidebar.minX + 12, y: y - 3, width: 28, height: 6), fill: faint)
        y += 26
        for (index, (color, width)) in [(blue, 70.0), (rgb(255, 149, 0), 56), (rgb(52, 199, 89), 62)].enumerated() {
            if index == 0 { capsule(CGRect(x: sidebar.minX + 6, y: y - 14, width: sidebar.width - 12, height: 28), radius: 7, fill: rgb(0, 0, 0, 0.07)) }
            capsule(CGRect(x: sidebar.minX + 17, y: y - 5, width: 10, height: 10), fill: color)
            capsule(CGRect(x: sidebar.minX + 38, y: y - 4, width: width, height: 8), fill: index == 0 ? strong : soft)
            y += 30
        }
        symbol("plus", center: CGPoint(x: sidebar.minX + 20, y: sidebar.maxY - 20), size: 12, weight: .medium, color: secondary)
        capsule(CGRect(x: sidebar.minX + 34, y: sidebar.maxY - 23, width: 44, height: 6), fill: faint)

        // 工具栏：搜索框（放大镜 + 淡灰条）、分享与更多。
        let toolbarY = window.minY + 26
        let search = CGRect(x: contentRight - 76 - 180, y: toolbarY - 14, width: 180, height: 28)
        capsule(search, fill: rgb(0, 0, 0, 0.05))
        symbol("magnifyingglass", center: CGPoint(x: search.minX + 16, y: toolbarY), size: 12, weight: .medium, color: secondary)
        capsule(CGRect(x: search.minX + 30, y: toolbarY - 3, width: 34, height: 6), fill: faint)
        symbol("square.and.arrow.up", center: CGPoint(x: contentRight - 50, y: toolbarY - 1), size: 14, color: secondary)
        symbol("ellipsis.circle", center: CGPoint(x: contentRight - 12, y: toolbarY), size: 15, color: secondary)
    }

    // MARK: 窗口正文

    private static func content(_ frame: Frame) {
        let rows = rows(frame)
        let done = rows.filter(\.done).count
        let left = contentLeft
        // 标题、副标题、进度
        capsule(CGRect(x: left, y: window.minY + 58, width: 220, height: 16), fill: strong)
        capsule(CGRect(x: left, y: window.minY + 88, width: 150, height: 8), fill: soft)
        capsule(CGRect(x: left, y: window.minY + 110, width: 240, height: 5), fill: rgb(0, 0, 0, 0.07))
        capsule(CGRect(x: left, y: window.minY + 110, width: 240 * Double(done) / Double(rows.count), height: 5), fill: blue)
        // 三张统计卡：浅蓝 / 浅绿 / 浅琥珀，各一条淡灰标签与一颗深色数字胶囊；完成数那张随勾选变长。
        let cardWidth = (contentRight - left - 24) / 3
        for (index, color) in [rgb(232, 241, 253), rgb(229, 245, 234), rgb(253, 243, 224)].enumerated() {
            let card = CGRect(x: left + Double(index) * (cardWidth + 12), y: window.minY + 134, width: cardWidth, height: 66)
            capsule(card, radius: 12, fill: color)
            capsule(CGRect(x: card.minX + 16, y: card.minY + 18, width: 56, height: 7), fill: rgb(0, 0, 0, 0.13))
            let number = index == 1 ? 24 + Double(done) * 4 : [38.0, 0, 30][index]
            capsule(CGRect(x: card.minX + 16, y: card.minY + 36, width: number, height: 14), fill: rgb(0, 0, 0, 0.62))
        }
        // 列标题：几条很淡的短灰条。
        let headerY = window.minY + 220
        for (x, width) in [(left + 36, 30.0), (left + 460, 26), (left + 580, 34)] { capsule(CGRect(x: x, y: headerY - 3, width: width, height: 6), fill: faint) }
        capsule(CGRect(x: contentRight - 26, y: headerY - 3, width: 26, height: 6), fill: faint)
        capsule(CGRect(x: left - 8, y: rowTop - 0.5, width: contentRight - left + 16, height: 0.5), radius: 0, fill: hairline)

        for (index, row) in rows.enumerated() {
            let rect = rowRect(index), y = rect.midY
            let hovered: Bool = switch frame.hover {
            case .row(index), .checkbox(index), .status(index), .title(index): true
            default: false
            }
            // 新建的那行在编辑与刚提交时保持选中底色；其余行悬停时有一层很淡的灰。
            if row.isNew, frame.stage == .editing || frame.stage == .added {
                capsule(rect.insetBy(dx: 0, dy: 2), radius: 8, fill: rgb(0, 122, 255, 0.09))
            } else if hovered {
                capsule(rect.insetBy(dx: 0, dy: 2), radius: 8, fill: rgb(0, 0, 0, 0.035))
            }
            let box = CGRect(x: checkbox(index).x - 9, y: y - 9, width: 18, height: 18)
            if row.done {
                capsule(box, fill: blue)
                symbol("checkmark", center: CGPoint(x: box.midX, y: box.midY), size: 9, weight: .heavy, color: .white)
            } else {
                let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5
                (frame.hover == .checkbox(index) ? blue : rgb(0, 0, 0, 0.25)).setStroke(); ring.stroke()
            }
            if row.isNew, frame.stage == .editing {
                // 正在输入的标题：白底输入框 + 系统蓝焦点环 + 插入点；还没敲字时是一条很淡的占位条。
                let field = titleField(index)
                let ring = NSBezierPath(roundedRect: field.insetBy(dx: -1.5, dy: -1.5), xRadius: 8.5, yRadius: 8.5)
                rgb(0, 122, 255, 0.45).setStroke(); ring.lineWidth = 3; ring.stroke()
                capsule(field, radius: 7, fill: .white)
                if row.title > 0 { capsule(CGRect(x: field.minX + 8, y: y - 4, width: row.title, height: 8), fill: strong) }
                else { capsule(CGRect(x: field.minX + 8, y: y - 4, width: 44, height: 8), fill: faint) }
                if frame.caret { capsule(CGRect(x: field.minX + 8 + row.title + 2, y: y - 9, width: 1.5, height: 18), radius: 0.75, fill: ink) }
            } else {
                capsule(CGRect(x: left + 36, y: y - 4, width: row.title, height: 8), fill: row.done ? soft : strong)
            }
            let pill = statusRect(index)
            let fill = switch row.status {
            case .done: rgb(52, 199, 89, 0.32)
            case .active: rgb(0, 122, 255, 0.28)
            case .todo: rgb(0, 0, 0, 0.09)
            }
            capsule(pill, fill: fill)
            if frame.hover == .status(index) { capsule(pill, fill: rgb(0, 0, 0, frame.pressed ? 0.1 : 0.05)) }
            capsule(CGRect(x: left + 580, y: y - 9, width: 18, height: 18), fill: rgb(0, 0, 0, 0.09))
            capsule(CGRect(x: left + 606, y: y - 3.5, width: row.owner, height: 7), fill: soft)
            capsule(CGRect(x: contentRight - 34, y: y - 3.5, width: 34, height: 7), fill: faint)
            capsule(CGRect(x: left + 28, y: rect.maxY - 0.5, width: contentRight - left - 28, height: 0.5), radius: 0, fill: hairline)
        }
        // 行内"＋ 新建"：蓝色加号 + 蓝色短条；悬停有浅蓝底，按下加深。
        let button = newTaskRect(rows: rows.count)
        if frame.hover == .newTask { capsule(button, radius: 8, fill: rgb(0, 122, 255, frame.pressed ? 0.16 : 0.08)) }
        symbol("plus", center: CGPoint(x: button.minX + 19, y: button.midY), size: 13, weight: .semibold, color: blue)
        capsule(CGRect(x: button.minX + 34, y: button.midY - 4, width: 46, height: 8), fill: rgb(0, 122, 255, 0.75))
    }

}
