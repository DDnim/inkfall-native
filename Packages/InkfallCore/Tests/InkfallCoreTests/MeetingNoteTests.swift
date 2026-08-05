import XCTest
@testable import InkfallCore

// 自动会议笔记（beta）里不需要活的 App 环境的那两半：合批调度、增量合并。
//
// 真正调模型那一层在 App 里（`MeetingNoteController`），靠 `--meeting-note-test`
// 真机验证。

final class MeetingNoteSchedulerTests: XCTestCase {

    private let hundred = String(repeating: "字", count: 100)

    // MARK: - 第一批的字数门槛

    /// 会议刚开头几句话不该触发 —— 那会得到一份「张三说了你好」的笔记。
    func testFirstBatchWaitsForEnoughContent() {
        var scheduler = MeetingNoteScheduler()
        XCTAssertNil(scheduler.append("大家好"))
        XCTAssertNil(scheduler.append("我们开始吧"))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(scheduler.pending.count, 2, "攒着，一条都不能丢")
    }

    /// 够了字数就把**攒下的全部**一次送出去，而不是只送最后那一段。
    func testCrossingTheThresholdSendsEverythingAccumulated() throws {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append("第一段")
        _ = scheduler.append("第二段")
        let batch = try XCTUnwrap(scheduler.append(hundred))
        XCTAssertTrue(batch.contains("第一段"))
        XCTAssertTrue(batch.contains("第二段"))
        XCTAssertTrue(batch.contains(hundred))
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    /// 门槛只管第一批。之后哪怕只多了三个字也照跑。
    func testLaterBatchesIgnoreTheThreshold() throws {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append(hundred)
        XCTAssertNil(scheduler.finish(), "没有积压")
        let next = try XCTUnwrap(scheduler.append("好的"))
        XCTAssertEqual(next, "好的")
    }

    // MARK: - 合批（这条最要紧）

    /// 上一轮在飞时，新段只攒不发 —— 否则会排起一条永远追不上的队。
    func testSegmentsArrivingDuringARunAreHeld() {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append(hundred)
        XCTAssertTrue(scheduler.isRunning)

        XCTAssertNil(scheduler.append("跑的时候来的第一段"))
        XCTAssertNil(scheduler.append("第二段"))
        XCTAssertNil(scheduler.append("第三段"))
        XCTAssertEqual(scheduler.pending.count, 3)
    }

    /// 一轮结束时，攒下的三段**合成一次**跑掉，而不是排三轮。
    func testFinishCoalescesEverythingIntoOneBatch() throws {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append(hundred)
        _ = scheduler.append("甲")
        _ = scheduler.append("乙")
        _ = scheduler.append("丙")

        let batch = try XCTUnwrap(scheduler.finish())
        XCTAssertEqual(batch, "甲\n\n乙\n\n丙")
        XCTAssertTrue(scheduler.isRunning, "接着就跑，不等下一段来触发")
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    /// 没有积压时结束就是真的空闲了。
    func testFinishWithoutBacklogGoesIdle() {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append(hundred)
        XCTAssertNil(scheduler.finish())
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(scheduler.hasOutstandingWork)
    }

    /// **一条都不能丢**：一场 60 段的会议，无论加工快慢，每一段的内容
    /// 最后都必须出现在某一批里。
    func testNoSegmentIsEverLost() {
        var scheduler = MeetingNoteScheduler()
        var sent = ""
        // 每 3 段结束一轮 —— 模拟加工比说话慢得多。
        for index in 0..<60 {
            if let batch = scheduler.append("段\(index)。") { sent += batch }
            if index % 3 == 2, let batch = scheduler.finish() { sent += batch }
        }
        while scheduler.hasOutstandingWork {
            if let batch = scheduler.finish() { sent += batch } else { break }
        }
        for index in 0..<60 {
            XCTAssertTrue(sent.contains("段\(index)。"), "第 \(index) 段丢了")
        }
    }

    /// 同一时刻绝不允许两轮在飞。
    func testNeverStartsASecondRunWhileOneIsInFlight() {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append(hundred)
        for index in 0..<20 {
            XCTAssertNil(scheduler.append("并发 \(index)"), "上一轮没结束就不该再发一批")
        }
    }

    // MARK: - 收尾

    /// 会话结束：一场只说了 80 个字的短会也该有它的笔记。
    func testFlushIgnoresTheThreshold() throws {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append("很短的一场会")
        XCTAssertFalse(scheduler.isRunning)
        let batch = try XCTUnwrap(scheduler.flush())
        XCTAssertEqual(batch, "很短的一场会")
    }

    /// 还有一轮在飞时 flush 不插队 —— 那一轮结束时 `finish()` 会把积压带走。
    func testFlushDoesNotJumpAheadOfARunningPass() {
        var scheduler = MeetingNoteScheduler()
        _ = scheduler.append(hundred)
        _ = scheduler.append("积压")
        XCTAssertNil(scheduler.flush())
        XCTAssertEqual(scheduler.pending, ["积压"])
    }
}

// MARK: - 增量合并

final class MeetingNoteDiffTests: XCTestCase {

    private func block(_ search: String, _ replacement: String) -> String {
        """
        <<<<<<< SEARCH
        \(search)
        =======
        \(replacement)
        >>>>>>> REPLACE
        """
    }

    func testParsesMultipleBlocksAndIgnoresChatter() {
        let output = """
        好的，我把新的内容合进去了：

        \(block("## 待办", "## 待办\n- 小李：周一前给报表"))

        另外还有一处：

        \(block("", "## 风险\n- 供应商交期不确定"))
        """
        let blocks = MeetingNoteDiff.parse(output)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].search, "## 待办")
        XCTAssertTrue(blocks[1].isAppend, "空 SEARCH = 追加")
    }

