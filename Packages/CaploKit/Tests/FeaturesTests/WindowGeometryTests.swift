import AppKit
import Testing
@testable import Features
import CaploDesignSystem

/// 窗口高亮的几何换算与最前窗口判定，全部使用合成数据，不读取真实窗口列表。
struct WindowGeometryTests {
    private func entry(pid: Int, number: Int, layer: Int = 0, alpha: Double = 1, size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(origin: CGPoint(x: 10, y: 20), size: size).dictionaryRepresentation as NSDictionary]
    }

    /// 录制条摆在目标框（区域或窗口）正下方，放不下就正上方；上下都放不下（最大化的浏览器窗口）时
    /// 贴屏幕底部，和全屏模式同一位置——以前会被钳到屏幕最上面，压住目标窗口的标签栏与地址栏。
    @MainActor @Test func recordBarFallsBackToTheScreenBottomWhenTheTargetFillsTheScreen() {
        // 14 寸屏：菜单栏 33 点，程序坞 70 点。目标框用显示器本地左上角坐标。
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
        let panel = CGSize(width: 860, height: 100)
        let bar = CaploMetrics.floatingBarHeight, inset = CaploMetrics.floatingBarInset
        func origin(_ region: CGRect) -> CGPoint { StudioWindows.recordBarOrigin(near: region, screenFrame: screen, visible: visible, panelSize: panel) }

        // 屏幕中间的小窗口：录制条在它正下方，不压窗口。
        let small = CGRect(x: 300, y: 300, width: 800, height: 400)
        let below = origin(small)
        #expect(below.y + inset + bar <= screen.maxY - small.maxY, "录制条压到了窗口下沿")
        #expect(abs(below.x + panel.width / 2 - (small.midX)) < 0.5, "录制条没有对准窗口中线")

        // 贴着屏幕底部的窗口：下方放不下，放到它正上方。
        let low = CGRect(x: 200, y: 500, width: 900, height: 440)
        let above = origin(low)
        #expect(above.y + inset >= screen.maxY - low.minY, "录制条压到了窗口上沿")
        #expect(above.y + panel.height <= visible.maxY)

        // 最大化的窗口：上下都放不下，贴屏幕底部（程序坞上方），绝不顶到屏幕最上面。
        let maximized = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let docked = origin(maximized)
        #expect(docked.y == visible.minY + CaploMetrics.Spacing.xl - inset, "最大化窗口时录制条在 \(docked.y)，没有贴到屏幕底部")
        #expect(docked.y + panel.height < visible.maxY - 300, "录制条跑到了屏幕上半部")
        #expect(abs(docked.x - (visible.midX - panel.width / 2)) < 0.5)
    }

}
