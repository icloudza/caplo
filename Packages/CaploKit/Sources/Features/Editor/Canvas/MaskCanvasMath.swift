import CoreGraphics
import EditingCore
import RenderKit

/// 画布上编辑遮罩用的纯几何：视图点 ↔ 录制内容的归一化坐标（0…1，左上原点）。
/// 不碰任何视图状态，可以单独测。
///
/// 正变换写在 `SceneRenderer.frame` 里，这里是它的逆，一共四级，少一级框就和画面分家：
/// 1. 遮罩坐标是**整幅画面**归一化的（遮罩贴在裁切之前的画面上），而下面几步都在**裁切区**里算，
///    所以先要过一遍 `crop.remap`；
/// 2. 内容按 `geometry(...)` 摆进成片矩形，固定取景时还在框内按 `focus.scale` 推近；
/// 3. 整体推近时整幅画面被 `sceneZoom` 变换；
/// 4. 全屏文字 / 卡片 / 分屏时画面层再被 `StageTransform` 缩放挪位（分屏还会把留白收掉，几何按收掉后的留白算）。
///
/// 传进来的 `focus` 必须由 `edit.cropResolved()` 求得，和渲染端同一个口径。
enum MaskCanvasMath {
    /// 视图点（`CanvasSurfaceView` 坐标，未翻转，y 向上）→ 整幅画面的归一化坐标。
    /// `sourceSize` 必须是裁切后的像素尺寸。
    static func normalized(_ point: CGPoint, videoRect: CGRect, edit: VideoEdit, sourceSize: CGSize,
                           focus: FocusState, stage: StageTransform = StageTransform()) -> CGPoint? {
        guard let context = Context(videoRect: videoRect, edit: SceneRenderer.stagedEdit(edit, stage: stage), sourceSize: sourceSize, focus: focus) else { return nil }
        var q = CGPoint(x: point.x - videoRect.minX, y: point.y - videoRect.minY)
        if !stage.isIdentity { q = q.applying(stage.affine(canvas: videoRect.size).inverted()) }
        if context.follow { q = q.applying(context.zoom.inverted()) }
        let u = (q.x - context.rect.minX) / context.rect.width
        let v = 1 - (q.y - context.rect.minY) / context.rect.height
        let inCrop = CGPoint(x: context.centerX + (u - 0.5) / context.scale,
                             y: context.centerY + (v - 0.5) / context.scale)
        return context.crop?.restore(inCrop) ?? inCrop
    }

    /// 整幅画面的归一化坐标 → 视图点。画遮罩框与把手用。
    static func viewPoint(_ normalized: CGPoint, videoRect: CGRect, edit: VideoEdit, sourceSize: CGSize,
                          focus: FocusState, stage: StageTransform = StageTransform()) -> CGPoint? {
        guard let context = Context(videoRect: videoRect, edit: SceneRenderer.stagedEdit(edit, stage: stage), sourceSize: sourceSize, focus: focus) else { return nil }
        let inCrop = context.crop?.remap(normalized) ?? normalized
        let u = 0.5 + (inCrop.x - context.centerX) * context.scale
        let v = 0.5 + (inCrop.y - context.centerY) * context.scale
        var q = CGPoint(x: context.rect.minX + u * context.rect.width, y: context.rect.minY + (1 - v) * context.rect.height)
        if context.follow { q = q.applying(context.zoom) }
        if !stage.isIdentity { q = q.applying(stage.affine(canvas: videoRect.size)) }
        return CGPoint(x: q.x + videoRect.minX, y: q.y + videoRect.minY)
    }

