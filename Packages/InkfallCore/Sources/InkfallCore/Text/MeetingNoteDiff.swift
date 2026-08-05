import Foundation

/// 会议笔记的增量合并。
///
/// ## 为什么是 diff 而不是「整篇重写」
///
/// 会议笔记是**边开边长**的：每来一批新内容，模型要在已有笔记上改。让它
/// 每次重吐整篇有三个问题 —— 输出 token 随会议时长线性上涨、已经稳定的段落
/// 会被无意义地重写（用户正看着的文字在跳）、而且长笔记重写容易丢内容。
///
/// 所以约定模型只输出**改动块**：
///
/// ```
/// <<<<<<< SEARCH
/// 要被替换的原文（逐字）
/// =======
/// 替换成的新内容
/// >>>>>>> REPLACE
/// ```
///
/// SEARCH 为空 = 追加到笔记末尾（新议题、新待办都走这条）。
/// 这个格式是模型最熟的一种（各家编码助手都在用），解析与合并都是确定性的。
public enum MeetingNoteDiff {

    public static let searchMarker = "<<<<<<< SEARCH"
    public static let separatorMarker = "======="
    public static let replaceMarker = ">>>>>>> REPLACE"

    public struct Block: Sendable, Equatable {
        public let search: String
        public let replacement: String

        public init(search: String, replacement: String) {
            self.search = search
            self.replacement = replacement
        }

        /// 空 SEARCH = 追加。
        public var isAppend: Bool {
            search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public struct MergeResult: Sendable, Equatable {
        public let text: String
        /// 成功应用的块数。
        public let applied: Int
        /// SEARCH 没匹配上、改走追加的块数。模型偶尔会把原文记错一个字，
        /// 那时**宁可追加也不能丢**——但要报出来，多了就说明提示词该修了。
        public let recovered: Int
        /// 整块被跳过（内容已经在笔记里，追加会重复）。
        public let skipped: Int
    }

    /// 从模型输出里挑出所有改动块。块外的解释文字一律忽略 ——
    /// 模型总会忍不住写两句「好的，我更新了笔记」。
    public static func parse(_ output: String) -> [Block] {
        var blocks: [Block] = []
        var lines = output.components(separatedBy: .newlines)[...]

        while let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces)
            .hasPrefix(searchMarker) }) {
            lines = lines[(start + 1)...]
            guard let separator = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == separatorMarker
            }) else { break }
            let search = lines[..<separator].joined(separator: "\n")
            lines = lines[(separator + 1)...]
            guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces)
                .hasPrefix(replaceMarker) }) else { break }
            let replacement = lines[..<end].joined(separator: "\n")
            lines = lines[(end + 1)...]
            blocks.append(Block(search: search, replacement: replacement))
        }
        return blocks
    }

    /// 把改动块合并进笔记。
    ///
    /// ⚠️ **绝不因为一个块没匹配上就整批放弃**：那一批里可能有五条真实的会议
    /// 结论，为了一处对不上的引用把它们全扔掉是最坏的选择。匹配不上的块
    /// 退化成追加（除非内容已经在笔记里）。
    public static func merge(_ blocks: [Block], into note: String) -> MergeResult {
        var text = note
        var applied = 0
        var recovered = 0
        var skipped = 0

        for block in blocks {
            let replacement = block.replacement.trimmingCharacters(in: .whitespacesAndNewlines)

            if block.isAppend {
                guard !replacement.isEmpty else { continue }
                guard !contains(text, replacement) else { skipped += 1; continue }
                text = append(replacement, to: text)
                applied += 1
                continue
            }

            let search = block.search.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = text.range(of: search) {
                text.replaceSubrange(range, with: replacement)
                applied += 1
            } else if replacement.isEmpty {
                // 想删一段却没找到 —— 什么都不做，别乱猜。
                skipped += 1
            } else if contains(text, replacement) {
                skipped += 1
            } else {
                text = append(replacement, to: text)
                recovered += 1
            }
        }

        return MergeResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           applied: applied, recovered: recovered, skipped: skipped)
    }

    /// 这一轮之后**哪几行是新的**（按行文本比对）。
    ///
    /// 用来把最近两轮的改动在界面上高亮出来 —— 会议笔记是隔十几秒跳变一次的，
    /// 不标出来的话用户根本不知道刚才那一跳改了什么，只能从头再读一遍。
    ///
    /// 用「行文本」而不是行号做身份：改写一行会让它后面所有行的行号都变，
    /// 按行号比对会把整篇都算成改动。
    public static func changedLines(from before: String, to after: String) -> Set<String> {
        let old = Set(lines(of: before))
        return Set(lines(of: after).filter { !old.contains($0) })
    }

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func append(_ addition: String, to note: String) -> String {
        let base = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? addition : base + "\n\n" + addition
    }

    /// 判重用宽松一点的比较：模型在空白与标点上不稳定，
    /// 逐字比较会让同一条结论被追加两遍。
    private static func contains(_ note: String, _ candidate: String) -> Bool {
        let normalizedNote = normalize(note)
        let normalizedCandidate = normalize(candidate)
        guard !normalizedCandidate.isEmpty else { return true }
        return normalizedNote.contains(normalizedCandidate)
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
    }
}
