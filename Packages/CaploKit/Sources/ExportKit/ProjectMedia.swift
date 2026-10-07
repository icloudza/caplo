import AVFoundation
import ProjectKit
import ImageIO

@_exported import EditingCore
import RenderKit
import CoreImage

/// 回放与导出共用独立图层解析结果；遮挡、空白和末帧保持遵循编辑时间。
@MainActor
public enum ProjectMedia {
    public static func compose(url: URL, document: ProjectDocument, levels: AudioLevels, edit: VideoEdit? = nil) async throws -> (AVMutableComposition, AVMutableAudioMix) {
        if let edit { try edit.validate(sourceDuration: document.duration) }
        guard !document.segments.isEmpty else { throw ProjectError.invalid(String(localized: "工程没有可播放的片段。")) }
        let composition = AVMutableComposition()
        // 声音：每个角色按"泳道"建轨——互不重叠的块共用一条轨，只有时间上重叠的块才另开一条（见 audioLanes）。
        // 以前独立编辑模式下每块一条轨，分割几百次就是几百条音轨，播放与导出的混音开销随之暴涨。
        var audioGroups: [MediaRole: [(Int, AVMutableCompositionTrack)]] = [:]
        // 分段编码可能产生不同的 H.264 参数集；按完整格式复用解码轨道，避免切换时解码失败。
        var videoGroups: [MediaRole: [(formats: [CMFormatDescription], track: AVMutableCompositionTrack)]] = [:]
        // 同一素材可能被剪成数百个片段；轨道与时间范围只加载一次，后续插入共享元数据。
        var sources: [String: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, formats: [CMFormatDescription])] = [:]
        let segments = document.segments.sorted(by: { $0.id < $1.id })
        let snapshot = edit ?? VideoEdit(duration: document.duration)
        let roleMap: [(MediaRole, TimelineMedia)] = [(.screen, .screen), (.camera, .camera), (.systemAudio, .system), (.microphone, .microphone)]
        for (role, logical) in roleMap {
          let separateAudio = !role.isVideo && (role == .systemAudio ? snapshot.systemClips != nil : snapshot.microphoneClips != nil)
          let media = separateAudio ? snapshot.mediaClips(logical) : snapshot.resolvedMedia(logical)
          let lanes = role.isVideo ? [:] : audioLanes(media)
          for original in media {
            // 卡片不引用素材：这段画面轨留空，合成器按卡片画背景与文字。
            if original.card != nil { continue }
            // 普通区间保持原速；超出源结尾的视频使用末帧的单帧区间扩展，音频不补内容。
            var jobs: [(VideoClip, Double?)] = []
            let playable = original.playableDuration
            if playable > 0.0001 { var live = original; live.duration = playable; jobs.append((live, nil)) }
            if role.isVideo, original.duration - playable > 0.0001 {
                var hold = original
                let frame = 1 / max(24, document.frameRate)
                hold.sourceStart = max(0, original.sourceStart + playable - frame)
                hold.timelineStart = (original.timelineStart ?? 0) + playable
                hold.duration = frame
                jobs.append((hold, original.duration - playable))
            }
          for (clip, heldDuration) in jobs {
            let cursor = clip.timelineStart ?? 0
            var segmentStart = 0.0
            for segment in segments {
                defer { segmentStart += segment.duration }
                let lower = max(clip.sourceStart, segmentStart)
                let upper = min(clip.sourceStart + clip.duration, segmentStart + segment.duration)
                guard upper > lower else { continue }
                let requested = CMTimeRange(start: CMTime(seconds: lower - segmentStart, preferredTimescale: 48_000), duration: CMTime(seconds: upper - lower, preferredTimescale: 48_000))
                do {
                    try Task.checkCancellation()
                    // 缺失的素材文件当空白跳过（工程照常打开与导出，编辑器会提示缺了哪些），见 ProjectStorage.load。
                    guard let path = mediaPath(for: role, in: segment, levels: levels, project: url), ProjectStorage.mediaExists(path, in: url) else { continue }
                    let offset = CMTime(seconds: segment.offset(for: role), preferredTimescale: 48_000)
                    let localRequest = CMTimeRange(start: requested.start - offset, duration: requested.duration)
                    let mediaType: AVMediaType = role.isVideo ? .video : .audio
                    let key = role.rawValue + ":" + path
                    let source: AVAssetTrack, sourceRange: CMTimeRange, formats: [CMFormatDescription]
                    if let cached = sources[key] {
                        source = cached.track; sourceRange = cached.range; formats = cached.formats
                    } else {
                        let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
                        guard let loaded = try await asset.loadTracks(withMediaType: mediaType).first else {
                            throw ProjectError.invalid(String(localized: "素材缺少预期轨道：\(path)"))
                        }
                        source = loaded; sourceRange = try await loaded.load(.timeRange)
                        formats = role.isVideo ? try await loaded.load(.formatDescriptions) : []
                        // 轨道对象不能替代素材生命周期；拼接完成前同时持有其所属 AVAsset。
                        sources[key] = (asset, source, sourceRange, formats)
                    }
                    let range = CMTimeRangeGetIntersection(sourceRange, otherRange: localRequest)
                    if range.duration > .zero {
                        let destination: AVMutableCompositionTrack
                        if role.isVideo {
                            let groups = videoGroups[role] ?? []
                            if let matching = groups.first(where: { group in
                                group.formats.count == formats.count && zip(group.formats, formats).allSatisfy {
                                    CMFormatDescriptionEqual($0.0, otherFormatDescription: $0.1)
                                }
                            }) {
                                destination = matching.track
                            } else {
                                // 首条屏幕 / 摄像头仍为 1 / 4；额外屏幕使用奇数 5 起，摄像头使用偶数 6 起。
                                let identifier = groups.isEmpty ? trackID(for: role) : CMPersistentTrackID((role == .screen ? 3 : 4) + groups.count * 2)
                                guard let created = composition.addMutableTrack(withMediaType: .video, preferredTrackID: identifier) else {
                                    throw ProjectError.invalid(String(localized: "无法创建视频解码轨道。"))
                                }
                                videoGroups[role, default: []].append((formats, created))
                                destination = created
                            }
                        } else {
                            let lane = lanes[original.id] ?? 0
                            if let matching = audioGroups[role]?.first(where: { $0.0 == lane }) { destination = matching.1 }
                            else {
                                guard let created = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: audioTrackID(role: role, lane: lane)) else { throw ProjectError.invalid(String(localized: "无法创建声音轨道。")) }
                                audioGroups[role, default: []].append((lane, created)); destination = created
                            }
                        }
                        // 所有素材使用同一裁剪交集；晚到的声音和摄像头保留各自偏移。
                        let position = CMTime(seconds: cursor + lower - clip.sourceStart, preferredTimescale: 48_000) + range.start - localRequest.start
                        try destination.insertTimeRange(range, of: source, at: position)
                        if let heldDuration {
                            destination.scaleTimeRange(CMTimeRange(start: position, duration: range.duration), toDuration: CMTime(seconds: heldDuration, preferredTimescale: 48_000))
                        } else if role.isVideo, CMTimeCompare(localRequest.end, range.end) > 0 {
                            // 素材比工程记的时长短一点（写入器按停止时刻记时长，最后一帧的显示时长够不到末尾）：
                            // 把最后一帧拉长补到片段末尾，最多补 1 秒；再长就是素材真的提前结束，那段不画。
                            let shortfall = CMTimeMinimum(CMTimeSubtract(localRequest.end, range.end), CMTime(seconds: 1, preferredTimescale: 48_000))
                            let hold = CMTimeMinimum(range.duration, CMTime(seconds: 1 / max(24, document.frameRate), preferredTimescale: 48_000))
                            if shortfall > .zero, hold > .zero {
                                destination.scaleTimeRange(CMTimeRange(start: position + range.duration - hold, duration: hold), toDuration: hold + shortfall)
                            }
                        }
                    }
                }
            }
          }
          }
        }
        // AVFoundation 不支持完全空的视频轨道导出；用原素材单帧提供时钟，合成器按逻辑空白只画背景。
        if composition.track(withTrackID: 1) == nil, snapshot.duration > 0,
           let path = segments.compactMap({ $0.files[.screen] }).first(where: { ProjectStorage.mediaExists($0, in: url) }) {
            let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: url))
            if let source = try await asset.loadTracks(withMediaType: .video).first,
               let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1) {
                let sourceRange = try await source.load(.timeRange)
                let frame = CMTimeRange(start: sourceRange.start, duration: min(sourceRange.duration, CMTime(seconds: 1 / max(24, document.frameRate), preferredTimescale: 48_000)))
                try track.insertTimeRange(frame, of: source, at: .zero)
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: frame.duration), toDuration: CMTime(seconds: snapshot.duration, preferredTimescale: 48_000))
            }
        }
        if composition.duration.seconds < snapshot.duration {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: CMTime(seconds: snapshot.duration - composition.duration.seconds, preferredTimescale: 48_000)))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [MediaRole.systemAudio, .microphone].flatMap { role in
            (audioGroups[role] ?? []).map { lane, track in
                volumeParameters(track: track, role: role, lane: lane, edit: snapshot, levels: levels)
            }
        }
        return (composition, mix)
    }

    /// 声音块的泳道：按起点排好，放进第一条已经空出来的泳道，都占着才开新泳道。
    /// 结果只由块的时间决定，合成与 `updatePresentation` 各算一遍也一定一致。
    nonisolated static func audioLanes(_ clips: [VideoClip]) -> [UUID: Int] {
        var ends: [Double] = [], result: [UUID: Int] = [:]
        let ordered = clips.enumerated().sorted { ($0.element.timelineStart ?? 0, $0.offset) < ($1.element.timelineStart ?? 0, $1.offset) }
        for (_, clip) in ordered {
            let start = clip.timelineStart ?? 0
            if let lane = ends.firstIndex(where: { $0 <= start + 0.0001 }) { ends[lane] = start + clip.duration; result[clip.id] = lane }
            else { ends.append(start + clip.duration); result[clip.id] = ends.count - 1 }
        }
        return result
    }

    /// 泳道的轨道号：第 0 道沿用角色的固定轨号（系统 2、麦克风 3），其余从 100 002 起，系统偶数、麦克风奇数。
    nonisolated static func audioTrackID(role: MediaRole, lane: Int) -> CMPersistentTrackID {
        lane == 0 ? trackID(for: role) : CMPersistentTrackID(100_000 + lane * 2 + (role == .systemAudio ? 0 : 1))
    }

    /// 轨道号反推泳道（`audioTrackID` 的逆运算）。
    nonisolated static func audioLane(trackID: CMPersistentTrackID) -> Int { trackID < 100_002 ? 0 : Int((trackID - 100_000) / 2) }

    /// 一条泳道的音量：泳道里每一块在自己的起点切到自己的增益（块与块之间是空的，切换点不会出声）。
    nonisolated static func volumeParameters(track: AVAssetTrack, role: MediaRole, lane: Int, edit: VideoEdit, levels: AudioLevels) -> AVMutableAudioMixInputParameters {
        let parameter = AVMutableAudioMixInputParameters(track: track)
        let audioTrack: AudioTrack = role == .systemAudio ? .system : .microphone
        let logical: TimelineMedia = role == .systemAudio ? .system : .microphone
        let independent = role == .systemAudio ? edit.systemClips != nil : edit.microphoneClips != nil
        let values = independent ? edit.mediaClips(logical) : edit.resolvedMedia(logical)
        let lanes = audioLanes(values)
        for clip in values.filter({ (lanes[$0.id] ?? 0) == lane }).sorted(by: { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }) {
            parameter.setVolume(levels.effectiveGain(for: audioTrack) * clip.gain(for: audioTrack), at: CMTime(seconds: clip.timelineStart ?? 0, preferredTimescale: 48_000))
        }
        return parameter
    }

    /// `pointers` 允许调用方复用已解析的指针事件（编辑会话内事件不变），避免每次重建播放项都在主线程解一遍 JSON。
    /// 麦克风在语音处理打开且该片段的产物已生成时换用产物；其余素材按录制文件。
    nonisolated static func mediaPath(for role: MediaRole, in segment: SegmentRecord, levels: AudioLevels, project: URL) -> String? {
        guard role == .microphone, levels.voiceProcessing, let processed = VoiceProcessor.processedPath(for: segment),
              let url = try? ProjectStorage.mediaURL(processed, in: project), FileManager.default.fileExists(atPath: url.path) else { return segment.files[role] }
        return processed
    }

    public static func playerItem(url: URL, document: ProjectDocument, levels: AudioLevels, edit: VideoEdit? = nil, pointers: PointerTimeline? = nil) async throws -> AVPlayerItem {
        let (composition, mix) = try await compose(url: url, document: document, levels: levels, edit: edit)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        if let edit { item.videoComposition = try videoComposition(composition: composition, edit: edit, shortEdge: 1080, pointers: pointers ?? loadPointers(url: url, document: document), backgroundImage: backgroundImage(for: edit.layout, in: url), frameRate: document.frameRate) }
        return item
    }

    nonisolated private static func trackID(for role: MediaRole) -> CMPersistentTrackID {
        switch role { case .screen: 1; case .systemAudio: 2; case .microphone: 3; case .camera: 4 }
    }

    /// 画布、镜头和音量不改变素材拼接，直接更新同一个播放项，保留解码与缓冲状态。
    public static func updatePresentation(item: AVPlayerItem, previous: VideoEdit, edit: VideoEdit, url: URL? = nil) throws {
        guard previous.hasSameMedia(as: edit), let composition = item.asset as? AVMutableComposition else {
            throw ProjectError.invalid(String(localized: "片段已变化，需要重新构建播放时间线。"))
        }
        if edit.differsVisually(from: previous) {
            let existing = item.videoComposition?.instructions.first as? SceneInstruction
            let background = previous.layout.backgroundImage == edit.layout.backgroundImage ? existing?.backgroundImage : url.flatMap { backgroundImage(for: edit.layout, in: $0) }
            let rate = item.videoComposition.map { 1 / $0.frameDuration.seconds } ?? 30
            item.videoComposition = try videoComposition(composition: composition, edit: edit, shortEdge: 1080, pointers: existing?.pointers ?? PointerTimeline(events: []), backgroundImage: background, frameRate: rate.isFinite && rate > 0 ? rate : 30, reusing: existing)
        }
        if previous.audio != edit.audio || previous.gainSignature != edit.gainSignature {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [MediaRole.systemAudio, .microphone].flatMap { role -> [AVMutableAudioMixInputParameters] in
                let tracks = composition.tracks.filter { $0.mediaType == .audio && ($0.trackID == trackID(for: role) || ($0.trackID >= 100_002 && $0.trackID % 2 == (role == .systemAudio ? 0 : 1))) }.sorted { $0.trackID < $1.trackID }
                return tracks.map { track in
                    volumeParameters(track: track, role: role, lane: audioLane(trackID: track.trackID), edit: edit, levels: edit.audio)
                }
            }
            item.audioMix = mix
        }
    }

    /// 项目列表的封面：成片里第一块录制画面的第一帧，盖上那一刻生效的**全部**遮罩。
    /// 以前只按源素材第 0 秒取遮罩：钉在成片时间上的遮罩不参与，剪掉开头之后封面还是被剪掉的那一帧。
    /// 读不出编辑数据就抛错而不是给一张没打码的图——封面上印着密钥比没有封面糟糕得多。
    public static func thumbnail(url: URL, document: ProjectDocument) async throws -> CGImage {
        let plan = try await Task.detached(priority: .utility) { () throws -> (path: String, local: Double, masks: [MaskState]) in
            let file = url.appendingPathComponent("edits.json")
            var edit: VideoEdit?
            var masks: [MaskState] = []
            if FileManager.default.fileExists(atPath: file.path) {
                if let decoded = try? JSONDecoder().decode(VideoEdit.self, from: Data(contentsOf: file)) { edit = decoded }
                else {
                    // 解不成完整编辑数据（只有音量的旧格式）：退回只读遮罩、按源时间求值。
                    var legacy = VideoEdit(duration: max(0.001, document.duration)); legacy.maskList = try EditStorage.maskList(in: url)
                    masks = legacy.sourceMasks(atSource: 0)
                }
            }
            let clip = edit?.orderedScreenClips.filter { $0.card == nil }.min { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
            let source = clip?.sourceStart ?? 0
            if let edit { masks = edit.activeMasks(at: (clip?.timelineStart ?? 0) + 0.0001) }
            var cursor = 0.0
            for segment in document.segments.sorted(by: { $0.id < $1.id }) {
                defer { cursor += segment.duration }
                guard source < cursor + segment.duration || segment.id == document.segments.map(\.id).max() else { continue }
                guard let path = segment.files[.screen], ProjectStorage.mediaExists(path, in: url) else { break }
                return (path, max(0, min(source - cursor, segment.duration - 0.001)), masks)
            }
            throw ProjectError.invalid(String(localized: "暂无缩略图。"))
        }.value
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try ProjectStorage.mediaURL(plan.path, in: url)))
        generator.maximumSize = CGSize(width: 640, height: 400)
        generator.appliesPreferredTrackTransform = true
        // 取精确的那一帧：遮罩按这一刻求值，容差放开可能取到遮罩还没盖上的相邻帧。
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: plan.local, preferredTimescale: 600)).image
        guard !plan.masks.isEmpty else { return frame }
        let image = CIImage(cgImage: frame)
        guard let masked = CIContext().createCGImage(MaskRenderer.apply(plan.masks, to: image), from: image.extent) else {
            throw ProjectError.invalid(String(localized: "无法生成已打码的缩略图。"))
        }
        return masked
    }

    /// 暂停和拖动时输出清晰静帧，使用同一个场景渲染器；不依赖原生视频图层的离屏可见性。
    public static func poster(url: URL, document: ProjectDocument, edit: VideoEdit, time: Double) async throws -> CGImage {
        let renderer = EditorPreviewRenderer()
        do {
            let image = try await renderer.render(url: url, document: document, edit: edit, time: time)
            await renderer.close()
            return image
        } catch {
            await renderer.close()
            throw error
        }
    }

    nonisolated static func pointerTimeline(url: URL, document: ProjectDocument) throws -> PointerTimeline {
        let events = try EditStorage.events(in: url, document: document)
        return PointerTimeline(events: events, cursorEmbedded: document.capture?.cursorEmbedded != false,
                               capturedCursors: CursorStorage.load(ids: Set(events.compactMap(\.cursorAssetID)), in: url))
    }

    nonisolated public static func loadPointers(url: URL, document: ProjectDocument) throws -> PointerTimeline {
        try ProjectMedia.pointerTimeline(url: url, document: document)
    }

    /// 读取工程内的自定义背景图；文件缺失或无法解码时回退到色板背景。
    /// 背景图只解码一次成位图（最长边不超过 3840，与导出上限一致）再交给 Core Image：
    /// `CIImage(contentsOf:)` 是惰性的，布局每变一步重算背景都会把原文件（5K WebP 软件解码）重新解一遍，拖留白时逐步卡顿、内存暴涨。
    nonisolated public static func backgroundImage(for layout: CanvasLayout, in url: URL) -> CIImage? {
        guard let path = layout.backgroundImage, let file = try? ProjectStorage.backgroundURL(path, in: url) else { return nil }
        return decodedBackground(at: file)
    }
    nonisolated static let backgroundMaximumEdge = 3840
    nonisolated static func decodedBackground(at file: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        guard let image = ImageDownsampler.image(from: source, maximumPixelSize: backgroundMaximumEdge) else { return CIImage(contentsOf: file) }
        return CIImage(cgImage: image)
    }

    private static func videoComposition(composition: AVMutableComposition, edit: VideoEdit, shortEdge: Int, pointers: PointerTimeline, backgroundImage: CIImage? = nil, frameRate: Double = 30, reusing previous: SceneInstruction? = nil) throws -> AVVideoComposition {
        guard let track = composition.track(withTrackID: trackID(for: .screen)), edit.duration > 0 else { throw ProjectError.invalid(String(localized: "时间线为空，请先恢复一个片段。")) }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = VideoCompositor.self
        let routes = composition.tracks.filter { $0.mediaType == .video }.flatMap { source in
            source.segments.filter { !$0.isEmpty }.map { VideoTrackRange(trackID: source.trackID, range: $0.timeMapping.target) }
        }
        let screens = routes.filter { $0.trackID == 1 || ($0.trackID >= 5 && $0.trackID % 2 == 1) }
        let cameras = edit.camera?.enabled == true ? routes.filter { $0.trackID >= 4 && $0.trackID % 2 == 0 } : []
        video.instructions = [SceneInstruction(trackID: track.trackID, edit: edit, screenRoutes: screens, cameraRoutes: cameras, pointers: pointers, backgroundImage: backgroundImage, reusing: previous)]
        // 短边按所选分辨率（720 / 1080 / 1440 / 2160），长边按比例伸展：方形以此为边长，横竖屏得到标准尺寸。
        let size = edit.layout.outputSize(shortEdge: shortEdge)
        video.renderSize = CGSize(width: size.width, height: size.height)
        // 输出帧率与录制帧率一致（旧工程 30）；60 fps 素材不再被折半。
        // 下限 5 而不是 24：GIF 按 10 / 15 帧出图，钳到 24 会白白多出六成的帧（体积跟着涨）。视频帧率由调用方保证 ≥ 24。
        video.frameDuration = CMTime(value: 1, timescale: Int32(max(5, min(120, frameRate.rounded()))))
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return video
    }

    /// 清掉这个文件夹里上次没收尾的导出临时文件（应用在导出中途被强制退出、崩溃时留下的）。
    /// 只删 6 小时前的，正在进行的导出写的临时文件不会被碰到。
    nonisolated static func removeStaleTemporaryFiles(in folder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let limit = Date().addingTimeInterval(-6 * 3600)
        for name in names where name.hasPrefix(".caplo-export-") {
            let file = folder.appendingPathComponent(name)
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < limit else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 固定工程快照导出；取消仅清理本次临时文件，不触碰用户原有目标或原素材。
    /// 旧入口：`longEdge` 1920 / 3840 对应 1080p / 4K 的 H.264（测试与旧调用方用）。
    public static func export(url: URL, document: ProjectDocument, levels: AudioLevels, destination: URL, edit: VideoEdit? = nil, longEdge: Int = 1920,
                              progress: @escaping @MainActor (Double) -> Void) async throws {
        var settings = ExportSettings()
        settings.resolution = longEdge >= 3840 ? .p2160 : .p1080
        try await export(url: url, document: document, levels: levels, destination: destination, edit: edit, settings: settings, progress: progress)
    }

    /// 按导出设置导出：格式、分辨率、帧率、画质、声音见 `ExportSettings`。
    /// `pointers`：编辑会话已经解析好的指针事件，传进来就不再重读。
    public static func export(url: URL, document: ProjectDocument, levels: AudioLevels, destination: URL, edit: VideoEdit? = nil, settings: ExportSettings,
                              pointers: PointerTimeline? = nil, progress: @escaping @MainActor (Double) -> Void) async throws {
        let (composition, mix) = try await compose(url: url, document: document, levels: levels, edit: edit)
        // 码率与帧率自己定（见 ExportEncoder）：系统预设在 4K 上只给约 10 Mbps 且降到 30 fps。
        let rate = settings.outputFrameRate(recorded: document.frameRate)
        // 指针事件与背景图在后台读：两小时的工程解析事件要 0.6 秒，背景图解码几十毫秒，以前都卡在主线程上。
        let timeline: PointerTimeline
        if let pointers { timeline = pointers }
        else if edit != nil { timeline = try await Task.detached(priority: .userInitiated) { try ProjectMedia.loadPointers(url: url, document: document) }.value }
        else { timeline = PointerTimeline(events: []) }
        let layout = edit?.layout
        nonisolated(unsafe) let background = await Task.detached(priority: .userInitiated) { layout.flatMap { backgroundImage(for: $0, in: url) } }.value
        let video = try edit.map { try videoComposition(composition: composition, edit: $0, shortEdge: settings.resolution.rawValue, pointers: timeline, backgroundImage: background, frameRate: rate) }
        let folder = destination.deletingLastPathComponent()
        removeStaleTemporaryFiles(in: folder)
        let temporary = folder.appendingPathComponent(".caplo-export-\(UUID()).\(settings.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await ExportEncoder.encode(asset: composition, videoComposition: video, audioMix: mix, destination: temporary, settings: settings) { value in
            Task { @MainActor in progress(value) }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        progress(1)
    }
}
