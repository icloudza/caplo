import AppKit
import AVFoundation
import RenderKit
import CoreImage
import CoreVideo
import IOSurface

/// 画布的唯一像素通道：播放项渲染出的每一帧（播放、定位、换合成后的重渲染）都从 `AVPlayerItemVideoOutput`
/// 取出，以 IOSurface 直接作为图层内容显示，零拷贝、无回读。没有播放项时才用离线渲染的静帧兜底。
/// 只在主线程使用；快照模式下改用 CGImage 内容，供离屏预览与测试读取像素。
@MainActor
final class CanvasPresenter: NSObject {
    weak var view: CanvasSurfaceView? {
        didSet { view?.snapshotMode = snapshotMode; if let frame { view?.show(frame) } else if let image { view?.show(image) } }
    }
    var snapshotMode = false {
        didSet { view?.snapshotMode = snapshotMode; if let frame { view?.show(frame) } }
    }
    /// 最近一次显示的播放器帧；`frameRevision` 每次显示新画面都递增，测试据此等待画面变化。
    private(set) var frame: CVPixelBuffer?
    private(set) var image: CGImage?
    private(set) var frameRevision: UInt64 = 0
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var displayLink: CADisplayLink?
    private static let snapshotContext = CIContext(options: [.cacheIntermediates: false])

    override init() { super.init() }

    /// 切换播放项：视频输出随之迁移。与合成器的像素属性一致（BGRA、IOSurface），不产生格式转换。
    func attach(item: AVPlayerItem?) {
        if let output, let old = self.item { old.remove(output) }
        self.item = item
        guard let item else { output = nil; return }
        let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        next.suppressesPlayerRendering = true
        item.add(next)
        output = next
        // 显示链路随播放项存在：按主屏刷新率查询新帧，查询本身只是几微秒。
        if displayLink == nil, let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) {
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func detach() {
        attach(item: nil)
        displayLink?.invalidate(); displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        pull(hostTime: link.targetTimestamp)
    }

    /// 显示链路每帧调用：播放项若有比当前更新的画面就取出显示。
    func pull(hostTime: CFTimeInterval) {
        guard let output else { return }
        let time = output.itemTime(forHostTime: hostTime)
        guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        present(buffer)
    }

    func present(_ buffer: CVPixelBuffer) {
        // 合成器输出按 BT.709 编码；播放器交来的若是拷贝过的缓冲，IOSurface 上没有色彩空间，
        // 图层会把它当 sRGB 显示（偏暗）。贴上去之前按缓冲附件补齐。
        SceneColor.tagSurface(of: buffer)
        frame = buffer; image = nil; frameRevision &+= 1
        view?.show(buffer)
    }

    /// 没有播放项时的兜底静帧。
    func present(image: CGImage) {
        self.image = image; frame = nil; frameRevision &+= 1
        view?.show(image)
    }

    /// 当前画面的位图快照（CPU 回读，只供测试与预览使用）。
    func snapshot() -> CGImage? {
        if let image { return image }
        guard let frame else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return Self.snapshotContext.createCGImage(CIImage(cvPixelBuffer: frame), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)), format: .RGBA8, colorSpace: space, deferred: false)
    }

    static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return snapshotContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)), format: .RGBA8, colorSpace: space, deferred: false)
    }
}
