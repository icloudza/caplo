import AppKit
import AVFoundation
import CoreImage
import ProjectKit
import EditingCore

/// 仅供离屏验收的合成演示工程；存入独立临时目录，不录屏、不扫描用户文件，也不写入真实项目库。
@MainActor
enum PreviewFixture {
    static func create(camera: Bool = false, pointer: Bool = false) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-visual-\(UUID())")
        let url = try ProjectStorage.create(in: root, name: "Caplo 1.2 发布清单")
        let lease = try ProjectLease(url: url)
        defer { withExtendedLifetime(lease) {} }
        let size = CGSize(width: 1280, height: 800)
        let screen = try screenImage()
        let mediaPath = "Media/000000-screen.mov"
        let movie = try ScreenMovieWriter(url: url.appendingPathComponent(mediaPath), pixelSize: size)
        for second in 0..<12 { try await movie.append(screen, at: Double(second)) }
        try await movie.finish(duration: 12)
        let audioPath = "Media/000000-microphone.caf"
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let audio = try AVAudioFile(forWriting: url.appendingPathComponent(audioPath), settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        pcm.frameLength = 48_000
        for second in 0..<12 {
            for frame in 0..<48_000 {
                let t = Double(second) + Double(frame) / 48_000
                let envelope = max(0, sin(t * 3.5)) * 0.55 + 0.02
                pcm.floatChannelData![0][frame] = Float(sin(t * 440 * .pi * 2) * envelope)
            }
            try audio.write(from: pcm)
        }
        var segment = SegmentRecord(id: 0, duration: 12, files: [.screen: mediaPath, .microphone: audioPath])
        if camera {
            let path = "Media/000000-camera.mov"
            try await cameraMovie(at: url.appendingPathComponent(path))
            segment.files[.camera] = path
        }
        segment.eventsPath = "Events/000000.json"
        var events = [PointerSample(time: 2.2, x: 0.85, y: 0.1, kind: .click), PointerSample(time: 7, x: 0.57, y: 0.42, kind: .click)]
        if pointer {
            for index in 0..<360 {
                let time = Double(index) / 30
                events.append(PointerSample(time: time, x: time < 5 ? 0.85 : 0.57, y: time < 5 ? 0.1 : 0.42, kind: .move))
            }
            var manifest = try ProjectStorage.load(url)
            manifest.capture = CaptureMetadata(desktopBounds: CGRect(origin: .zero, size: size), pixelSize: size, pointPixelScale: 1, pointerEnabled: true)
            manifest.capture?.cursorEmbedded = false
            try ProjectStorage.save(manifest, to: url)
        }
        try JSONEncoder().encode(events).write(to: url.appendingPathComponent(segment.eventsPath!), options: .atomic)
        try ProjectStorage.commit(segment, to: url); try ProjectStorage.complete(url)
        let document = try ProjectStorage.load(url)
        var edit = try EditStorage.load(in: url, document: document)
        if pointer {
            edit.pointer?.style = .tahoe; edit.pointer?.smoothing = 0.5
            edit.pointer?.bounce = 0.2; edit.pointer?.sway = 0.3; edit.pointer?.motionBlur = 0.2
        }
        _ = edit.split(at: 4); _ = edit.split(at: 9)
        // 画布：冷灰纯色底，窗口留边距、带阴影悬浮在上面——像一段干净的真实录屏，不用渐变壁纸。
        edit.layout.background = CanvasBackground(start: (0.86, 0.875, 0.895), end: (0.86, 0.875, 0.895))
        edit.layout.padding = 48; edit.layout.cornerRadius = 12; edit.layout.shadow = true
        // 放一段文字：文字面板要有选中的一段才显示排版与外观那一串参数，离屏快照才看得到色板。
        var title = TextPreset.lowerThird.segment(start: 1, duration: 3)
        title.text = "第一步：新建任务"; title.timelineStart = 1
        edit.addText(title)
        // 第 9 秒插一块章节卡片（深色底，和浅色画面拉开）：时间线上画面轨多一块卡片，后面的内容让开，快照 editor-card 在卡片正中取帧。
        if let card = edit.insertCard(at: 9, duration: 3) {
            edit.updateCard(id: card) { $0.text.text = "第二部分\n上线与发布"; $0.background = .ink }
        }
        try EditStorage.save(edit, in: url, document: document)
        return url
    }

