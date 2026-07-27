import CoreAudio
import Foundation

/// CoreAudio 设备发现与输入增益。
enum AudioDevices {

    /// 内置麦克风的 device id。
    ///
    /// ⚠️ **必须优先绑内置麦克风。**高层音频引擎在你一碰输入的瞬间就用
    /// *系统默认输入设备* 初始化 I/O unit；默认是蓝牙耳机时，macOS 立刻把它
    /// 从 A2DP 切到低保真 HFP，**全系统音质塌掉** —— 哪怕没在录音、
    /// 哪怕之后又把设备指回去。
    ///
    /// 判据：transport 是 BuiltIn **且**有输入流。
    static func builtInInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return nil }

        return devices.first { device in
            transportType(device) == kAudioDeviceTransportTypeBuiltIn && hasInputStream(device)
        }
    }

    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// 录音要用的设备：内置优先，没有才回落默认输入。
    static func recordingDevice() -> AudioDeviceID? {
        builtInInput() ?? defaultInput()
    }

    static func name(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // 必须走 Unmanaged：直接把 CFString 变量的地址交出去，是在对一个
        // 可能含对象引用的类型形成 raw pointer，行为不可靠。
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "?" }
        return value as String
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return 0 }
        return transport
    }

    private static func hasInputStream(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    // MARK: - 输入增益

    /// 把录音设备的输入音量抬到至少 `targetPercent`。
    ///
    /// macOS（以及跑自己那套自动增益的 App，比如视频通话）会把输入音量拖到
    /// ~30%，录出来太轻转不出字。**已经 ≥ 目标就不动** —— 不要去压用户
    /// 自己调高的音量。
    static func boostInputVolume(targetPercent: UInt8) {
        guard let device = recordingDevice() else { return }
        let target = Float(min(targetPercent, 100)) / 100
        // 优先 master element；只暴露每通道音量的设备就逐通道抬。
        if boost(device: device, element: kAudioObjectPropertyElementMain, target: target) {
            return
        }
        for channel in UInt32(1)...UInt32(2) {
            _ = boost(device: device, element: channel, target: target)
        }
    }

    /// - Returns: 这个 element 是否受理了请求（存在且可写），
    ///            调用方据此决定要不要逐通道回落。
    private static func boost(device: AudioDeviceID, element: UInt32, target: Float) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return false }

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }

        var current: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr
        else { return false }
        if current >= target { return true }

        var value = target
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        return status == noErr
    }
}
