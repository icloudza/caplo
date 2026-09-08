import Testing
import Foundation
@testable import EditingCore

@Test func cameraLayoutStaysInsideEveryCanvasAndValidatesPersistentValues() throws {
    var layout = CameraLayout()
    for shape in CameraLayout.Shape.allCases {
        layout.shape = shape
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 2160, height: 2160)] {
            for corner in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                layout.x = corner.0; layout.y = corner.1; layout.size = 0.45
                let rect = layout.rect(in: size)
                #expect(CGRect(origin: .zero, size: size).contains(rect))
                #expect(abs(rect.width / min(size.width, size.height) - 0.45) < 0.001)
                if layout.y == 0 { #expect(rect.midY > size.height / 2) }
            }
        }
    }
    var edit = VideoEdit(duration: 5); edit.camera = layout
    try edit.validate(sourceDuration: 5)
    let restored = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
    #expect(restored == edit)
    var history = EditHistory(); history.record(edit)
    edit.camera?.mirrored.toggle()
    #expect(history.undo(current: edit) == restored)
    edit.camera?.size = .nan
    #expect(throws: EditError.self) { try edit.validate(sourceDuration: 5) }
}
