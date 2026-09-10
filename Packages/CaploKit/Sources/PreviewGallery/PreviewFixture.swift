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
        let url = try ProjectStorage.create(in: root, name: "产品演示 · 合成示例")
        let lease = try ProjectLease(url: url)
        defer { withExtendedLifetime(lease) {} }
        let size = CGSize(width: 1280, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        func rectangle(_ rect: CGRect, color: NSColor, radius: Double = 0) {
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func label(_ text: String, x: Double, y: Double, size: Double = 18, color: NSColor = .darkGray, bold: Bool = false) {
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color])
        }
        let purple = NSColor(calibratedRed: 0.4, green: 0.35, blue: 0.85, alpha: 1)
        rectangle(CGRect(x: 0, y: 0, width: 220, height: 800), color: NSColor(calibratedWhite: 0.94, alpha: 1))
        label("○  NOTES", x: 28, y: 740, size: 25, color: purple, bold: true)
        rectangle(CGRect(x: 18, y: 642, width: 184, height: 45), color: purple.withAlphaComponent(0.12), radius: 8)
        label("我的工作空间", x: 36, y: 655, size: 16, color: purple, bold: true)
        label("项目笔记", x: 36, y: 591, size: 16)
        label("灵感收藏", x: 36, y: 535, size: 16)
        label("最近访问", x: 36, y: 479, size: 16)
        label("让好想法，发生。", x: 270, y: 716, size: 34, bold: true)
        label("每一个值得记录的瞬间，都可以成为下一个作品。", x: 272, y: 676, size: 17, color: .gray)
        rectangle(CGRect(x: 1050, y: 714, width: 178, height: 46), color: purple, radius: 8)
        label("＋ 新建笔记", x: 1074, y: 728, size: 16, color: .white, bold: true)
        let titles = ["本周的创作计划", "产品演示脚本", "下一次旅行"]
        let subtitles = ["把想法变成清晰的表达", "从一个好故事开始", "去看看不一样的风景"]
        let cardColors = [NSColor(calibratedRed: 0.87, green: 0.84, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.82, green: 0.92, blue: 0.87, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.88, blue: 0.78, alpha: 1)]
        for index in 0..<3 {
            let x = 270.0 + Double(index) * 326
            rectangle(CGRect(x: x, y: 362, width: 304, height: 252), color: .white, radius: 14)
            rectangle(CGRect(x: x + 14, y: 456, width: 276, height: 143), color: cardColors[index], radius: 9)
            label(["✦", "↗", "☀"][index], x: x + 122, y: 499, size: 46, color: purple)
            label(titles[index], x: x + 22, y: 413, size: 20, bold: true)
            label(subtitles[index], x: x + 22, y: 382, size: 14, color: .gray)
        }
        label("最近更新", x: 270, y: 298, size: 22, bold: true)
        for index in 0..<3 {
            let y = 224.0 - Double(index) * 66
            rectangle(CGRect(x: 270, y: y, width: 956, height: 53), color: .white, radius: 7)
            label(["整理今天的灵感", "完善第一个演示视频", "分享新的创作进展"][index], x: 290, y: y + 17, size: 16)
            label("今天", x: 1148, y: y + 18, size: 13, color: .gray)
        }
        label("用于界面验收的合成内容", x: 30, y: 28, size: 12, color: .gray)
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw FixtureError.failed }
        let mediaPath = "Media/000000-screen.mov"
        let writer = try AVAssetWriter(outputURL: url.appendingPathComponent(mediaPath), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 800])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 800, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.failed }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw FixtureError.failed }
        CIContext().render(CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: 1280 / Double(cgImage.width), y: 800 / Double(cgImage.height))), to: pixel)
        for second in 0..<12 {
            while !input.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(second), timescale: 1)) else { throw writer.error ?? FixtureError.failed }
        }
        writer.endSession(atSourceTime: CMTime(value: 12, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.failed }
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
        // 放一段文字：文字面板要有选中的一段才显示排版与外观那一串参数，离屏快照才看得到色板。
        var title = TextPreset.title.segment(start: 1, duration: 3)
        title.text = "产品演示"; title.timelineStart = 1
        edit.addText(title)
        try EditStorage.save(edit, in: url, document: document)
        return url
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
