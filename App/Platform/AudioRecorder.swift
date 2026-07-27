import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import InkfallCore

/// 手工搭 AUHAL 的录音器。
///
/// **刻意不用 AVAudioEngine 之类的高层引擎。**它们在你一碰输入的瞬间就用
/// *系统默认输入设备* 初始化 I/O unit；默认是蓝牙耳机时，macOS 立刻把耳机从
/// A2DP 切到低保真 HFP，**全系统音频音质塌掉** —— 哪怕没有开始采集、
/// 哪怕之后又把设备指回去。手工搭 AUHAL 可以在 `AudioUnitInitialize` **之前**
/// 就把设备绑到内置麦克风，蓝牙输入根本不会被打开。
///
/// 线程：`start/stop/flush` 从主线程调；渲染回调跑在 CoreAudio 的 I/O 线程。
/// 两者共享的状态全部用锁保护，临界区只有「往缓冲区追加字节」这么长。
final class AudioRecorder: @unchecked Sendable {

    // MARK: - 状态

    private let lock = NSLock()
    /// 16 bit 交错 PCM。回调追加，flush/stop 取走。
    private var pcm = Data()
    private var unit: AudioUnit?
    private var running = false
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 1
    /// 当前 take 的起点。flush 会把它按保留的尾巴往回拨。
    private var startedAt: CFAbsoluteTime?

    /// 峰值电平（0...1），UI 每 50ms 读一次。
    private var peakLevel: Float = 0
    /// 本段超过噪声门限的样本数 —— 提交策略那条「有效语音 ≥ 150ms」的实时对应物，
    /// 让 UI 能在提交之前就知道这段值不值得转写。
    private var activeSamples: UInt64 = 0
    private let activeSampleAmplitude = RecordingSubmissionPolicy.default.activeSampleAmplitude

    private let trimmer = SilenceTrimmer.default

    // MARK: - 权限

    var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophoneAccess(_ done: @escaping @Sendable (Bool) -> Void = { _ in }) {
        AVCaptureDevice.requestAccess(for: .audio) { done($0) }
    }

    // MARK: - 只读快照

    var isRecording: Bool { lock.withLock { running } }

    var level: Float { lock.withLock { peakLevel } }

    /// 当前 take 已录的时长（秒）—— 断句的 180 秒硬上限用它。
    var takeDurationSeconds: Double {
        lock.withLock {
            let bytesPerSecond = sampleRate * Double(max(channelCount, 1)) * 2
            guard bytesPerSecond > 0 else { return 0 }
            return Double(pcm.count) / bytesPerSecond
        }
    }

    /// 本段累计的有声毫秒数。
    var activeAudioMs: Double {
        lock.withLock {
            let samplesPerMs = sampleRate * Double(max(channelCount, 1)) / 1000
            guard samplesPerMs > 0 else { return 0 }
            return Double(activeSamples) / samplesPerMs
        }
    }

    // MARK: - 预热

