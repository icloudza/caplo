import AppKit
import Observation
import ScreenCaptureKit
import AVFoundation
import ProjectKit

public struct CaptureSource: Identifiable, Sendable {
    public enum Kind: String, Sendable { case display = "全屏", window = "窗口" }
    public let id: String
    public let title: String
    public let kind: Kind
    public var displayID: CGDirectDisplayID? = nil
    /// 全局坐标（左上角原点）下的窗口 / 显示器位置，用于屏幕悬停选择。
    public var frame: CGRect? = nil
    public var applicationName: String? = nil
    public var windowTitle: String? = nil
    public var processID: pid_t? = nil
    public var windowID: UInt32? = nil

    public init(id: String, title: String, kind: Kind, displayID: CGDirectDisplayID? = nil, frame: CGRect? = nil,
                applicationName: String? = nil, windowTitle: String? = nil, processID: pid_t? = nil, windowID: UInt32? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.displayID = displayID; self.frame = frame
        self.applicationName = applicationName; self.windowTitle = windowTitle; self.processID = processID; self.windowID = windowID
    }
}

public struct RecordingOptions: Sendable {
    public var systemAudio = false
    public var microphone = false
    public var microphoneDeviceID: String?
    public var camera = false
    public var cameraDeviceID: String?
    /// 用户选的摄像头格式（nil 自动：不超过 1080p 的最大尺寸、30 fps）。
    public var cameraFormat: CameraFormat?
    public var systemAudioApplicationBundleIDs: [String]?
    public var countdown = 3
    public var capturePointer = true
    public var reconstructCursor = true
    public var region: CGRect?
    /// 录制帧率（24…120），默认 60：滚动与光标运动更顺滑，编码与回放都按同一帧率。
    public var frameRate = 60.0
    public init() {}
}