    /// 官网首屏演示视频的工程：按真实录制的样子合成——被录的是一整块 macOS 桌面（本机壁纸、菜单栏、任务清单窗口，见 `DemoDesktop`），
    /// 2× 像素、60 fps、60 Hz 连续指针采样（含按下 / 松开与指针形状）。操作是一段完整的小任务：点"新建任务"、输入标题并回车、
    /// 把新任务改为进行中、勾掉第二行；界面随悬停、按下、输入逐帧变化。三次点击间隔都在合并阈值内，生成一整段推近，
    /// 相机在三处之间由跟随弹簧平移，最后一次点击 2.2 秒后拉远。不分割、不加文字卡片，镜头、光标与背景都走新工程的默认规则。
    static func demo() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-demo-\(UUID())")
        let url = try ProjectStorage.create(in: root, name: "Caplo 1.2 发布清单")
        let lease = try ProjectLease(url: url)
        defer { withExtendedLifetime(lease) {} }
        let duration = 11.0
        let wallpaperURL = DesktopWallpaper.currentURL()
        let desktop = try DemoDesktop(wallpaper: wallpaperURL.flatMap { DesktopWallpaper.decode($0, maximumPixelSize: DesktopWallpaper.maximumEdge) })
        typealias D = DemoDesktop
        // 指针动作（屏幕点坐标）：从列表下方空白处出发，去"新建任务"、新任务的状态、第二行的勾选框，停一会儿再回到起点，循环播放首尾接得上。
        let start = CGPoint(x: 700, y: 668)
        let button = D.newTaskRect(rows: 6), status = D.statusRect(6), check = D.checkbox(1)
        let moves = [
            Glide(start: 0.4, duration: 1.1, to: CGPoint(x: button.midX - 6, y: button.midY + 2), bend: 0.12),
            // 点下去之后手顺势往右挪开一点，I 形光标不压在正在输入的字上。
            Glide(start: 1.95, duration: 0.55, to: CGPoint(x: button.midX + 170, y: button.midY + 8), bend: 0.04),
            Glide(start: 3.2, duration: 0.85, to: CGPoint(x: status.midX + 3, y: status.midY + 1), bend: -0.06),
            Glide(start: 4.75, duration: 1.05, to: CGPoint(x: check.x + 1, y: check.y + 1), bend: 0.08),
            Glide(start: 6.7, duration: 1.1, to: CGPoint(x: 560, y: 470), bend: 0.05),
            Glide(start: 9.3, duration: 1.2, to: start, bend: -0.05),
        ]
        let clicks = [1.75, 4.3, 6.05]
        func position(at time: Double) -> CGPoint {
            var point = start
            for move in moves where time > move.start { point = move.position(from: point, at: time) }
            return point
        }
        // 界面时间线：点下"新建任务"一帧后出现新行；每 0.12 秒敲一下，3.0 秒回车提交；之后两次点击各在松开后一帧生效。
        func frame(at time: Double) -> D.Frame {
            var frame = D.Frame()
            switch time {
            case ..<(clicks[0] + 0.1): frame.stage = .initial
            case ..<3.0:
                frame.stage = .editing
                frame.typed = max(0, min(D.keystrokes, Int((time - 1.95) / 0.12) + 1))
                let typingEnds = 1.95 + Double(D.keystrokes) * 0.12
                frame.caret = time < typingEnds || Int((time - typingEnds) / 0.53) % 2 == 0
            case ..<(clicks[1] + 0.1): frame.stage = .added
            case ..<(clicks[2] + 0.1): frame.stage = .started
            default: frame.stage = .finished
            }
            frame.pressed = clicks.contains { time >= $0 && time < $0 + 0.08 }
            frame.hover = D.target(at: position(at: time), frame: frame)
            return frame
        }
        let mediaPath = "Media/000000-screen.mov"
        let writer = try ScreenMovieWriter(url: url.appendingPathComponent(mediaPath), pixelSize: D.pixelSize)
        var events: [PointerSample] = []
        var previous: D.Frame?
        for index in 0..<Int(duration * 60) {
            let time = Double(index) / 60, current = frame(at: time)
            if current != previous { try await writer.append(try desktop.image(current), at: time); previous = current }
            let point = position(at: time)
            var sample = PointerSample(time: time, x: point.x / D.size.width, y: point.y / D.size.height, kind: .move)
            if case .title = current.hover { sample.shape = .text } else { sample.shape = .arrow }
            events.append(sample)
        }
        try await writer.finish(duration: duration)
        for click in clicks {
            for (kind, time) in [(PointerSample.Kind.click, click), (.release, click + 0.08)] {
                let point = position(at: time)
                var sample = PointerSample(time: time, x: point.x / D.size.width, y: point.y / D.size.height, kind: kind)
                sample.shape = .arrow; sample.button = 0
                if kind == .click { sample.clickCount = 1 }
                events.append(sample)
            }
        }
        events.sort { $0.time < $1.time }
        var segment = SegmentRecord(id: 0, duration: duration, files: [.screen: mediaPath])
        segment.eventsPath = "Events/000000.json"
        try JSONEncoder().encode(events).write(to: url.appendingPathComponent(segment.eventsPath!), options: .atomic)
        var manifest = try ProjectStorage.load(url)
        manifest.capture = CaptureMetadata(desktopBounds: CGRect(origin: .zero, size: D.size), pixelSize: D.pixelSize, pointPixelScale: D.scale, pointerEnabled: true)
        manifest.capture?.cursorEmbedded = false; manifest.capture?.frameRate = 60
        try ProjectStorage.save(manifest, to: url)
        try ProjectStorage.commit(segment, to: url); try ProjectStorage.complete(url)
        // 编辑：和录完打开编辑器同一条路径——默认背景是这台机器的桌面壁纸，光标与自动聚焦按默认规则生成。
        // 只在画布上加留白、阴影和背景模糊，让录屏像一块屏幕摆在壁纸前（都是面板上能调的参数）。
        let document = try ProjectStorage.load(url)
        var edit = try EditStorage.load(in: url, document: document, wallpaper: wallpaperURL)
        edit.layout.padding = 44; edit.layout.cornerRadius = 14; edit.layout.shadow = true; edit.layout.backgroundBlur = 40
        try EditStorage.save(edit, in: url, document: document)
        return url
    }

    /// 一次手部移动：最小加加速度曲线（起停都缓、中段最快），路径按 `bend` 向一侧微弯——手腕转动划出的弧，而不是直线。
    struct Glide {
        var start: Double, duration: Double, to: CGPoint, bend: Double
        func position(from: CGPoint, at time: Double) -> CGPoint {
            let progress = min(1, max(0, (time - start) / duration))
            let s = progress * progress * progress * (10 - 15 * progress + 6 * progress * progress)
            let dx = to.x - from.x, dy = to.y - from.y
            let control = CGPoint(x: (from.x + to.x) / 2 - dy * bend, y: (from.y + to.y) / 2 + dx * bend)
            let u = 1 - s
            return CGPoint(x: u * u * from.x + 2 * u * s * control.x + s * s * to.x, y: u * u * from.y + 2 * u * s * control.y + s * s * to.y)
        }
    }

    /// 录下来的"屏幕"：中性的 macOS 风格任务清单——灰白侧栏、白色正文、系统蓝按钮，不用紫色和渐变。
    /// 按 1280 × 800 点绘制，`scale` 倍像素输出（默认 2×，和 Retina 录屏一样，推近后小字仍清楚）。
    static func screenImage(scale: Double = 2) throws -> CGImage {
        let size = CGSize(width: 1280, height: 800)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw FixtureError.failed }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func rectangle(_ rect: CGRect, color: NSColor, radius: Double = 0) {
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func label(_ text: String, x: Double, y: Double, size: Double = 16, color: NSColor = NSColor(calibratedWhite: 0.13, alpha: 1), weight: NSFont.Weight = .regular, center: Bool = false) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
            let width = center ? (text as NSString).size(withAttributes: attributes).width : 0
            (text as NSString).draw(at: CGPoint(x: x - width / 2, y: y), withAttributes: attributes)
        }
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        let blue = rgb(0, 122, 255), gray = rgb(134, 134, 142), line = rgb(232, 232, 236)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        // 侧栏与红黄绿
        rectangle(CGRect(x: 0, y: 0, width: 240, height: 800), color: rgb(244, 244, 247))
        rectangle(CGRect(x: 240, y: 0, width: 1, height: 800), color: line)
        for (index, color) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
            rectangle(CGRect(x: 20 + Double(index) * 20, y: 766, width: 12, height: 12), color: color, radius: 6)
        }
        rectangle(CGRect(x: 12, y: 646, width: 216, height: 34), color: rgb(226, 226, 232), radius: 7)
        for (index, item) in [("收件箱", "4"), ("今天", "6"), ("计划", "12"), ("已完成", "")].enumerated() {
            let y = 696 - Double(index) * 42
            rectangle(CGRect(x: 26, y: y + 2, width: 14, height: 14), color: index == 1 ? blue : gray, radius: 4)
            label(item.0, x: 52, y: y, size: 15, weight: index == 1 ? .semibold : .regular)
            label(item.1, x: 204, y: y, size: 14, color: gray)
        }
        label("项目", x: 26, y: 506, size: 12, color: gray, weight: .semibold)
        for (index, item) in [("Caplo 1.2", rgb(0, 122, 255)), ("官网改版", rgb(255, 149, 0)), ("用户反馈", rgb(52, 199, 89))].enumerated() {
            let y = 470 - Double(index) * 38
            rectangle(CGRect(x: 28, y: y + 4, width: 10, height: 10), color: item.1, radius: 5)
            label(item.0, x: 52, y: y, size: 15)
        }
        // 工具栏：搜索框 + 新建任务（点击位置：屏幕坐标约 1088, 80）
        rectangle(CGRect(x: 770, y: 704, width: 220, height: 32), color: rgb(240, 240, 243), radius: 8)
        label("搜索", x: 800, y: 711, size: 14, color: gray)
        rectangle(CGRect(x: 1013, y: 702, width: 150, height: 36), color: blue, radius: 8)
        label("＋ 新建任务", x: 1088, y: 711, size: 15, color: .white, weight: .semibold, center: true)
        // 六行任务；第二行（中心 y 464）的"进行中"约在屏幕坐标 730, 336。
        let rows: [(String, Bool, String, String, String)] = [
            ("更新官网截图", true, "已完成", "小林", "10/06"), ("录制新功能演示", false, "进行中", "我", "10/08"),
            ("整理更新说明", true, "已完成", "阿杰", "10/07"), ("提交 App Store 审核", false, "待开始", "我", "10/10"),
            ("修复导出取消无响应", true, "已完成", "小林", "10/05"), ("通知测试用户", false, "待开始", "Mia", "10/12"),
        ]
        let done = rows.filter(\.1).count
        // 标题、进度
        label("Caplo 1.2 发布", x: 300, y: 640, size: 30, weight: .bold)
        label("10 月 12 日截止 · \(rows.count) 项中已完成 \(done) 项", x: 302, y: 610, size: 15, color: gray)
        rectangle(CGRect(x: 300, y: 590, width: 460, height: 6), color: rgb(232, 232, 236), radius: 3)
        rectangle(CGRect(x: 300, y: 590, width: 460 * Double(done) / Double(rows.count), height: 6), color: blue, radius: 3)
        for (title, x) in [("任务", 344.0), ("状态", 704), ("负责人", 860), ("截止", 1160)] { label(title, x: x, y: 552, size: 13, color: gray) }
        rectangle(CGRect(x: 300, y: 542, width: 956, height: 1), color: line)
        for (index, row) in rows.enumerated() {
            let center = 520 - Double(index) * 56
            if row.1 {
                rectangle(CGRect(x: 306, y: center - 10, width: 20, height: 20), color: blue, radius: 10)
                label("✓", x: 316, y: center - 9, size: 13, color: .white, weight: .bold, center: true)
            } else {
                NSColor(srgbRed: 0.75, green: 0.75, blue: 0.78, alpha: 1).setStroke()
                let ring = NSBezierPath(ovalIn: CGRect(x: 307, y: center - 9, width: 18, height: 18)); ring.lineWidth = 1.6; ring.stroke()
            }
            label(row.0, x: 344, y: center - 10, size: 16, color: row.1 ? gray : NSColor(calibratedWhite: 0.13, alpha: 1))
            let (fill, ink): (NSColor, NSColor) = row.2 == "已完成" ? (rgb(227, 245, 231), rgb(31, 138, 58)) : row.2 == "进行中" ? (rgb(225, 237, 255), rgb(10, 96, 214)) : (rgb(238, 238, 241), rgb(107, 107, 117))
            rectangle(CGRect(x: 690, y: center - 13, width: 80, height: 26), color: fill, radius: 13)
            label(row.2, x: 730, y: center - 9, size: 13, color: ink, weight: .medium, center: true)
            rectangle(CGRect(x: 860, y: center - 11, width: 22, height: 22), color: rgb(214, 216, 222), radius: 11)
            label(String(row.3.prefix(1)), x: 871, y: center - 8, size: 12, color: rgb(70, 72, 80), weight: .semibold, center: true)
            label(row.3, x: 892, y: center - 10, size: 15)
            label(row.4, x: 1160, y: center - 10, size: 15, color: gray)
            rectangle(CGRect(x: 300, y: center - 28, width: 956, height: 1), color: line)
        }
        guard let image = context.makeImage() else { throw FixtureError.failed }
        return image
    }

    /// 屏幕素材写入器：画面按时间逐张追加、每张持续到下一张，最后一张持续到 `finish(duration:)`。
    /// 逐张写而不是先攒齐：2× 桌面一帧就是 20 MB，演示视频上百个状态全放内存会吃掉几个 GB。
    final class ScreenMovieWriter {
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let pixelSize: CGSize
        private let context = CIContext()

        init(url: URL, pixelSize: CGSize) throws {
            self.pixelSize = pixelSize
            let width = Int(pixelSize.width), height = Int(pixelSize.height)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? FixtureError.failed }
            writer.startSession(atSourceTime: .zero)
        }

        func append(_ image: CGImage, at time: Double) async throws {
            var created: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let pixel = created else { throw FixtureError.failed }
            context.render(CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: pixelSize.width / Double(image.width), y: pixelSize.height / Double(image.height))), to: pixel)
            while !input.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            guard adaptor.append(pixel, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else { throw writer.error ?? FixtureError.failed }
        }

        func finish(duration: Double) async throws {
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600)); input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? FixtureError.failed }
        }
    }

    /// 几何人像只用来检查画中画的占位、裁切和布局，不依赖真人照片或设备权限。
    private static func cameraMovie(at url: URL) async throws {
        let size = CGSize(width: 640, height: 480), image = NSImage(size: CGSize(width: 640, height: 480))
        image.lockFocus()
        NSColor(calibratedRed: 0.8, green: 0.85, blue: 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.48, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 135, y: -120, width: 370, height: 370)).fill()
        NSColor(calibratedRed: 0.22, green: 0.19, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 216, y: 200, width: 208, height: 234)).fill()
        NSColor(calibratedRed: 0.92, green: 0.72, blue: 0.57, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 237, y: 192, width: 166, height: 194), xRadius: 76, yRadius: 76).fill()
        NSColor(calibratedRed: 0.22, green: 0.19, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 218, y: 335, width: 190, height: 84)).fill()
        for x in [277.0, 350.0] { NSBezierPath(ovalIn: CGRect(x: x, y: 300, width: 12, height: 12)).fill() }
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw FixtureError.failed }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.failed }
        writer.startSession(atSourceTime: .zero)
        var created: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let pixel = created else { throw FixtureError.failed }
        CIContext().render(CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 640 / Double(cg.width), y: 480 / Double(cg.height))), to: pixel)
        for second in 0..<12 {
            while !input.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(second), timescale: 1)) else { throw writer.error ?? FixtureError.failed }
        }
        writer.endSession(atSourceTime: CMTime(value: 12, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.failed }
    }
    enum FixtureError: Error { case failed }
}
