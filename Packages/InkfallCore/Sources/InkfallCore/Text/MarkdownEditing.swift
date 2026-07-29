import Foundation

/// Markdown 编辑器里那几个「本来就该有」的行为：回车续列表、⌘B/⌘I 包裹、
/// Tab 缩进。
///
/// 全是纯文本运算，不碰 NSTextView —— 所以能测。宿主那边只负责把
/// 「当前正文 + 选区」递进来，再把结果写回去。
public enum MarkdownEditing {

    /// 一次编辑的结果：新正文 + 新选区。
    public struct Edit: Equatable, Sendable {
        public let text: String
        public let selection: NSRange
        public init(text: String, selection: NSRange) {
            self.text = text
            self.selection = selection
        }
    }

    // MARK: - 回车续列表

    /// 敲回车时该自动补上的列表前缀。
    ///
    /// - 在 `- 甲` 后面回车 → 下一行自动是 `- `
    /// - 在 `3. 甲` 后面回车 → 下一行自动是 `4. `（序号会递增）
    /// - 在 `- [ ] 甲` 后面回车 → 下一行自动是 `- [ ] `（未勾选，不继承勾选状态）
    /// - 在**空的**列表项（只有标记没有内容）后面回车 → 返回空串，
    ///   表示「把这一行的标记清掉」。这是所有 markdown 编辑器的共同约定，
    ///   也是唯一能退出列表的方式。
    /// - 普通段落 → nil，回车就是回车。
    public static func listContinuation(forLine line: String) -> String? {
        guard let marker = listMarker(of: line) else { return nil }
        let content = String(line.dropFirst(marker.raw.count))
        // 空列表项：回车 = 退出列表。
        if content.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return marker.next
    }

    private struct Marker {
        /// 原样的前缀，含缩进与尾随空格。
        let raw: String
        /// 下一行该用的前缀。
        let next: String
    }

    private static func listMarker(of line: String) -> Marker? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = String(line.dropFirst(indent.count))

        // 任务列表要先于无序列表判断 —— `- [ ] ` 的前缀本身就是 `- `。
        for bullet in ["- ", "* ", "+ "] {
            if rest.hasPrefix(bullet) {
                let afterBullet = String(rest.dropFirst(bullet.count))
                for box in ["[ ] ", "[x] ", "[X] "] where afterBullet.hasPrefix(box) {
                    return Marker(raw: indent + bullet + box,
                                  // 新的一项永远是未勾选的。
                                  next: indent + bullet + "[ ] ")
                }
                return Marker(raw: indent + bullet, next: indent + bullet)
            }
        }

        // 有序列表：`12. ` / `12) `
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        for sep in [". ", ") "] where afterDigits.hasPrefix(sep) {
            return Marker(raw: indent + digits + sep,
                          next: indent + "\(number + 1)" + sep)
        }
        return nil
    }

    /// 光标所在行的内容（不含换行符）。
    public static func line(in text: String, at location: Int) -> String {
        let chars = Array(text)
        let clamped = max(0, min(location, chars.count))
        var start = clamped
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = clamped
        while end < chars.count, chars[end] != "\n" { end += 1 }
        return String(chars[start..<end])
    }

    // MARK: - ⌘B / ⌘I 包裹

    /// 用 `marker` 包裹选中的文字；已经被包裹的就解开（开关式）。
    ///
    /// 选区为空时插入一对标记并把光标放进中间 —— 敲 ⌘B 然后直接打字是
    /// 最常见的用法，不该逼用户先选中再加粗。
    public static func toggleWrap(_ text: String, selection: NSRange,
                                  marker: String) -> Edit {
        let chars = Array(text)
        let start = max(0, min(selection.location, chars.count))
        let end = max(start, min(start + selection.length, chars.count))
        let selected = String(chars[start..<end])
        let width = marker.count

        // 已经包裹了 → 解开。两种写法都要认：标记在选区**内**、或在选区**外**。
        if selected.count >= width * 2,
           selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(width).dropLast(width))
            let new = String(chars[0..<start]) + inner + String(chars[end...])
            return Edit(text: new, selection: NSRange(location: start, length: inner.count))
        }
        if start >= width, end + width <= chars.count,
           String(chars[(start - width)..<start]) == marker,
           String(chars[end..<(end + width)]) == marker {
            let new = String(chars[0..<(start - width)]) + selected
                + String(chars[(end + width)...])
            return Edit(text: new,
                        selection: NSRange(location: start - width, length: selected.count))
        }

        let new = String(chars[0..<start]) + marker + selected + marker + String(chars[end...])
        // 空选区：光标落在两个标记中间。有选区：整段仍然选中。
        let location = selected.isEmpty ? start + width : start + width
        return Edit(text: new, selection: NSRange(location: location, length: selected.count))
    }

    // MARK: - Tab 缩进

    public static let indentUnit = "  "

    /// 给选区覆盖到的每一行加一级缩进。选区为空时也作用于光标所在行 ——
    /// 在列表里按 Tab 想要的是「降一级」，不是插入一个制表符。
    public static func indent(_ text: String, selection: NSRange) -> Edit {
        transformLines(text, selection: selection) { indentUnit + $0 }
    }

    /// 去掉一级缩进。本来就没有缩进的行原样不动。
    public static func outdent(_ text: String, selection: NSRange) -> Edit {
        transformLines(text, selection: selection) { line in
            if line.hasPrefix(indentUnit) { return String(line.dropFirst(indentUnit.count)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            // 只有一个空格也算，别让半级缩进卡住。
            if line.hasPrefix(" ") { return String(line.dropFirst()) }
            return line
        }
    }

    private static func transformLines(_ text: String, selection: NSRange,
                                       _ transform: (String) -> String) -> Edit {
        let chars = Array(text)
        let start = max(0, min(selection.location, chars.count))
        let end = max(start, min(start + selection.length, chars.count))

        var lineStart = start
        while lineStart > 0, chars[lineStart - 1] != "\n" { lineStart -= 1 }
        var lineEnd = end
        while lineEnd < chars.count, chars[lineEnd] != "\n" { lineEnd += 1 }

        let block = String(chars[lineStart..<lineEnd])
        let rebuilt = block.components(separatedBy: "\n").map(transform)
            .joined(separator: "\n")
        let new = String(chars[0..<lineStart]) + rebuilt + String(chars[lineEnd...])
        let delta = rebuilt.count - block.count
        // 选区跟着一起长/缩，别让缩进把选中范围甩掉。
        return Edit(text: new,
                    selection: NSRange(location: lineStart,
                                       length: max(0, block.count + delta)))
    }
}
