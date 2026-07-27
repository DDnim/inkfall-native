import Foundation

/// 提交前压缩静音：切掉首尾静音（各留一小段，免得第一个/最后一个字被削掉），
/// 并把超过 `maxPauseMs` 的内部停顿压到正好那么长。
///
/// 少传静音 = 上传更小、Whisper 更快、幻觉更少。
public struct SilenceTrimmer: Sendable, Equatable {
    /// 低于满量程这个比例（约 −34 dBFS）的样本算静音。与提交策略同值。
    public var noiseFloor: Float
    /// 第一个/最后一个有声样本之外保留的音频。
    public var edgePaddingMs: Double
    /// 超过这个长度的内部停顿会被压到这个长度，前后各留一半。
    public var maxPauseMs: Double

    public init(noiseFloor: Float = 0.02,
                edgePaddingMs: Double = 300,
                maxPauseMs: Double = 2000) {
        self.noiseFloor = noiseFloor
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

        let threshold = Int16(noiseFloor * Float(Int16.max))
        let padFrames = Int(edgePaddingMs / 1000 * sampleRate)
        let maxPauseFrames = Int(maxPauseMs / 1000 * sampleRate)
        let pauseKeepFrames = maxPauseFrames / 2

        var keepRanges: [Range<Int>] = []
        var currentStart = -1
        var previousActive = -1

        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frameCount {
                var active = false
                let base = frame * bytesPerFrame
                for channel in 0..<channelCount {
                    let o = base + channel * 2
                    let sample = Int16(bitPattern: UInt16(raw[o]) | (UInt16(raw[o + 1]) << 8))
                    if sample > threshold || sample < -threshold { active = true; break }
                }
                guard active else { continue }

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