/// 全应用共享会话；工程租约持续到所有片段提交后才释放。
@MainActor @Observable
public final class ScreenRecorder {
    public static let shared = ScreenRecorder()
    public enum Phase: Sendable { case idle, countdown, starting, recording, pausing, paused, resuming, stopping }
    public private(set) var phase: Phase = .idle
    public private(set) var sources: [CaptureSource] = []
    public private(set) var loadingSources = false
    public private(set) var errorMessage: String?
    public private(set) var completedURL: URL?
    public private(set) var projectURL: URL?
    public private(set) var startedAt: Date?
    public private(set) var countdownRemaining = 0
    public private(set) var elapsedBeforeResume = 0.0
    public private(set) var activeIntervalStart: TimeInterval?
    /// 当前这段计时在墙钟上的原点（`elapsed == 0` 对应的时刻），暂停时为 nil；录制条用它把刷新节拍对齐到读数变化的时刻。
    public private(set) var elapsedOrigin: Date?
    public var isBusy: Bool { phase != .idle }
    public var canStop: Bool { phase == .recording || phase == .paused }
    public var elapsed: Double {
        elapsedBeforeResume + (activeIntervalStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }

    private var content: SCShareableContent?
    private var stream: SCStream?
    private var systemAudioStream: SCStream?
    private var microphoneObserver: NSObjectProtocol?
    private var cameraCapture: CameraCapture?
    /// 本次录制是否带摄像头（倒计时阶段就为真，画中画先显示占位）；录制中的摄像头会话给屏幕上的画中画预览用。
    public private(set) var sessionUsesCamera = false
    public var cameraPreviewFeed: CameraFeed? { cameraCapture?.previewFeed }
    private var microphoneCapture: MicrophoneCapture?
    /// 麦克风借用了录制条试听中的采集（没有重启引擎）：结束时只摘写入器。
    private var microphoneBorrowed = false
    private var writer: SegmentedCaptureWriter?
    private var delegate: StreamDelegate?
    private var lease: ProjectLease?
    private var pointerRecorder: PointerRecorder?
    private var firstFrameTimeout: Task<Void, Never>?
    private var sessionID: UUID?
    /// 全屏 / 区域录制的显示器与当前过滤器排除的本应用窗口号；录制期间监视本应用窗口的增减。
    private var sessionDisplayID: CGDirectDisplayID?
    private var excludedWindowIDs: Set<CGWindowID> = []
    private var knownVisibleWindowIDs: Set<CGWindowID> = []
    private var exclusionWatcher: Task<Void, Never>?
    private init() {}

    /// 仅由用户点击触发枚举，打开窗口或生成界面预览不会访问屏幕。
    public func refreshSources() async {
        guard !isBusy, !loadingSources else { return }
        loadingSources = true
        errorMessage = nil
        defer { loadingSources = false }
        do {
            let newContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            content = newContent
            let displays = newContent.displays.enumerated().map { index, display in
                CaptureSource(id: "display-\(display.displayID)", title: "显示器 \(index + 1) · \(display.width) × \(display.height)", kind: .display, displayID: display.displayID, frame: display.frame)
            }
            let windows = newContent.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 0 && $0.frame.height > 0 && !($0.title ?? "").isEmpty
            }.map {
                CaptureSource(id: "window-\($0.windowID)", title: "\($0.owningApplication?.applicationName ?? "应用") — \($0.title ?? "窗口")", kind: .window,
                              frame: $0.frame, applicationName: $0.owningApplication?.applicationName, windowTitle: $0.title,
                              processID: $0.owningApplication?.processID, windowID: $0.windowID)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            sources = displays + windows
        } catch {
            content = nil
            sources = []
            errorMessage = "无法读取录制来源。请在系统设置中允许 Caplo 录制屏幕，必要时退出并重新打开应用。\n\(error.localizedDescription)"
        }
    }


    public func start(sourceID: String, options: RecordingOptions) async {
        guard !isBusy, !loadingSources else { return }
        guard var content, let source = sources.first(where: { $0.id == sourceID }) else {
            errorMessage = "请先选择录制来源。"; return
        }
        phase = .starting
        errorMessage = nil; completedURL = nil; projectURL = nil
        sessionUsesCamera = options.camera; microphoneBorrowed = false
        elapsedBeforeResume = 0; activeIntervalStart = nil; elapsedOrigin = nil
        let id = UUID(); sessionID = id
        do {
            if options.microphone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard sessionID == id, phase == .starting else { return }
                guard allowed else { throw RecordingError.message("请在系统设置中允许麦克风访问，或关闭麦克风后再录制。") }
            }
            if options.camera {
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard sessionID == id, phase == .starting else { return }
                guard allowed else { throw RecordingError.message("请在系统设置中允许摄像头访问，或关闭摄像头后再录制。") }
            }
            _ = try resolveAudio(options, content: content)
            _ = try resolveCamera(options)
            phase = .countdown
            for count in stride(from: max(0, options.countdown), to: 0, by: -1) {
                countdownRemaining = count
                try await Task.sleep(for: .seconds(1))
                guard sessionID == id else { return }
            }
            countdownRemaining = 0
            phase = .starting
            // 倒计时期间应用可能退出或窗口可能关闭，重新取内容快照，不沿用已经失效的进程 ID。
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard sessionID == id else { return }
            // 设备也可能被拔出，绝不静默改用其他输入。
            let audioPlan = try resolveAudio(options, content: content)
            let cameraPlan = try resolveCamera(options)
            let filter: SCContentFilter
            var pointerBounds = CGRect.zero
            var pointerWindow: CGWindowID?
            if source.kind == .display,
               let display = content.displays.first(where: { "display-\($0.displayID)" == sourceID }) {
                // 排除本应用全部窗口（录制控制条、四角标记、区域框都不录进片子）：按窗口号 / 进程 / 包标识取并集，
                // 优先按窗口排除；录制期间本应用窗口有增减时 watchOwnWindows 重建过滤器更新到流上。
                var exclusion = OwnWindowExclusion(content: content)
                if exclusion.isEmpty {
                    // 这版系统"仅在屏窗口"的快照里可能没有本进程的浮层，再取一次包含离屏窗口的快照找一遍。
                    if let wider = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
                        guard sessionID == id else { return }
                        let again = OwnWindowExclusion(content: wider)
                        if !again.isEmpty { exclusion = again }
                    }
                }
                if exclusion.isEmpty {
                    NSLog("Caplo：两次共享内容快照里都没有本应用的窗口，只能靠浮层的 sharingType 挡住。%@", OwnWindowExclusion.diagnostics(content: content))
                }
                NSLog("Caplo：录制过滤器排除本应用 %d 个窗口、%d 个应用条目", exclusion.windows.count, exclusion.applications.count)
                filter = exclusion.filter(display: display)
                sessionDisplayID = display.displayID
                excludedWindowIDs = exclusion.windowIDs
                knownVisibleWindowIDs = OwnWindowExclusion.visibleWindowIDs()
                pointerBounds = CGDisplayBounds(display.displayID)
            } else if let window = content.windows.first(where: { "window-\($0.windowID)" == sourceID }) {
                filter = SCContentFilter(desktopIndependentWindow: window)
                pointerBounds = window.frame; pointerWindow = window.windowID
            } else { throw RecordingError.message("所选来源已不可用，请刷新后重试。") }
            let captureSize: CGSize
            if let region = options.region {
                guard source.kind == .display, region.width >= 32, region.height >= 32,
                      CGRect(origin: .zero, size: filter.contentRect.size).contains(region) else {
                    throw RecordingError.message("选区已超出显示器范围，请重新选择。")
                }
                captureSize = region.size
                pointerBounds = region.offsetBy(dx: pointerBounds.minX, dy: pointerBounds.minY)
            } else { captureSize = filter.contentRect.size }
            let dimensions = Self.encodingSize(points: captureSize, scale: Double(filter.pointPixelScale))
            let frameRate = options.frameRate.isFinite ? min(120, max(24, options.frameRate)) : 60
            let config = SCStreamConfiguration()
            config.width = dimensions.width; config.height = dimensions.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate.rounded()))
            // 深队列：换段、编码器起步或系统瞬时负载时不丢帧；保留最后一帧用于换段快照也不会耗尽缓冲池。
            config.queueDepth = 8
            // 编码器原生的 4:2:0 视频范围格式：省去每帧 BGRA → YUV 转换，内存带宽减半。
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorSpaceName = CGColorSpace.itur_709
            config.captureDynamicRange = .SDR
            config.showsCursor = true
            // 系统声音使用独立过滤流，选择应用不会改变屏幕画面，也不受窗口来源限制。
            config.capturesAudio = false
            // 录制期间本进程不出声，不需要排除本进程音频；这个开关疑似让录完后本进程的播放器音频时钟起不来（HAL 报 stop）。
            config.excludesCurrentProcessAudio = false
            config.captureMicrophone = audioPlan.microphoneDeviceID != nil
            config.microphoneCaptureDeviceID = audioPlan.microphoneDeviceID
            config.sampleRate = 48_000; config.channelCount = 2
            config.ignoreShadowsSingleWindow = true
            if let region = options.region { config.sourceRect = region }
            let name = "录制 \(Date().formatted(date: .abbreviated, time: .shortened))"
            let project = try ProjectStorage.create(name: name)
            projectURL = project
            lease = try ProjectLease(url: project)
            var initial = try ProjectStorage.load(project)
            initial.capture = CaptureMetadata(desktopBounds: pointerBounds, pixelSize: CGSize(width: dimensions.width, height: dimensions.height), pointPixelScale: Double(filter.pointPixelScale), pointerEnabled: options.capturePointer)
            initial.capture?.microphoneDeviceID = audioPlan.microphoneDeviceID
            initial.capture?.cameraDeviceID = cameraPlan.deviceID
            initial.capture?.systemAudioApplicationBundleIDs = audioPlan.applicationBundleIDs
            initial.capture?.systemAudioEnabled = audioPlan.systemAudio
            initial.capture?.frameRate = frameRate
            let output = SegmentedCaptureWriter(project: project, width: dimensions.width, height: dimensions.height,
                systemAudio: options.systemAudio, microphone: options.microphone, camera: options.camera, frameRate: frameRate,
                onStarted: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.sessionID == id, self.phase == .starting else { return }
                        self.phase = .recording
                        self.startedAt = Date()
                        self.activeIntervalStart = ProcessInfo.processInfo.systemUptime
                        self.elapsedOrigin = self.startedAt
                        self.firstFrameTimeout?.cancel()
                    }
                }, onFailure: { [weak self] message in
                    Task { @MainActor in await self?.handleFailure(message, sessionID: id) }
                })
            let delegate = StreamDelegate { [weak self] message in
                Task { @MainActor in await self?.handleFailure(message, sessionID: id) }
            }
            if options.capturePointer {
                let pointer = PointerRecorder(bounds: pointerBounds, windowID: pointerWindow, clock: CMClockGetHostTimeClock(), writer: output)
                pointerRecorder = pointer
                let monitoring = pointer.start()
                // 增强模式只在事件监听建立后隐藏原光标；监听失败时保留系统光标，基础录制仍可用。
                config.showsCursor = !options.reconstructCursor || !monitoring
            }
            // 麦克风在本进程用 AVCaptureSession 采集：用户在控制中心选的麦克风模式（语音突显等）作用于本进程的采集，
            // 交给屏幕采集服务录麦克风时它不生效。录制时不做任何自己的处理，系统给什么就录什么；会话起不来退回屏幕采集流。
            if let deviceID = audioPlan.microphoneDeviceID {
                let failure: @Sendable (String) -> Void = { [weak self] message in
                    Task { @MainActor in await self?.handleFailure(message, sessionID: id) }
                }
                if MicrophoneMonitor.shared.borrow(deviceID: deviceID, writer: output, onFailure: failure) {
                    // 录制条已经在试听同一只麦克风：把写入器挂上去即可，引擎不停不重开（iPhone 麦克风不闪、系统模式不丢）。
                    microphoneBorrowed = true
                    config.captureMicrophone = false; config.microphoneCaptureDeviceID = nil
                    NSLog("Caplo：麦克风沿用录制条试听中的采集，不重启")
                } else {
                    let microphone = MicrophoneCapture(writer: output, onFailure: failure)
                    do {
                        try await microphone.start(deviceID: deviceID)
                        guard sessionID == id, phase != .stopping else { microphone.stop(); return }
                        microphoneCapture = microphone
                        config.captureMicrophone = false; config.microphoneCaptureDeviceID = nil
                        MicrophoneModes.shared.startObserving()
                    } catch {
                        NSLog("Caplo：本进程麦克风采集不可用，改由屏幕采集流录制：%@", error.localizedDescription)
                    }
                }
            }
            initial.capture?.cursorEmbedded = config.showsCursor
            try ProjectStorage.save(initial, to: project)
            let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
            self.writer = output; self.delegate = delegate; self.stream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            if let deviceID = cameraPlan.deviceID {
                let camera = CameraCapture(writer: output) { [weak self] message in
                    Task { @MainActor in await self?.handleFailure(message, sessionID: id) }
                }
                cameraCapture = camera
                // 录制条的预览采集图还在跑就借来只挂消费者，摄像头不灭不重开、画面不断；没有才自己起。
                // 与预览用同一条规则落实格式，这样借用判断才会一致。
                let format = AVCaptureDevice(uniqueID: deviceID).flatMap { CameraFormat.resolve(available: CameraFormat.available(on: $0), wanted: cameraPlan.format) }
                try await camera.start(deviceID: deviceID, format: format, adopting: CameraMonitor.shared.borrowFeed(for: deviceID, format: format))
                guard sessionID == id, phase != .stopping else { await camera.stop(); return }
            }
            if audioPlan.systemAudio {
                guard let display = content.displays.first else { throw RecordingError.message("没有可用的系统声音采集来源。") }
                let audioFilter: SCContentFilter
                if let selected = audioPlan.applicationBundleIDs {
                    let applications = content.applications.filter { app in selected.contains { RecordingAudioPlan.matches(application: app.bundleIdentifier, selection: $0) } }
                    audioFilter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
                } else {
                    audioFilter = SCContentFilter(display: display, excludingApplications: OwnWindowExclusion(content: content).applications, exceptingWindows: [])
                }
                let audioConfig = SCStreamConfiguration()
                audioConfig.capturesAudio = true
                audioConfig.excludesCurrentProcessAudio = false
                audioConfig.sampleRate = 48_000; audioConfig.channelCount = 2
                audioConfig.width = 2; audioConfig.height = 2
                audioConfig.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                audioConfig.queueDepth = 3
                let audioStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: delegate)
                systemAudioStream = audioStream
                try audioStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
                // 这条流只要声音，但系统仍按 minimumFrameInterval 产出 2×2 的画面样本；没有接收者时每帧都会打一行
                // "stream output NOT found. Dropping frame"，挂一个丢弃接收者把它们静默吃掉。
                try audioStream.addStreamOutput(Self.discardingOutput, type: .screen, sampleHandlerQueue: output.queue)
                try await audioStream.startCapture()
                guard sessionID == id, phase != .stopping else { try? await audioStream.stopCapture(); return }
            }
            if config.captureMicrophone { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue) }
            try await stream.startCapture()
            guard sessionID == id, phase != .stopping else { try? await stream.stopCapture(); return }
            output.startTimer(clock: CMClockGetHostTimeClock())
            observeMicrophone(audioPlan.microphoneDeviceID, session: id)
            guard sessionID == id, phase == .starting else { return }
            if sessionDisplayID != nil { watchOwnWindows(session: id) }
            firstFrameTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                await self?.handleFailure("没有收到有效画面，请检查权限或重新选择来源。", sessionID: id)
            }
        } catch { await handleFailure(error.localizedDescription, sessionID: id) }
    }

    public func cancelCountdown() {
        guard phase == .countdown else { return }
        sessionID = nil; countdownRemaining = 0; phase = .idle; sessionUsesCamera = false
    }

    public func pause() async {
        guard phase == .recording, let writer else { return }
        phase = .pausing
        freezeTimer()
        await writer.pause(at: captureTime)
        if phase == .pausing { phase = .paused }
    }

    public func resume() async {
        guard phase == .paused, let writer else { return }
        phase = .resuming
        await writer.resume(at: captureTime)
        if phase == .resuming {
            activeIntervalStart = ProcessInfo.processInfo.systemUptime
            elapsedOrigin = Date().addingTimeInterval(-elapsedBeforeResume)
            phase = .recording
        }
    }

    public func stop() async {
        guard canStop else { return }
        await finish(warning: nil)
    }

    private func freezeTimer() {
        elapsedBeforeResume = elapsed
        activeIntervalStart = nil
        elapsedOrigin = nil
    }

    // 所有流的样本已由 MediaClockBridge 变换为主机时钟，暂停、鼠标和收尾也使用同一时钟。
    private var captureTime: CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// 录制期间每半秒看一眼本进程可见窗口的集合：出现了过滤器还没排除的窗口（控制条重新显示、四角标记重建等）
    /// 就重取共享内容快照、重建过滤器更新到流上。集合没变就不重复取快照。
    private func watchOwnWindows(session id: UUID) {
        exclusionWatcher?.cancel()
        exclusionWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.sessionID == id, let stream = self.stream, let displayID = self.sessionDisplayID else { return }
                let visible = OwnWindowExclusion.visibleWindowIDs()
                guard visible != self.knownVisibleWindowIDs else { continue }
                self.knownVisibleWindowIDs = visible
                guard OwnWindowExclusion.needsRefresh(excluded: self.excludedWindowIDs, visible: visible) else { continue }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    guard self.sessionID == id, let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
                    let exclusion = OwnWindowExclusion(content: content)
                    // 只有快照里多出了能排除的本应用窗口才更新过滤器：更新会让系统重新评估浮层的 sharingType，无谓的更新可能把它们放进画面。
                    guard !exclusion.windowIDs.isSubset(of: self.excludedWindowIDs) else { continue }
                    try await stream.updateContentFilter(exclusion.filter(display: display))
                    guard self.sessionID == id else { return }
                    self.excludedWindowIDs = exclusion.windowIDs
                    NSLog("Caplo：录制过滤器已更新，排除本应用 %d 个窗口", exclusion.windows.count)
                } catch { NSLog("Caplo：更新录制过滤器失败：%@", error.localizedDescription) }
            }
        }
    }

    private func handleFailure(_ message: String, sessionID id: UUID) async {
        guard sessionID == id, phase != .idle, phase != .stopping else { return }
        await finish(warning: message)
    }

    private func finish(warning: String?) async {
        phase = .stopping; freezeTimer()
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        exclusionWatcher?.cancel(); exclusionWatcher = nil; sessionDisplayID = nil
        pointerRecorder?.stop(); pointerRecorder = nil
        if let microphoneObserver { NotificationCenter.default.removeObserver(microphoneObserver) }
        microphoneObserver = nil
        let stopTime = captureTime
        var issue = warning
        // 先冻结写入边界，设备停止即使较慢也不能继续产生超出停止时刻的新片段。
        if let writer { await writer.pause(at: stopTime) }
        // 停止摄像头并排空其回调队列之后，写入器才能按共同的停止时间提交尾段。
        if let cameraCapture { await cameraCapture.stop() }
        cameraCapture = nil
        microphoneCapture?.stop(); microphoneCapture = nil
        if microphoneBorrowed { MicrophoneMonitor.shared.release(); microphoneBorrowed = false }
        if let stream {
            do { try await stream.stopCapture() } catch { issue = issue ?? error.localizedDescription }
        }
        if let systemAudioStream {
            do { try await systemAudioStream.stopCapture() } catch { issue = issue ?? error.localizedDescription }
        }
        if let writer {
            do { try await writer.finish(at: stopTime) } catch { issue = issue ?? error.localizedDescription }
        }
        if let projectURL {
            do {
                guard !(try ProjectStorage.load(projectURL)).segments.isEmpty else {
                    throw RecordingError.message(issue ?? "未收到可保存的画面，请检查来源和权限后重试。")
                }
                try ProjectStorage.complete(projectURL, warning: issue)
                completedURL = projectURL
            } catch { issue = issue ?? error.localizedDescription }
        }
        errorMessage = issue
        stream = nil; systemAudioStream = nil; writer = nil; delegate = nil; sessionID = nil; lease = nil
        startedAt = nil; phase = .idle; sessionUsesCamera = false
    }

    private func resolveAudio(_ options: RecordingOptions, content: SCShareableContent) throws -> RecordingAudioPlan {
        try RecordingAudioPlan.resolve(options: options, microphones: options.microphone ? AudioInputCatalog.microphones() : [],
            defaultMicrophoneID: options.microphone ? AVCaptureDevice.default(for: .audio)?.uniqueID : nil,
            applicationIDs: Set(content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }.map(\.bundleIdentifier)))
    }

    private func resolveCamera(_ options: RecordingOptions) throws -> RecordingCameraPlan {
        try RecordingCameraPlan.resolve(enabled: options.camera, selectedID: options.cameraDeviceID,
            cameras: options.camera ? CameraInputCatalog.cameras() : [],
            defaultID: options.camera ? AVCaptureDevice.default(for: .video)?.uniqueID : nil, format: options.cameraFormat)
    }

    private func observeMicrophone(_ deviceID: String?, session: UUID) {
        guard let deviceID else { return }
        microphoneObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard (notification.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
            Task { @MainActor in await self?.handleFailure("麦克风已断开，已结束录制并保存已收到的内容。", sessionID: session) }
        }
    }

    /// 首个采集版本限制最长边为 3840，保留比例并对齐偶数像素，避免 H.264 编码尺寸错误。
    static func encodingSize(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0 else { return (2, 2) }
        let width = max(2, points.width * scale)
        let height = max(2, points.height * scale)
        let factor = min(1, 3840 / max(width, height))
        return (max(2, Int(width * factor) / 2 * 2), max(2, Int(height * factor) / 2 * 2))
    }

}

extension ScreenRecorder {
    /// 声音流上画面样本的丢弃接收者（无状态，可共用）。
    nonisolated static let discardingOutput = DiscardingStreamOutput()
}

/// 什么都不做的流接收者：只为让系统知道有人接收，不再逐帧报"没有接收者"。
final class DiscardingStreamOutput: NSObject, SCStreamOutput, Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

/// 系统代理只通过 Sendable 闭包转交状态，不在未知回调线程修改 UI。
private final class StreamDelegate: NSObject, SCStreamDelegate, Sendable {
    let failure: @Sendable (String) -> Void
    init(failure: @escaping @Sendable (String) -> Void) { self.failure = failure }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { failure(error.localizedDescription) }
}
