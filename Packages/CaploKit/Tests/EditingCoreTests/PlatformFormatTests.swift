import Foundation
import Testing
@testable import EditingCore

@Test func platformFormatsAreUniqueAndCoverEveryOrientation() {
    let ids = PlatformFormat.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    var grouped = 0
    for orientation in CanvasRatio.Orientation.allCases {
        let formats = PlatformFormat.formats(in: orientation)
        #expect(!formats.isEmpty)
        #expect(formats.allSatisfy { $0.ratio.orientation == orientation && !$0.platform.isEmpty && !$0.usage.isEmpty })
        grouped += formats.count
    }
    // 三组正好覆盖全部平台，没有平台被分组漏掉或重复。
    #expect(grouped == PlatformFormat.all.count)
    #expect(CanvasRatio.widescreen.orientation == .landscape && CanvasRatio.tall.orientation == .portrait && CanvasRatio.square.orientation == .square)
    #expect(PlatformFormat.format(id: "douyin.portrait")?.title == "抖音 · 竖屏 9:16")
    #expect(PlatformFormat.format(id: "missing") == nil)
    // 只经平台进入的比例必须有平台可显示。
    for ratio in CanvasRatio.allCases where !CanvasRatio.common.contains(ratio) {
        #expect(PlatformFormat.first(matching: ratio) != nil)
    }
}

@Test func platformFormatsMatchRecommendedOutputSizes() throws {
    let expected: [(id: String, width: Int, height: Int)] = [
        ("douyin.portrait", 1080, 1920), ("bilibili.landscape", 1920, 1080), ("xiaohongshu.tall", 1080, 1440),
        ("channels.tall", 1080, 1260), ("instagram.feed", 1080, 1350), ("instagram.square", 1080, 1080),
        ("youtube.shorts", 1080, 1920), ("linkedin.landscape", 1920, 1080),
    ]
    for item in expected {
        let format = try #require(PlatformFormat.format(id: item.id))
        let size = format.ratio.outputSize(shortEdge: 1080)
        #expect(size.width == item.width && size.height == item.height, "\(item.id)")
    }
}

@Test func ratioValuesMatchNamesAndOutputSizesStayEven() throws {
    for ratio in CanvasRatio.allCases {
        let parts = ratio.rawValue.split(separator: ":").compactMap { Double($0) }
        #expect(parts.count == 2)
        #expect(abs(ratio.value - parts[0] / parts[1]) < 1e-9)
        let data = try JSONEncoder().encode(ratio)
        #expect(try JSONDecoder().decode(CanvasRatio.self, from: data) == ratio)
        for edge in [1080, 2160] {
            let size = ratio.outputSize(shortEdge: edge)
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
            #expect(min(size.width, size.height) == edge)
        }
    }
    #expect(Set(CanvasRatio.common).count == CanvasRatio.common.count)
    let ultrawide = CanvasRatio.ultrawide.outputSize(shortEdge: 2160)
    #expect(ultrawide.width == 5040 && ultrawide.height == 2160)
    let standard = CanvasRatio.standard.outputSize(shortEdge: 1080)
    #expect(standard.width == 1440 && standard.height == 1080)
}
