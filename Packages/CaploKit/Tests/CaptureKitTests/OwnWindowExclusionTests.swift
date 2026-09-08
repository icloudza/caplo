import AppKit
import Testing
@testable import CaptureKit

/// 本应用窗口的判定：窗口号在本进程可见窗口里、所属进程一致、所属包标识一致三者任一即排除；别的应用不排除。
@Test func ownWindowIsRecognisedByNumberProcessOrBundle() {
    let visible: Set<CGWindowID> = [41, 42]
    func own(_ id: CGWindowID, pid: pid_t?, bundle: String?, frame: CGRect = .zero, frames: [CGRect] = []) -> Bool {
        OwnWindowExclusion.isOwn(windowID: id, owningProcessID: pid, owningBundleID: bundle, frame: frame, processID: 100, bundleID: "com.caplo", visibleWindowIDs: visible, visibleFrames: frames)
    }
    #expect(own(41, pid: nil, bundle: nil))
    #expect(own(7, pid: 100, bundle: nil))
    #expect(own(7, pid: 5, bundle: "com.caplo"))
    #expect(!own(7, pid: 5, bundle: "com.other"))
    #expect(!OwnWindowExclusion.isOwn(windowID: 7, owningProcessID: 5, owningBundleID: nil, frame: .zero, processID: 100, bundleID: nil, visibleWindowIDs: visible, visibleFrames: []))
    // 没标所属应用的窗口按几何匹配；标了别的应用的即使同尺寸也不排除。
    let frame = CGRect(x: 40, y: 60, width: 360, height: 84)
    #expect(own(9, pid: nil, bundle: nil, frame: frame, frames: [frame]))
    #expect(own(9, pid: nil, bundle: nil, frame: frame.offsetBy(dx: 0.4, dy: -0.4), frames: [frame]))
    #expect(!own(9, pid: nil, bundle: nil, frame: frame.offsetBy(dx: 2, dy: 0), frames: [frame]))
    #expect(!own(9, pid: 5, bundle: "com.other", frame: frame, frames: [frame]))
}

/// 窗口号超出 32 位（新系统上的状态栏窗口）或非正数时不转换，不能断言崩溃。
@Test func oversizedWindowNumbersAreSkippedInsteadOfTrapping() {
    #expect(OwnWindowExclusion.windowID(fromNumber: 4021) == 4021)
    #expect(OwnWindowExclusion.windowID(fromNumber: Int(UInt32.max) + 1) == nil)
    #expect(OwnWindowExclusion.windowID(fromNumber: Int.max) == nil)
    #expect(OwnWindowExclusion.windowID(fromNumber: 0) == nil)
    #expect(OwnWindowExclusion.windowID(fromNumber: -1) == nil)
}

/// AppKit 的左下原点框换算成采集框架的左上原点框。
@Test func appKitFramesConvertToCaptureCoordinates() {
    let converted = OwnWindowExclusion.captureFrame(CGRect(x: 40, y: 60, width: 360, height: 84), primaryHeight: 1000)
    #expect(converted == CGRect(x: 40, y: 856, width: 360, height: 84))
}

/// 可见窗口集合跟着窗口显示 / 隐藏变化；出现过滤器没排除的窗口才需要重建。
@MainActor @Test func visibleWindowIDsFollowOnScreenWindowsAndDriveRefresh() {
    let window = NSWindow(contentRect: CGRect(x: -400, y: -400, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    let id = CGWindowID(window.windowNumber)
    #expect(id > 0 && OwnWindowExclusion.visibleWindowIDs().contains(id))
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    #expect(OwnWindowExclusion.visibleWindows().contains { $0.id == id && $0.frame == OwnWindowExclusion.captureFrame(window.frame, primaryHeight: primaryHeight) })
    window.orderOut(nil)
    #expect(!OwnWindowExclusion.visibleWindowIDs().contains(id))
    #expect(OwnWindowExclusion.needsRefresh(excluded: [1, 2], visible: [1, 2, 3]))
    #expect(!OwnWindowExclusion.needsRefresh(excluded: [1, 2, 3], visible: [1, 2]))
    #expect(!OwnWindowExclusion.needsRefresh(excluded: [1, 2], visible: []))
}
