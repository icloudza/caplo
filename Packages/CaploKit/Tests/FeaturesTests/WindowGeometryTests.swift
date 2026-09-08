import AppKit
import Testing
@testable import Features

/// 窗口高亮的几何换算与最前窗口判定，全部使用合成数据，不读取真实窗口列表。
struct WindowGeometryTests {
    private func entry(pid: Int, number: Int, layer: Int = 0, alpha: Double = 1, size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(origin: CGPoint(x: 10, y: 20), size: size).dictionaryRepresentation as NSDictionary]
    }

    @Test func globalTopLeftConvertsToAppKitBottomLeft() {
        let rect = WindowGeometry.appKitRect(fromGlobal: CGRect(x: 100, y: 50, width: 400, height: 300), primaryHeight: 1080)
        #expect(rect == CGRect(x: 100, y: 730, width: 400, height: 300))
    }

    @Test func globalRectMapsIntoEachScreenOverlay() {
        let window = CGRect(x: 2000, y: 50, width: 400, height: 300)
        // 主显示器 1920×1080：本地坐标与全局坐标一致。
        #expect(WindowGeometry.localRect(window, in: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080) == window)
        // 右侧显示器 1440×900，AppKit 坐标下底边在 y = 180（顶边与主显示器齐平）：全局左上角原点为 (1920, 0)。
        let right = CGRect(x: 1920, y: 180, width: 1440, height: 900)
        #expect(WindowGeometry.localRect(window, in: right, primaryHeight: 1080) == CGRect(x: 80, y: 50, width: 400, height: 300))
        // 右侧显示器底边与主显示器齐平时，其顶边在全局坐标中位于 y = 180。
        let rightBottomAligned = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        #expect(WindowGeometry.localRect(window, in: rightBottomAligned, primaryHeight: 1080) == CGRect(x: 80, y: -130, width: 400, height: 300))
    }

    @Test func frontmostSkipsOwnProcessNonNormalLayersAndTinyWindows() {
        let list: [[String: Any]] = [
            entry(pid: 1, number: 11, layer: 25),                 // 菜单栏等高层窗口
            entry(pid: 42, number: 12),                            // 自身进程
            entry(pid: 7, number: 13, alpha: 0),                   // 隐形窗口
            entry(pid: 7, number: 14, size: CGSize(width: 10, height: 10)),
            entry(pid: 9, number: 15),
            entry(pid: 8, number: 16),
        ]
        let front = WindowGeometry.frontmostWindow(in: list, excluding: 42)
        #expect(front?.pid == 9 && front?.windowID == 15)
        #expect(WindowGeometry.frontmostWindow(in: [entry(pid: 42, number: 1)], excluding: 42) == nil)
    }
}
