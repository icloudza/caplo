import Foundation
import CoreGraphics
import Testing
@testable import EditingCore

@Test func portraitContentFitsWithoutCropping() {
    let size = LayoutGeometry.fittedSize(content: CGSize(width: 900, height: 1600), inside: CGSize(width: 960, height: 540), padding: 30)
    #expect(size.height == 480)
    #expect(size.width == 270)
}

@Test func invalidOrExcessiveInsetsProduceEmptyGeometry() {
    #expect(LayoutGeometry.fittedSize(content: .zero, inside: CGSize(width: 960, height: 540), padding: 0) == .zero)
    #expect(LayoutGeometry.fittedSize(content: CGSize(width: 100, height: 100), inside: CGSize(width: 50, height: 50), padding: 100) == .zero)
    #expect(LayoutGeometry.fittedSize(content: CGSize(width: CGFloat.infinity, height: 100), inside: CGSize(width: 50, height: 50), padding: 0) == .zero)
}

@Test func negativeInsetsDoNotExpandContent() {
    #expect(LayoutGeometry.fittedSize(content: CGSize(width: 200, height: 100), inside: CGSize(width: 100, height: 100), padding: -50) == CGSize(width: 100, height: 50))
}

@Test func layoutPreservesUserChoicesAcrossSerialization() throws {
    var layout = CanvasLayout()
    layout.ratio = .portrait
    layout.background = .ocean
    layout.padding = 72
    layout.cornerRadius = 20
    layout.shadow = false
    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(CanvasLayout.self, from: data) == layout)
}
