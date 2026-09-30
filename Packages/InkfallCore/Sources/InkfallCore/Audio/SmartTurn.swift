import Accelerate
import Foundation

/// Smart Turn v3.2（pipecat 训练，BSD-2）：本机模型听**语调和停顿**判「这句说完了没有」，不看文字。
/// 停顿 0.2 秒时先问它 —— 判没说完就接着听，不花 Groq 的转写额度；判说完了才转写、再问 Jev（2026-09-30 境）。
///
/// 模型本身（CoreML，约 3 ms）在 App 侧跑，这里只把录音器的 PCM 变成它要的样子：
/// 16 kHz 单声道 float、正好 8 秒（128000 个样本），不够的在**前面**补零、最新的在最后。
/// 归一化和 Whisper 的 log-mel 都在模型里。
public enum SmartTurn {
    public static let sampleRate = 16_000.0
    public static let windowSamples = 128_000
    /// 大于它算说完了（模型卡上的阈值）。
    public static let threshold: Float = 0.5

    /// 交错的 16-bit PCM（任意采样率、声道数）→ 16 kHz 单声道、最近 ≤ 8 秒。
    /// 降采样是「每 ratio 个取平均」再按比例取点：Whisper 的 mel 只看 8 kHz 以下，这点低通够用。
    /// 最后一个输出对齐最后一个输入（模型最在意句尾）。
    ///
    /// 全走 vDSP：停顿里每 0.2 秒在主线程上算一次，逐个样本的 Swift 循环在 Debug 构建里
    /// 48 kHz 双声道 8 秒要 190 ms（2026-10-01 实测）。
    public static func window(pcm: Data, sampleRate rate: Double, channels: Int) -> [Float] {
        let channels = max(channels, 1)
        let frames = pcm.count / (2 * channels)
        guard frames > 0, rate > 0 else { return [] }
        let ratio = rate / sampleRate
        let width = max(1, Int(ratio.rounded()))
        let outCount = min(windowSamples, Int(Double(frames) / ratio))
        guard outCount > 0 else { return [] }

        // 1. 只取用得到的尾巴，混成单声道、缩到 -1…1
        let needed = min(frames, Int((Double(outCount - 1) * ratio).rounded(.up)) + width)
        var samples = [Int16](repeating: 0, count: needed * channels)   // 拷一份：Data 切片不保证按 2 字节对齐
        _ = samples.withUnsafeMutableBytes { pcm.suffix(needed * channels * 2).copyBytes(to: $0) }
        var mono = [Float](repeating: 0, count: needed)
        var channel = [Float](repeating: 0, count: needed)
        samples.withUnsafeBufferPointer { source in
            for index in 0..<channels {
                vDSP_vflt16(source.baseAddress! + index, vDSP_Stride(channels), &channel, 1, vDSP_Length(needed))
                mono.withUnsafeMutableBufferPointer { sum in
                    vDSP_vadd(sum.baseAddress!, 1, channel, 1, sum.baseAddress!, 1, vDSP_Length(needed))
                }
            }
        }
        var scale = 1 / (32768 * Float(channels))
        mono.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, vDSP_Length(needed)) }
        if ratio == 1 { return mono }

        // 2. 低通：smoothed[k] = mono[k ..< k + width] 的平均（多留一个，线性插值要读 k + 1）
        let smoothedCount = needed - width + 1
        var smoothed = [Float](repeating: 0, count: smoothedCount + 1)
        let kernel = [Float](repeating: 1 / Float(width), count: width)
        vDSP_conv(mono, 1, kernel, 1, &smoothed, 1, vDSP_Length(smoothedCount), vDSP_Length(width))
        smoothed[smoothedCount] = smoothed[smoothedCount - 1]

        // 3. 按比例取点，最后一个对齐末尾
        var first = Float(max(0, Double(smoothedCount - 1) - Double(outCount - 1) * ratio))
        var step = Float(ratio)
        var positions = [Float](repeating: 0, count: outCount)
        vDSP_vramp(&first, &step, &positions, 1, vDSP_Length(outCount))
        var low: Float = 0, high = Float(smoothedCount - 1)
        positions.withUnsafeMutableBufferPointer {
            vDSP_vclip($0.baseAddress!, 1, &low, &high, $0.baseAddress!, 1, vDSP_Length(outCount))
        }
        var out = [Float](repeating: 0, count: outCount)
        vDSP_vlint(smoothed, positions, 1, &out, 1, vDSP_Length(outCount), vDSP_Length(smoothedCount + 1))
        return out
    }
}

/// 停顿里什么时候问 Smart Turn：0.2 秒（`.pause`）问第一次；判没说完，静音每长 `recheckEvery` 再问一次
/// （模型看到的静音越长越有把握，合成语音实测「一年有十三个月」0.2 秒时 0.08、0.6 秒时 0.71）；
/// 判说完了 / 再开口 / 收了就不问了。问一次约 3 ms。
public struct TurnEndWatch: Sendable {
    public static let recheckEvery = 0.2

    private var nextAt: Double?

    public init() {}

    /// `.pause` 来了：`silence` 是当前这段静音的长度，马上就该问。
    public mutating func paused(silence: Double) {
        nextAt = silence
    }

    /// 每帧调：到点了返回 true（调用方去问），并排好下一次。
    public mutating func due(silence: Double) -> Bool {
        guard let at = nextAt, silence >= at else { return false }
        nextAt = silence + Self.recheckEvery
        return true
    }

    public mutating func stop() {
        nextAt = nil
    }
}
