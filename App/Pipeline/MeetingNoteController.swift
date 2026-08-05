import Foundation
import InkfallCore

/// 自动会议笔记（beta）。
///
/// 落笔现在产出的是**转写**，不是笔记 —— 它忠实记录每个人说了什么，但会后
/// 要的是「定了什么、谁去做」。这一路和现有的转写/加工**完全并行**：同一批
/// 段落，一边照常落进正文，一边在旁边维护一份不断长出来的会议笔记。
///
/// 三件事决定了它必须是这个形状（见 `MeetingNoteScheduler` / `MeetingNoteDiff`）：
///
/// 1. **合批**：这一轮要把「已有笔记 + 新内容」整个喂进去，十几秒起步，
///    而段是几秒一条。每段跑一次会排起一条永远追不上的队。
/// 2. **增量**：模型只输出改动块，不重吐整篇 —— 否则输出成本随会议时长
///    线性上涨，用户正看着的文字还会不停跳。
/// 3. **绝不影响主链路**：这一路慢、会失败、是 beta。它的任何问题都不能
///    拖住转写、加工与粘贴。
@MainActor
@Observable
final class MeetingNoteController {

    /// 当前这场会的笔记正文。面板右栏直接读它。
    private(set) var note = ""
    /// 正在整理中（有一轮在飞，或者还有攒着没送的内容）。
    private(set) var isWorking = false
    /// 最近一次出的状况，给面板显示一行小字。
    private(set) var notice: String?
    /// 这份会议笔记落盘成的那条笔记 id。
    private(set) var noteID: String?

    /// **最近一轮**新增/改写的行。
    ///
    /// 会议笔记是隔十几秒跳变一次的，不标出来用户根本不知道刚才那一跳改了
    /// 什么，只能从头再读一遍 —— 而它会越来越长。
    private(set) var latestChangedLines: Set<String> = []
    /// **上一轮**的改动。留两代是因为一轮要十几秒：你正读着的时候很可能
    /// 已经又跳过一次，只标最新的那一代会让上一次的改动凭空消失。
    private(set) var previousChangedLines: Set<String> = []

    private var scheduler = MeetingNoteScheduler()
    private let store: SettingsStore
    private let notes: NoteStore
    private let processing: PostProcessingCoordinator

    /// 源笔记（转写那一份）的 id 与标题 —— 结果要挂在它旁边。
    private var sourceNoteID: String?
    private var sourceTitle = ""

    init(store: SettingsStore, notes: NoteStore, processing: PostProcessingCoordinator) {
        self.store = store
        self.notes = notes
        self.processing = processing
    }

    var isEnabled: Bool { store.settings.meetingNotesEnabled }

    // MARK: - 会话

    func begin(sourceNoteID: String, title: String) {
        scheduler = MeetingNoteScheduler()
        note = ""
        noteID = nil
        latestChangedLines = []
        previousChangedLines = []
        notice = nil
        isWorking = false
        self.sourceNoteID = sourceNoteID
        sourceTitle = title
        guard isEnabled else { return }
        Log.write("meeting: 开始（源笔记 \(sourceNoteID)）")
    }

    /// 一段转写落地了。**同步返回**，绝不让主链路等这一路。
    func ingest(_ text: String) {
        guard isEnabled else { return }
        guard let batch = scheduler.append(text) else {
            syncWorking()
            return
        }
        run(batch)
    }

    /// 会话停了：把攒着的最后一批跑完。
    ///
    /// ⚠️ 不等它 —— 用户停止录音的那一刻界面就该回到编辑态。这一批在后台
    /// 落地，完成后笔记自己会更新。
    func finishSession() {
        guard isEnabled else { return }
        guard let batch = scheduler.flush() else {
            syncWorking()
            return
        }
        Log.write("meeting: 收尾批次")
        run(batch)
    }

    // MARK: - 一轮加工

    private func run(_ batch: String) {
        syncWorking()
        let current = note
        let instructions = MeetingNotePrompt.instructions(
            memoryContext: store.settings.processingMemoryContext)
        let body = MeetingNotePrompt.userBody(note: current, transcript: batch)

        Task { [processing] in
            let output = await processing.transform(instructions: instructions, input: body,
                                                    label: "meeting")
            self.apply(output, batch: batch, base: current)
        }
    }

    private func apply(_ output: String?, batch: String, base: String) {
        defer {
            // ⚠️ 无论成败都要 `finish()`：不调它，调度器会永远以为有一轮在飞，
            // 之后所有段都只攒不发 —— 表现为「会议笔记停在某一刻不动了」。
            if let next = scheduler.finish() { run(next) } else { syncWorking() }
        }

        guard let output else {
            // 这一轮没跑通：把内容**还给调度器**，下一轮连着新内容一起再试。
            // 直接丢掉等于这几段永远不会进笔记。
            _ = scheduler.append(batch)
            notice = "会议笔记这一轮没跑通，已排到下一轮"
            return
        }

        let blocks = MeetingNoteDiff.parse(output)
        guard !blocks.isEmpty else {
            // 模型认为这一批没有值得记的东西 —— 合法结果，不是失败。
            Log.write("meeting: 这一批没有需要记的内容")
            return
        }
        let merged = MeetingNoteDiff.merge(blocks, into: base)
        previousChangedLines = latestChangedLines
        latestChangedLines = MeetingNoteDiff.changedLines(from: base, to: merged.text)
        note = merged.text
        Log.write("meeting: 合并 \(merged.applied) 块"
            + (merged.recovered > 0 ? "（\(merged.recovered) 块没匹配上，改成追加）" : "")
            + (merged.skipped > 0 ? "（跳过 \(merged.skipped) 块重复）" : "")
            + " → \(note.count) 字")
        notice = merged.recovered > 0 ? "有 \(merged.recovered) 处没对上原文，已追加到末尾" : nil
        persist()
    }

    private func syncWorking() {
        isWorking = scheduler.hasOutstandingWork
    }

    // MARK: - 落盘

    /// 会议笔记是**另一条笔记**，不覆盖转写那一份。
    private func persist() {
        guard !note.isEmpty else { return }
        let id = noteID ?? UUID().uuidString.uppercased()
        noteID = id
        var entry = notes.note(id: id)
            ?? HistoryEntry(id: id, createdAtMs: HistoryEntry.nowMs(),
                            title: MeetingNoteController.title(from: sourceTitle),
                            transcriptionMode: store.settings.transcriptionMode,
                            postProcessingEnabled: true)
        entry.sourceText = note
        entry.finalText = note
        entry.linkedNoteID = sourceNoteID
        notes.upsert(entry)
    }

    static func title(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "会议笔记" : "\(trimmed) · 会议笔记"
    }
}
