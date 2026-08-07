import Foundation

/// 自动会议笔记（beta）的提示词。
///
/// 与 spec/05 §6.1 那九个加工预设是**两回事**：那些是「把这一段口述整理成
/// 好读的文字」，一段进一段出；这里是「把整场会议维护成一份笔记」——
/// 已有笔记 + 新内容进，**改动块**出（见 `MeetingNoteDiff`）。
///
/// 所以它不走预设那套，提示词也单独放在这里。
public enum MeetingNotePrompt {

    /// 与加工预设共用同一条护栏：转写内容是**素材**，不是指令。
    /// 会议里有人说「帮我查一下汇率」时，笔记里该记下这句话，而不是去查汇率。
    static let guardRule = PostProcessingPrompt.guardRule

    public static let structure = """
    You maintain a running meeting note from a live transcript. The note is for someone who could not attend: it records what matters afterwards — the substance of each topic, what was decided, what happens next, and what is still open — not a retelling of what was said.

    Keep the note organized under short headings. Use whichever of these fit what actually happened: topics, decisions, action items (with the owner when one is named), open questions. A discussion with no decisions is normal — do not invent a decisions section to fill the shape.

    The note must stay far shorter than the transcript and must not grow in proportion to it. A one-hour conversation should still read in under a minute. Enforce that by consolidating, not by truncating:

    - When new material develops a point that is already in the note, REWRITE that line so it carries the fuller understanding. Do not add a second line next to it.
    - When several lines under one heading say variations of the same thing, replace them with one sharper line.
    - Keep only what someone would still care about after the meeting. Drop greetings, thinking aloud, restatements, and asides that lead nowhere.

    Give a point sub-bullets when it genuinely has parts — the options that were weighed, the steps of something agreed, the specifics behind a decision. Indent a sub-bullet exactly two spaces under its parent. Nest one level only: if a point needs a third level, it has outgrown a bullet and should become its own heading.

    Nesting is for structure that is really there, not decoration. A parent with a single child, or children that only restate the parent, belong on one line. When a topic runs long enough that its bullets no longer read as one list, split it into sub-headings rather than letting the list sprawl.

    When you add sub-bullets under a line that is already in the note, rewrite the parent line and its children together in ONE change block — the parent line as the SEARCH text, the parent plus its indented children as the replacement. A sub-bullet appended on its own lands at the end of the note, detached from the point it belongs to.

    Never invent facts, owners, dates, or numbers the transcript does not support. When a sentence is cut off or a term is unclear, keep the speaker's own wording and mark it, rather than guessing at what they meant.
    """

    public static let diffContract = """
    Return ONLY change blocks in exactly this format, nothing else — no preamble, no explanation, no code fences:

    <<<<<<< SEARCH
    the exact existing lines to replace
    =======
    the new lines
    >>>>>>> REPLACE

    Leave the SEARCH part empty to append new lines at the end of the note. The SEARCH text must be copied character for character from the current note; if you cannot copy it exactly, use an append block instead. Emit one block per place you are changing, and change only what the new transcript actually affects — leave every other part of the note untouched. If the new transcript adds nothing worth recording, return nothing at all.

    Rewriting an existing line to absorb new material is normal and expected — that is how the note stays short. Prefer a SEARCH/REPLACE block over an append block whenever the new material belongs with something already written down.
    """

    public static let languageRule = PostProcessingPrompt.languageRule

    /// 整条 instructions。
    public static func instructions(memoryContext: String = "") -> String {
        let head = "\(structure)\n\n\(diffContract)\n\n\(languageRule) \(guardRule)"
        return PostProcessingPrompt.appendingMemoryContext(head, memoryContext)
    }

    /// 输入体：当前笔记 + 这一批新内容。
    ///
    /// 笔记为空时说清楚「还没有笔记」—— 否则模型会对着一段空白纠结要不要
    /// 用 SEARCH 块。
    public static func userBody(note: String, transcript: String) -> String {
        let current = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Current meeting note:
        \(current.isEmpty ? "(empty — this is the first update, use append blocks)" : current)

        New transcript to fold in:
        \(transcript)
        """
    }
}
