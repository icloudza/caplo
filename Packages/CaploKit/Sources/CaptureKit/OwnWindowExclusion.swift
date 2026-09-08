import AppKit
import ScreenCaptureKit

/// 全屏采集时要从画面里排除的本应用窗口：录制控制条、四角标记、区域框、窗口高亮都不能录进片子。
/// 按几种身份取并集——窗口号与本进程当前可见窗口一致、所属进程号一致、所属包标识一致，
/// 以及快照里没标所属应用、但几何与本进程某个可见窗口完全一致的窗口；系统快照里偶尔没有本应用的条目时仍能认出自己的窗口。
/// 过滤器优先按窗口排除（窗口号明确，不依赖系统把窗口归到哪个应用），一个都没找到才退回按应用排除。
/// 窗口级排除是快照：录制期间本应用窗口有增减时要重建过滤器更新到流上（见 `ScreenRecorder.watchOwnWindows`）。
/// 与此并行，录制期间显示的浮层都设了 `sharingType = .none`（FocuSee 同款：截屏时控件消失），快照里找不到自己时靠它挡住。
public struct OwnWindowExclusion {
    public let windows: [SCWindow]
    public let applications: [SCRunningApplication]
    public var windowIDs: Set<CGWindowID> { Set(windows.map(\.windowID)) }
    public var isEmpty: Bool { windows.isEmpty && applications.isEmpty }

    @MainActor public init(content: SCShareableContent) {
        let own = Self.visibleWindows()
        self.init(content: content, processID: ProcessInfo.processInfo.processIdentifier, bundleID: Bundle.main.bundleIdentifier,
                  visibleWindowIDs: Set(own.compactMap(\.id)), visibleFrames: own.map(\.frame))
    }

    init(content: SCShareableContent, processID: pid_t, bundleID: String?, visibleWindowIDs: Set<CGWindowID>, visibleFrames: [CGRect] = []) {
        applications = content.applications.filter { $0.processID == processID || (bundleID != nil && $0.bundleIdentifier == bundleID) }
        windows = content.windows.filter {
            Self.isOwn(windowID: $0.windowID, owningProcessID: $0.owningApplication?.processID, owningBundleID: $0.owningApplication?.bundleIdentifier,
                       frame: $0.frame, processID: processID, bundleID: bundleID, visibleWindowIDs: visibleWindowIDs, visibleFrames: visibleFrames)
        }
    }

    /// 纯判定：窗口号在本进程可见窗口里、所属进程 / 包标识与本应用一致；没标所属应用的窗口按几何与本进程可见窗口完全一致才算
    /// （限定"没标所属"是为了不误伤别的应用同尺寸的窗口，比如被录的全屏应用）。
    static func isOwn(windowID: CGWindowID, owningProcessID: pid_t?, owningBundleID: String?, frame: CGRect,
                      processID: pid_t, bundleID: String?, visibleWindowIDs: Set<CGWindowID>, visibleFrames: [CGRect]) -> Bool {
        if visibleWindowIDs.contains(windowID) { return true }
        if let owningProcessID, owningProcessID == processID { return true }
        if let bundleID, let owningBundleID, owningBundleID == bundleID { return true }
        if owningProcessID == nil, visibleFrames.contains(where: { sameFrame($0, frame) }) { return true }
        return false
    }

    /// 本进程当前可见窗口：窗口号（放得进 32 位才有）与采集坐标下的框。
    @MainActor static func visibleWindows() -> [(id: CGWindowID?, frame: CGRect)] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSApplication.shared.windows.filter(\.isVisible).map {
            (windowID(fromNumber: $0.windowNumber), captureFrame($0.frame, primaryHeight: primaryHeight))
        }
    }

    /// 本进程当前可见窗口的窗口号（`windowNumber` 与系统的 CGWindowID 一致）。
    @MainActor public static func visibleWindowIDs() -> Set<CGWindowID> { Set(visibleWindows().compactMap(\.id)) }

    /// 窗口号放得进 32 位才是可采集的窗口号；状态栏之类的系统窗口在新系统上会给出超出 32 位的编号，直接强转会断言崩溃。
    static func windowID(fromNumber number: Int) -> CGWindowID? {
        guard number > 0 else { return nil }
        return CGWindowID(exactly: number)
    }

    /// 采集框架的窗口框以主显示器左上角为原点、y 向下；AppKit 以主显示器左下角为原点、y 向上。
    static func captureFrame(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// 可见窗口里有过滤器还没排除的，就要重建过滤器。
    static func needsRefresh(excluded: Set<CGWindowID>, visible: Set<CGWindowID>) -> Bool { !visible.isSubset(of: excluded) }

    public func filter(display: SCDisplay) -> SCContentFilter {
        windows.isEmpty
            ? SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
            : SCContentFilter(display: display, excludingWindows: windows)
    }

    /// 快照里找不到自己时写进日志的线索：本进程可见窗口与快照里没标所属应用的窗口。
    @MainActor public static func diagnostics(content: SCShareableContent) -> String {
        let own = NSApplication.shared.windows.filter(\.isVisible).map {
            "\($0.windowNumber)@\($0.level.rawValue) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height)) sharing=\($0.sharingType.rawValue) \($0.title)"
        }
        let orphan = content.windows.filter { $0.owningApplication == nil }.map {
            "\($0.windowID)@\($0.windowLayer) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height)) \($0.title ?? "-")"
        }
        return "本进程可见窗口 \(own.count) 个：\(own.joined(separator: "；"))。快照 \(content.applications.count) 个应用、\(content.windows.count) 个窗口，没标所属的 \(orphan.count) 个：\(orphan.joined(separator: "；"))"
    }
}
