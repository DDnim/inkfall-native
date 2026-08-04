import Foundation

/// 笔记留下来的语音片段，以及把它们拼成一整段的办法。
///
/// 「全篇转译」存在的理由（spec/01 §6.8）：**说话人标签只在一次推理内稳定**。
/// 落笔是边录边切的，每一段各自跑一次分离 —— 于是第 1 段的 `S01` 和第 3 段的
/// `S01` 很可能不是同一个人。把整篇的片段拼成一个 WAV 跑**一次**，聚类才是
/// 全篇范围的，人物关系才对得上。
public enum NoteAudio {

    /// 片段文件名。带 unix 毫秒 —— 天然唯一，合并笔记时可以直接 move 而不撞名，
    /// 按名字排序就是按说话顺序（spec/03 §1）。
    public static func clipName(atMs milliseconds: UInt64) -> String {
        "voice-\(milliseconds).wav"
    }

    public static func isClipName(_ name: String) -> Bool {
        name.hasPrefix("voice-") && name.hasSuffix(".wav")
    }

    /// 正文里仍然存在的 `[audio](…)` 标记，按出现顺序。
    ///
    /// 这是「该拼哪些片段」的**真相源**：用户在编辑器里删掉某条语音，
    /// 全篇转译就该跳过它。正文里一条都没有时调用方回落到扫目录
    /// （原生版目前还没有语音条 UI，走的就是回落那条）。
    public static func references(inMarkdown text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[audio]("), let end = trimmed.firstIndex(of: ")") else {
                return nil
            }
            let start = trimmed.index(trimmed.startIndex, offsetBy: "[audio](".count)
            guard start < end else { return nil }
            let reference = String(trimmed[start..<end]).trimmingCharacters(in: .whitespaces)
            // 只接受本笔记目录里的片段名 —— 带路径分隔符的一律拒掉，
            // 否则正文里一句 `[audio](../../别人的东西)` 就能读到目录外。
            guard isClipName(reference), !reference.contains("/") else { return nil }
            return reference
        }
    }

    public struct Concatenated: Sendable, Equatable {
        public let data: Data
        public let durationMs: UInt64
        /// 真正拼进去了几段。
        public let usedClips: Int
        /// 因为解析不了或者格式不一致被跳过的段数。
        public let skippedClips: Int
    }

    /// 把若干 WAV 拼成一个。
    ///
    /// ⚠️ **以第一段的格式为准**，采样率/声道数不同的后续片段直接跳过而不是
    /// 硬拼：裸 PCM 拼上去只会得到变调的噪声，而那正是「换了麦克风之后
    /// 全篇转译出来全是乱码」这类问题最难查的形态。跳过多少要报出来。
    public static func concatenate(_ clips: [Data]) -> Concatenated? {
        var pcm = Data()
        var format: (sampleRate: UInt32, channels: UInt16)?
        var used = 0
        var skipped = 0

        for clip in clips {
            guard let info = WAV.parse(clip) else {
                skipped += 1
                continue
            }
            if let format {
                guard format.sampleRate == info.sampleRate,
                      format.channels == info.channels else {
                    skipped += 1
                    continue
                }
            } else {
                format = (info.sampleRate, info.channels)
            }
            pcm.append(clip.subdata(in: info.dataRange))
            used += 1
        }

        guard let format, !pcm.isEmpty else { return nil }
        // 16 bit = 每个采样 2 字节。
        let bytesPerSecond = UInt64(format.sampleRate) * UInt64(format.channels) * 2
        return Concatenated(
            data: WAV.encode(pcm: pcm, sampleRate: format.sampleRate, channels: format.channels),
            durationMs: bytesPerSecond == 0 ? 0 : UInt64(pcm.count) * 1000 / bytesPerSecond,
            usedClips: used,
            skippedClips: skipped)
    }

    /// 结果笔记的标题：`原标题 · 全篇转译`。
    public static let titleSuffix = "全篇转译"

    public static func resultTitle(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? titleSuffix : "\(trimmed) · \(titleSuffix)"
    }
}
