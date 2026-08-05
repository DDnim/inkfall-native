import Foundation

/// 提交前压缩静音：切掉首尾静音（各留一小段，免得第一个/最后一个字被削掉），
/// 并把超过 `maxPauseMs` 的内部停顿压到正好那么长。
///
/// 少传静音 = 上传更小、Whisper 更快、幻觉更少。
public struct SilenceTrimmer: Sendable, Equatable {
    /// 低于这个**窗口 RMS 峰值**的一段算静音（`AudioLevel` 那把尺子）。
    /// 与提交策略同值 —— 两者判「有没有人说话」必须用同一把尺子，
    /// 否则会出现「策略放行了，裁剪却把内容剪光」这种最难查的组合。
    ///
    /// ⚠️ 曾经是「瞬时振幅 > 0.02 的采样」，实测把安静的真人说话剪掉 92%
    /// （日志里 `removed=29251ms kept=2620ms`）—— 原因见 `AudioLevel`。
    public var noiseFloor: Float
    /// 活动判定的窗口长度。整窗保留，不做逐采样的碎剪。
    public var windowSeconds: Double
    /// 第一个/最后一个有声样本之外保留的音频。
    public var edgePaddingMs: Double
    /// 超过这个长度的内部停顿会被压到这个长度，前后各留一半。
    public var maxPauseMs: Double

    public init(noiseFloor: Float = 0.015,
                windowSeconds: Double = AudioLevel.defaultWindowSeconds,
                edgePaddingMs: Double = 300,
                maxPauseMs: Double = 2000) {
        self.noiseFloor = noiseFloor
        self.windowSeconds = windowSeconds
        self.edgePaddingMs = edgePaddingMs
        self.maxPauseMs = maxPauseMs
    }

    public static let `default` = SilenceTrimmer()

    public struct Result: Sendable, Equatable {
        public let pcm: Data
        public let keptMs: Double
        public let removedMs: Double
    }

    /// 输入是 16 bit 交错 PCM（不含 WAV 头）。
    /// **全静音的输入原样返回**，让提交策略去给出正确的「静音」裁决。
    public func trim(pcm: Data, sampleRate: Double, channelCount: Int) -> Result {
        let bytesPerFrame = max(channelCount, 1) * 2
        let frameCount = pcm.count / bytesPerFrame
        let originalMs = Double(frameCount) / sampleRate * 1000
        let unchanged = Result(pcm: pcm, keptMs: originalMs, removedMs: 0)

        guard frameCount > 0, sampleRate > 0, channelCount > 0 else { return unchanged }

        let padFrames = Int(edgePaddingMs / 1000 * sampleRate)
        let maxPauseFrames = Int(maxPauseMs / 1000 * sampleRate)
        let pauseKeepFrames = maxPauseFrames / 2

        var keepRanges: [Range<Int>] = []
        var currentStart = -1
        var previousActive = -1

        // 先按窗口算能量：逐采样判「超没超阈值」会把安静的真人说话判成静音，
        // 因为语音波形绝大多数瞬时采样都贴近零（见 `AudioLevel`）。
        let windowFrames = max(1, Int(windowSeconds * sampleRate))
        var windowActive = [Bool](repeating: false, count: (frameCount + windowFrames - 1)
                                  / windowFrames)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for window in windowActive.indices {
                let start = window * windowFrames
                let end = min(start + windowFrames, frameCount)
                var energy: Float = 0
                var count = 0
                for frame in start..<end {
                    let base = frame * bytesPerFrame
                    for channel in 0..<channelCount {
                        let o = base + channel * 2
                        let value = Float(Int16(bitPattern: UInt16(raw[o])
                                                | (UInt16(raw[o + 1]) << 8))) / Float(Int16.max)
                        energy += value * value
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                windowActive[window] =
                    AudioLevel.normalized(rms: (energy / Float(count)).squareRoot()) >= noiseFloor
            }
        }

        do {
            for frame in 0..<frameCount {
                guard windowActive[frame / windowFrames] else { continue }

                if currentStart < 0 {
                    currentStart = max(frame - padFrames, 0)
                } else if frame - previousActive - 1 > maxPauseFrames {
                    keepRanges.append(currentStart..<min(previousActive + 1 + pauseKeepFrames,
                                                         frameCount))
                    currentStart = frame - pauseKeepFrames
                }
                previousActive = frame
            }
        }

        guard currentStart >= 0 else { return unchanged }
        keepRanges.append(currentStart..<min(previousActive + 1 + padFrames, frameCount))

        let keptFrames = keepRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard keptFrames < frameCount else { return unchanged }

        var condensed = Data(capacity: keptFrames * bytesPerFrame)
        for range in keepRanges {
            condensed.append(pcm[(range.lowerBound * bytesPerFrame)..<(range.upperBound * bytesPerFrame)])
        }

        let keptMs = Double(keptFrames) / sampleRate * 1000
        return Result(pcm: condensed, keptMs: keptMs, removedMs: originalMs - keptMs)
    }
}
