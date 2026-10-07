import SwiftUI
import CaploDesignSystem
import EditingCore

/// 画面遮罩：遮罩列表与选中遮罩的参数。
///
/// 敏感遮罩没有"不透明度"这一项，这是故意的：用不透明度淡入淡出等于把原文按比例混回画面，
/// 0.15 秒乘 30 帧就是四帧可读的密钥。要柔化边界请用羽化，那不会让原文重新出现。
struct MaskPanel: View {
    let model: VideoEditorModel

    /// 新建之后直接选中它并滚进视口——面板显示的永远是时间线上选中的那一条。
    private func select(_ id: UUID) { model.select(.mask(id)); model.reveal(id) }

    /// 单条遮罩的参数：类型、遮挡方式与强度、形状与位置，最后是删除。起止时间只在时间线上拖。
    @ViewBuilder private func controls(for id: UUID, mask: MaskSegment) -> some View {
        Picker("类型", selection: kindBinding(id)) {
            Text("盖住内容").tag(MaskSegment.Kind.sensitive)
            Text("高亮区域").tag(MaskSegment.Kind.highlight)
        }.environment(\.colorScheme, .dark)
        if mask.kind == .sensitive {
            Picker("遮挡方式", selection: effectBinding(id)) {
                Text("模糊").tag(MaskSegment.Effect.blur)
                Text("像素化").tag(MaskSegment.Effect.pixelate)
            }.environment(\.colorScheme, .dark)
            EditorFill(model: model, title: "强度", value: amountBinding(id),
                         range: MaskSegment.amountRange, decimals: 0, defaultValue: MaskSegment.defaultAmount)
            if mask.amount < MaskSegment.weakAmount {
                PanelNote("强度偏低，画面里的文字可能仍然认得出来。导出前建议提到 \(Int(MaskSegment.weakAmount)) 以上。")
            }
        } else {
            EditorFill(model: model, title: "周围压暗", value: binding(id, \.darkness),
                         range: 0...0.95, suffix: "%", percentage: true, defaultValue: 0.55)
            EditorStepper(model: model, title: "淡入", value: optionalBinding(id, \.fadeIn, fallback: 0.15), range: 0...1.5, defaultValue: 0.15)
            EditorStepper(model: model, title: "淡出", value: optionalBinding(id, \.fadeOut, fallback: 0.15), range: 0...1.5, defaultValue: 0.15)
        }
        Picker("形状", selection: shapeBinding(id)) {
            Text("矩形").tag(MaskSegment.Shape.rectangle)
            Text("椭圆").tag(MaskSegment.Shape.ellipse)
        }.environment(\.colorScheme, .dark)
        EditorRegion(model: model, title: "区域", shape: .box(minimumSide: 0.02), aspect: model.sourceAspect,
                     region: regionBinding(id), readout: EditorRegion.sizeReadout)
        if mask.shape == .rectangle {
            EditorSlider(model: model, title: "圆角", value: binding(id, \.cornerRadius), range: 0...80, decimals: 0, defaultValue: 0)
        }
        if mask.kind == .sensitive {
            EditorSlider(model: model, title: "羽化", value: binding(id, \.feather), range: 0...60, decimals: 0, defaultValue: 0)
        }
        Button("删除此遮罩") { model.select(.mask(id)); model.deleteSelection() }
            .buttonStyle(StudioButtonStyle(.destructive, size: .small))
    }

