import Foundation
import Testing
import CaptureKit
@testable import Features

/// 开始录制在前置检查就退出（来源失效、来源还在读取）时，上一段录制的 completedURL 还在；
/// 只看它是否为空会判断成"录完了、交给编辑器"，结果准备窗口已藏、录制条不回来，屏幕上什么都没有。
@MainActor @Test func recordBarComesBackWhenStartExitsWithoutANewProject() {
    let earlier = URL(fileURLWithPath: "/tmp/上一段.caplo"), fresh = URL(fileURLWithPath: "/tmp/这一段.caplo")
    #expect(RecordBarModel.shouldReturnToBar(busy: false, completed: earlier, before: earlier), "没产出新工程，录制条应当回来")
    #expect(RecordBarModel.shouldReturnToBar(busy: false, completed: nil, before: nil))
    #expect(!RecordBarModel.shouldReturnToBar(busy: false, completed: fresh, before: earlier), "产出了新工程，应当交给编辑器")
    #expect(!RecordBarModel.shouldReturnToBar(busy: true, completed: nil, before: nil), "正在录制，不该放回录制条")
}
