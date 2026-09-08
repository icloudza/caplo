import SwiftUI
import CaploDesignSystem
import EditingCore
import RenderKit
import ProjectKit
import ExportKit

/// 自定义布局（像 FocuSee）：在当前帧上直接拖录屏与人像的位置、拉角改大小，“应用”才写进工程。
/// 人像按叠放布局自由摆放（卡片布局打开时先换算成等价的叠放）；录屏在留白之内缩放与摆位。
/// 对话框需要的三张图：打开前在后台取好，对话框一出现就是完整画面。
struct CustomLayoutStills: Sendable {
    var screen: CGImage?
    var camera: CGImage?
    var backdrop: CGImage?

    @MainActor static func load(model: VideoEditorModel) async -> CustomLayoutStills {
        let stills = await model.layoutStills()
        var loaded = CustomLayoutStills(screen: stills.screen, camera: stills.camera)
        if let image = ProjectMedia.backgroundImage(for: model.edit.layout, in: model.entry.url) {
            loaded.backdrop = CIContext().createCGImage(image, from: image.extent)
        }
        return loaded
    }
}

struct CustomLayoutSheet: View {
    let model: VideoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var camera: CameraLayout
    @State private var layout: CanvasLayout
    @State private var screenImage: CGImage?
    @State private var cameraImage: CGImage?
    @State private var backdrop: CGImage?
    @State private var dragStart: (camera: CameraLayout, layout: CanvasLayout)?
    @State private var revealed = false
    /// 拖动中吸附上的参考线（画布边、留白边、中线、另一块的边与中线），青色画出来。
    @State private var guides: [CustomLayoutMath.Guide] = []