    var body: some View {
        PanelSection("遮罩", info: "随画面缩放，剪切后自动拆分") {
            if let id = model.selectedMask, let mask = model.edit.mask(id: id) {
                // 高亮画成"虚线框里有一块亮区"，与敏感遮罩的空心虚线框成对；别写没有的符号名（"spotlight" 不存在，图标会整个空掉）。
                PanelSelection(symbol: mask.kind == .highlight
                               ? (mask.shape == .ellipse ? "circle.dashed.inset.filled" : "square.dashed.inset.filled")
                               : (mask.shape == .ellipse ? "circle.dashed" : "rectangle.dashed"),
                               title: model.edit.maskDisplayTitle(mask, numbers: model.edit.maskNumbers()),
                               trailing: timecode(mask.timelineStart ?? mask.start)) {
                    controls(for: id, mask: mask)
                }
            } else if model.edit.maskList.isEmpty {
                PanelNote("暂无遮罩。用下面的按钮在播放头处添加 2 秒遮罩，然后在画布上拖动它的位置和大小。")
            } else {
                PanelNote("在时间线的遮罩块上点一下，这里就显示那一条的参数。")
            }
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button("添加遮罩") { if let id = model.addMask(kind: .sensitive) { select(id) } }
                    .buttonStyle(StudioButtonStyle(.secondary))
                Button("添加高亮") { if let id = model.addMask(kind: .highlight) { select(id) } }
                    .buttonStyle(StudioButtonStyle(.secondary))
            }
            if model.edit.hasWeakMask {
                PanelNote("有遮罩的强度低于 \(Int(MaskSegment.weakAmount))，导出前请确认它确实盖住了内容。")
            }
        }
        // 进面板时还没选中就先选第一条，免得面板空着、非得先去时间线点一下。
        .onAppear {
            model.maskEditing = true
            selectFirstIfNeeded()
        }
        // 面板可能比工程先出现（直接打开到这个面板时）：载入完成再补选一次。
        .onChange(of: model.ready) { selectFirstIfNeeded() }
        .onDisappear { model.maskEditing = false }
    }

    // MARK: 绑定
    // 滑块直写 model.edit，撤销快照由 EditorSlider 的 begin/endInteraction 负责；
    // 下拉这类离散动作走 commit，一次点击就是一个可撤销步骤。

    private func selectFirstIfNeeded() {
        if model.selectedMask == nil, let first = model.edit.maskList.first?.id { model.select(.mask(first)) }
    }

    /// 遮罩存的是中心与尺寸，底板用左上角与尺寸：两边在这里换算，四个值一次写进去。
    private func regionBinding(_ id: UUID) -> Binding<CGRect> {
        Binding(get: {
            guard let mask = model.edit.mask(id: id) else { return CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2) }
            return CGRect(x: mask.x - mask.width / 2, y: mask.y - mask.height / 2, width: mask.width, height: mask.height)
        }, set: { rect in
            model.edit.updateMask(id: id) { mask in
                mask.x = rect.midX; mask.y = rect.midY; mask.width = rect.width; mask.height = rect.height
            }
        })
    }

    private func binding(_ id: UUID, _ key: WritableKeyPath<MaskSegment, Double>) -> Binding<Double> {
        Binding(get: { model.edit.mask(id: id)?[keyPath: key] ?? 0 }, set: { value in
            model.edit.updateMask(id: id) { $0[keyPath: key] = value }
        })
    }
    private func optionalBinding(_ id: UUID, _ key: WritableKeyPath<MaskSegment, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { model.edit.mask(id: id)?[keyPath: key] ?? fallback }, set: { value in
            model.edit.updateMask(id: id) { $0[keyPath: key] = value }
        })
    }
    /// 强度写的是编码值，所以要经过 `setAmount` 而不是直接赋值。
    private func amountBinding(_ id: UUID) -> Binding<Double> {
        Binding(get: { model.edit.mask(id: id)?.amount ?? MaskSegment.defaultAmount }, set: { value in
            model.edit.updateMask(id: id) { $0.setAmount(value) }
        })
    }
    private func kindBinding(_ id: UUID) -> Binding<MaskSegment.Kind> {
        Binding(get: { model.edit.mask(id: id)?.kind ?? .sensitive }, set: { value in
            model.commit { edit in
                edit.updateMask(id: id) { mask in
                    mask.kind = value
                    // 高亮才有淡入淡出；换成敏感遮罩要把它们清掉，否则两端会有几帧原文透出来。
                    if value == .sensitive { mask.fadeIn = nil; mask.fadeOut = nil }
                    else if mask.fadeIn == nil { mask.fadeIn = 0.15; mask.fadeOut = 0.15 }
                }
            }
        })
    }
    private func effectBinding(_ id: UUID) -> Binding<MaskSegment.Effect> {
        Binding(get: { model.edit.mask(id: id)?.effect ?? .blur }, set: { value in
            model.commit { $0.updateMask(id: id) { $0.setEffect(value) } }
        })
    }
    private func shapeBinding(_ id: UUID) -> Binding<MaskSegment.Shape> {
        Binding(get: { model.edit.mask(id: id)?.shape ?? .rectangle }, set: { value in
            model.commit { $0.updateMask(id: id) { $0.shape = value } }
        })
    }
}
