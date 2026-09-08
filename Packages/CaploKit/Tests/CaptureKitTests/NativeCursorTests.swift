import AppKit
import Testing
import EditingCore
import ProjectKit
@testable import CaptureKit

@Test @MainActor func nativeCursorPersistsHotspotScaleAndMovesWithProject() throws {
    let asset = try #require(NativeCursorCapture.capture(NSCursor.pointingHand))
    #expect(asset.isValid)
    #expect(abs(asset.hotspotX / asset.scale - NSCursor.pointingHand.hotSpot.x) < 0.001)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try ProjectStorage.create(in: root, name: "原始光标")
    try CursorStorage.save(asset, in: original); try CursorStorage.save(asset, in: original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: original.appendingPathComponent("Cursors").path).count == 1)
    let moved = root.appendingPathComponent("moved.caplo")
    try FileManager.default.moveItem(at: original, to: moved)
    #expect(CursorStorage.load(ids: [asset.id, "../../outside"], in: moved) == [asset.id: asset])
    let other = CapturedCursor(png: asset.png, width: asset.width, height: asset.height, hotspotX: 0, hotspotY: 0, scale: asset.scale)
    #expect(other.id != asset.id)
    try Data("broken".utf8).write(to: moved.appendingPathComponent("Cursors/\(asset.id).json"))
    #expect(CursorStorage.load(ids: [asset.id], in: moved).isEmpty)
}
