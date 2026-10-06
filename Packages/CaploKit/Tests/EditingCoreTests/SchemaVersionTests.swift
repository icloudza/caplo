import Foundation
import Testing
@testable import EditingCore

/// 版本号只有两个合法取值：5（连续拼接）和 6（图层模型）。
/// 叠加层不再各自升一档——旧版本打开只会少画一层，为此把工程标成"打不开"得不偿失。
/// 唯一该写 `schemaVersion` 的地方是 `normalizeSchemaVersion(layered:)`；
/// 到处手写数字曾经让"添加遮罩"直接报"版本不支持"。
private func recordingLikeEdit() -> VideoEdit {
    var edit = VideoEdit(duration: 8)
    // 自动镜头存在原素材域（timelineStart 为空），这是触发 prepareLayerEditing 的条件。
    edit.focuses = [FocusSegment(start: 1, duration: 2, x: 0.5, y: 0.5, automatic: true)]
    return edit
}

@Test func projectsSavedDuringDevelopmentStillOpenAndFallBack() throws {
    var edit = recordingLikeEdit()
    edit.addMask(MaskSegment(start: 0, duration: 2, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    // 开发期间存成过 7 / 8 / 9 的工程照常打开。
    for version in 5...VideoEdit.maximumSchemaVersion {
        var copy = edit; copy.schemaVersion = version
        try copy.validate(sourceDuration: 8)
    }
    // 再存一次就落回 6。
    var legacy = edit; legacy.schemaVersion = 9
    legacy.normalizeSchemaVersion()
    #expect(legacy.schemaVersion == VideoEdit.writtenSchemaVersion)
    // 完全未知的版本仍然拒绝，不能拿不认识的数据去覆盖用户文件。
    for version in [0, 4, VideoEdit.maximumSchemaVersion + 1, 200] {
        var copy = edit; copy.schemaVersion = version
        #expect(throws: EditError.self) { try copy.validate(sourceDuration: 8) }
    }
}

