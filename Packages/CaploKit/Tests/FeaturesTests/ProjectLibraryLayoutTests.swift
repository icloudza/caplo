import AppKit
import SwiftUI
import Testing
import ProjectKit
@testable import Features

@MainActor
struct ProjectLibraryLayoutTests {
    @Test func libraryListStaysBelowUnifiedTopBar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caplo-library-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectStorage.create(in: root, name: "布局检查")
        let window = StudioWindows.make(title: "布局检查", content: ProjectLibraryView(previewOnly: true, previewProjectURL: project),
                                        size: CGSize(width: 900, height: 620), chrome: .unifiedTitle)
        defer { window.close() }
        window.orderFront(nil)
        let host = try #require(window.contentView?.subviews.first)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        let scroll = try #require(find(host))
        let frameInWindow = scroll.convert(scroll.bounds, to: nil as NSView?)
        let contentHeight = window.contentView!.bounds.height
        print("scroll frame in window:", frameInWindow, "window content height:", contentHeight, "insets:", scroll.contentInsets, "auto:", scroll.automaticallyAdjustsContentInsets)
        if let out = ProcessInfo.processInfo.environment["CAPLO_LAYOUT_PNG"], let content = window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        // 列表必须整体位于 52 点顶栏之下，且没有被系统标题栏再插入一层内边距。
        #expect(frameInWindow.maxY <= contentHeight - 52 + 0.5)
        #expect(scroll.contentInsets.top == 0)
    }
}
