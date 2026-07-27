import Foundation

/// 一条笔记。
///
/// 磁盘上仍叫 `history.json`、字段仍叫 `sourceText`/`finalText` —— **不要改**，
/// 那是与现有用户数据的兼容边界。类型名在 Swift 侧正名为 Note。
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAtMs: UInt64
    /// 用户可改的标题。默认是创建时刻的本地 "YYYY-MM-DD HH:MM"。
    public var title: String
    /// 原始转写（含 `[截图]` / `[语音]` 这类短标记）。
    public var sourceText: String
    /// 加工后的正文（含 `![alt](file.png)` / `[audio](file.wav)` 块）。
    public var finalText: String
    public var editorClipboardText: String?
    public var transcriptionMode: TranscriptionMode
    public var postProcessingEnabled: Bool
    public var postProcessingPreset: PostProcessingPreset?
    /// 分离标签 → 真名。持久化后侧栏在标签已被替换成名字之后仍可再编辑。
    public var speakerNames: [String: String]

    public init(id: String = UUID().uuidString.uppercased(),
                createdAtMs: UInt64 = HistoryEntry.nowMs(),
                title: String? = nil,
                sourceText: String = "",
                finalText: String = "",
                editorClipboardText: String? = nil,
                transcriptionMode: TranscriptionMode = .groqProxy,
                postProcessingEnabled: Bool = false,
                postProcessingPreset: PostProcessingPreset? = nil,
                speakerNames: [String: String] = [:]) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.title = title ?? HistoryEntry.defaultTitle(createdAtMs)
        self.sourceText = sourceText
        self.finalText = finalText
        self.editorClipboardText = editorClipboardText
        self.transcriptionMode = transcriptionMode
        self.postProcessingEnabled = postProcessingEnabled
        self.postProcessingPreset = postProcessingPreset
        self.speakerNames = speakerNames
    }

    /// 显示/插入用的正文：`finalText` 为空时回落 `sourceText`。
    public var displayText: String {
        finalText.isEmpty ? sourceText : finalText
    }

    public static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    /// 默认标题 = 创建时刻的本地 "YYYY-MM-DD HH:MM"，这样每条笔记一眼可辨。
    public static func defaultTitle(_ ms: UInt64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // 老数据缺 title / speakerNames，容错解码。
    private enum CodingKeys: String, CodingKey {
        case id, createdAtMs, title, sourceText, finalText, editorClipboardText
        case transcriptionMode, postProcessingEnabled, postProcessingPreset, speakerNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString.uppercased()
        createdAtMs = (try? c.decode(UInt64.self, forKey: .createdAtMs)) ?? HistoryEntry.nowMs()
        let decodedTitle = (try? c.decode(String.self, forKey: .title)) ?? ""
        title = decodedTitle.isEmpty ? HistoryEntry.defaultTitle(createdAtMs) : decodedTitle
        sourceText = (try? c.decode(String.self, forKey: .sourceText)) ?? ""
        finalText = (try? c.decode(String.self, forKey: .finalText)) ?? ""
        editorClipboardText = try? c.decodeIfPresent(String.self, forKey: .editorClipboardText)
        transcriptionMode = (try? c.decode(TranscriptionMode.self, forKey: .transcriptionMode)) ?? .groqProxy
        postProcessingEnabled = (try? c.decode(Bool.self, forKey: .postProcessingEnabled)) ?? false
        postProcessingPreset = try? c.decodeIfPresent(PostProcessingPreset.self, forKey: .postProcessingPreset)
        speakerNames = (try? c.decode([String: String].self, forKey: .speakerNames)) ?? [:]
    }
}

// MARK: - 落笔会话

/// 一段的生命周期。`processing` 是**瞬态，永不落盘** —— 重启不可能续上
/// 一次在飞的转写。存盘和读盘时都会剔除。
public enum NoteSegmentStatus: String, Codable, Sendable {
    case done, failed, processing
}

