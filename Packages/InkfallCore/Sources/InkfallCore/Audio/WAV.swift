import Foundation

/// 16 bit PCM WAV 的读写。录音器产出的都是这个格式（44 字节标准头）。
public enum WAV {

    /// 用 16 bit PCM 数据封一个标准 44 字节头的 WAV。
    public static func encode(pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var out = Data(capacity: 44 + pcm.count)
        out.append(contentsOf: Array("RIFF".utf8))
        out.appendLE(UInt32(36 + dataSize))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        out.appendLE(UInt32(16))          // PCM fmt chunk 大小
        out.appendLE(UInt16(1))           // 格式 = PCM
        out.appendLE(channels)
        out.appendLE(sampleRate)
        out.appendLE(byteRate)
        out.appendLE(blockAlign)
        out.appendLE(bitsPerSample)
        out.append(contentsOf: Array("data".utf8))
        out.appendLE(dataSize)
        out.append(pcm)
        return out
    }

    public struct PCMInfo: Sendable, Equatable {
        public let sampleRate: UInt32
        public let channels: UInt16
        /// data 块在原始字节里的半开区间。
        public let dataRange: Range<Int>
    }

    /// 极简 RIFF 走查：只认未压缩的 16 bit PCM，其余一律返回 nil。
    ///
    /// 调用方**必须 fail-open**（解析不出来就当作有声音）—— 绝不能因为容器
    /// 格式意外而丢掉真实语音。
    public static func parse(_ wav: Data) -> PCMInfo? {
        let bytes = [UInt8](wav)
        func tag(_ o: Int) -> String? {
            guard o + 4 <= bytes.count else { return nil }
            return String(bytes: bytes[o..<(o + 4)], encoding: .ascii)
        }
        func u16(_ o: Int) -> UInt16? {
            guard o + 2 <= bytes.count else { return nil }
            return UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)
        }
        func u32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8)
                | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }

        var sampleRate: UInt32?
        var channels: UInt16?
        var bitsPerSample: UInt16?
        var dataRange: Range<Int>?

        var offset = 12
        while offset + 8 <= bytes.count {
            guard let chunkID = tag(offset), let size = u32(offset + 4) else { return nil }
            let body = offset + 8
            switch chunkID {
            case "fmt ":
                guard u16(body) == 1 else { return nil }   // 只认 PCM
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bitsPerSample = u16(body + 14)
            case "data":
                let upper = min(body + Int(size), bytes.count)
                guard body <= upper else { return nil }
                dataRange = body..<upper
            default:
                break
            }
            // chunk 是字对齐的：奇数长度后面补一个字节。
            offset = body + Int(size) + Int(size % 2)
        }

        guard let rate = sampleRate, rate > 0,
              let ch = channels, ch > 0,
              bitsPerSample == 16,
              let range = dataRange, range.upperBound > range.lowerBound
        else { return nil }

        return PCMInfo(sampleRate: rate, channels: ch, dataRange: range)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
