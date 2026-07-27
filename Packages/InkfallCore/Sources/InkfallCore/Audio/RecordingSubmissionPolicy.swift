import Foundation

/// 一段录音要不要送去转写。
public enum SubmissionVerdict: String, Sendable, Equatable {
    case submit
    case tooShort
    case silent
}

/// 一段录音的最小载体（与平台无关）。
public struct RecordedAudio: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var durationMs: UInt64

    public init(filename: String = "inkfall-recording.wav",
                mimeType: String = "audio/wav",
                data: Data,
                durationMs: UInt64) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.durationMs = durationMs
    }
}

public struct RecordingSubmissionPolicy: Sendable, Equatable {
    public var minimumDurationMs: UInt64
    public var minimumAudioBytes: Int
    /// 低于满量程这个比例（约 −34 dBFS）的样本算背景噪声而不是语音。
    public var activeSampleAmplitude: Float
    /// 值得转写所需的累计有声时长。Whisper 会对静音**产生幻觉文本**，
    /// 所以达不到这个量的录音绝不能提交。
    public var minimumActiveAudioMs: Double

    public init(minimumDurationMs: UInt64 = 700,
                minimumAudioBytes: Int = 4096,
                activeSampleAmplitude: Float = 0.02,
                minimumActiveAudioMs: Double = 150) {
        self.minimumDurationMs = minimumDurationMs
        self.minimumAudioBytes = minimumAudioBytes
        self.activeSampleAmplitude = activeSampleAmplitude
        self.minimumActiveAudioMs = minimumActiveAudioMs
    }

    public static let `default` = RecordingSubmissionPolicy()

    public func verdict(for audio: RecordedAudio) -> SubmissionVerdict {
        if audio.durationMs < minimumDurationMs || audio.data.count < minimumAudioBytes {
            return .tooShort
        }
        return containsAudibleAudio(audio.data) ? .submit : .silent
    }

    /// 扫 16 bit PCM，判断累计超阈值时长是否达到 `minimumActiveAudioMs`。
    ///
    /// **解析不出来时 fail-open 返回 true** —— 绝不能因为一个意料之外的容器
    /// 格式而把真实语音丢掉。
    func containsAudibleAudio(_ wav: Data) -> Bool {
        guard let pcm = WAV.parse(wav) else { return true }

        let threshold = Int16(activeSampleAmplitude * Float(Int16.max))
        let samplesPerMs = Double(pcm.sampleRate) * Double(pcm.channels) / 1000.0
        let required = Int64(minimumActiveAudioMs * samplesPerMs)
        guard required > 0 else { return true }

        var active: Int64 = 0
        return wav.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = pcm.dataRange.lowerBound
            let end = pcm.dataRange.upperBound - 1
            while offset < end {
                let lo = UInt16(raw[offset])
                let hi = UInt16(raw[offset + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                if sample > threshold || sample < -threshold {
                    active += 1
                    if active >= required { return true }
                }
                offset += 2
            }
            return false
        }
    }
}
