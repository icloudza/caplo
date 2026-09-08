import CoreImage
import Testing
import EditingCore
@testable import RenderKit

/// 摄像头画中画始终叠在录制画面之上：时间线行序把摄像头排在画面之后（新默认）也一样，行序只描述布局。
@Test func cameraOverlayStaysAboveScreenRegardlessOfRowOrder() throws {
    var edit = VideoEdit(duration: 8)
    edit.prepareLayerEditing(camera: true, system: false, microphone: false)
    edit.layout.padding = 0; edit.layout.cornerRadius = 0; edit.layout.shadow = false
    var layout = CameraLayout(); layout.shape = .roundedRectangle; layout.shadow = false; layout.size = 0.4
    edit.camera = layout
    let screen = edit.clips[0].id, camera = try #require(edit.cameraClips?.first?.id)
    let size = CGSize(width: 320, height: 180), bounds = CGRect(origin: .zero, size: size)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
    let cameraImage = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
    let context = CIContext()
    func counts(order: [UUID]) -> (green: Int, red: Int) {
        var value = edit; value.layerOrder = order
        let frame = SceneRenderer.frame(source: source, edit: value, time: 1, size: size, camera: cameraImage)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(frame, toBitmap: &bytes, rowBytes: 320 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var green = 0, red = 0
        for o in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[o + 1] > 150 && bytes[o] < 80 { green += 1 } else if bytes[o] > 150 && bytes[o + 1] < 80 { red += 1 }
        }
        return (green, red)
    }
    let below = counts(order: [screen, camera]), above = counts(order: [camera, screen])
    #expect(below.green > 2000 && below.red > 30000, "摄像头行在画面之下时画中画仍在画面之上：\(below)")
    #expect(below == above, "行序不影响叠放次序")
}