    /// 预建并 initialize 好 unit，省掉第一次录音的冷启动
    /// （HAL 设备初始化 + I/O unit 建立，首次可达数百 ms 到 1 秒以上）。
    ///
    /// ⚠️ **只在存在内置麦克风时预热。**预热默认设备可能在 App 完全空闲时
    /// 就把蓝牙耳机拖进 HFP。没有内置麦克风就让第一次录音去付这个成本。
    func prewarm() {
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            let alreadyBuilt = unit != nil
            lock.unlock()
            guard !alreadyBuilt else { return }
            guard let device = AudioDevices.builtInInput() else {
                Log.write("audio prewarm skipped: 没有内置麦克风")
                return
            }
            do {
                try setUpUnit(device: device)
                Log.write("audio prewarm ready device=\(AudioDevices.name(device)) "
                          + "rate=\(sampleRate) channels=\(channelCount)")
            } catch {
                Log.write("audio prewarm failed: \(error)")
            }
        }
    }

    // MARK: - 起停

    enum RecorderError: Error, CustomStringConvertible {
        case noInputDevice
        case componentNotFound
        case setup(String, OSStatus)
        case notInitialized
        case startFailed(OSStatus)
        case notRecording

        var description: String {
            switch self {
            case .noInputDevice: return "没有可用的音频输入设备"
            case .componentNotFound: return "找不到音频输入组件"
            case .setup(let stage, let s): return "音频输入初始化失败（\(stage): \(s)）"
            case .notInitialized: return "音频输入未初始化"
            case .startFailed(let s): return "无法启动音频输入（\(s)）"
            case .notRecording: return "当前没有正在进行的录音"
            }
        }
    }

    func start() throws {
        if isRecording { return }

        let existing: AudioUnit? = lock.withLock { unit }
        if existing == nil {
            guard let device = AudioDevices.recordingDevice() else {
                throw RecorderError.noInputDevice
            }
            try setUpUnit(device: device)
        }

        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        peakLevel = 0
        activeSamples = 0
        startedAt = CFAbsoluteTimeGetCurrent()
        running = true
        let u = unit
        lock.unlock()

        guard let u else { throw RecorderError.notInitialized }

        let status = AudioOutputUnitStart(u)
        guard status != noErr else { return }

        // ⚠️ AUHAL unit 会「僵死」：start 失败（见过 268451843）之后，unit 进入一种
        // **后续 start 看似成功但完全不产生音频**的状态 —— 线上出现过 53 秒录音
        // 只有 44 字节（只有 WAV 头）。拆掉重建，再试一次。
        Log.write("audio start failed status=\(status)；重建 unit 后重试")
        do {
            try rebuildAndStart()
            Log.write("audio start 在重建 unit 后恢复")
        } catch {
            lock.withLock { running = false; startedAt = nil }
            Log.write("audio start 重建后仍失败: \(error)")
            throw error
        }
    }

    private func rebuildAndStart() throws {
        lock.lock()
        let old = unit
        unit = nil
        lock.unlock()
        if let old {
            AudioOutputUnitStop(old)
            AudioComponentInstanceDispose(old)
        }

        guard let device = AudioDevices.recordingDevice() else {
            throw RecorderError.noInputDevice
        }
        try setUpUnit(device: device)

        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        startedAt = CFAbsoluteTimeGetCurrent()
        let u = unit
        lock.unlock()

        guard let u else { throw RecorderError.notInitialized }
        let status = AudioOutputUnitStart(u)
        guard status == noErr else { throw RecorderError.startFailed(status) }
    }

    /// 停止并取走整段录音（已做静音压缩、已封成 WAV）。
    func stop() throws -> RecordedAudio {
        lock.lock()
        guard running, let u = unit else {
            lock.unlock()
            throw RecorderError.notRecording
        }
        lock.unlock()

        AudioOutputUnitStop(u)

        lock.lock()
        running = false
        let durationMs = startedAt.map { UInt64((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? 0
        let raw = pcm
        pcm = Data()
        let rate = sampleRate
        let channels = channelCount
        startedAt = nil
        peakLevel = 0
        activeSamples = 0
        lock.unlock()

        // 诊断僵死的 unit：多秒的录音却几乎没有 PCM，说明 unit 报了「已启动」
        // 但从未送出音频。记下来，事后能认出这种故障。
        if raw.count < 1024 && durationMs > 2000 {
            Log.write("audio unit 没有产生数据 —— 引擎可能已僵死"
                      + "（bytes=\(raw.count) durationMs=\(durationMs)）")
        }

        return package(pcm: raw, fallbackDurationMs: durationMs,
                       rate: rate, channels: channels, filenamePrefix: "inkfall-recording")
    }

    /// 秒表「计圈」：把已录的音频切成一段，引擎不停，继续录进新的一段。
    ///
    /// 在 PCM 锁内原子完成 —— 回调也在同一把锁下追加，所以对进来的音频是原子的。
    /// `tailMs` 保留尾部音频作为下一段的开头（当前都传 0，能力留给按过去的停顿切）。
    func flushSegment(retainingTailMs tailMs: UInt64 = 0) throws -> RecordedAudio {
        guard isRecording else { throw RecorderError.notRecording }

        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let rate = sampleRate
        let channels = max(channelCount, 1)
        let frameBytes = max(channels * 2, 2)
        let bytesPerMs = max(rate * Double(channels) / 1000 * 2, 0)

        var tailBytes = Int((Double(tailMs) * bytesPerMs).rounded())
        tailBytes -= tailBytes % frameBytes            // 帧对齐，绝不切在样本中间
        if tailBytes > pcm.count {
            tailBytes = pcm.count - (pcm.count % frameBytes)
        }
        let prefixLength = pcm.count - tailBytes
        let prefix = pcm.prefix(prefixLength)
        pcm = Data(pcm.suffix(tailBytes))

        let retainedMs = bytesPerMs > 0 ? UInt64((Double(tailBytes) / bytesPerMs).rounded()) : 0
        let totalMs = startedAt.map { UInt64((now - $0) * 1000) } ?? 0
        let clampedRetained = min(retainedMs, totalMs)
        let prefixMs = totalMs - clampedRetained
        // 把段起点往回拨，让保留的尾巴把已流逝的时间带进下一段。
        startedAt = now - Double(clampedRetained) / 1000
        activeSamples = 0
        lock.unlock()

        return package(pcm: Data(prefix), fallbackDurationMs: prefixMs,
                       rate: rate, channels: channels, filenamePrefix: "inkfall-segment")
    }

    /// 丢掉当前录音，不产出任何东西。
    func cancel() {
        lock.lock()
        let u = unit
        let wasRunning = running
        running = false
        pcm.removeAll(keepingCapacity: true)
        startedAt = nil
        peakLevel = 0
        activeSamples = 0
        lock.unlock()
        if wasRunning, let u { AudioOutputUnitStop(u) }
    }

    /// 压缩静音 + 封 WAV。
    private func package(pcm raw: Data, fallbackDurationMs: UInt64,
                         rate: Double, channels: Int, filenamePrefix: String) -> RecordedAudio {
        let trimmed = trimmer.trim(pcm: raw, sampleRate: rate, channelCount: channels)
        let (data, durationMs): (Data, UInt64) = trimmed.removedMs > 0
            ? (trimmed.pcm, UInt64(max(trimmed.keptMs, 0)))
            : (raw, fallbackDurationMs)
        if trimmed.removedMs > 0 {
            Log.write("silence trim removed=\(Int(trimmed.removedMs))ms kept=\(Int(trimmed.keptMs))ms")
        }
        let wav = WAV.encode(pcm: data, sampleRate: UInt32(rate.rounded()),
                            channels: UInt16(channels))
        return RecordedAudio(
            filename: "\(filenamePrefix)-\(Int(Date().timeIntervalSince1970)).wav",
            data: wav, durationMs: durationMs)
    }

    // MARK: - AUHAL 搭建

    /// 建并 initialize 一个只做输入的 AUHAL，绑到 `device`。
    ///
    /// **顺序即正确性**：设备必须在 `AudioUnitInitialize` **之前**设好，
    /// 这样任何别的输入设备 —— 尤其是系统默认的那个 —— 都不会被打开。
    private func setUpUnit(device: AudioDeviceID) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.componentNotFound
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "create")
        guard let newUnit else { throw RecorderError.componentNotFound }

        do {
            // 1. 开输入（element 1 = 输入总线）
            var enable: UInt32 = 1
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &enable,
                                           UInt32(MemoryLayout<UInt32>.size)), "enable input")
            // 2. 关输出（element 0 = 输出总线）
            var disable: UInt32 = 0
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &disable,
                                           UInt32(MemoryLayout<UInt32>.size)), "disable output")
            // 3. ★ 绑设备 —— 必须在 Initialize 之前
            var bound = device
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &bound,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)), "bind device")
            // 4. 读硬件格式
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(newUnit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 1, &hardware, &size),
                      "hardware format")
            let channels = max(Int(hardware.mChannelsPerFrame), 1)

            // 5. 客户端格式：硬件采样率下的交错 float32。
            //    AUHAL 负责从设备格式转过来，回调里再转成 16 bit PCM。
            var client = AudioStreamBasicDescription(
                mSampleRate: hardware.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                            | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32,
                mReserved: 0)
            try check(AudioUnitSetProperty(newUnit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 1, &client,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                      "client format")

            // 6. 输入回调
            var callback = AURenderCallbackStruct(
                inputProc: audioRecorderInputProc,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_SetInputCallback,
                                           kAudioUnitScope_Global, 0, &callback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "set callback")

            // 7. Initialize
            try check(AudioUnitInitialize(newUnit), "initialize")

            // 8. 回读协商后的客户端格式
            var negotiated = AudioStreamBasicDescription()
            var negotiatedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let rate: Double
            if AudioUnitGetProperty(newUnit, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output, 1,
                                    &negotiated, &negotiatedSize) == noErr {
                rate = negotiated.mSampleRate
            } else {
                rate = 48_000
            }

            lock.lock()
            unit = newUnit
            sampleRate = rate
            channelCount = max(Int(negotiated.mChannelsPerFrame), 1)
            lock.unlock()
        } catch {
            AudioComponentInstanceDispose(newUnit)
            throw error
        }
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status != noErr else { return }
        Log.write("audio unit setup failed stage=\(stage) status=\(status)")
        throw RecorderError.setup(stage, status)
    }

    // MARK: - 渲染（CoreAudio I/O 线程）

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
        lock.lock()
        let u = unit
        let isRunning = running
        let channels = channelCount
        lock.unlock()

        guard let u, isRunning, frames > 0 else { return noErr }

        let sampleCount = Int(frames) * channels
        var buffer = [Float](repeating: 0, count: sampleCount)

        var status: OSStatus = noErr
        buffer.withUnsafeMutableBufferPointer { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                    mData: raw.baseAddress))
            status = AudioUnitRender(u, flags, timestamp, bus, frames, &list)
        }
        guard status == noErr else { return status }

        append(samples: buffer)
        return noErr
    }

    private func append(samples: [Float]) {
        guard !samples.isEmpty else { return }

        var chunk = Data(capacity: samples.count * 2)
        var peak: Float = 0
        var active: UInt64 = 0

        for sample in samples {
            let value = max(-1, min(1, sample))
            peak = max(peak, abs(value))
            if abs(value) > activeSampleAmplitude { active += 1 }
            let intSample = Int16(value * Float(Int16.max))
            let bits = UInt16(bitPattern: intSample)
            chunk.append(UInt8(bits & 0xff))
            chunk.append(UInt8((bits >> 8) & 0xff))
        }

        lock.lock()
        pcm.append(chunk)
        peakLevel = peak
        activeSamples += active
        lock.unlock()
    }
}

/// AUHAL 输入回调的 C 入口；转回录音器实例。
private func audioRecorderInputProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
    return recorder.render(flags: ioActionFlags, timestamp: inTimeStamp,
                           bus: inBusNumber, frames: inNumberFrames)
}
