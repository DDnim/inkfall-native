import XCTest
@testable import InkfallCore

final class MarkdownEditingTests: XCTestCase {

    // MARK: - 回车续列表

    func testContinuesUnorderedList() {
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "- 甲"), "- ")
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "* 甲"), "* ")
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "+ 甲"), "+ ")
    }

    func testContinuesOrderedListWithIncrementedNumber() {
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "3. 甲"), "4. ")
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "9) 甲"), "10) ")
    }

    func testContinuesTaskListAlwaysUnchecked() {
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "- [ ] 甲"), "- [ ] ")
        // 上一项勾了，新的一项也该是空的 —— 不继承勾选状态。
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "- [x] 甲"), "- [ ] ")
    }

    func testPreservesIndent() {
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "    - 甲"), "    - ")
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "  2. 甲"), "  3. ")
    }

    /// 空列表项上回车 = 退出列表。这是唯一的退出方式，丢了它列表就出不去。
    func testEmptyItemExitsList() {
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "- "), "")
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "1. "), "")
        XCTAssertEqual(MarkdownEditing.listContinuation(forLine: "- [ ] "), "")
    }

    func testPlainParagraphIsNotAList() {
        XCTAssertNil(MarkdownEditing.listContinuation(forLine: "普通一行"))
        XCTAssertNil(MarkdownEditing.listContinuation(forLine: ""))
        // 少了标记后面的空格就不是列表，`-甲` 是普通文本。
        XCTAssertNil(MarkdownEditing.listContinuation(forLine: "-甲"))
        // 破折号开头的中文句子不该被当成列表。
        XCTAssertNil(MarkdownEditing.listContinuation(forLine: "—— 他这么说"))
    }

    func testLineAtLocation() {
        let text = "第一行\n第二行\n第三行"
        XCTAssertEqual(MarkdownEditing.line(in: text, at: 0), "第一行")
        XCTAssertEqual(MarkdownEditing.line(in: text, at: 5), "第二行")
        XCTAssertEqual(MarkdownEditing.line(in: text, at: text.count), "第三行")
    }

    // MARK: - 包裹

    func testWrapsSelection() {
        let edit = MarkdownEditing.toggleWrap("甲乙丙", selection: NSRange(location: 1, length: 1),
                                              marker: "**")
        XCTAssertEqual(edit.text, "甲**乙**丙")
        XCTAssertEqual(edit.selection, NSRange(location: 3, length: 1))
    }

    func testUnwrapsWhenMarkersInsideSelection() {
        let edit = MarkdownEditing.toggleWrap("甲**乙**丙", selection: NSRange(location: 1, length: 5),
                                              marker: "**")
        XCTAssertEqual(edit.text, "甲乙丙")
        XCTAssertEqual(edit.selection, NSRange(location: 1, length: 1))
    }

    /// 用户双击选中的是「乙」，标记在选区外面 —— 也得能解开，
    /// 否则再按一次 ⌘B 会得到 `甲****乙****丙`。
    func testUnwrapsWhenMarkersOutsideSelection() {
        let edit = MarkdownEditing.toggleWrap("甲**乙**丙", selection: NSRange(location: 3, length: 1),
                                              marker: "**")
        XCTAssertEqual(edit.text, "甲乙丙")
        XCTAssertEqual(edit.selection, NSRange(location: 1, length: 1))
    }

    func testEmptySelectionPutsCaretBetweenMarkers() {
        let edit = MarkdownEditing.toggleWrap("甲乙", selection: NSRange(location: 1, length: 0),
                                              marker: "*")
        XCTAssertEqual(edit.text, "甲**乙")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    // MARK: - 缩进

    func testIndentsEveryLineInSelection() {
        let edit = MarkdownEditing.indent("- 甲\n- 乙", selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(edit.text, "  - 甲\n  - 乙")
    }

    /// 选区为空也要作用于光标所在行 —— 在列表里按 Tab 想要的是降一级。
    func testIndentsCaretLineWhenSelectionEmpty() {
        let edit = MarkdownEditing.indent("- 甲\n- 乙", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(edit.text, "  - 甲\n- 乙")
    }

    func testOutdentLeavesUnindentedLinesAlone() {
        let edit = MarkdownEditing.outdent("  - 甲\n- 乙", selection: NSRange(location: 0, length: 9))
        XCTAssertEqual(edit.text, "- 甲\n- 乙")
    }

    func testOutdentHandlesTabAndSingleSpace() {
        XCTAssertEqual(
            MarkdownEditing.outdent("\t- 甲", selection: NSRange(location: 0, length: 4)).text,
            "- 甲")
        XCTAssertEqual(
            MarkdownEditing.outdent(" - 甲", selection: NSRange(location: 0, length: 4)).text,
            "- 甲")
    }
}

final class DraftHistoryTests: XCTestCase {

    func testUndoRestoresPreviousSnapshot() {
        var history = DraftHistory(initial: "甲")
        history.record("甲乙", at: 0)
        history.record("甲乙丙", at: 10)
        XCTAssertEqual(history.undo(), "甲乙")
        XCTAssertEqual(history.undo(), "甲")
        XCTAssertNil(history.undo())
    }

    /// 连续打字合并成一步 —— 否则 ⌘Z 变成一个字一个字往回退。
    func testCoalescesRapidEdits() {
        var history = DraftHistory(initial: "")
        history.record("甲", at: 0)
        history.record("甲乙", at: 0.2)
        history.record("甲乙丙", at: 0.5)
        XCTAssertEqual(history.undo(), "")
        XCTAssertFalse(history.canUndo)
    }

    func testPauseStartsANewStep() {
        var history = DraftHistory(initial: "")
        history.record("甲", at: 0)
        history.record("甲乙", at: 5)
        XCTAssertEqual(history.undo(), "甲")
        XCTAssertEqual(history.undo(), "")
    }

    func testRedo() {
        var history = DraftHistory(initial: "甲")
        history.record("甲乙", at: 10)
        XCTAssertEqual(history.undo(), "甲")
        XCTAssertEqual(history.redo(), "甲乙")
        XCTAssertNil(history.redo())
    }

    /// 撤销之后再编辑，重做分支必须作废 —— 标准撤销语义。
    func testEditAfterUndoDropsRedoBranch() {
        var history = DraftHistory(initial: "甲")
        history.record("甲乙", at: 10)
        _ = history.undo()
        history.record("甲丙", at: 20)
        XCTAssertFalse(history.canRedo)
    }

    func testUnchangedTextIsNotRecorded() {
        var history = DraftHistory(initial: "甲")
        history.record("甲", at: 10)
        XCTAssertFalse(history.canUndo)
    }

    /// 换一篇笔记必须清空 —— 否则 ⌘Z 会把上一篇的正文倒进这一篇。
    func testResetClearsHistory() {
        var history = DraftHistory(initial: "甲")
        history.record("甲乙", at: 10)
        history.reset(to: "另一篇")
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}

/// 说话人标签的排版约定：**换行，不是分段**。
///
/// 渲染端配套要求 `markdownSoftBreakMode(.lineBreak)` —— CommonMark 默认
/// 把单个 `\n` 当空格，不配套的话所有轮次会糊在一行里。
final class SpeakerTranscriptLayoutTests: XCTestCase {

    func testTurnsAreSeparatedBySingleNewline() {
        let out = SpeakerTranscript.compose([
            .init(speaker: 0, text: "今天先对一下排期"),
            .init(speaker: 1, text: "我这边下周三能给"),
            .init(speaker: 0, text: "好"),
        ])
        XCTAssertTrue(out.labeled)
        XCTAssertEqual(out.speakerCount, 2)
        XCTAssertEqual(out.text,
                       "说话人 1：今天先对一下排期\n说话人 2：我这边下周三能给\n说话人 1：好")
        // 单换行，不是空行分段。
        XCTAssertFalse(out.text.contains("\n\n"))
    }

    /// 只有一个人说话时不打标签 —— 独白加「说话人 1：」只是噪声。
    func testMonologueIsNotLabeled() {
        let out = SpeakerTranscript.compose([
            .init(speaker: 0, text: "甲"),
            .init(speaker: 0, text: "乙"),
        ])
        XCTAssertFalse(out.labeled)
        XCTAssertFalse(out.text.contains("说话人"))
    }
}
