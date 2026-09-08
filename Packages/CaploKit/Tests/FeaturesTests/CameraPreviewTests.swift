import AppKit
import AVFoundation
import Testing
import CaptureKit
import EditingCore
import ProjectKit
@testable import Features

/// 画中画默认停在可见区域右下角；预览模型与摄像头关闭时不起预览会话、不显示画中画；录制器空闲时没有摄像头会话。
@MainActor @Test func cameraPreviewPlacementAndGating() throws {
    let frame = CameraPreviewSession.frame(in: CGRect(x: 0, y: 40, width: 1920, height: 1040))
    #expect(frame == CGRect(x: 1920 - 24 - 168, y: 64, width: 168, height: 168))
    let defaults = try #require(UserDefaults(suiteName: "caplo.tests.camera-preview." + UUID().uuidString))
    defaults.set(true, forKey: "recording.camera")
    RecordBarModel.preview().syncCameraMonitor(defaults: defaults)
    #expect(!CameraMonitor.shared.active && CameraMonitor.shared.feed == nil && !CameraPreviewSession.isShowing)
    let model = RecordBarModel(mode: .display, source: CaptureSource(id: "display-1", title: "显示器", kind: .display))
    defaults.set(false, forKey: "recording.camera")
    model.syncCameraMonitor(defaults: defaults)
    #expect(!CameraMonitor.shared.active && !CameraPreviewSession.isShowing)
    #expect(ScreenRecorder.shared.cameraPreviewFeed == nil && !ScreenRecorder.shared.sessionUsesCamera)
}

/// 所选设备不在线就当关闭：名称为 nil、可用性为假；系统默认只要有任一设备就可用。
@Test func disconnectedDevicesCountAsOff() {
    let cameras = [CaptureCamera(id: "cam-a", name: "内置")]
    #expect(RecordingDeviceNames.camera(id: "cam-a", cameras: cameras) == "内置")
    #expect(RecordingDeviceNames.camera(id: "iphone", cameras: cameras) == nil)
    #expect(RecordingDeviceNames.camera(id: "", cameras: cameras) == "默认摄像头")
    #expect(RecordingDeviceNames.camera(id: "", cameras: []) == nil)
    let mics = [CaptureMicrophone(id: "mic-a", name: "iPhone")]
    #expect(RecordingDeviceNames.microphone(id: "mic-b", devices: mics) == nil)
    #expect(RecordingDeviceNames.microphone(id: "", devices: []) == nil)
    #expect(RecordingDeviceNames.available(id: "", in: ["x"]) && !RecordingDeviceNames.available(id: "", in: []))
    #expect(RecordingDeviceNames.available(id: "x", in: ["x"]) && !RecordingDeviceNames.available(id: "y", in: ["x"]))
}

/// 录制时的画中画只是屏幕上的取景窗：把它拖到别处，新工程首次打开时编辑器人像仍是 `CameraLayout` 自己的默认布局。
@MainActor @Test func livePreviewPositionNeverReachesTheEditorLayout() throws {
    CameraPreviewSession.show(feed: CameraFeed(queue: DispatchQueue(label: "test.camera-pip")), on: NSScreen.main ?? NSScreen.screens[0])
    let panel = try #require(NSApp.windows.first { $0.contentView is CameraPreviewView })
    panel.setFrameOrigin(CGPoint(x: 80, y: 120))
    #expect(panel.frame.origin == CGPoint(x: 80, y: 120))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-live-pip-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "带摄像头")
    var document = ProjectDocument(name: "带摄像头")
    document.segments = [SegmentRecord(id: 0, duration: 2, files: [.camera: "Media/000000-camera.mov"])]
    let edit = try EditStorage.load(in: url, document: document)
    #expect(edit.camera == CameraLayout())
    let rect = try #require(edit.camera?.rect(in: CGSize(width: 1920, height: 1080)))
    #expect(rect.maxX > 1920 * 0.9 && rect.minY < 1080 * 0.1)
    CameraPreviewSession.hide()
    #expect(!CameraPreviewSession.isShowing)
}

/// 摄像头格式偏好进录制选项：存 "宽x高@帧率"，缺省或乱值为自动（nil）。
@Test func cameraFormatPreferenceFlowsIntoRecordingOptions() throws {
    let defaults = try #require(UserDefaults(suiteName: "caplo.tests.camera-format." + UUID().uuidString))
    var options = RecordingOptions()
    RecordingCameraPreferences.apply(to: &options, defaults: defaults)
    #expect(options.cameraFormat == nil)
    defaults.set("1920x1440@60", forKey: "recording.cameraFormat")
    RecordingCameraPreferences.apply(to: &options, defaults: defaults)
    #expect(options.cameraFormat == CameraFormat(width: 1920, height: 1440, frameRate: 60))
    defaults.set("乱", forKey: "recording.cameraFormat")
    RecordingCameraPreferences.apply(to: &options, defaults: defaults)
    #expect(options.cameraFormat == nil)
}

/// 录制条没显示着时，设置页开关、设备插拔经由隐藏的录制条视图触发的同步不得把试听 / 预览拉起来。
@MainActor @Test func hiddenRecordBarNeverStartsMonitors() throws {
    let defaults = try #require(UserDefaults(suiteName: "caplo.tests.hidden-bar." + UUID().uuidString))
    defaults.set(true, forKey: "recording.camera"); defaults.set(true, forKey: "recording.microphone")
    let model = RecordBarModel(mode: .display, source: CaptureSource(id: "display-1", title: "显示器", kind: .display))
    #expect(!StudioWindows.isRecordBarVisible)
    model.syncCameraMonitor(defaults: defaults); model.syncMicrophoneMonitor(defaults: defaults)
    #expect(!CameraMonitor.shared.active && CameraMonitor.shared.feed == nil && !MicrophoneMonitor.shared.active)
    #expect(!CameraPreviewSession.isShowing)
}

/// 画中画自己收帧：挂上采集图后帧出口有人接，换成 nil 后出口清掉。
@MainActor @Test func previewViewTakesFramesFromTheFeed() {
    let view = CameraPreviewView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let feed = CameraFeed(queue: DispatchQueue(label: "test.camera-preview-feed"))
    #expect(!feed.hasPreviewSink)
    view.attach(feed)
    #expect(feed.hasPreviewSink)
    view.attach(nil)
    #expect(!feed.hasPreviewSink)
}

/// 录制条上的短名：去掉系统设备名的引号与"的相机 / 的麦克风"后缀，其他名字原样；系统声音全部时只显示"系统声音"。
@Test func recordBarShowsShortDeviceNames() {
    #expect(RecordingDeviceNames.short("“云之安的 iPhone”的相机") == "云之安的 iPhone")
    #expect(RecordingDeviceNames.short("“云之安的 iPhone”的麦克风") == "云之安的 iPhone")
    #expect(RecordingDeviceNames.short("FaceTime HD Camera") == "FaceTime HD")
    #expect(RecordingDeviceNames.short("MacBook Pro麦克风") == "MacBook Pro麦克风")
    #expect(RecordingDeviceNames.short("\"\"") == "\"\"")
    #expect(RecordingDeviceNames.camera(id: "a", cameras: [CaptureCamera(id: "a", name: "“云之安的 iPhone”的相机")]) == "云之安的 iPhone")
    #expect(RecordingDeviceNames.systemAudio(scope: "all", selected: [], applications: []) == "系统声音")
    #expect(RecordingDeviceNames.systemAudio(scope: "applications", selected: ["a", "b"], applications: []) == "2 个应用")
}
