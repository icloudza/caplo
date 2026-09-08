import AppKit
import SwiftUI
import QuartzCore
import AVFoundation
import Observation
import EditingCore
import ExportKit
import CaploDesignSystem

@MainActor @Observable
final class TimelineViewport {
    var zoom = 0.0
    var snapping = true
    var fitRequest = 0
    var trackHeights: [Double] = [40, 40, 40, 40]
    /// 画布 / 时间线分界正在拖动；持久化等昂贵操作延后，可见色块仍按当前几何重绘。
    var liveResizing = false
    @ObservationIgnored var width = 700.0
    func fit(duration: Double) {
        zoom = min(4, max(-12, log2(width / max(1, duration) / 60)))
        fitRequest &+= 1
    }
}

struct TimelineViewportBridge: NSViewRepresentable {
    @Environment(\.caploMaterialOpaquePreview) private var materialOpaquePreview
    let model: VideoEditorModel
    let viewport: TimelineViewport
    func makeNSView(context: Context) -> TimelineViewportView { TimelineViewportView(model: model, viewport: viewport) }
    func updateNSView(_ view: TimelineViewportView, context: Context) {
        view.materialOpaqueOverride = materialOpaquePreview
        view.liveResizing = viewport.liveResizing
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, zoom: viewport.zoom, fit: viewport.fitRequest, heights: viewport.trackHeights)
    }
    static func dismantleNSView(_ view: TimelineViewportView, coordinator: ()) { view.detach() }
}

/// 固定轨头和滚动内容共用一个有限尺寸视口，绘制量随窗口宽度变化，不随视频总长度变化。
/// 播放头是独立图层：暂停时跟随模型位置；播放时由显示链路按屏幕刷新率读取播放器时基直接驱动，
/// 与 30 fps 的模型回调解耦，轨道本身只在视口变化时重绘。滚动条为自绘覆盖式细条，只在内容超出时出现。
@MainActor
final class TimelineViewportView: NSView {
    private let model: VideoEditorModel
    private let viewport: TimelineViewport
    private var edit: VideoEdit
    private var analysis = TimelineAnalysis()
    private var index: TimelineIndex
    private var selection: Set<UUID> = []
    private var focus: UUID?
    private var primary: UUID?
    private var scale = 60.0
    private var offset = 0.0
    private var fitRequest = 0
    private var detached = false
    private var playbackPosition = 0.0
    private var drag: Drag?
    private var renamePopover: NSPopover?
    private enum DropTarget: Equatable {
        case row(UUID), before(UUID?), invalid(UUID)
    }
    private var dropTarget: DropTarget?
    private var snappedTime: Double?
    private var autoScrollTask: Task<Void, Never>?
    private var dragLocation: CGPoint?
    private var dragModifiers: NSEvent.ModifierFlags = []
    private let playhead = CALayer()
    private let playheadHandle = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var playbackFollow = TimelinePlaybackFollow()
    private var lastDisplayTimestamp: Double?
    private var followPausedUntil = 0.0
    private let navigator = TimelineNavigatorView()
    private let skimmer = CALayer()
    private let skimmerHandle = CAShapeLayer()
    private let skimmerTime = CATextLayer()
    /// 悬停时间码的底板：文字层只负责文字，按字体行高垂直居中放在底板里，宽度随文字。
    private let skimmerPlate = CALayer()
    private let skimmerFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    private let dragGhost = CALayer()
    private let dragGhostTitle = CATextLayer()
    private var mouseTracking: NSTrackingArea?
    private var tooltipLabels: [NSView.ToolTipTag: String] = [:]
    private var hoveredPoint: CGPoint?
    private var retainedExtent = 0.0
    private var ghostGrabOffset = CGPoint.zero
    private(set) var dragGhostVisible = false
    private(set) var skimmerVisible = false
    /// 当前 draw 调用的目标上下文；标签不依赖图标等嵌套绘制暂时设置的 NSGraphicsContext。
    private var textDrawingContext: CGContext?

    /// 纵向滚动保留紧凑滑块；水平导航由独立的时间线总览条承担。
    private var verticalKnob = CGRect.zero
    private var scrollDrag: (origin: CGPoint, offset: Double)?
    private var verticalOffset = 0.0
    /// 色块已经按可见行绘制，分界拖动也更新当前几何，避免冻结旧滚动条和行背景。
    var liveResizing = false {
        didSet {
            guard liveResizing != oldValue else { return }
            if !liveResizing { changedViewport() }
        }
    }
    private var trackHeights: [Double] = [40, 40, 40, 40]
    private var resizingTrack: (index: Int, origin: Double, height: Double)?
    private var audioRows: [AudioTrack: Int] = [:]
    /// 轨头只放一个 18 点图标：宽 44，图标居中；静音 / 仅播放此轨已移到工具栏。
    static let headerWidth = 44.0
    static let timeOrigin = headerWidth + 10
    private var timeOrigin: Double { Self.timeOrigin }
    private var headerWidth: Double { Self.headerWidth }
    /// 行成员关系独立于时间；固定行高让同行拖放与行间插入使用稳定坐标。
    private struct Block {
        let id: UUID
        let role: TimelineMedia?
        let title: String
        /// 按角色与序号生成的默认名称；用户自定义名称清空时回到它。
        let defaultTitle: String
        let start: Double
        let duration: Double
        let span: FocusSpan?
    }
    private var blocks: [Block] = []
    private var rows: [[Block]] = []
    private var rowByBlock: [UUID: Int] = [:]
    private let rowHeight = 42.0
    private var totalHeight: Double { Double(rows.count) * rowHeight }
    /// 时间线到内容结尾为止，只留 48 点让末尾的把手好抓；不再在片子后面拖出半屏空白。
    /// 交互期间范围只可向外扩展；裁短时收缩视口会反向改变拖动增量。
    private var timelineExtent: Double {
        max(retainedExtent, edit.duration + 48 / scale)
    }
    private func rowY(_ number: Int) -> Double { 28 + Double(number) * rowHeight - verticalOffset }
    private func rebuildBlocks() {
        var values: [UUID: Block] = [:]
        let screenNumbers = Dictionary(uniqueKeysWithValues: edit.clips.enumerated().map { ($0.element.id, $0.offset) })
        for role in [TimelineMedia.screen, .camera, .system, .microphone] {
            if role == .camera, !model.entry.document.segments.contains(where: { $0.files[.camera] != nil }) { continue }
            if role == .system, !model.audioTracks.contains(.system) { continue }
            if role == .microphone, !model.audioTracks.contains(.microphone) { continue }
            let clips = edit.mediaClips(role), timing = TimelineIndex(clips: clips)
            for (number, clip) in clips.enumerated() {
                let title = role == .screen ? "录制画面" : role == .camera ? "摄像头" : role == .system ? "系统声音" : "麦克风"
                let labelNumber = role == .screen ? (screenNumbers[clip.id] ?? number) : number
                let defaultTitle = title + String(format: " %02d", labelNumber + 1)
                values[clip.id] = Block(id: clip.id, role: role, title: clip.title ?? defaultTitle, defaultTitle: defaultTitle, start: timing.boundaries[number], duration: clip.duration, span: nil)
            }
        }
        let focuses = Dictionary(uniqueKeysWithValues: edit.focuses.map { ($0.id, $0) })
        for span in edit.focusSpans() {
            guard let focus = focuses[span.focusID] else { continue }
            let defaultTitle = String(format: "镜头聚焦 · %.1f×", focus.scale)
            values[span.focusID] = Block(id: span.focusID, role: nil, title: focus.displayTitle, defaultTitle: defaultTitle, start: span.start, duration: span.duration, span: span)
        }
        blocks = edit.orderedLayerIDs.compactMap { values.removeValue(forKey: $0) }
        blocks += values.values.sorted { $0.start < $1.start }
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        rows = edit.timelineRows.map { $0.compactMap { lookup[$0] }.sorted { $0.start < $1.start } }.filter { !$0.isEmpty }
        rowByBlock.removeAll(); audioRows.removeAll()
        for (number, row) in rows.enumerated() {
            for block in row {
                rowByBlock[block.id] = number
                if block.role == .system, audioRows[.system] == nil { audioRows[.system] = number }
                if block.role == .microphone, audioRows[.microphone] == nil { audioRows[.microphone] = number }
            }
        }
        let items = blocks.map { block in
            let kind: TimelineNavigatorItem.Kind
            switch block.role { case .screen: kind = .screen; case .camera: kind = .camera; case .system, .microphone: kind = .audio; case nil: kind = .focus }
            return TimelineNavigatorItem(id: block.id, start: block.start, duration: block.duration, kind: kind)
        }
        navigator.update(items: items, duration: timelineExtent, visibleStart: offset, visibleDuration: contentWidth / scale, playhead: playbackPosition)
    }
    private var trackArea: CGRect { CGRect(x: 0, y: 28, width: bounds.width, height: max(1, bounds.height - 28 - TimelineNavigatorView.preferredHeight)) }
    private(set) var trackDrawCount = 0
    private(set) var visibleClipDrawCount = 0
    private(set) var visibleFocusDrawCount = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    private var materialObserver: NSObjectProtocol?
    var materialOpaqueOverride: Bool? {
        didSet {
            guard oldValue != materialOpaqueOverride else { return }
            navigator.materialOpaqueOverride = materialOpaqueOverride
            refreshMaterialAppearance()
        }
    }