    func testReplaceAndAppend() {
        let note = "## 议题\n- 季度报表\n\n## 待办\n- 小李：出报表"
        let blocks = MeetingNoteDiff.parse(
            block("- 小李：出报表", "- 小李：周一前出报表") + "\n"
            + block("", "## 决定\n- 先做最小版本"))
        let result = MeetingNoteDiff.merge(blocks, into: note)
        XCTAssertTrue(result.text.contains("- 小李：周一前出报表"))
        XCTAssertTrue(result.text.hasSuffix("## 决定\n- 先做最小版本"))
        XCTAssertEqual(result.applied, 2)
        XCTAssertEqual(result.recovered, 0)
    }

    /// ⚠️ 一个块没匹配上，**绝不能把整批扔掉** —— 那一批里可能还有五条真实
    /// 的会议结论。退化成追加，并报出来。
    func testUnmatchedSearchFallsBackToAppendInsteadOfDroppingContent() {
        let note = "## 议题\n- 季度报表"
        let blocks = MeetingNoteDiff.parse(
            block("- 这一行笔记里根本没有", "- 小王：下周二演示"))
        let result = MeetingNoteDiff.merge(blocks, into: note)
        XCTAssertTrue(result.text.contains("- 小王：下周二演示"), "内容不能丢")
        XCTAssertEqual(result.recovered, 1)
        XCTAssertEqual(result.applied, 0)
    }

    /// 但已经在笔记里的内容不能被追加第二遍。
    func testAlreadyPresentContentIsNotDuplicated() {
        let note = "## 待办\n- 小李：周一前出报表"
        let blocks = MeetingNoteDiff.parse(block("", "- 小李：周一前出报表"))
        let result = MeetingNoteDiff.merge(blocks, into: note)
        XCTAssertEqual(result.text, note)
        XCTAssertEqual(result.skipped, 1)
    }

    /// 判重要容得下空白与标点的抖动 —— 模型在这两件事上从不稳定。
    func testDuplicateDetectionToleratesPunctuationDrift() {
        let note = "## 待办\n- 小李：周一前出报表"
        let blocks = MeetingNoteDiff.parse(block("", "- 小李，周一前出报表。"))
        XCTAssertEqual(MeetingNoteDiff.merge(blocks, into: note).skipped, 1)
    }

    /// 第一次更新：笔记是空的，全部走追加。
    func testFirstUpdateOnAnEmptyNote() {
        let blocks = MeetingNoteDiff.parse(block("", "## 议题\n- 季度报表"))
        let result = MeetingNoteDiff.merge(blocks, into: "")
        XCTAssertEqual(result.text, "## 议题\n- 季度报表")
    }

    /// 模型什么都没输出 = 这一批没有值得记的东西，笔记原样不动。
    func testEmptyOutputLeavesTheNoteAlone() {
        let note = "## 议题\n- 季度报表"
        XCTAssertEqual(MeetingNoteDiff.merge(MeetingNoteDiff.parse(""), into: note).text, note)
        XCTAssertEqual(MeetingNoteDiff.merge(MeetingNoteDiff.parse("没有需要更新的内容。"),
                                             into: note).text, note)
    }

    /// 残缺的块（只有开头没有结尾）不能把已有笔记搞坏。
    func testTruncatedBlockIsIgnored() {
        let broken = "<<<<<<< SEARCH\n## 议题\n=======\n## 议题\n- 新的"
        let note = "## 议题\n- 季度报表"
        XCTAssertTrue(MeetingNoteDiff.parse(broken).isEmpty)
        XCTAssertEqual(MeetingNoteDiff.merge(MeetingNoteDiff.parse(broken), into: note).text, note)
    }
}

// MARK: - 高亮最近两轮的改动

final class MeetingNoteChangedLinesTests: XCTestCase {

    /// 只有真正新增/改写的行算改动 —— 没动过的行不能被标亮，
    /// 否则每跳一次整篇都在闪。
    func testOnlyNewLinesCount() {
        let before = "## 议题\n- 季度报表\n- 新功能排期"
        let after = "## 议题\n- 季度报表\n- 新功能排期\n- 供应商风险"
        XCTAssertEqual(MeetingNoteDiff.changedLines(from: before, to: after),
                       ["- 供应商风险"])
    }

    /// ⚠️ 改写一行会让它后面所有行的**行号**都变，所以身份必须是行文本
    /// 而不是行号 —— 否则一次小改动会把整篇算成改动。
    func testRewritingOneLineDoesNotMarkTheRest() {
        let before = "## 议题\n- 报表\n- 排期\n- 风险"
        let after = "## 议题\n- 报表：明天五点前交\n- 排期\n- 风险"
        XCTAssertEqual(MeetingNoteDiff.changedLines(from: before, to: after),
                       ["- 报表：明天五点前交"])
    }

    /// 第一轮：整篇都是新的。
    func testFirstUpdateMarksEverything() {
        let changed = MeetingNoteDiff.changedLines(from: "", to: "## 议题\n- 季度报表")
        XCTAssertEqual(changed, ["## 议题", "- 季度报表"])
    }

    /// 什么都没变时不该标出任何行。
    func testNoChangeMarksNothing() {
        let note = "## 议题\n- 季度报表"
        XCTAssertTrue(MeetingNoteDiff.changedLines(from: note, to: note).isEmpty)
    }

    /// 空行与缩进的抖动不算改动 —— 模型在这两件事上从不稳定。
    func testWhitespaceDriftIsNotAChange() {
        let before = "## 议题\n- 季度报表"
        let after = "## 议题\n\n  - 季度报表  \n"
        XCTAssertTrue(MeetingNoteDiff.changedLines(from: before, to: after).isEmpty)
    }
}
