import CRNNoise
import Foundation

/// RNNoise（2017 版小模型，约 9 万参数）：48 kHz、480 样本一帧的循环神经网络降噪，输入输出都是 16 位整数量程的浮点。
final class RNNoiseFilter {
    static let frame = 480
    private let state: OpaquePointer
    init() { state = rnnoise_create(nil) }
    deinit { rnnoise_destroy(state) }

    /// 整段处理：不足一帧的尾巴补零；模型的合成窗有一帧（10 毫秒）的固有延迟，输出已提前一帧对齐输入。
    func process(_ signal: [Float]) -> [Float] {
        let frame = Self.frame
        let frames = (signal.count + frame - 1) / frame + 1
        var output = [Float](repeating: 0, count: frames * frame)
        var input = [Float](repeating: 0, count: frame), result = [Float](repeating: 0, count: frame)
        for index in 0..<frames {
            for offset in 0..<frame {
                let position = index * frame + offset
                input[offset] = position < signal.count ? signal[position] * 32_768 : 0
            }
            _ = rnnoise_process_frame(state, &result, input)
            for offset in 0..<frame { output[index * frame + offset] = result[offset] / 32_768 }
        }
        // 去掉一帧延迟：输出第 k 帧对应输入第 k-1 帧。
        return Array(output[frame..<(frame + signal.count)])
    }
}