    init(model: VideoEditorModel, stills: CustomLayoutStills = CustomLayoutStills()) {
        self.model = model
        // 原帧已经取好：一开始就按真实录屏比例换算，画面不会先按 16 : 9 摆一次再跳。
        let source = stills.screen.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 16, height: 9)
        let converted = CustomLayoutMath.customEquivalent(camera: model.edit.camera ?? CameraLayout(), edit: model.edit, sourceSize: source)
        _camera = State(initialValue: converted.camera)
        _layout = State(initialValue: converted.layout)
        _screenImage = State(initialValue: stills.screen)
        _cameraImage = State(initialValue: stills.camera)
        _backdrop = State(initialValue: stills.backdrop)
    }

    private var edit: VideoEdit { var copy = model.edit; copy.camera = camera; copy.layout = layout; copy.focuses = []; return copy }
    private var sourceSize: CGSize { screenImage.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 16, height: 9) }

    var body: some View {
        VStack(spacing: CaploMetrics.Spacing.l) {
            Text("自定义布局").font(CaploFont.panelTitle).foregroundStyle(CaploColor.textPrimary)
            GeometryReader { proxy in
                let size = CustomLayoutMath.canvasSize(fitting: proxy.size, ratio: layout.ratio.value)
                canvas(size: size).frame(width: size.width, height: size.height).position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(minWidth: 640, minHeight: 360)
            HStack {
                Text("拖动录屏或人像改位置，拉右下角改大小。").font(CaploFont.caption).foregroundStyle(CaploColor.textTertiary)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(StudioButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("应用") {
                    let applied = camera, canvas = layout
                    model.commit { $0.camera = applied; $0.layout.screenScale = canvas.screenScale; $0.layout.screenOffsetX = canvas.screenOffsetX; $0.layout.screenOffsetY = canvas.screenOffsetY }
                    dismiss()
                }.buttonStyle(StudioButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(CaploMetrics.Spacing.l)
        .frame(width: 900, height: 600)
        .background(CaploColor.surfaceOpaqueWindow)
        .opacity(revealed ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.22)) { revealed = true } }
        .task {
            // 打开前没取到帧（极少见）才在这里补取，并带淡入。
            guard screenImage == nil, cameraImage == nil else { return }
            let stills = await CustomLayoutStills.load(model: model)
            withAnimation(.easeInOut(duration: 0.25)) {
                screenImage = stills.screen; cameraImage = stills.camera; backdrop = stills.backdrop
                let converted = CustomLayoutMath.customEquivalent(camera: model.edit.camera ?? CameraLayout(), edit: model.edit, sourceSize: sourceSize)
                camera = converted.camera; layout = converted.layout
            }
        }
    }

    /// 画布：背景 → 录屏（圆角、阴影）→ 人像；两者都带虚线框和右下角把手。坐标全部按 Core Image 算再翻成视图坐标。
    @ViewBuilder private func canvas(size: CGSize) -> some View {
        let screen = CustomLayoutMath.flip(SceneRenderer.geometry(edit: edit, sourceSize: sourceSize, size: size).rect, in: size)
        let portrait = CustomLayoutMath.flip(SceneRenderer.cameraRect(edit: edit, layout: camera, size: size, sourceSize: sourceSize), in: size)
        let radius = min(layout.cornerRadius * size.width / 960, min(screen.width, screen.height) / 2)
        ZStack(alignment: .topLeading) {
            background.frame(width: size.width, height: size.height).clipped().zIndex(-2)
            Group {
                if let screenImage { Image(decorative: screenImage, scale: 1).resizable() } else { CaploColor.surfaceOpaqueRaised }
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(layout.shadow ? 0.35 : 0), radius: 12, y: 6)
            .overlay { guide(screen.size) }
            .offset(x: screen.minX, y: screen.minY)
            .zIndex(0)
            .gesture(screenDrag(size: size, screen: screen))
            handle(at: CGPoint(x: screen.maxX, y: screen.maxY)).zIndex(2).gesture(screenResize(size: size, screen: screen))
            Group {
                if let cameraImage { Image(decorative: cameraImage, scale: 1).resizable().scaledToFill().scaleEffect(x: camera.mirrored ? -1 : 1) } else { CaploColor.accentSoft }
            }
            .frame(width: portrait.width, height: portrait.height)
            .clipShape(portraitShape(portrait))
            .overlay { if !camera.isCameraFull { guide(portrait.size) } }
            .offset(x: portrait.minX, y: portrait.minY)
            .zIndex(camera.underScreen ? -1 : 1)
            .allowsHitTesting(!camera.isCameraFull)
            .gesture(cameraDrag(size: size, portrait: portrait))
            if !camera.isCameraFull {
                handle(at: CGPoint(x: portrait.maxX, y: portrait.maxY)).gesture(cameraResize(size: size, portrait: portrait))
            }
            guideLines(size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 吸附参考线：竖线贯穿整高、横线贯穿整宽，中线吸附时就是一个十字。
    private func guideLines(size: CGSize) -> some View {
        Path { path in
            for guide in guides {
                switch guide {
                case .vertical(let x): path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                case .horizontal(let y): path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
        }
        .stroke(CaploColor.record, lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func innerRect(size: CGSize) -> CGRect {
        let padding = layout.padding * size.width / 960
        return CGRect(x: padding, y: padding, width: max(0, size.width - 2 * padding), height: max(0, size.height - 2 * padding))
    }

    private var background: some View {
        Group {
            if let backdrop {
                Image(decorative: backdrop, scale: 1).resizable().scaledToFill()
            } else {
                let colors = layout.background.colors
                LinearGradient(colors: [Color(red: colors.start.red, green: colors.start.green, blue: colors.start.blue),
                                        Color(red: colors.end.red, green: colors.end.green, blue: colors.end.blue)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private func portraitShape(_ rect: CGRect) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: camera.isCameraFull ? 0 : min(rect.width, rect.height) * camera.cornerRadius)
    }

    private func guide(_ size: CGSize) -> some View {
        Rectangle().strokeBorder(CaploColor.accent, style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(width: size.width, height: size.height).allowsHitTesting(false)
    }

    private func handle(at point: CGPoint) -> some View {
        Circle().fill(CaploColor.accent).frame(width: 12, height: 12).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .position(point)
    }

    // MARK: - 手势：拖动改位置，拉右下角改大小；松手前一直基于按下时的布局算，不累积误差。

    private func screenDrag(size: CGSize, screen: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = (camera, layout) }
                guard let start = dragStart else { return }
                var base = edit; base.layout = start.layout
                let origin = CustomLayoutMath.flip(SceneRenderer.geometry(edit: base, sourceSize: sourceSize, size: size).rect, in: size)
                let moved = origin.offsetBy(dx: value.translation.width, dy: value.translation.height)
                let portrait = CustomLayoutMath.flip(SceneRenderer.cameraRect(edit: edit, layout: camera, size: size, sourceSize: sourceSize), in: size)
                let snapped = CustomLayoutMath.snap(moved, canvas: CGRect(origin: .zero, size: size), inner: innerRect(size: size), targets: [portrait])
                guides = snapped.guides
                layout = CustomLayoutMath.placingScreen(at: snapped.rect, in: start.layout, size: size)
            }
            .onEnded { _ in dragStart = nil; guides = [] }
    }

    private func screenResize(size: CGSize, screen: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = (camera, layout) }
                guard let start = dragStart else { return }
                var base = edit; base.layout = start.layout
                let origin = CustomLayoutMath.flip(SceneRenderer.geometry(edit: base, sourceSize: sourceSize, size: size).rect, in: size)
                let edge = CustomLayoutMath.snapEdge(origin.minX + origin.width + value.translation.width, to: [size.width, innerRect(size: size).maxX])
                guides = edge.guide.map { [.vertical($0)] } ?? []
                layout = CustomLayoutMath.scalingScreen(toWidth: edge.value - origin.minX, from: start.layout, edit: base, sourceSize: sourceSize, size: size)
            }
            .onEnded { _ in dragStart = nil; guides = [] }
    }

    private func cameraDrag(size: CGSize, portrait: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = (camera, layout) }
                guard let start = dragStart else { return }
                let origin = CustomLayoutMath.flip(start.camera.rect(in: size), in: size)
                let moved = origin.offsetBy(dx: value.translation.width, dy: value.translation.height)
                let screen = CustomLayoutMath.flip(SceneRenderer.geometry(edit: edit, sourceSize: sourceSize, size: size).rect, in: size)
                let snapped = CustomLayoutMath.snap(moved, canvas: CGRect(origin: .zero, size: size), inner: innerRect(size: size), targets: [screen])
                guides = snapped.guides
                camera = CustomLayoutMath.placingPortrait(at: snapped.rect, in: start.camera, size: size)
            }
            .onEnded { _ in dragStart = nil; guides = [] }
    }

    private func cameraResize(size: CGSize, portrait: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = (camera, layout) }
                guard let start = dragStart else { return }
                let origin = CustomLayoutMath.flip(start.camera.rect(in: size), in: size)
                let edge = CustomLayoutMath.snapEdge(origin.minX + origin.width + value.translation.width, to: [size.width, innerRect(size: size).maxX, size.width / 2])
                guides = edge.guide.map { [.vertical($0)] } ?? []
                camera = CustomLayoutMath.sizingPortrait(toWidth: edge.value - origin.minX, from: start.camera, size: size)
            }
            .onEnded { _ in dragStart = nil; guides = [] }
    }
}

/// 自定义布局的纯几何换算，视图坐标（Y 向下）与 Core Image 坐标（Y 向上）互转，全部可测。
enum CustomLayoutMath {
    enum Guide: Equatable { case vertical(CGFloat), horizontal(CGFloat) }
    /// 吸附距离（视图点）。
    static let snapDistance: CGFloat = 8

    /// 拖动时的吸附：每个轴上把矩形的左 / 中 / 右（上 / 中 / 下）与画布边、留白边、画布中线以及另一块的边与中线比较，
    /// 取最近且在吸附距离内的一条对齐；命中的位置画参考线，中线命中时两条线就是十字。
    static func snap(_ rect: CGRect, canvas: CGRect, inner: CGRect, targets: [CGRect], distance: CGFloat = snapDistance) -> (rect: CGRect, guides: [Guide]) {
        var xLines = [canvas.minX, canvas.maxX, canvas.midX, inner.minX, inner.maxX]
        var yLines = [canvas.minY, canvas.maxY, canvas.midY, inner.minY, inner.maxY]
        for target in targets { xLines += [target.minX, target.maxX, target.midX]; yLines += [target.minY, target.maxY, target.midY] }
        var snapped = rect
        var guides: [Guide] = []
        if let x = nearest(edges: [rect.minX, rect.midX, rect.maxX], lines: xLines, distance: distance) {
            snapped.origin.x += x.delta; guides.append(.vertical(x.line))
        }
        if let y = nearest(edges: [rect.minY, rect.midY, rect.maxY], lines: yLines, distance: distance) {
            snapped.origin.y += y.delta; guides.append(.horizontal(y.line))
        }
        return (snapped, guides)
    }

    /// 拉把手时右 / 下边的吸附。
    static func snapEdge(_ value: CGFloat, to lines: [CGFloat], distance: CGFloat = snapDistance) -> (value: CGFloat, guide: CGFloat?) {
        guard let hit = nearest(edges: [value], lines: lines, distance: distance) else { return (value, nil) }
        return (value + hit.delta, hit.line)
    }

    private static func nearest(edges: [CGFloat], lines: [CGFloat], distance: CGFloat) -> (delta: CGFloat, line: CGFloat)? {
        var best: (delta: CGFloat, line: CGFloat)?
        for edge in edges {
            for line in lines where abs(line - edge) <= distance {
                if best == nil || abs(line - edge) < abs(best!.delta) { best = (line - edge, line) }
            }
        }
        return best
    }

    /// 画布在给定空间里按比例最大化。
    static func canvasSize(fitting space: CGSize, ratio: Double) -> CGSize {
        guard space.width > 0, space.height > 0, ratio > 0 else { return .zero }
        let width = min(space.width, space.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    /// Core Image 的左下原点矩形 ↔ 视图的左上原点矩形。
    static func flip(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 卡片布局（侧边 / 在后 / 分屏）换算成看起来一模一样的自定义布局：人像变成同位置、同大小、同宽高比的叠放圆角矩形
    /// （“在后”保留垫在录屏下面的层级，分屏的人像不随聚焦缩小），录屏用画面布局的缩放与摆位复现原来的矩形。
    /// 叠放与人像全屏原样返回。
    static func customEquivalent(camera: CameraLayout, edit: VideoEdit, sourceSize: CGSize) -> (camera: CameraLayout, layout: CanvasLayout) {
        guard camera.usesCard else { return (camera, edit.layout) }
        let size = CGSize(width: 1920, height: 1920 / max(0.1, edit.layout.ratio.value))
        let padding = edit.layout.padding * size.width / 960
        let frames = camera.isSide ? camera.sideFrames(canvas: size, padding: padding, screen: sourceSize)
            : camera.isBehind ? camera.behindFrames(canvas: size, padding: padding, screen: sourceSize)
            : camera.splitFrames(canvas: size, padding: padding, screen: sourceSize)
        var portrait = camera
        portrait.mode = .overlay; portrait.shape = .roundedRectangle
        portrait.aspect = frames.camera.height > 0 ? min(4, max(0.25, frames.camera.width / frames.camera.height)) : 0.6
        portrait.size = min(0.6, max(0.12, frames.camera.width / min(size.width, size.height)))
        portrait.belowScreen = camera.isBehind
        if camera.isBehind { portrait.shadow = false }
        if camera.isSplit { portrait.shadow = edit.layout.shadow; portrait.shrinkOnFocus = false }
        portrait = placingPortrait(at: flip(frames.camera, in: size), in: portrait, size: size)
        var reference = edit; reference.camera = portrait; reference.layout.screenScale = 1; reference.layout.screenOffsetX = 0; reference.layout.screenOffsetY = 0
        let full = SceneRenderer.geometry(edit: reference, sourceSize: sourceSize, size: size).rect
        var canvas = edit.layout
        canvas.screenScale = full.width > 0 ? min(1, max(0.2, frames.screen.width / full.width)) : 1
        canvas = placingScreen(at: flip(frames.screen, in: size), in: canvas, size: size)
        return (portrait, canvas)
    }

    /// 人像矩形（视图坐标）→ 归一化位置；越界钳到可移动区域内。
    static func placingPortrait(at rect: CGRect, in layout: CameraLayout, size: CGSize) -> CameraLayout {
        let edge = min(size.width, size.height), margin = edge * 0.035
        let width = edge * layout.size, height = layout.shape == .circle ? width : width / layout.effectiveAspect
        let spanX = size.width - 2 * margin - width, spanY = size.height - 2 * margin - height
        var copy = layout
        copy.x = spanX > 0 ? min(1, max(0, (rect.minX - margin) / spanX)) : 0.5
        copy.y = spanY > 0 ? min(1, max(0, (rect.minY - margin) / spanY)) : 0.5
        return copy
    }

    /// 拉把手改人像宽度：大小相对画布短边，钳在 12 %…60 %。
    static func sizingPortrait(toWidth width: Double, from layout: CameraLayout, size: CGSize) -> CameraLayout {
        var copy = layout
        copy.size = min(0.6, max(0.12, width / min(size.width, size.height)))
        return copy
    }

    /// 录屏矩形（视图坐标）→ 在留白内剩余空间里的位置（−1…1，Y 向下为正）。
    static func placingScreen(at rect: CGRect, in layout: CanvasLayout, size: CGSize) -> CanvasLayout {
        let padding = layout.padding * size.width / 960
        let inner = CGRect(x: padding, y: padding, width: max(0, size.width - 2 * padding), height: max(0, size.height - 2 * padding))
        let slackX = inner.width - rect.width, slackY = inner.height - rect.height
        var copy = layout
        copy.screenOffsetX = slackX > 0.5 ? min(1, max(-1, ((rect.minX - inner.minX) / slackX) * 2 - 1)) : 0
        copy.screenOffsetY = slackY > 0.5 ? min(1, max(-1, ((rect.minY - inner.minY) / slackY) * 2 - 1)) : 0
        return copy
    }

    /// 拉把手改录屏宽度：相对留白内等比适配的宽度，钳在 30 %…100 %。
    static func scalingScreen(toWidth width: Double, from layout: CanvasLayout, edit: VideoEdit, sourceSize: CGSize, size: CGSize) -> CanvasLayout {
        var reference = edit; reference.layout = layout; reference.layout.screenScale = 1
        let full = SceneRenderer.geometry(edit: reference, sourceSize: sourceSize, size: size).rect.width
        var copy = layout
        copy.screenScale = full > 0 ? min(1, max(0.2, width / full)) : 1
        return copy
    }
}
