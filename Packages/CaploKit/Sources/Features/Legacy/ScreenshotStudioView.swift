import SwiftUI
import AppKit
import CaploDesignSystem
import EditingCore
import RenderKit

/// 图片样式复用画布规范；截图与标注入口保留明确的未接通状态，避免可点但无结果的工具。
public struct ScreenshotStudioView: View {
    @State private var image: NSImage?
    @State private var filename = "图片与截图"
    @State private var layout = CanvasLayout()
    @State private var error: String?
    public init() {}
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(filename).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { importImage() } label: { Label("导入图片", systemImage: "photo.badge.plus") }.buttonStyle(CaploButtonStyle(prominent: true))
                Button("截取屏幕") {}.disabled(true).help("截图采集将在后续版本接通")
            }.buttonStyle(CaploButtonStyle()).padding(18).background(StudioSurface(raised: true))
            StudioDivider()
            HStack(spacing: 0) {
                ZStack {
                    StudioSurface()
                    if let image { CanvasPreview(layout: layout, image: image).padding(32) }
                    else {
                        VStack(spacing: 14) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38, weight: .light)).foregroundStyle(CaploStyle.accent)
                            Text("给画面一个好背景").font(.system(size: 20, weight: .medium))
                            Text("导入图片，预览比例、留白与圆角。") .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("选择图片") { importImage() }.buttonStyle(CaploButtonStyle())
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                StudioDivider(vertical: true)
                LayoutInspector(layout: $layout).frame(width: 260).background(StudioSurface(raised: true))
            }
            StudioDivider()
            HStack(spacing: 12) {
                ForEach([("箭头", "arrow.up.right"), ("文字", "textformat"), ("图形", "rectangle"), ("遮挡", "square.fill")], id: \.0) { title, symbol in
                    Button {} label: { Label(title, systemImage: symbol) }.disabled(true)
                }
                Spacer()
                Text("标注与图片导出尚未接通").font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(CaploButtonStyle()).padding(12).background(StudioSurface(raised: true))
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }.frame(minWidth: 850, minHeight: 600)
            .tint(CaploStyle.accent)
            .preferredColorScheme(.dark)
    }
    private func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let loaded = NSImage(contentsOf: url), loaded.isValid else { error = "图片无法读取。"; return }
        image = loaded; filename = url.lastPathComponent; error = nil
    }
}
