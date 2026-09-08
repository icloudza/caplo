import AppKit
import SwiftUI
import QuartzCore
import CoreVideo
import IOSurface
import CaploDesignSystem

/// 预览窗格里的成片显示面：井底色上以 IOSurface 为内容的视频图层，按画面比例贴满窗格等比适配（不留白，
/// 像专业剪辑器的播放器区域）。所有几何变化都关闭隐式动画，且与视图尺寸在同一事务内更新。
/// 帧由 `CanvasPresenter` 推送，视图只负责几何与显示。
@MainActor
final class CanvasSurfaceView: NSView {
    private let videoLayer = CALayer()
    private var materialObserver: NSObjectProtocol?
    var materialOpaqueOverride: Bool? { didSet { if oldValue != materialOpaqueOverride { applyAppearance() } } }
    weak var presenter: CanvasPresenter?
    var aspectRatio = 16.0 / 9 { didSet { if aspectRatio != oldValue { updateGeometry() } } }
    /// 当前成片图层在视图内的位置，供测试校验几何与尺寸同步。
    private(set) var videoRect = CGRect.zero
    var snapshotMode = false
    /// 时间线为空时不显示旧画面与投影。
    var isHiddenContent = false {
        didSet {
            guard isHiddenContent != oldValue else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            videoLayer.isHidden = isHiddenContent
            CATransaction.commit()
        }
    }
    static let inset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // 工作区卡片圆角由图层原生完成，拖动分界时只是几何变化，没有任何重绘或遮罩栅格化。
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.masksToBounds = true
        videoLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(videoLayer)
        applyAppearance()
        updateGeometry()
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    // 视频之外的留边属于透明玻璃外壳；不能宣告整张视图不透明，否则系统会跳过后方合成。
    override var isOpaque: Bool { false }

    /// 显示新帧：普通模式贴 IOSurface，快照模式贴 CGImage（离屏缓存显示只认位图内容）。
    func show(_ buffer: CVPixelBuffer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if snapshotMode, let image = CanvasPresenter.cgImage(from: buffer) { videoLayer.contents = image }
        else if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() { videoLayer.contents = surface }
        else if let image = CanvasPresenter.cgImage(from: buffer) { videoLayer.contents = image }
        CATransaction.commit()
    }

    func show(_ image: CGImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.contents = image
        CATransaction.commit()
    }

    /// 几何必须与视图尺寸在同一事务里更新：SwiftUI 在自己的刷新阶段设置视图尺寸，若等到 AppKit 的 `layout()`
    /// 再摆放图层，会比分界线晚一个绘制周期，拖动时成片总在"追"分界线，看起来就是抖动。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateGeometry()
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorMaterialDrawing.stopObserving(&materialObserver)
        if window != nil {
            materialObserver = EditorMaterialDrawing.observeChanges { [weak self] in self?.applyAppearance() }
        }
        applyAppearance()
        updateGeometry()
    }

    private func updateGeometry() {
        let available = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        guard available.width > 0, available.height > 0 else { return }
        let scale = min(available.width / aspectRatio, available.height)
        let size = CGSize(width: (aspectRatio * scale).rounded(), height: scale.rounded())
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height).integral
        let contentsScale = window?.backingScaleFactor ?? 2
        guard rect != videoRect || videoLayer.contentsScale != contentsScale else { return }
        videoRect = rect
        // 只改几何：视频纹理由合成器缩放，不重新上传；投影路径随尺寸更新。
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = rect
        videoLayer.contentsScale = contentsScale
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let surface = EditorMaterialDrawing.surface(CaploNSColor.surfaceCanvasWell, opaque: CaploNSColor.surfaceOpaqueCanvas, appearance: effectiveAppearance, opaqueOverride: materialOpaqueOverride)
        layer?.backgroundColor = EditorMaterialDrawing.color(surface, appearance: effectiveAppearance)
        CATransaction.commit()
    }

}
