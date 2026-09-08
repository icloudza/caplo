import Foundation
import AppKit
import Testing
@testable import RenderKit

/// 样式预览在后台渲染：第一次取为空且不阻塞，稍后缓存里就有了；再取直接命中。
@MainActor @Test func cursorPreviewsRenderOffTheMainThreadAndCache() async throws {
    let store = CursorPreviews()
    let started = Date()
    let first = store.image(customStyle: "1-01")
    #expect(first == nil)
    #expect(Date().timeIntervalSince(started) < 0.05)
    var image: NSImage?
    for _ in 0..<200 {
        image = store.image(customStyle: "1-01")
        if image != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let rendered = try #require(image)
    #expect(rendered.size.height > 0 && rendered.size.height <= 44)
    #expect(store.image(customStyle: "1-01") === rendered)
    #expect(store.image(customStyle: "9-99") == nil)
}

/// 预热会在后台把一组的预览全部画好，之后取用直接命中；只加载这一组的素材。
@MainActor @Test func cursorPreviewsWarmUpRendersTheWholeGroup() async throws {
    let assets = CursorAssets.Store()
    let store = CursorPreviews(store: assets)
    store.warmUp(group: .circle)
    let ids = CursorStyle.styles(in: .circle).map(\.id)
    for _ in 0..<400 {
        if ids.allSatisfy({ store.image(customStyle: $0) != nil }) { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ids.allSatisfy { store.image(customStyle: $0) != nil })
    #expect(assets.loadedCount == 10)
}

