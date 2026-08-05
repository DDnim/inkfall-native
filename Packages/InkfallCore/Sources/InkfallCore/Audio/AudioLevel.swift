import Foundation

/// 一段音频「有多响」的统一度量。**两端共用**（spec/09）。
///
/// ## 为什么是窗口 RMS 峰值，而不是「超阈值的采样数」
///
/// 桌面端最初数的是「瞬时振幅超过 0.02 的采样累计多久」，实测把真人说话
/// 判成了静音：语音波形**绝大多数瞬时采样都贴近零**（正弦波待在峰值附近的
/// 时间很短），所以「2% 的采样超过 0.02」恰恰就是正常说话的样子，而那条
/// 判据要求累计 150 ms —— 一段 5 秒的话得有 3% 的采样超阈值才算数。
///
/// 用 AMI 会议语料（17.5 分钟真实四人会议）实测这条判据：**71 段里 34 段
/// 被判「没声音」丢掉，其中 23 段真的有人在说话**，包括一段 19.5 秒的需求
/// 陈述 —— 它的「有效采样」只有 17 ms，而窗口 RMS 峰值是 0.0399，
/// 是阈值的 2.7 倍。
///
/// iOS 端（`AudioSegmentGate`）早就换成了窗口 RMS 峰值，效果一直很好。
/// 它的道理值得原样保留：
///
/// > 峰值（而不是均值）才分得开「真的有人说话」和「只有室内底噪」——
/// > 静音永远不会明显高过底噪，而真实语音在每个音节起振处都会尖上去。
///
/// 阈值是照着实测的**室内底噪（0.004–0.006）与正常说话（0.02+）之间**取的。
public enum AudioLevel {

    /// 显示与判据共用的归一化刻度：RMS × 3.2（说话很少超过 0.3 RMS）。
    /// ⚠️ 与 iOS 端 `AVAudioPCMBuffer.normalizedLevel()` **必须一致** ——
    /// 阈值是在这把尺子上量出来的，换了尺子阈值就全错。
    public static let displayScale: Float = 3.2

    /// 峰值分析窗口。短到一句短促的话也能占满一个窗口。
    public static let defaultWindowSeconds: Double = 0.05

    /// 一段 16 bit PCM 的窗口 RMS 峰值。
    ///
    /// - Returns: 0…1；`nil` 表示这段音频解析不出来（调用方要 **fail-open**，
    ///   绝不能因为容器格式意外而把真实语音丢掉）。
    public static func windowedPeak(wav: Data,
                                    windowSeconds: Double = defaultWindowSeconds) -> Float? {
        guard let pcm = WAV.parse(wav) else { return nil }
        let samplesPerWindow = max(1, Int(Double(pcm.sampleRate) * windowSeconds)
            * Int(pcm.channels))
        var peak: Float = 0

        wav.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = pcm.dataRange.lowerBound
            let end = pcm.dataRange.upperBound - 1
            var sum: Float = 0
            var count = 0
            while offset < end {
                let lo = UInt16(raw[offset])
                let hi = UInt16(raw[offset + 1])
                let value = Float(Int16(bitPattern: lo | (hi << 8))) / Float(Int16.max)
                sum += value * value
                count += 1
                if count == samplesPerWindow {
                    peak = max(peak, normalized(rms: (sum / Float(count)).squareRoot()))
                    sum = 0
                    count = 0
                }
                offset += 2
            }
            // 末尾不足一窗的余数也要算 —— 一段短促的话可能整个就在这里。
            if count > 0 {
                peak = max(peak, normalized(rms: (sum / Float(count)).squareRoot()))
            }
        }
        return peak
    }

    /// 已经解码成 float 的采样（转写路径手里就是这个）。
    public static func windowedPeak(samples: [Float], sampleRate: Double,
                                    windowSeconds: Double = defaultWindowSeconds) -> Float {
        guard !samples.isEmpty, sampleRate > 0 else { return 0 }
        let window = max(1, Int(sampleRate * windowSeconds))
        var peak: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var energy: Float = 0
            for i in index..<end { energy += samples[i] * samples[i] }
            peak = max(peak, normalized(rms: (energy / Float(end - index)).squareRoot()))
            index = end
        }
        return peak
    }

    public static func normalized(rms: Float) -> Float {
        min(1, max(0, rms * displayScale))
    }
}
