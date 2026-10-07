import Foundation
import Observation
import EditingCore

/// 画布预设：把比例、背景、留白、圆角、阴影与裁切保存为可复用的一组；自定义图片属于工程，不进预设。
struct CanvasPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layout: CanvasLayout
}

@MainActor @Observable
final class CanvasPresetStore {
    static let shared = CanvasPresetStore()
    private static let key = "canvas.presets"
    private(set) var presets: [CanvasPreset]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = (try? JSONDecoder().decode([CanvasPreset].self, from: defaults.data(forKey: Self.key) ?? Data())) ?? []
    }

    func save(name: String, layout: CanvasLayout) {
        var stored = layout
        stored.backgroundImage = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = CanvasPreset(name: trimmed.isEmpty ? String(localized: "预设 \(presets.count + 1)") : trimmed, layout: stored)
        presets.removeAll { $0.name == preset.name }
        presets.append(preset)
        persist()
    }

    func remove(_ preset: CanvasPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        defaults.set((try? JSONEncoder().encode(presets)) ?? Data(), forKey: Self.key)
    }
}
