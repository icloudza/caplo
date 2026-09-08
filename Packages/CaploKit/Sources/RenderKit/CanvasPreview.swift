import SwiftUI
import AppKit
import EditingCore

/// 图片样式预览；与视频共享布局模型和背景调色板。视频的像素合成由 SceneRenderer 独立承载。
public struct CanvasPreview: View {
    let layout: CanvasLayout
    let image: NSImage?

    public init(layout: CanvasLayout, image: NSImage? = nil) {
        self.layout = layout
        self.image = image
    }

    public var body: some View {
        GeometryReader { proxy in
            // 留白和圆角以 960 点画布为参考缩放，避免预览窗口尺寸改变相对样式。
            let size = LayoutGeometry.fittedSize(
                content: image?.size ?? CGSize(width: 1440, height: 900),
                inside: proxy.size,
                padding: layout.padding * proxy.size.width / 960
            )
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        DemoContent()
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius * proxy.size.width / 960))
                .shadow(color: .black.opacity(layout.shadow ? layout.shadowOpacity * 0.85 : 0),
                        radius: layout.shadowBlur * proxy.size.width / 960 * 1.3, y: layout.shadowOffset * proxy.size.width / 960)
            }
        }
        .aspectRatio(layout.ratio.value, contentMode: .fit)
        .clipped()
        .accessibilityLabel(image == nil ? "演示画布，尚未载入素材" : "已导入的图片预览")
    }

    private var colors: [Color] {
        let palette = SceneRenderer.palette(layout.background)
        return [palette.0, palette.1].map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }
}

private struct DemoContent: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.75)).frame(width: 7, height: 7)
                }
                Spacer()
                Text("让每一次演示，更清楚。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(index == 0 ? 0.13 : 0.05))
                            .frame(width: 50, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.025))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ideas into motion.")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text("捕捉灵感，专注表达。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: 8)
                                .fill([Color.purple, .blue, .orange][index].opacity(0.12))
                                .overlay(Image(systemName: ["cursorarrow.rays", "rectangle.on.rectangle", "sparkles"][index])
                                    .foregroundStyle(.secondary))
                        }
                    }
                    .frame(maxHeight: 70)
                    Text("示例内容 · 仅用于布局预览")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
