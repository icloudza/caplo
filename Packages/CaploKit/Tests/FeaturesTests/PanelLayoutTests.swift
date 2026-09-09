import AppKit
import SwiftUI
import Testing
import ProjectKit
import EditingCore
import CaploDesignSystem
@testable import Features

/// 属性面板的宽度必须是常数：展开一段文字、滚动条冒出来、某个控件的最小宽度偏大，
/// 都不能把整列的宽度顶来顶去（表现是预设格子跟着一起变宽变窄）。
extension WindowLifecycleTests {
    /// 面板里塞一个远超列宽的子视图，同一列里其它控件的宽度不能受影响。
    @Test func panelContentColumnIgnoresAnOversizedChild() {
        _ = NSApplication.shared
        for oversized in [false, true] {
            let host = NSHostingView(rootView: PanelContainer("宽度") {
                CaliperSlider("探针", value: .constant(0.5), configuration: .editorPercent(0...1)).frame(height: 24)
                if oversized { Color.red.frame(width: 900, height: 8) }
            })
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 400)
            host.layoutSubtreeIfNeeded()
            let caliper = allPanelSubviews(of: host).compactMap { $0 as? CaliperView }.first
            #expect(caliper?.bounds.width == CaploMetrics.panelContentWidth,
                    "塞了超宽子视图 \(oversized) 时列宽变成了 \(caliper?.bounds.width ?? -1)")
        }
    }

    /// 时间线上选中一段文字（面板从"空着"变成"显示这一段的参数"）前后，面板列宽与列内控件宽度完全一致。
    ///
    /// 用户遇到的那一幕是「始终显示滚动条」（接鼠标时系统也会切过去）下才有：内容变高、
    /// 传统滚动条冒出来吃掉 17 点，列宽当场从 268 掉到 251，整列含预设格子跟着重排。
    /// 这里尽量把进程切到传统滚动条再测——AppKit 只在首次取用时解析这个偏好，整套跑时可能已经被别的用例定死成浮层，
    /// 那样这条就只剩浮层下的弱断言；机制本身由上面那条超宽子视图的用例守着，单独跑这条能看到 268 → 251。
    @Test func selectingATextKeepsThePanelWidth() async throws {
        _ = NSApplication.shared
        let scrollerKey = "AppleShowScrollBars"
        let previousScrollers = UserDefaults.standard.object(forKey: scrollerKey)
        UserDefaults.standard.set("Always", forKey: scrollerKey)
        defer {
            if let previousScrollers { UserDefaults.standard.set(previousScrollers, forKey: scrollerKey) }
            else { UserDefaults.standard.removeObject(forKey: scrollerKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        defer { model.close() }
        await model.open()
        for _ in 0..<300 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        var edit = model.edit
        var text = TextSegment(start: 0, duration: 2, text: "产品演示")
        text.timelineStart = 0.2
        text.layout = .splitLeft
        edit.addText(text)
        model.commit { $0 = edit }
        let id = try #require(model.edit.textList.first?.id)

        let host = NSHostingView(rootView: TextPanelProbe(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 1600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        // 面板一出现就会自动选中第一段，所以先量"选中"这一态，再手动清掉选中量"空着"那一态。
        var columns: [CGFloat] = []
        var rows: [Bool: Set<CGFloat>] = [:]
        var segments: [CGFloat] = []
        for selected in [true, false] {
            model.selectedText = selected ? id : nil
            host.layoutSubtreeIfNeeded()
            // 第一支卡尺是列宽探针（排在面板内容前面），其余都是那一段的参数行。
            let subviews = allPanelSubviews(of: host)
            let calipers = subviews.compactMap { ($0 as? CaliperView)?.bounds.width }
            columns.append(try #require(calipers.first))
            rows[selected] = Set(calipers.dropFirst())
            // 版式那一排四个中文选项：标题另起一行之后它才占得满整行，挤在同一行会被压窄、标题竖排成两个字。
            segments += subviews.filter { String(describing: type(of: $0)).hasSuffix("SwiftUISegmentedControl") }.map(\.bounds.width)
        }
        // 选没选中，列宽一模一样，并且就是写死的那个值。
        #expect(columns == [CaploMetrics.panelContentWidth, CaploMetrics.panelContentWidth], "列宽 \(columns)")
        // 选中那一段的参数行彼此等宽，且不超出列宽；没选中时没有参数行。
        let selectedRows = try #require(rows[true])
        #expect(selectedRows.count == 1, "参数行宽度不一致：\(selectedRows)")
        #expect(selectedRows.allSatisfy { $0 <= CaploMetrics.panelContentWidth })
        #expect(rows[false]?.isEmpty == true)
        // AppKit 的分段控件会比 SwiftUI 给的框略宽几点，所以比的是"没被压回最小宽度"，不是逐点相等。
        let row = try #require(selectedRows.first)
        #expect(segments.count == 1 && segments.allSatisfy { $0 >= row && $0 <= CaploMetrics.panelContentWidth },
                "版式选择器被挤窄了：\(segments)，行宽 \(row)")
    }

    private func allPanelSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allPanelSubviews(of: $0) }
    }
}

/// 只要面板本体，不带播放器与时间线，测宽度足够。
private struct TextPanelProbe: View {
    let model: VideoEditorModel
    var body: some View {
        PanelContainer("文字层") {
            CaliperSlider("列宽探针", value: .constant(0.5), configuration: .editorPercent(0...1)).frame(height: 24)
            TextPanel(model: model)
        }
    }
}
