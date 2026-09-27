import Foundation

/// 历史记录的一条（试做，exp/interject：助手模式下录的话不粘贴，记在这里）。
///
/// 文件仍是 `history.json`、字段名与减法前的笔记 / Tauri 版相同 —— **不要改**，
/// 那是和用户已有数据的兼容边界（结构取自 73063b0^ 的 `Notes.swift`）。
/// 减法前笔记才有的字段（editorClipboardText / linkedNoteID）原样读进来原样写回，不丢。
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAtMs: UInt64
    public var title: String
    /// 原始转写。
    public var sourceText: String
    /// 加工后的文字。
    public var finalText: String
    public var editorClipboardText: String?
    public var transcriptionMode: TranscriptionMode
    public var postProcessingEnabled: Bool
    public var postProcessingPreset: PostProcessingPreset?
    public var speakerNames: [String: String]
    public var linkedNoteID: String?

    public init(id: String = UUID().uuidString.uppercased(),
                createdAtMs: UInt64 = HistoryEntry.nowMs(),
                title: String? = nil,
                sourceText: String,
                finalText: String,
                transcriptionMode: TranscriptionMode,
                postProcessingEnabled: Bool,
                postProcessingPreset: PostProcessingPreset?) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.title = title ?? HistoryEntry.defaultTitle(createdAtMs)
        self.sourceText = sourceText
        self.finalText = finalText
        self.transcriptionMode = transcriptionMode
        self.postProcessingEnabled = postProcessingEnabled
        self.postProcessingPreset = postProcessingPreset
        self.speakerNames = [:]
    }

    /// 显示用：`finalText` 为空时回落 `sourceText`。
    public var displayText: String { finalText.isEmpty ? sourceText : finalText }

    public static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// 默认标题 = 创建时刻的本地 "YYYY-MM-DD HH:MM"。
    public static func defaultTitle(_ ms: UInt64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// 新的放最前，超过 `limit` 从最旧的丢。
    public static func appending(_ entry: HistoryEntry, to entries: [HistoryEntry], limit: Int = 500) -> [HistoryEntry] {
        Array(([entry] + entries).prefix(limit))
    }

    // 老数据缺字段，容错解码（与 73063b0^ 相同）。
    private enum CodingKeys: String, CodingKey {
        case id, createdAtMs, title, sourceText, finalText, editorClipboardText
        case transcriptionMode, postProcessingEnabled, postProcessingPreset, speakerNames
        case linkedNoteID
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
        transcriptionMode = (try? c.decode(TranscriptionMode.self, forKey: .transcriptionMode)) ?? .local
        postProcessingEnabled = (try? c.decode(Bool.self, forKey: .postProcessingEnabled)) ?? false
        postProcessingPreset = try? c.decodeIfPresent(PostProcessingPreset.self, forKey: .postProcessingPreset)
        linkedNoteID = try? c.decodeIfPresent(String.self, forKey: .linkedNoteID)
        speakerNames = (try? c.decode([String: String].self, forKey: .speakerNames)) ?? [:]
    }
}
