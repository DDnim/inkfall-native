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
    /// 值得转写所需的**窗口 RMS 峰值**（`AudioLevel` 那把尺子）。
    ///
    /// Whisper 会对静音**产生幻觉文本**（「谢谢观看」「Thank you.」），
    /// 所以太安静的录音绝不能提交；但判据必须分得开「安静的真人说话」和
    /// 「室内底噪」—— 为什么是窗口峰值而不是数超阈值的采样，见 `AudioLevel`。
    ///
    /// 0.015 取自 iOS 端 `AudioSegmentGate` 的实测标定：室内底噪
    /// 0.004–0.006，正常说话 0.02+。
    public var minimumPeakLevel: Float
    /// 峰值分析窗口。
    public var peakWindowSeconds: Double

    public init(minimumDurationMs: UInt64 = 500,
                minimumAudioBytes: Int = 4096,
                minimumPeakLevel: Float = 0.015,
                peakWindowSeconds: Double = AudioLevel.defaultWindowSeconds) {
        self.minimumDurationMs = minimumDurationMs
        self.minimumAudioBytes = minimumAudioBytes
        self.minimumPeakLevel = minimumPeakLevel
        self.peakWindowSeconds = peakWindowSeconds
    }

    public static let `default` = RecordingSubmissionPolicy()

    public func verdict(for audio: RecordedAudio) -> SubmissionVerdict {
        if audio.durationMs < minimumDurationMs || audio.data.count < minimumAudioBytes {
            return .tooShort
        }
        return containsAudibleAudio(audio.data) ? .submit : .silent
    }

    /// 这段音频里有没有人在说话。
    ///
    /// **解析不出来时 fail-open 返回 true** —— 绝不能因为一个意料之外的容器
    /// 格式而把真实语音丢掉（spec/10 A10）。
    func containsAudibleAudio(_ wav: Data) -> Bool {
        guard let peak = AudioLevel.windowedPeak(wav: wav, windowSeconds: peakWindowSeconds) else {
            return true
        }
        return peak >= minimumPeakLevel
    }
}