public struct NoteSessionSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var rawText: String
    public var finalText: String
    public var status: NoteSegmentStatus
    public var pasted: Bool
    public var createdAtMs: UInt64
    /// 全篇转译产出的那条独立笔记（面板上会多一个「打开笔记」跳转按钮）。
    public var openNoteId: String?

    public init(id: UInt64, rawText: String = "", finalText: String = "",
                status: NoteSegmentStatus = .processing, pasted: Bool = false,
                createdAtMs: UInt64 = HistoryEntry.nowMs(), openNoteId: String? = nil) {
        self.id = id
        self.rawText = rawText
        self.finalText = finalText
        self.status = status
        self.pasted = pasted
        self.createdAtMs = createdAtMs
        self.openNoteId = openNoteId
    }

    /// 显示/插入用的文本：加工后的 `finalText`，为空则回落原始转写。
    public var displayText: String {
        finalText.isEmpty ? rawText : finalText
    }
}

/// 落笔会话：这一轮录进面板的有序段，加上它们聚合进的那条笔记。
/// 每次变更后持久化到 `note_session.json`。
public struct NoteSession: Codable, Sendable, Equatable {
    public var segments: [NoteSessionSegment]
    /// 这些段聚合进的那条笔记 —— 重启后如果它还在历史里，就接着往同一篇写。
    public var sessionEntryId: String?
    /// 本次会话开始的时刻（第一段的 unix ms）。
    public var startedAtMs: UInt64?

    public init(segments: [NoteSessionSegment] = [],
                sessionEntryId: String? = nil,
                startedAtMs: UInt64? = nil) {
        self.segments = segments
        self.sessionEntryId = sessionEntryId
        self.startedAtMs = startedAtMs
    }

    /// 按 id 插入或就地更新。保留 `pasted` 与原始 `createdAtMs`
    /// （一个 `processing` 占位块会**原地**变成 done/failed）。
    /// id 就是粘贴队列的单调序号，所以按 id 排序即插入顺序。
    public mutating func upsert(id: UInt64, raw: String, final: String, status: NoteSegmentStatus) {
        let now = HistoryEntry.nowMs()
        if startedAtMs == nil { startedAtMs = now }
        if let i = segments.firstIndex(where: { $0.id == id }) {
            segments[i].rawText = raw
            segments[i].finalText = final
            segments[i].status = status
        } else {
            segments.append(NoteSessionSegment(id: id, rawText: raw, finalText: final,
                                               status: status, createdAtMs: now))
            segments.sort { $0.id < $1.id }
        }
    }

    public mutating func markPasted(_ ids: [UInt64]) {
        for i in segments.indices where ids.contains(segments[i].id) {
            segments[i].pasted = true
        }
    }

    /// 面板内删除。**历史笔记的正文刻意不动。**
    public mutating func delete(id: UInt64) {
        segments.removeAll { $0.id == id }
    }

    /// 「粘贴所有」要收集的载荷：所有未粘贴的 done 段，按 id 序。
    public func unpastedDoneInOrder() -> [(id: UInt64, text: String)] {
        segments.filter { $0.status == .done && !$0.pasted }
            .sorted { $0.id < $1.id }
            .map { ($0.id, $0.displayText) }
    }

    /// 倒数第 n 个 done 段（1 = 最新），给右⌥ + 数字的快速粘贴用。
    public func nthFromLastDone(_ n: Int) -> (id: UInt64, text: String)? {
        guard n >= 1 else { return nil }
        let done = segments.filter { $0.status == .done }
        guard done.count >= n else { return nil }
        let seg = done[done.count - n]
        return (seg.id, seg.displayText)
    }

    public func segmentText(id: UInt64) -> String? {
        segments.first { $0.id == id }?.displayText
    }

    /// 还有没有未粘贴的 done 段 —— 决定重启后要不要弹「已恢复上次会话」。
    public var hasUnpastedDone: Bool {
        segments.contains { $0.status == .done && !$0.pasted }
    }

    /// 「已settle」：没有待粘贴的东西。驱动自动轮转 —— 在一个 settle 的会话上
    /// 开始录音会开一篇新的，而不是接着写。
    public var isSettled: Bool { !hasUnpastedDone }

    public mutating func clear() {
        segments.removeAll()
        sessionEntryId = nil
        startedAtMs = nil
    }

    /// 剔除瞬态的 `processing` 段。读盘后与存盘前都要跑。
    public mutating func dropProcessing() {
        segments.removeAll { $0.status == .processing }
    }

    /// 可安全落盘的副本。
    public func persistable() -> NoteSession {
        var copy = self
        copy.dropProcessing()
        return copy
    }
}
