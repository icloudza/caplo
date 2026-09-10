import Foundation
import Testing
@testable import EditingCore
/// 背景：预设按名字存、自定义按 hex 存，认不出的名字退回默认档；旧工程存过的档不能因此打不开。
@Test func backgroundPresetsAndCustomColoursRoundTrip() throws {
    // 面板顺序的头一档就是 Cap 的第二个预设（青到琥珀），最后一档是日出。
    #expect(CanvasBackground.gradients.first == .shoal && CanvasBackground.gradients.last == .sunrise)
    #expect(CanvasBackground.gradients.count == 16 && CanvasBackground.solids.count == 8)
    // 撤掉的两档不在面板上：森林只为旧工程留着，仍然画得出颜色。
    #expect(!CanvasBackground.gradients.contains(.forest))
    #expect(CanvasBackground.forest.colors.start.green > 0.15 && !CanvasBackground.forest.isSolid)
    // 预设的色标就是 Cap 那一套。
    let iris = CanvasBackground.iris.colors
    #expect(abs(iris.start.red - 69.0 / 255) < 0.002 && abs(iris.end.blue - 179.0 / 255) < 0.002)
    // 纯色档两端同色。
    #expect(CanvasBackground.solidWhite.isSolid && !CanvasBackground.solidWhite.isCustom)

    // 自定义渐变：两端不同存成一对 hex，读回来分毫不差。
    let custom = CanvasBackground(start: (red: 0.2, green: 0.6, blue: 1), end: (red: 1, green: 0, blue: 0.5))
    #expect(custom.rawValue == "#3399FF-#FF0080" && custom.isCustom && !custom.isSolid)
    #expect(abs(custom.colors.end.blue - 0.502) < 0.005)
    // 两端同色就是一个自定义纯色。
    let flat = CanvasBackground(start: (red: 0.1, green: 0.1, blue: 0.1), end: (red: 0.1, green: 0.1, blue: 0.1))
    #expect(flat.rawValue == "#1A1A1A" && flat.isSolid && flat.isCustom)
    // 分量越界先钳。
    #expect(CanvasBackground(start: (red: -1, green: 2, blue: 0.5), end: (red: 0, green: 0, blue: 0)).rawValue == "#00FF80-#000000")

    // 工程文件里仍然只是一个字符串。
    var layout = CanvasLayout(); layout.background = custom
    let data = try JSONEncoder().encode(layout)
    #expect(String(data: data, encoding: .utf8)?.contains("\"background\":\"#3399FF-#FF0080\"") == true)
    #expect(try JSONDecoder().decode(CanvasLayout.self, from: data).background == custom)

    // 认不出的名字（改过名、或来自更新的版本）按默认档画，不返回一片黑。
    let unknown = CanvasBackground(rawValue: "还没有的档")
    #expect(unknown.colors.start == CanvasBackground.iris.colors.start && !unknown.isCustom)
}