    /// 归一化矩形（中心 + 尺寸）在视图里的外接矩形。椭圆遮罩也用它，只是描边画成椭圆。
    static func viewRect(center: CGPoint, size: CGSize, videoRect: CGRect, edit: VideoEdit, sourceSize: CGSize,
                         focus: FocusState, stage: StageTransform = StageTransform()) -> CGRect? {
        let corners = [CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                       CGPoint(x: center.x + size.width / 2, y: center.y + size.height / 2)]
            .compactMap { viewPoint($0, videoRect: videoRect, edit: edit, sourceSize: sourceSize, focus: focus, stage: stage) }
        guard corners.count == 2 else { return nil }
        return CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                      width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y))
    }

    /// 成片矩形（录屏画面在视图里占的位置）。
    static func screenRect(videoRect: CGRect, edit: VideoEdit, sourceSize: CGSize,
                           focus: FocusState, stage: StageTransform = StageTransform()) -> CGRect? {
        guard let context = Context(videoRect: videoRect, edit: SceneRenderer.stagedEdit(edit, stage: stage), sourceSize: sourceSize, focus: focus) else { return nil }
        var rect = context.rect
        if context.follow { rect = rect.applying(context.zoom) }
        if !stage.isIdentity { rect = rect.applying(stage.affine(canvas: videoRect.size)) }
        return rect.offsetBy(dx: videoRect.minX, dy: videoRect.minY)
    }

    private struct Context {
        let rect: CGRect
        let follow: Bool
        let zoom: CGAffineTransform
        let scale: Double
        let centerX: Double
        let centerY: Double
        /// 非空时遮罩坐标要在整幅画面域与裁切区域之间来回换算。
        let crop: CropRect?

        /// 版式变换不进这里：它作用在整幅画面上，由上面几个入口在最后一步单独叠加 / 剥除。
        init?(videoRect: CGRect, edit: VideoEdit, sourceSize: CGSize, focus: FocusState) {
            guard videoRect.width > 1, videoRect.height > 1, sourceSize.width > 0, sourceSize.height > 0 else { return nil }
            let size = videoRect.size
            rect = SceneRenderer.geometry(edit: edit, sourceSize: sourceSize, size: size).rect
            guard rect.width > 0, rect.height > 0 else { return nil }
            follow = !edit.layout.fixedFocusFrame && focus.scale > 1.0001 && edit.camera?.isCameraFull != true
            zoom = follow ? SceneRenderer.sceneZoom(focus: focus, screen: rect, size: size) : .identity
            scale = follow ? 1 : max(1, focus.scale)
            centerX = follow ? 0.5 : focus.x
            centerY = follow ? 0.5 : focus.y
            let region = edit.layout.effectiveCrop
            crop = (region?.isFull ?? true) ? nil : region
        }
    }

    /// 把手的命中半径。框在画面上很小时（分屏把画面压成一栏、或者遮罩本来就小）要按框收窄：
    /// 八个把手各占一片固定大小的命中区，框一小就连成一片，块体本身一点也点不着——
    /// 表现为"选中之后只能改大小、挪不动"。
    ///
    /// 上下左右都有中点把手，所以一条边上有三个锚点；半径小于边长的四分之一才留得下可拖的缝，
    /// 这里取 0.22 留一点余量。
    static func handleReach(_ rect: CGRect, size: CGFloat, slop: CGFloat) -> CGFloat {
        max(2, min(size / 2 + slop, min(rect.width, rect.height) * 0.22))
    }

    /// 八个把手加块体本身。
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, body
        var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }
        /// 把手在矩形里的相对位置（0…1，左上原点）；块体返回中心。
        var anchor: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0); case .top: CGPoint(x: 0.5, y: 0); case .topRight: CGPoint(x: 1, y: 0)
            case .right: CGPoint(x: 1, y: 0.5); case .bottomRight: CGPoint(x: 1, y: 1); case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomLeft: CGPoint(x: 0, y: 1); case .left: CGPoint(x: 0, y: 0.5); case .body: CGPoint(x: 0.5, y: 0.5)
            }
        }
    }

    /// 拖动把手后的新矩形（归一化坐标，左上原点）。
    /// 对角（或对边）固定不动，被拖的那一侧跟到 `point`；最小边长防止拖成零面积。
    static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint, minimum: Double = 0.01) -> CGRect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        switch handle {
        case .topLeft: left = point.x; top = point.y
        case .top: top = point.y
        case .topRight: right = point.x; top = point.y
        case .right: right = point.x
        case .bottomRight: right = point.x; bottom = point.y
        case .bottom: bottom = point.y
        case .bottomLeft: left = point.x; bottom = point.y
        case .left: left = point.x
        case .body: return rect
        }
        // 越过对边时不翻面，停在最小边长上：手感上边被"顶住"，比矩形突然翻过去容易控制。
        if handle == .topLeft || handle == .left || handle == .bottomLeft { left = min(left, right - minimum) }
        if handle == .topRight || handle == .right || handle == .bottomRight { right = max(right, left + minimum) }
        if handle == .topLeft || handle == .top || handle == .topRight { top = min(top, bottom - minimum) }
        if handle == .bottomLeft || handle == .bottom || handle == .bottomRight { bottom = max(bottom, top + minimum) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 遮罩存的是中心加尺寸；把矩形换回去，并把中心钳制在画面内。
    /// 尺寸不钳制到画面内：贴边的遮罩要能挂出画面外一点，才不会在边缘留一条没盖住的缝。
    static func components(_ rect: CGRect) -> (x: Double, y: Double, width: Double, height: Double) {
        (min(1, max(0, rect.midX)), min(1, max(0, rect.midY)),
         min(2, max(0.004, rect.width)), min(2, max(0.004, rect.height)))
    }
}