    private struct Drag {
        enum Kind { case scrub, block(Block, VideoEdit.FocusDragEdge), reorder(UUID) }
        let kind: Kind
        let origin: CGPoint
        let snapshot: VideoEdit
        let timeline: TimelineIndex
        let scale: Double
        let offset: Double
        var moved = false
        var horizontalDelta = 0.0
        let rowIDs: [[UUID]]
        let snapEdges: [Double]
        var blockID: UUID? {
            switch kind { case .scrub: nil; case .block(let block, _): block.id; case .reorder(let id): id }
        }
    }

    init(model: VideoEditorModel, viewport: TimelineViewport) {
        self.model = model; self.viewport = viewport
        edit = model.edit; index = TimelineIndex(clips: model.edit.clips)
        super.init(frame: .zero)
        wantsLayer = true
        // 可见轨道按需重绘；尺寸变化时显式刷新，不复用带旧滚动条的冻结位图。
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        playhead.backgroundColor = CaploNSColor.record.cgColor
        layer?.addSublayer(playhead)
        // 标尺内的播放头把手：底部收尖的小标签，拖动时也更容易看清落点。
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 0, y: 0)); handle.addLine(to: CGPoint(x: 11, y: 0)); handle.addLine(to: CGPoint(x: 11, y: 7))
        handle.addLine(to: CGPoint(x: 5.5, y: 12)); handle.addLine(to: CGPoint(x: 0, y: 7)); handle.closeSubpath()
        playheadHandle.path = handle
        playheadHandle.fillColor = CaploNSColor.record.cgColor
        playheadHandle.bounds = CGRect(x: 0, y: 0, width: 11, height: 12)
        playheadHandle.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(playheadHandle)
        setAccessibilityRole(.group)
        setAccessibilityLabel("视频时间线，方向键逐帧定位，空格播放，Command A 全选片段")
        configureOverlays()
        addSubview(navigator)
        navigator.onRangeChange = { [weak self] start, duration in self?.navigate(start: start, duration: duration) }
        rebuildBlocks()
        // 从下一轮开始观察，避免把播放时间加入 SwiftUI makeNSView 的依赖集合。
        Task { @MainActor [weak self] in self?.observePlayhead(); self?.observePlaying(); self?.observeSkimmer() }
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }
    func detach() { detached = true; EditorMaterialDrawing.stopObserving(&materialObserver); clearDrag(); navigator.detach(); model.skim(nil); stopDisplayLink() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorMaterialDrawing.stopObserving(&materialObserver)
        if window != nil {
            materialObserver = EditorMaterialDrawing.observeChanges { [weak self] in self?.refreshMaterialAppearance() }
        }
        refreshMaterialAppearance()
    }

    /// SwiftUI 每次刷新都会调用；只有内容或几何变化才重绘，与每帧播放位置分离。
    func update(edit: VideoEdit, analysis: TimelineAnalysis, selection: Set<UUID>, primary: UUID?, focus: UUID?, zoom: Double, fit: Int, heights: [Double]? = nil) {
        var changed = false
        if let heights, heights.count == 4 {
            let clamped = heights.enumerated().map { min(200, max($0.offset == 0 ? 40 : 26, $0.element.isFinite ? $0.element : 40)) }
            if clamped != trackHeights { trackHeights = clamped; changed = true }
        }
        if self.edit.clips != edit.clips { index = TimelineIndex(clips: edit.clips) }
        if self.edit != edit || self.selection != selection || self.primary != primary || self.focus != focus { changed = true }
        if analysis.system.count != self.analysis.system.count || analysis.microphone.count != self.analysis.microphone.count { changed = true }
        let contentChanged = self.edit != edit
        self.edit = edit; if contentChanged { rebuildBlocks() }; self.analysis = analysis; self.selection = selection; self.primary = primary; self.focus = focus
        let nextScale = drag == nil ? 60 * pow(2, zoom) : scale
        if nextScale != scale {
            let center = offset + contentWidth / scale / 2
            scale = nextScale; offset = center - contentWidth / scale / 2; retainedExtent = 0
            changed = true
        }
        if fit != fitRequest {
            fitRequest = fit
            offset = 0; retainedExtent = 0
            changed = true
        }
        guard changed else { return }
        changedViewport()
    }
    private var contentWidth: Double { max(1, bounds.width - timeOrigin - 8) }
    private var accent: NSColor { CaploNSColor.accent }
    /// CALayer 不会自动解析视图的外观；鼠标回调中也必须按当前窗口解析动态颜色。
    private func resolvedColor(_ color: NSColor) -> CGColor {
        TimelineTextRenderer.resolvedColor(color, appearance: effectiveAppearance)
    }
    private var visibleRange: Range<Double> { offset..<(offset + contentWidth / scale) }
    private func x(_ time: Double) -> Double { timeOrigin + (time - offset) * scale }
    private func time(_ x: Double) -> Double { max(0, offset + (x - timeOrigin) / scale) }
    private func clampOffset() {
        offset = min(max(0, timelineExtent - contentWidth / scale), max(0, offset))
        verticalOffset = min(max(0, totalHeight - trackArea.height), max(0, verticalOffset))
    }

    override func layout() {
        super.layout()
        viewport.width = contentWidth
        navigator.frame = CGRect(x: timeOrigin, y: max(28, bounds.height - TimelineNavigatorView.preferredHeight), width: contentWidth, height: TimelineNavigatorView.preferredHeight)
        clampOffset(); refreshHoveredPreview(); updateScroller(); updatePlayhead()
        // 纵向范围可能随高度重新约束，图层按钮和行底图必须在同一布局周期刷新。
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterialAppearance()
    }
    private func refreshMaterialAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        updateSkimmer(); updateGhostColors()
        needsDisplay = true
    }
    private func observePlayhead() {
        guard !detached else { return }
        withObservationTracking {
            let position = model.position
            // 播放期间由显示链路驱动，30 fps 的模型回调不再回拉播放头。
            if displayLink == nil { playbackPosition = position; updatePlayhead() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlayhead() }
        }
    }
    private func observePlaying() {
        guard !detached else { return }
        withObservationTracking { syncDisplayLink(playing: model.playing) } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlaying() }
        }
    }
    /// 播放时用视图所在显示器的刷新率读取播放器时基（连续时钟，不按渲染帧量化）驱动播放头。
    private func syncDisplayLink(playing: Bool) {
        if playing {
            guard displayLink == nil, !detached else { return }
            playbackFollow.reset(); lastDisplayTimestamp = nil
            let link = displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            stopDisplayLink()
            playbackPosition = model.position
            updatePlayhead()
        }
    }
    private func stopDisplayLink() {
        displayLink?.invalidate(); displayLink = nil; lastDisplayTimestamp = nil; playbackFollow.reset()
    }
    @objc private func displayTick(_ link: CADisplayLink) {
        guard !detached, model.playing else { return }
        let time: Double
        if let timebase = model.player.currentItem?.timebase { time = CMTimebaseGetTime(timebase).seconds }
        else { time = model.player.currentTime().seconds }
        guard time.isFinite else { return }
        playbackPosition = min(edit.duration, max(0, time))
        let now = CACurrentMediaTime()
        let elapsed = lastDisplayTimestamp.map { now - $0 } ?? 1 / 60
        lastDisplayTimestamp = now
        followPlayhead(elapsed: elapsed)
        updatePlayhead()
    }
    /// 接近右缘后连续平移，把播放头稳定留在视窗右侧；按真实帧间隔平滑，不整页跳转。
    private func followPlayhead(elapsed: Double) {
        guard drag == nil, scrollDrag == nil, !navigator.isInteracting, CACurrentMediaTime() >= followPausedUntil else { return }
        let next = playbackFollow.advance(offset: offset, playhead: playbackPosition, visibleDuration: contentWidth / scale, elapsed: elapsed)
        guard abs(next - offset) > 0.00001 else { return }
        offset = next
        changedViewport()
    }
    private func navigate(start: Double, duration: Double) {
        guard start.isFinite, duration.isFinite, duration > 0 else { return }
        hoveredPoint = nil; model.skim(nil)
        playbackFollow.reset(); followPausedUntil = CACurrentMediaTime() + 0.5
        scale = min(960, max(60 * pow(2, -12), contentWidth / duration))
        viewport.zoom = log2(scale / 60)
        offset = max(0, start)
        retainedExtent = max(retainedExtent, offset + contentWidth / scale)
        changedViewport()
    }
    private func updatePlayhead() {
        let point = x(playbackPosition)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hidden = point < timeOrigin || point > bounds.width - 4
        playhead.isHidden = hidden; playheadHandle.isHidden = hidden
        playhead.frame = CGRect(x: point - 0.75, y: 0, width: 1.5, height: trackArea.maxY)
        playheadHandle.position = CGPoint(x: point, y: 0)
        CATransaction.commit()
        updateSkimmer(); navigator.updatePlayhead(playbackPosition)
        setAccessibilityValue(TimelineTime.code(playbackPosition))
    }
    /// 总览视窗和纵向滑块只更新几何；播放推进不重新采集或遍历素材。
    private func updateScroller() {
        navigator.updateVisibleRange(start: offset, duration: contentWidth / scale, totalDuration: timelineExtent)
        let height = totalHeight
        if height > trackArea.height + 0.5 {
            let knobHeight = max(28, trackArea.height * trackArea.height / height)
            let y = trackArea.minY + (trackArea.height - knobHeight) * (verticalOffset / max(1, height - trackArea.height))
            verticalKnob = CGRect(x: bounds.width - 7, y: y, width: 5, height: knobHeight)
        } else { verticalKnob = .zero }
    }
    private func drawScrollbars() {
        let alpha = scrollDrag == nil ? 0.38 : 0.7
        for knob in [verticalKnob] where !knob.isEmpty {
            CaploNSColor.textTertiary.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: knob, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
    /// 命中滑块开始拖动；命中轨道空白则向该方向翻页。返回是否消耗了这次按下。
    private func beginScrollbarInteraction(at point: CGPoint) -> Bool {
        if !verticalKnob.isEmpty, point.x >= bounds.width - 14, trackArea.contains(point) {
            if verticalKnob.insetBy(dx: -5, dy: -4).contains(point) { scrollDrag = (point, verticalOffset); needsDisplay = true; return true }
            verticalOffset += (point.y < verticalKnob.midY ? -1 : 1) * trackArea.height * 0.8
            changedViewport(); return true
        }
        return false
    }
    private func dragScrollbar(to point: CGPoint) {
        guard let drag = scrollDrag else { return }
        let height = totalHeight
        let travel = max(1, trackArea.height - verticalKnob.height)
        verticalOffset = drag.offset + (point.y - drag.origin.y) / travel * max(0, height - trackArea.height)
        changedViewport()
    }
    private func changedViewport() {
        clampOffset(); refreshHoveredPreview(); updateScroller(); updatePlayhead(); updateTooltips()
        needsDisplay = true; window?.invalidateCursorRects(for: self)
    }
    override func scrollWheel(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option), abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), drag == nil {
            verticalOffset -= event.scrollingDeltaY; changedViewport(); return
        }
        if drag != nil { return }
        playbackFollow.reset(); followPausedUntil = CACurrentMediaTime() + 0.5
        if event.modifierFlags.contains(.option), drag == nil {
            let anchorX = convert(event.locationInWindow, from: nil).x
            let anchor = time(anchorX)
            let next = min(4, max(-12, viewport.zoom - event.scrollingDeltaY * 0.02))
            viewport.zoom = next; scale = 60 * pow(2, next)
            offset = anchor - (anchorX - timeOrigin) / scale
        } else {
            offset -= (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY) / scale
        }
        changedViewport()
        if let point = dragLocation { updateDrag(at: point, modifiers: dragModifiers) }
    }

    /// 拖动预览只改变可见分组；松手后才提交 rowGroups 和统一层序。
    private var presentedRows: [[Block]] {
        guard dragGhostVisible, let drag, let id = drag.blockID, let dropTarget else { return rows }
        if case .invalid = dropTarget { return rows }
        let movingIDs: Set<UUID>
        if case .reorder = drag.kind { movingIDs = Set(drag.rowIDs.first { $0.contains(id) } ?? [id]) }
        else { movingIDs = [id] }
        let moving = blocks.filter { movingIDs.contains($0.id) }
        var result = rows.map { $0.filter { !movingIDs.contains($0.id) } }.filter { !$0.isEmpty }
        switch dropTarget {
        case .row(let target):
            if let index = result.firstIndex(where: { $0.contains { $0.id == target } }) { result[index] = (result[index] + moving).sorted { $0.start < $1.start } }
        case .before(let target):
            let index = target.flatMap { target in result.firstIndex { $0.contains { $0.id == target } } } ?? result.count
            result.insert(moving, at: index)
        case .invalid: break
        }
        return result
    }
    /// 同行成员按真实起点排序，横向只取可见范围及跨越左边界的前一个块。
    private func visibleMembers(_ members: [Block]) -> ArraySlice<Block> {
        func lowerBound(_ value: Double) -> Int {
            var low = 0, high = members.count
            while low < high {
                let mid = (low + high) / 2
                if members[mid].start < value { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let first = max(0, lowerBound(offset - TimelineInteractionGeometry.minimumBlockWidth / scale) - 1)
        let last = lowerBound(visibleRange.upperBound)
        return members[first..<max(first, last)]
    }
    private func isFloating(_ id: UUID) -> Bool {
        guard dragGhostVisible, let drag, let moving = drag.blockID else { return false }
        if case .reorder = drag.kind { return drag.rowIDs.first { $0.contains(moving) }?.contains(id) == true }
        return moving == id
    }
    private func blockRect(_ block: Block, row: Int) -> CGRect {
        TimelineInteractionGeometry.blockRect(start: block.start, duration: block.duration, scale: scale, offset: offset,
            header: timeOrigin, y: rowY(row) + 6, height: rowHeight - 12)
    }
    private func color(for block: Block) -> NSColor {
        switch block.role { case .system, .microphone: CaploNSColor.audio; case .camera: CaploNSColor.warning; case .screen: accent; case nil: CaploNSColor.zoom }
    }
    /// 轨道类别图标：实心、圆润的符号，轨头里再垫一块类别色的圆角小徽章，与块的颜色对应。
    private func symbol(for block: Block) -> String {
        switch block.role { case .system: "speaker.wave.2.fill"; case .microphone: "mic.fill"; case .camera: "video.fill"; case .screen: "play.rectangle.fill"; case nil: "scope" }
    }
    private func drawRoleIcon(_ block: Block, at rect: CGRect, badge: Bool = false) {
        let category = color(for: block)
        if badge {
            category.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
        let glyphColor = badge ? category : NSColor.white.withAlphaComponent(0.9)
        guard let tint = NSColor(cgColor: resolvedColor(glyphColor)),
              let image = NSImage(systemSymbolName: symbol(for: block), accessibilityDescription: block.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: badge ? 11 : 12, weight: .semibold)
                    .applying(.init(paletteColors: [tint]))) else { return }
        // SymbolConfiguration 直接提供固定颜色，不再通过 lockFocus 嵌套切换当前图形上下文。
        // 符号位图四周带基线留白且不对称（"scope" 尤其明显），按位图里实际可见像素的中心对齐徽章中心；视图是翻转坐标，纵向按图像高度换算。
        let size = image.size
        let visible = Self.visibleBounds(of: image, key: "\(symbol(for: block))@\(badge ? 11 : 12)")
        image.draw(in: CGRect(x: rect.midX - visible.midX, y: rect.midY - (size.height - visible.midY), width: size.width, height: size.height))
    }
    private static var symbolVisibleBounds: [String: CGRect] = [:]
    /// 光栅化一次扫描 alpha，得到符号的可见范围（图像坐标，y 向上）；同一符号同一字号只算一次。
    private static func visibleBounds(of image: NSImage, key: String) -> CGRect {
        if let cached = symbolVisibleBounds[key] { return cached }
        let scale = 4.0
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        var result = CGRect(origin: .zero, size: image.size)
        if width > 0, height > 0, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let data = context.data?.assumingMemoryBound(to: UInt8.self) {
                var minX = width, maxX = -1, minY = height, maxY = -1
                for y in 0..<height { for x in 0..<width where data[(y * width + x) * 4 + 3] > 16 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                } }
                if maxX >= minX, maxY >= minY {
                    result = CGRect(x: Double(minX) / scale, y: Double(minY) / scale, width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
                }
            }
        }
        symbolVisibleBounds[key] = result
        return result
    }
    private func configureOverlays() {
        skimmer.zPosition = 4; skimmerHandle.zPosition = 4; skimmerPlate.zPosition = 5; skimmerTime.zPosition = 6
        skimmerHandle.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 7, height: 7), transform: nil)
        skimmerHandle.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        skimmerHandle.anchorPoint = CGPoint(x: 0.5, y: 0)
        skimmerTime.font = skimmerFont
        skimmerTime.fontSize = 9; skimmerTime.alignmentMode = .center
        skimmerTime.contentsScale = 2
        skimmerPlate.cornerRadius = 3
        for overlay in [skimmer, skimmerHandle, skimmerPlate, skimmerTime] { overlay.isHidden = true; layer?.addSublayer(overlay) }
        dragGhost.isHidden = true; dragGhost.zPosition = 20; dragGhost.cornerRadius = 6
        dragGhost.borderWidth = 1.5; dragGhost.shadowColor = NSColor.black.cgColor
        dragGhost.shadowOpacity = 0.28; dragGhost.shadowRadius = 14; dragGhost.shadowOffset = CGSize(width: 0, height: 8)
        dragGhostTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        dragGhostTitle.fontSize = 11; dragGhostTitle.contentsScale = 2; dragGhostTitle.truncationMode = .end
        dragGhost.addSublayer(dragGhostTitle); layer?.addSublayer(dragGhost)
    }
    /// 拖动副本只包含当前块的矢量色块与标题；不截图、不采样媒体，也不重画整条时间线位图。
    private func updateDragGhost(at point: CGPoint) {
        guard let drag, let id = drag.blockID, let number = rowByBlock[id], let block = blocks.first(where: { $0.id == id }) else { return }
        let rect = blockRect(block, row: number)
        if !dragGhostVisible {
            // 悬浮副本为极短块保留可读标题，不改变原块的时间宽度或裁剪基准。
            let width = min(520, max(144, min(rect.maxX, bounds.width - 8) - max(timeOrigin, rect.minX)))
            let fromHeader: Bool
            if case .reorder = drag.kind { fromHeader = true } else { fromHeader = false }
            ghostGrabOffset = CGPoint(x: fromHeader ? -32 : min(width - 10, max(10, drag.origin.x - max(timeOrigin, rect.minX))), y: min(26, max(4, drag.origin.y - rect.minY)))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dragGhost.bounds = CGRect(x: 0, y: 0, width: width, height: rowHeight - 12)
            dragGhostTitle.frame = CGRect(x: 10, y: 8, width: width - 20, height: 16)
            dragGhostTitle.string = block.title
            updateGhostColors()
            dragGhost.shadowPath = CGPath(roundedRect: dragGhost.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            var transform = reduceMotion ? CATransform3DIdentity : CATransform3DMakeScale(1.025, 1.025, 1)
            if !reduceMotion { transform = CATransform3DRotate(transform, -0.012, 0, 0, 1) }
            dragGhost.transform = transform
            dragGhost.isHidden = false; dragGhostVisible = true
            CATransaction.commit()
            if !reduceMotion {
                let lift = CABasicAnimation(keyPath: "transform")
                lift.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.98, 0.98, 1)); lift.toValue = NSValue(caTransform3D: transform)
                lift.duration = 0.14; lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dragGhost.add(lift, forKey: "lift")
            }
        }
        updateGhostColors()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dragGhost.position = CGPoint(x: point.x - ghostGrabOffset.x + dragGhost.bounds.width / 2, y: point.y - ghostGrabOffset.y + dragGhost.bounds.height / 2 - 3)
        CATransaction.commit()
    }
    private func updateGhostColors() {
        guard let id = drag?.blockID, let block = blocks.first(where: { $0.id == id }) else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let conflict: Bool
            if case .invalid = dropTarget { conflict = true } else { conflict = false }
            let count: Int
            if let drag, case .reorder = drag.kind { count = drag.rowIDs.first { $0.contains(id) }?.count ?? 1 } else { count = 1 }
            dragGhostTitle.string = conflict ? "此处时间已被占用" : count > 1 ? "整行 · \(count) 个块" : block.title
            dragGhostTitle.foregroundColor = CaploNSColor.textPrimary.cgColor
            // 浮起块会盖在其他文字之上，使用中性实色底的高透明度混合，避免透出下方标签。
            let ghostBase = CaploNSColor.surfaceOpaqueRaised.blended(withFraction: 0.24, of: color(for: block)) ?? CaploNSColor.surfaceOpaqueRaised
            dragGhost.backgroundColor = ghostBase.withAlphaComponent(EditorMaterialDrawing.usesOpaqueSurface(appearance: effectiveAppearance, opaqueOverride: materialOpaqueOverride) ? 1 : 0.94).cgColor
            dragGhost.borderColor = (conflict ? CaploNSColor.record : accent).cgColor
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); mouseTracking = tracking
        updateTooltips()
    }
    private func updateTooltips() {
        removeAllToolTips(); tooltipLabels.removeAll()
        let shown = presentedRows
        let first = max(0, Int(verticalOffset / rowHeight)), last = min(shown.count, Int((verticalOffset + trackArea.height) / rowHeight) + 1)
        guard first < last else { return }
        for row in first..<last {
            let members = shown[row]
            let head = CGRect(x: 0, y: rowY(row), width: headerWidth, height: rowHeight).intersection(trackArea)
            // 提示只报名字和时间，操作说明交给右键菜单。
            if !head.isNull { tooltipLabels[addToolTip(head, owner: self, userData: nil)] = members.map(\.title).joined(separator: "、") }
            for block in visibleMembers(members) {
                let rect = blockRect(block, row: row).intersection(CGRect(x: timeOrigin, y: trackArea.minY, width: contentWidth, height: trackArea.height))
                if !rect.isNull { tooltipLabels[addToolTip(rect, owner: self, userData: nil)] = block.title + "\n" + TimelineTime.code(block.start) + " → " + TimelineTime.code(block.start + block.duration) }
            }
        }
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        tooltipLabels[tag] ?? ""
    }
    override func mouseMoved(with event: NSEvent) {
        guard drag == nil, scrollDrag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= timeOrigin, point.x < bounds.width - 8, point.y >= 0, point.y < trackArea.maxY, !model.playing {
            hoveredPoint = point; model.skim(min(edit.duration, TimelineTime.quantized(time(point.x))))
        } else { hoveredPoint = nil; model.skim(nil) }
        updateSkimmer()
    }
    override func mouseExited(with event: NSEvent) {
        hoveredPoint = nil; model.skim(nil); updateSkimmer()
    }
    /// 鼠标静止时横滚或缩放，也要以屏幕上的悬停点重新映射预览时间。
    private func refreshHoveredPreview() {
        guard drag == nil, scrollDrag == nil, !model.playing, model.skimPosition != nil, let point = hoveredPoint else { return }
        guard point.x >= timeOrigin, point.x < bounds.width - 8, point.y >= 0, point.y < trackArea.maxY else {
            hoveredPoint = nil; model.skim(nil); return
        }
        model.skim(min(edit.duration, TimelineTime.quantized(time(point.x))))
    }
    private func observeSkimmer() {
        guard !detached else { return }
        withObservationTracking { _ = model.skimPosition; updateSkimmer() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSkimmer() }
        }
    }
    /// 测试钩子：立即刷新悬停时间码，并读出底板与文字层的位置。
    func refreshSkimmerForTesting() { updateSkimmer() }
    func skimmerFramesForTesting() -> (plate: CGRect, text: CGRect)? { skimmerVisible ? (skimmerPlate.frame, skimmerTime.frame) : nil }

    private func updateSkimmer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let position = model.skimPosition
        let visible = position != nil && !model.playing && drag == nil
        let point = position.map { x($0) } ?? -1
        skimmerVisible = visible && point >= timeOrigin && point < bounds.width - 8
        skimmer.isHidden = !skimmerVisible; skimmerHandle.isHidden = !skimmerVisible; skimmerTime.isHidden = !skimmerVisible; skimmerPlate.isHidden = !skimmerVisible
        if let position, skimmerVisible {
            skimmer.backgroundColor = resolvedColor(CaploNSColor.textSecondary.withAlphaComponent(0.7))
            skimmerHandle.fillColor = resolvedColor(CaploNSColor.textSecondary)
            skimmer.frame = CGRect(x: point - 0.5, y: 6, width: 1, height: trackArea.maxY - 6)
            skimmerHandle.position = CGPoint(x: point, y: 0)
            let code = TimelineTime.code(position)
            skimmerTime.string = code
            let plate = CaploNSColor.surfaceOpaqueRaised.withAlphaComponent(EditorMaterialDrawing.usesOpaqueSurface(appearance: effectiveAppearance, opaqueOverride: materialOpaqueOverride) ? 1 : 0.88)
            skimmerPlate.backgroundColor = resolvedColor(plate); skimmerTime.foregroundColor = resolvedColor(CaploNSColor.textPrimary)
            // 底板贴着文字：左右各 6 点留白、高 16；文字层高度取字体行高并在底板里垂直居中，避免 CATextLayer 顶对齐带来的下坠。
            let textWidth = ceil((code as NSString).size(withAttributes: [.font: skimmerFont]).width)
            let lineHeight = ceil(skimmerFont.ascender - skimmerFont.descender)
            let plateWidth = textWidth + 12, plateHeight: CGFloat = 16
            let plateX = min(bounds.width - plateWidth - 8, max(timeOrigin, point + 8))
            skimmerPlate.frame = CGRect(x: plateX, y: 7, width: plateWidth, height: plateHeight)
            skimmerTime.frame = CGRect(x: plateX + 6, y: 7 + (plateHeight - lineHeight) / 2, width: textWidth, height: lineHeight)
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let previous = textDrawingContext
        textDrawingContext = context
        defer { textDrawingContext = previous }
        effectiveAppearance.performAsCurrentDrawingAppearance { drawTimelineContents() }
    }

    private func drawTimelineContents() {
        trackDrawCount += 1; visibleClipDrawCount = 0
        if let context = textDrawingContext {
            EditorMaterialDrawing.drawPanel(in: bounds, appearance: effectiveAppearance, context: context, flipped: isFlipped,
                                            opaqueOverride: materialOpaqueOverride, clearsBacking: false)
        }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: trackArea).addClip()
        let shown = presentedRows
        let first = max(0, Int(verticalOffset / rowHeight)), last = min(shown.count, Int((verticalOffset + trackArea.height) / rowHeight) + 1)
        var accessibleClips: [Any] = []
        visibleFocusDrawCount = 0
        if first < last {
            for number in first..<last {
                let members = shown[number], y = rowY(number), selected = members.contains { isSelected($0) }
                (selected ? accent.withAlphaComponent(0.07) : CaploNSColor.textPrimary.withAlphaComponent(0.025)).setFill()
                CGRect(x: 0, y: y, width: bounds.width, height: rowHeight - 1).fill()
                if let first = members.first(where: { $0.role == .system || $0.role == .microphone }) ?? members.first {
                    drawRoleIcon(first, at: CGRect(x: headerWidth / 2 - 11, y: y + (rowHeight - 22) / 2, width: 22, height: 22), badge: true)
                    if members.count > 1, first.role != .system, first.role != .microphone { label(String(members.count), in: CGRect(x: 47, y: y + 3, width: 16, height: 12), color: CaploNSColor.textTertiary, size: 8) }
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: timeOrigin, y: y, width: contentWidth, height: rowHeight)).addClip()
                // 极端缩放时最小外观可能相交；选中块置顶，并提供右键同行列表保证每个块都可访问。
                let drawing = visibleMembers(members).sorted { !isSelected($0) && isSelected($1) }
                for block in drawing {
                    if isFloating(block.id) {
                        let placeholder = blockRect(block, row: number)
                        color(for: block).withAlphaComponent(0.08).setFill()
                        NSBezierPath(roundedRect: placeholder, xRadius: 6, yRadius: 6).fill()
                        color(for: block).withAlphaComponent(0.35).setStroke()
                        let outline = NSBezierPath(roundedRect: placeholder.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                        outline.setLineDash([4, 4], count: 2, phase: 0); outline.stroke()
                    } else { drawBlock(block, row: number) }
                    if block.role == .screen { visibleClipDrawCount += 1 }
                    if block.role == nil { visibleFocusDrawCount += 1 }
                    let element = TimelineClipAccessibilityElement { [weak self] in self?.select(block) }
                    element.setAccessibilityRole(.button)
                    element.setAccessibilityLabel("\(block.title)，起点 \(TimelineTime.code(block.start))，时长 \(TimelineTime.code(block.duration))")
                    element.setAccessibilityParent(self)
                    let rect = blockRect(block, row: number)
                    element.setAccessibilityFrameInParentSpace(CGRect(x: rect.minX, y: bounds.height - y - rowHeight, width: rect.width, height: rowHeight))
                    accessibleClips.append(element)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        setAccessibilityChildren(accessibleClips + [navigator])
        NSGraphicsContext.restoreGraphicsState()
        CaploNSColor.separator.setFill(); CGRect(x: headerWidth - 1, y: 0, width: 1, height: bounds.height).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: timeOrigin, y: 0, width: contentWidth, height: 28)).addClip()
        drawRuler()
        NSGraphicsContext.restoreGraphicsState()
        if let snappedTime, x(snappedTime) >= timeOrigin, x(snappedTime) < bounds.width - 8 {
            CaploNSColor.warning.withAlphaComponent(0.7).setFill(); CGRect(x: x(snappedTime), y: 0, width: 1, height: trackArea.maxY).fill()
        }
        drawScrollbars()
    }
    private func label(_ text: String, in rect: CGRect, color: NSColor, size: Double = 10, bold: Bool = false) {
        guard let context = textDrawingContext else { return }
        TimelineTextRenderer.draw(text, in: rect, color: color, size: size, bold: bold,
                                  appearance: effectiveAppearance, context: context, flipped: isFlipped)
    }
    private func drawRuler() {
        let steps = [1.0 / 30, 1.0 / 15, 1.0 / 6, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200, 14_400, 86_400]
        let major = steps.first { $0 * scale >= 100 } ?? max(86_400, contentWidth / scale / 5)
        let minor = max(1.0 / 30, major / 5)
        // 刻度只画到时间线尽头；内容比视口短时右侧留空，不再标出不存在的时间。
        let first = floor(offset / minor), last = ceil(min(visibleRange.upperBound, timelineExtent) / minor)
        guard last >= first else { return }
        for step in Int(first)...Int(last) {
            let value = Double(step) * minor
            let isMajor = abs(value / major - (value / major).rounded()) < 0.001
            CaploNSColor.separator.setFill(); CGRect(x: x(value), y: isMajor ? 16 : 21, width: 1, height: isMajor ? 10 : 5).fill()
            if isMajor { label(TimelineTime.code(value), in: CGRect(x: x(value) + 4, y: 1, width: 96, height: 14), color: CaploNSColor.textSecondary, size: 9) }
        }
    }
    private func isSelected(_ block: Block) -> Bool {
        if block.role == nil { return model.selectedFocus == block.id }
        if block.role == .screen { return model.selectedMediaID == nil && model.selectedFocus == nil && (selection.contains(block.id) || primary == block.id) }
        return model.selectedMediaID == block.id
    }
    private func select(_ block: Block) {
        if block.role == .screen { model.selectClip(block.id) }
        else if let role = block.role { model.selectedFocus = nil; model.selectedMedia = role; model.selectedMediaID = block.id }
        else { model.selectedMedia = nil; model.selectedMediaID = nil; model.selectedFocus = block.id }
        needsDisplay = true
    }
    private func drawBlock(_ block: Block, row: Int) {
        let rect = blockRect(block, row: row)
        guard rect.maxX > timeOrigin, rect.minX < bounds.width else { return }
        let color = color(for: block)
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        // 类别色仍是主要识别线索；细亮边只提供玻璃卡片的层次，不影响块的命中范围。
        CaploNSColor.glassEdge.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        edge.lineWidth = CaploMetrics.hairline; edge.stroke()
        if block.role == .system || block.role == .microphone,
           let role = block.role, let clip = edit.mediaClips(role).first(where: { $0.id == block.id }) {
            let samples = role == .system ? analysis.system : analysis.microphone
            if !samples.isEmpty {
                // 波形从块左缘 6 点铺到右缘 6 点；每 2 点一根，取这 2 点覆盖时间段内的峰值（金字塔查询），缩放再粗也不漏掉短促的声音。
                let waveform = NSBezierPath()
                let step = 2.0
                let left = max(timeOrigin, rect.minX + 6), right = min(bounds.width, rect.maxX - 6)
                for pixel in stride(from: left, to: max(left, right), by: step) {
                    let begin = time(pixel) - block.start, finish = time(pixel + step) - block.start
                    guard finish > 0, begin < clip.playableDuration else { continue }
                    let start = clip.sourceStart + max(0, begin), end = clip.sourceStart + min(clip.playableDuration, finish)
                    let peak = role == .system ? analysis.systemPeak(from: start, to: end) : analysis.microphonePeak(from: start, to: end)
                    let height = max(1, Double(peak) * rect.height * 0.75)
                    waveform.appendRect(CGRect(x: pixel, y: rect.midY - height / 2, width: 1.25, height: height))
                }
                color.withAlphaComponent(0.55).setFill(); waveform.fill()
            }
        }
        if rect.width < 72 { drawRoleIcon(block, at: CGRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14)) }
        else {
            // 标题固定在整块的正中，横向滚动时随块一起移动、不跟随可见部分；块比文字窄才靠左截断。
            let width = ceil((block.title as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)]).width)
            let available = max(0, rect.width - 18)
            let x = width <= available ? rect.midX - width / 2 : rect.minX + 9
            label(block.title, in: CGRect(x: x, y: rect.minY + 8, width: min(width, available), height: 14), color: CaploNSColor.textPrimary, size: 10, bold: true)
        }
        if block.duration * scale < TimelineInteractionGeometry.minimumBlockWidth {
            color.withAlphaComponent(0.6).setFill()
            CGRect(x: rect.minX + 2, y: rect.maxY - 3, width: max(1, block.duration * scale - 4), height: 1).fill()
        }
        if isSelected(block) {
            // 选中描边画在块内部：外扩的描边在块贴着轨道左缘时会被裁掉一截。
            accent.setStroke(); let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5); border.lineWidth = 1.5; border.stroke()
            accent.setFill()
            for point in [rect.minX + 3, rect.maxX - 5] { CGRect(x: point, y: rect.minY + 7, width: 2, height: rect.height - 14).fill() }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard model.ready else { return }
        let point = convert(event.locationInWindow, from: nil)
        model.skim(nil); hoveredPoint = nil; updateSkimmer()
        if beginScrollbarInteraction(at: point) { return }
        snappedTime = nil
        if point.y < 28, point.x >= timeOrigin {
            drag = Drag(kind: .scrub, origin: point, snapshot: edit, timeline: index, scale: scale, offset: offset, rowIDs: rows.map { $0.map(\.id) }, snapEdges: [])
            seek(time(point.x), modifiers: event.modifierFlags); return
        }
        guard trackArea.contains(point) else { return }
        let number = Int((point.y - 28 + verticalOffset) / rowHeight)
        guard rows.indices.contains(number), let first = rows[number].first else { return }
        if point.x >= headerWidth, point.x < timeOrigin { return }
        let hit = hitBlock(at: point, row: number)
        let block = hit?.0 ?? first
        if block.role == .screen, event.modifierFlags.contains(.command) { model.selectClip(block.id, extending: true) }
        else { select(block) }
        retainedExtent = timelineExtent
        if point.x < headerWidth {
            drag = Drag(kind: .reorder(block.id), origin: point, snapshot: edit, timeline: index, scale: scale, offset: offset, rowIDs: rows.map { $0.map(\.id) }, snapEdges: [])
        } else if let edge = hit?.1 {
            drag = Drag(kind: .block(block, edge), origin: point, snapshot: edit, timeline: index, scale: scale, offset: offset, rowIDs: rows.map { $0.map(\.id) }, snapEdges: snapTargets(for: block, edge: edge))
        } else { retainedExtent = 0; model.seek(time(point.x)) }
    }
    private func hitBlock(at point: CGPoint, row: Int) -> (Block, VideoEdit.FocusDragEdge)? {
        guard rows.indices.contains(row) else { return nil }
        let hits = visibleMembers(rows[row]).compactMap { block -> (Block, VideoEdit.FocusDragEdge)? in
            TimelineInteractionGeometry.hitEdge(at: point, rect: blockRect(block, row: row)).map { (block, $0) }
        }
        let value = time(point.x)
        return hits.first { value >= $0.0.start && value < $0.0.start + $0.0.duration }
            ?? hits.first { isSelected($0.0) }
            ?? hits.min { abs($0.0.start - value) < abs($1.0.start - value) }
    }
    /// 每个块有自己的右键菜单：先选中它，再列出这个块的操作；"同行块"作为子菜单方便在重叠的块之间切换。
    /// 行内空白处右键只列同行块。
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let number = Int((point.y - 28 + verticalOffset) / rowHeight)
        guard trackArea.contains(point), rows.indices.contains(number) else { return nil }
        let siblings = rows[number].sorted { $0.start < $1.start }
        let menu = NSMenu()
        if let (block, _) = hitBlock(at: point, row: number) {
            if !isSelected(block) { select(block) }
            let header = NSMenuItem(title: block.title + " · " + TimelineTime.code(block.start), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header); menu.addItem(.separator())
            // 分割：右键落点处，以及播放头处（播放头在这块里时）；两侧留不下最小时长就禁用。
            let clicked = TimelineTime.quantized(time(point.x))
            let here = NSMenuItem(title: "在此处分割 · " + TimelineTime.code(clicked), action: #selector(splitBlockHere(_:)), keyEquivalent: "")
            here.target = self; here.representedObject = clicked; here.isEnabled = model.canSplit(at: clicked)
            menu.addItem(here)
            let atPlayhead = NSMenuItem(title: "在播放头分割", action: #selector(splitBlockAtPlayhead(_:)), keyEquivalent: "b")
            atPlayhead.target = self; atPlayhead.isEnabled = model.canSplit
            menu.addItem(atPlayhead)
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "重命名…", action: #selector(renameBlock(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = block.id
            menu.addItem(rename)
            if block.role == .screen {
                let duplicate = NSMenuItem(title: "复制片段", action: #selector(duplicateBlock(_:)), keyEquivalent: "d")
                duplicate.target = self; menu.addItem(duplicate)
            }
            if let role = block.role, role == .system || role == .microphone {
                let track: AudioTrack = role == .system ? .system : .microphone
                for solo in [false, true] {
                    let item = NSMenuItem(title: solo ? "仅播放此轨" : "静音", action: #selector(toggleRowAudio(_:)), keyEquivalent: "")
                    item.target = self; item.identifier = NSUserInterfaceItemIdentifier(track.rawValue + (solo ? ".solo" : ".mute"))
                    item.state = (solo ? edit.audio.solo : edit.audio.muted).contains(track) ? .on : .off
                    item.isEnabled = model.audioTracks.contains(track)
                    menu.addItem(item)
                }
            }
            let delete = NSMenuItem(title: "删除", action: #selector(deleteBlock(_:)), keyEquivalent: "\u{8}")
            delete.keyEquivalentModifierMask = []; delete.target = self; menu.addItem(delete)
            if siblings.count > 1 {
                menu.addItem(.separator())
                let group = NSMenuItem(title: "同行块", action: nil, keyEquivalent: "")
                group.submenu = rowMembersMenu(siblings)
                menu.addItem(group)
            }
            return menu
        }
        guard siblings.count > 1 else { return nil }
        return rowMembersMenu(siblings)
    }
    private func rowMembersMenu(_ members: [Block]) -> NSMenu {
        let menu = NSMenu(title: "同行块")
        for block in members {
            let item = NSMenuItem(title: block.title + " · " + TimelineTime.code(block.start), action: #selector(selectRowMember(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = block.id; item.state = isSelected(block) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    @objc private func splitBlockHere(_ sender: NSMenuItem) { if let time = sender.representedObject as? Double { model.split(at: time) } }
    /// 在块下方弹出改名框；确定或回车写入模型，留空恢复默认名称。
    @objc private func renameBlock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let block = blocks.first(where: { $0.id == id }), let row = rowByBlock[id] else { return }
        renamePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let content = BlockRenameView(title: block.title == block.defaultTitle ? "" : block.title, defaultTitle: block.defaultTitle,
                                      commit: { [weak self, weak popover] value in self?.renameBlock(id, to: value); popover?.close() },
                                      cancel: { [weak popover] in popover?.close() })
        popover.contentViewController = NSHostingController(rootView: content)
        let rect = blockRect(block, row: row).intersection(bounds)
        popover.show(relativeTo: rect.isNull ? CGRect(x: timeOrigin, y: rowY(row), width: 1, height: rowHeight) : rect, of: self, preferredEdge: .maxY)
        renamePopover = popover
    }
    /// 改名写入模型；空白恢复默认名称。菜单与测试共用。
    func renameBlock(_ id: UUID, to title: String) { model.renameBlock(id, to: title) }
    @objc private func splitBlockAtPlayhead(_ sender: Any?) { model.split() }
    @objc private func deleteBlock(_ sender: Any?) { model.deleteSelection() }
    @objc private func duplicateBlock(_ sender: Any?) { model.duplicateSelection() }
    @objc private func toggleRowAudio(_ sender: NSMenuItem) {
        guard let name = sender.identifier?.rawValue else { return }
        let track: AudioTrack = name.hasPrefix("system.") ? .system : .microphone
        if name.hasSuffix(".solo") { model.toggleSolo(track) } else { model.toggleMute(track) }
    }
    @objc private func selectRowMember(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let block = blocks.first(where: { $0.id == id }) else { return }
        select(block)
    }
    private func snapTargets(for block: Block, edge: VideoEdit.FocusDragEdge) -> [Double] {
        var moving = Set([block.id])
        // 关联聚焦随录制块一起移动，不能反过来成为自己的吸附目标。
        if block.role == .screen, edge == .body {
            moving.formUnion(edit.focuses.filter { $0.targetClipID == block.id }.map(\.id))
        }
        return blocks.filter { !moving.contains($0.id) }.flatMap { [$0.start, $0.start + $0.duration] } + [0, model.position]
    }
    private func seek(_ value: Double, modifiers: NSEvent.ModifierFlags) {
        let snap = viewport.snapping && !modifiers.contains(.option) ? index.snap(value, tolerance: 8 / scale) : nil
        snappedTime = snap
        model.seek(min(edit.duration, snap ?? TimelineTime.quantized(value)))
        playbackPosition = model.position; updatePlayhead(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if scrollDrag != nil { dragScrollbar(to: point); return }
        dragLocation = point; dragModifiers = event.modifierFlags
        updateDrag(at: point, modifiers: event.modifierFlags); startAutoScroll()
    }
    private func updateDrag(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var drag else { return }
        let resisted: Bool
        switch drag.kind { case .reorder, .block(_, .body): resisted = true; default: resisted = false }
        let displacement = resisted ? TimelineDragIntent.displacement(from: drag.origin, to: point) : CGPoint(x: point.x - drag.origin.x, y: point.y - drag.origin.y)
        if point.x >= timeOrigin { drag.horizontalDelta = displacement.x / drag.scale + offset - drag.offset }
        let delta = drag.horizontalDelta
        if resisted ? TimelineDragIntent.shouldBegin(from: drag.origin, to: point) : hypot(displacement.x, displacement.y) > 3 { drag.moved = true }
        self.drag = drag
        switch drag.kind {
        case .scrub: seek(time(point.x), modifiers: modifiers)
        case .reorder:
            guard drag.moved else { return }
            updateDropTarget(at: point, proposed: drag.snapshot)
            updateDragGhost(at: CGPoint(x: drag.origin.x + displacement.x, y: drag.origin.y + displacement.y)); needsDisplay = true
        case .block(let block, let edge):
            guard drag.moved else { return }
            model.beginInteraction()
            var next = drag.snapshot
            let anchor = edge == .trailing ? block.start + block.duration : block.start
            let desired = anchor + delta
            var snap: Double?
            if viewport.snapping && !modifiers.contains(.option) {
                let nearby = drag.snapEdges.filter { abs($0 - desired) < 8.0 / drag.scale }
                snap = nearby.min { abs($0 - desired) < abs($1 - desired) }
            }
            snappedTime = snap
            var adjustment = (snap ?? TimelineTime.quantized(desired)) - anchor
            adjustment = drag.snapshot.rowDragDelta(for: block.id, edge: edge, proposed: adjustment, leavingRow: edge == .body && !remainsInOriginalRow(drag, at: point))
            if let role = block.role { next.dragMedia(role, id: block.id, edge: edge, delta: adjustment, sourceDuration: model.entry.document.duration) }
            else if let span = block.span { next.materializeFocus(span); next.dragFocus(id: block.id, edge: edge, delta: adjustment) }
            next.constrainTimelineFocuses()
            if edge == .body {
                updateDropTarget(at: point, proposed: next)
                updateDragGhost(at: CGPoint(x: drag.origin.x + displacement.x, y: drag.origin.y + displacement.y))
            } else { dropTarget = nil }
            if model.edit != next { model.edit = next; model.previewChanged() }
            needsDisplay = true
        }
    }
    private func remainsInOriginalRow(_ drag: Drag, at point: CGPoint) -> Bool {
        guard let id = drag.blockID else { return false }
        let position = (point.y - 28 + verticalOffset) / rowHeight
        let number = Int(floor(position)), fraction = position - floor(position)
        guard drag.rowIDs.indices.contains(number), drag.rowIDs[number].contains(id) else { return false }
        // 水平拖动即使从块上缘抓起也不自动拆行；明确竖向拖向行间才脱离。
        return abs(point.y - drag.origin.y) <= 8 || (fraction >= 0.22 && fraction <= 0.78)
    }
    private func updateDropTarget(at point: CGPoint, proposed: VideoEdit) {
        guard let drag, let id = drag.blockID else { return }
        let rowPosition = (point.y - 28 + verticalOffset) / rowHeight
        let number = Int(floor(rowPosition)), fraction = rowPosition - floor(rowPosition)
        let reorder: Bool
        if case .reorder = drag.kind { reorder = true } else { reorder = false }
        if !reorder, remainsInOriginalRow(drag, at: point) { dropTarget = nil; return }
        if !reorder, drag.rowIDs.indices.contains(number), fraction >= 0.22, fraction <= 0.78 {
            let row = drag.rowIDs[number]
            if row.contains(id) { dropTarget = nil }
            else if let target = row.first {
                dropTarget = proposed.canPlaceBlock(id, inRowContaining: target) ? .row(target) : .invalid(target)
            }
        } else {
            let moving = reorder ? Set(drag.rowIDs.first { $0.contains(id) } ?? [id]) : Set([id])
            let boundary = min(drag.rowIDs.count, max(0, number + (fraction >= 0.5 ? 1 : 0)))
            let target = drag.rowIDs.dropFirst(boundary).flatMap { $0 }.first { !moving.contains($0) }
            dropTarget = .before(target)
        }
    }
    private func startAutoScroll() {
        guard autoScrollTask == nil, drag != nil else { return }
        autoScrollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard let self, !detached, drag != nil else { return }
                advanceAutoScroll()
            }
        }
    }
    /// 用固定时间步推进，鼠标停在边缘也可滚动；位移加入拖动起点映射，不让素材在滚动后跳变。
    func advanceAutoScroll() {
        guard let point = dragLocation, let drag else { return }
        let oldX = offset, oldY = verticalOffset
        let reordering: Bool
        switch drag.kind { case .reorder: reordering = true; default: reordering = false }
        if point.y < 50 { verticalOffset -= 12 }
        else if point.y > trackArea.maxY - 24 { verticalOffset += 12 }
        if !reordering, point.x >= timeOrigin {
            let left = timeOrigin + 24, right = timeOrigin + contentWidth - 24
            if point.x < left { offset -= min(1, (left - point.x) / 24) * 15 / scale }
            else if point.x > right { offset += min(1, (point.x - right) / 24) * 15 / scale }
        }
        clampOffset()
        guard oldX != offset || oldY != verticalOffset else { return }
        changedViewport(); updateDrag(at: point, modifiers: dragModifiers)
    }
    private func clearDrag() {
        autoScrollTask?.cancel(); autoScrollTask = nil
        drag = nil; dragLocation = nil; dropTarget = nil; snappedTime = nil
        dragGhost.removeAllAnimations(); dragGhost.isHidden = true; dragGhostVisible = false
        // 松手也保留当前可见起点，避免轨道刚完成裁剪便整片跳动。
        retainedExtent = max(0, offset + contentWidth / scale)
        changedViewport()
    }
    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: 28, width: headerWidth, height: max(0, trackArea.height)), cursor: .openHand)
        let first = max(0, Int(verticalOffset / rowHeight)), last = min(rows.count, Int((verticalOffset + trackArea.height) / rowHeight) + 1)
        if first < last {
            for row in first..<last {
                for block in visibleMembers(rows[row]) {
                    let rect = blockRect(block, row: row)
                    for x in [rect.minX - 4, rect.maxX - 8] {
                        let handle = CGRect(x: x, y: rect.minY - 3, width: 12, height: rect.height + 6).intersection(CGRect(x: timeOrigin, y: 28, width: contentWidth, height: trackArea.height))
                        if !handle.isNull { addCursorRect(handle, cursor: .resizeLeftRight) }
                    }
                }
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        if scrollDrag != nil { scrollDrag = nil; needsDisplay = true; return }
        guard let initial = drag else { return }
        if initial.moved { updateDrag(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags) }
        if case .invalid = dropTarget { model.cancelInteraction(); clearDrag(); return }
        if let drag, drag.moved, let id = drag.blockID, let dropTarget {
            model.beginInteraction()
            switch dropTarget {
            case .row(let target): _ = model.edit.placeBlock(id, inRowContaining: target)
            case .before(let target):
                if case .reorder = drag.kind { model.edit.moveTimelineRow(containing: id, before: target) }
                else { model.edit.placeBlock(id, beforeRowContaining: target) }
            case .invalid: break
            }
        }
        model.endInteraction(); clearDrag()
    }
    override func keyDown(with event: NSEvent) {
        if let resize = resizingTrack {
            if event.keyCode == 53 { trackHeights[resize.index] = resize.height; viewport.trackHeights = trackHeights; changedViewport() }
            resizingTrack = nil
        }
        if drag != nil, event.keyCode != 53 { model.cancelInteraction(); clearDrag() }
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": model.selectedClipIDs = Set(edit.clips.map(\.id)); model.selectedClip = edit.clips.first?.id; model.selectedFocus = nil
            case "d": model.duplicateSelection()
            case "b": model.split()
            case "z": if shift { model.redo() } else { model.undo() }
            default: super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 49: model.togglePlayback()
        case 123: model.seek(TimelineTime.quantized(model.position) - (shift ? 10 : 1) / 30.0)
        case 124: model.seek(TimelineTime.quantized(model.position) + (shift ? 10 : 1) / 30.0)
        case 115: model.seek(0)
        case 119: model.seek(edit.duration)
        case 51, 117: model.deleteSelection()
        case 53: model.cancelInteraction(); clearDrag()
        default: super.keyDown(with: event)
        }
    }
}

/// 轨道为自绘视图，显式提供片段操作给辅助功能，保留与鼠标选择相同的模型入口。
@MainActor
private final class TimelineClipAccessibilityElement: NSAccessibilityElement {
    nonisolated let press: @MainActor @Sendable () -> Void
    init(press: @escaping @MainActor @Sendable () -> Void) { self.press = press; super.init() }
    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        Task { @MainActor in action() }
        return true
    }
}
