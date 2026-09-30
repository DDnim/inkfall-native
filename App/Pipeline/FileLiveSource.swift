import Foundation
import InkfallCore

/// `--live-sim` 用的假录音器：把一段 wav 按真实时间一点点「录」进来。
///
/// 电平和真录音器同一把尺子（最近一个约 10 ms 缓冲的振幅峰值），打包也走
/// `AudioRecorder.package`（静音压缩 + WAV）。只有麦克风和房间是假的 ——
/// 转写、Jev、核对、切段全是真的，延迟就是真的。
@MainActor
final class FileLiveSource: LiveAudioSource {

    private let samples: [Int16]
    private let rate: Double
    private let started: CFAbsoluteTime
    /// 已经「录」进来的样本数（放完之后接着录底噪）。
    private var recorded = 0
    private var buffer: [Int16] = []
    private var generation = 0
    private var rng = SystemRandomNumberGenerator()
    private(set) var level: Float = 0

    var durationSeconds: Double { Double(samples.count) / rate }
    var elapsed: Double { CFAbsoluteTimeGetCurrent() - started }

    init?(wav: Data) {
        guard let info = WAV.parse(wav), info.channels == 1 else { return nil }
        let bytes = wav[info.dataRange]
        var samples = [Int16](repeating: 0, count: bytes.count / 2)
        _ = samples.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        self.samples = samples
        rate = Double(info.sampleRate)
        started = CFAbsoluteTimeGetCurrent()
    }

    /// 把「现在」之前的音频追加进缓冲，更新电平。30 Hz 调。
    func advance() {
        let target = Int(elapsed * rate)
        guard target > recorded else { return }
        for index in recorded..<target {
            // 放完之后：安静房间的底噪（±40 / 32768 ≈ 0.001）
            buffer.append(index < samples.count ? samples[index] : Int16.random(in: -40...40, using: &rng))
        }
        recorded = target
        let window = max(1, Int(rate * 0.0107))
        let peak = buffer.suffix(window).map { abs(Int32($0)) }.max() ?? 0
        level = Float(peak) / Float(Int16.max)
    }

    func peek() -> (audio: RecordedAudio, mark: AudioRecorder.Mark)? {
        (package(buffer), AudioRecorder.Mark(generation: generation, bytes: buffer.count * 2))
    }

    func cut(upTo mark: AudioRecorder.Mark) -> Bool {
        guard mark.generation == generation, mark.bytes / 2 <= buffer.count else { return false }
        buffer.removeFirst(mark.bytes / 2)
        generation += 1
        return true
    }

    func turnWindow() -> [Float]? {
        let tail = buffer.suffix(SmartTurn.windowSamples)
        return SmartTurn.window(pcm: tail.withUnsafeBytes { Data($0) }, sampleRate: rate, channels: 1)
    }

    func takeAll() -> RecordedAudio? {
        let audio = package(buffer)
        buffer = []
        generation += 1
        return audio
    }

    private func package(_ pcm: [Int16]) -> RecordedAudio {
        let data = pcm.withUnsafeBytes { Data($0) }
        return AudioRecorder.package(pcm: data, fallbackDurationMs: UInt64(Double(pcm.count) / rate * 1000),
                                     rate: rate, channels: 1, filenamePrefix: "inkfall-sim")
    }
}
