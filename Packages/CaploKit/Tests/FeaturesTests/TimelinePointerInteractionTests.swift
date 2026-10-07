import AppKit
import AVFoundation
import SwiftUI
import CaploDesignSystem
import EditingCore
import ProjectKit
import Testing
@testable import Features

extension WindowLifecycleTests {

    private func makeTimelinePointerModel(root: URL) async throws -> VideoEditorModel {
        _ = NSApplication.shared
        let url = try await makeEditorFixture(root: root)
        let model = VideoEditorModel(entry: LibraryEntry(url: url, document: try ProjectStorage.load(url)))
        await model.open()
        do {
            try await waitForTimelinePointer { model.ready && !model.loading && model.player.currentItem?.status == .readyToPlay }
            return model
        } catch { model.close(); throw error }
    }

    private func waitForTimelinePointer(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimelinePointerCheckError.timeout
    }
}

private enum TimelinePointerCheckError: Error { case timeout }

/// 直接向测试进程自己的 NSView 发送事件，不控制桌面，也不依赖用户鼠标位置或系统输入权限。
@MainActor
private final class TimelinePointerHarness {
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let view: TimelineViewportView
    let window: NSWindow

    init(model: VideoEditorModel, zoom: Double, snapping: Bool = false) {
        self.model = model
        viewport = TimelineViewport(); viewport.zoom = zoom; viewport.snapping = snapping
        view = TimelineViewportView(model: model, viewport: viewport)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 250)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        sync()
    }

    func sync() {
        view.update(edit: model.edit, analysis: model.analysis, selection: model.selectedClipIDs,
                    primary: model.selectedClip, focus: model.selectedFocus, mask: model.selectedMask, text: model.selectedText, caption: model.selectedCaption, zoom: viewport.zoom, fit: 1)
    }

    func mouse(_ type: NSEvent.EventType, x: Double, y: Double) throws {
        let location = view.convert(CGPoint(x: x, y: y), to: nil)
        let event: NSEvent
        if type == .mouseExited {
            event = try #require(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        } else {
            event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        case .mouseExited: view.mouseExited(with: event)
        default: Issue.record("测试不支持该鼠标事件")
        }
        sync()
    }

    func close() {
        view.detach(); window.contentView = nil; window.close()
    }
}

extension WindowLifecycleTests {
    /// 右键菜单按块的种类给操作；落点分割用的是右键位置的时间，播放头分割在块边缘时禁用。
    @Test func rightClickOnASplittableBlockOffersSplitAtClickAndPlayhead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        let harness = TimelinePointerHarness(model: model, zoom: 0)
        defer { harness.close() }
        let id = try #require(model.edit.clips.first?.id)
        // 素材 4 秒，从起点算 2 秒处右键：两侧各 2 秒，可以分割。
        let x = TimelineViewportView.timeOrigin + 2 * 60
        let location = harness.view.convert(CGPoint(x: x, y: 49), to: nil as NSView?)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(harness.view.menu(for: event))
        // 录制画面块：能分割、能在落点添加聚焦 / 遮罩 / 文字；删除单独放在最后。
        #expect(menu.items.first { $0.title == "在此处添加" }?.submenu?.items.count == 3)
        #expect(menu.items.last?.title == "删除")
        let here = try #require(menu.items.first { $0.title.hasPrefix("在此处分割") })
        let clicked = try #require(here.representedObject as? Double)
        #expect(here.isEnabled)
        #expect(abs(clicked - 2) < 0.02)
        #expect(model.selectedClip == id)
        let action = try #require(here.action)
        #expect(NSApplication.shared.sendAction(action, to: here.target, from: here))
        harness.sync()
        #expect(model.edit.clips.count == 2)
        let head = try #require(model.edit.clips.first { $0.id == id })
        #expect(abs(head.duration - 2) < 0.02)
        // 播放头在 0 秒：块起点处不能分割，菜单项禁用。
        model.seek(0)
        let again = try #require(harness.view.menu(for: event))
        #expect(again.items.first { $0.title == "在播放头分割" }?.isEnabled == false)
    }
}

extension WindowLifecycleTests {

    /// 选中互斥：面板自动选中、面板里的删除按钮、⌘A 以前都只写自己那一项，别的类别留着旧选中，
    /// 删除键按"字幕 → 文字 → 遮罩 → 素材 → 镜头"的优先级挑，会删掉一个看不见的东西。
    @Test func selectionsAreExclusiveSoDeleteRemovesWhatIsShown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeTimelinePointerModel(root: root)
        defer { model.close() }
        model.seek(0.5); let mask = try #require(model.addMask())
        model.seek(1.5); model.addFocus()
        let focus = try #require(model.selectedFocus)
        model.select(.mask(mask))

        // 镜头面板里点"删除此镜头"：删的必须是镜头，遮罩不动。
        model.select(.focus(focus)); model.deleteSelection()
        #expect(!model.edit.focuses.contains { $0.id == focus }, "删除此镜头没有删掉镜头")
        #expect(model.edit.mask(id: mask) != nil, "删除此镜头删掉的是还选着的遮罩")

        // ⌘A 全选画面片段：遮罩的选中要清掉，否则删除键先删遮罩。
        model.select(.mask(mask))
        let harness = TimelinePointerHarness(model: model, zoom: 1)
        defer { harness.close() }
        harness.window.makeFirstResponder(harness.view)
        let selectAll = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: harness.window.windowNumber,
                                                      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        harness.view.keyDown(with: selectAll)
        #expect(model.selectedMask == nil, "⌘A 之后遮罩还处于选中")
        #expect(model.selectedClipIDs == Set(model.edit.clips.map(\.id)))

        // 改键：与同范围或全局命令撞键的组合不收；改成功后时间线按新键分派，旧键不再触发。
        let shortcuts = ShortcutStore.shared
        defer { shortcuts.resetAll() }
        #expect(shortcuts.problem(assigning: KeyCombo("b", command: true), to: .selectAllClips) != nil, "和分割撞键的 ⌘B 被收下了")
        #expect(shortcuts.problem(assigning: KeyCombo("n", command: true), to: .selectAllClips) != nil, "和全局新建录制撞键的 ⌘N 被收下了")
        #expect(shortcuts.problem(assigning: KeyCombo("k"), to: .selectAllClips) == nil)
        shortcuts.assign(KeyCombo("k"), to: .selectAllClips)
        model.selectedClipIDs = []; model.selectedClip = nil
        harness.view.keyDown(with: selectAll)
        #expect(model.selectedClipIDs.isEmpty, "改键后旧的 ⌘A 还在全选")
        let remapped = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
                                                     context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        harness.view.keyDown(with: remapped)
        #expect(model.selectedClipIDs == Set(model.edit.clips.map(\.id)), "改成 K 之后按 K 没有全选")
    }

}

