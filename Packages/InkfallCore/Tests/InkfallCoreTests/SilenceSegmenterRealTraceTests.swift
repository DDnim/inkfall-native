import XCTest
@testable import InkfallCore

/// 自动断句的验收：**真实电平序列 + 一组必须不误切的合成用例**。
///
/// 背景：旧的噪声底估计只在「非语音」时允许上升，会自锁 —— 会话在真静音里
/// 起录，底噪被播种在 epsilon，退出语音的门槛被绝对下限钉死在 0.0025，
/// 而真实停顿的最低电平是 0.0042，于是永远出不了语音态、底噪也永远追不上去。
/// 那一版在下面**所有合成用例上都正常**，偏偏在真机序列上一刀都切不出来，
/// 所以这个文件同时留着两类用例，缺一不可。
final class SilenceSegmenterRealTraceTests: XCTestCase {

    private func cuts(_ frames: [(Double, Float)],
                      config: SilenceSegmenterConfig = .default) -> [Double] {
        var segmenter = SilenceSegmenter(config: config)
        var elapsed = 0.0
        var result: [Double] = []
        for (delta, level) in frames {
            elapsed += delta
            if segmenter.feed(level: level, delta: delta) {
                result.append((elapsed * 100).rounded() / 100)
            }
        }
        return result
    }

    private func flat(_ count: Int, _ level: Float) -> [(Double, Float)] {
        Array(repeating: (1.0 / 30, level), count: count)
    }

    // MARK: - 真机序列

    /// 17.6 秒、含一个 2.3 秒自然停顿的真实录音必须切出段来。
    /// 这是旧算法唯一失败、也是唯一能暴露自锁的用例。
    func testRealPausedDialogGetsSegmented() {
        let result = cuts(RecordedLevelTrace.pausedDialog)
        XCTAssertFalse(result.isEmpty,
                       "真实停顿切不出段 —— 噪声底大概率又自锁在 epsilon 上了")
        // 第一刀应落在那个 2.3 秒停顿里（约 3.9s–6.2s）。
        guard let first = result.first else { return }
        XCTAssertGreaterThan(first, 3.5)
        XCTAssertLessThan(first, 7.0)
    }

    // MARK: - 不许误切

    /// 电平恒定的持续说话绝不能切 —— 窗口最小值等于语音本身，
    /// 没有「底噪对语音峰值封顶」的话底噪会一路爬到语音高度，切出一堆假段。
    func testSteadySpeechNeverCuts() {
        XCTAssertEqual(cuts(flat(600, 0.08)), [])
    }

    func testSilenceOnlyNeverCuts() {
        XCTAssertEqual(cuts(flat(600, 0.0001)), [])
    }

    /// 句中 0.4 秒的短停顿不该切（阈值是 1.3 秒）。
    func testShortPauseDoesNotCut() {
        XCTAssertEqual(cuts(flat(90, 0.08) + flat(12, 0.0009) + flat(90, 0.08)), [])
    }

    /// 渐弱的说话不该被当成停顿。
    func testFadingSpeechDoesNotCut() {
        let frames = (0..<600).map { i in
            (1.0 / 30, Float(0.08 * exp(-Double(i) / 400)))
        }
        XCTAssertEqual(cuts(frames), [])
    }

    // MARK: - 该切的要切

    func testClearPauseCutsExactlyOnce() {
        let result = cuts(flat(150, 0.08) + flat(90, 0.0009) + flat(150, 0.08))
        XCTAssertEqual(result.count, 1)
    }

    /// 嘈杂环境：底噪 0.02、语音 0.15，同样要能切。
    /// 相对判定的意义就在这里 —— 固定阈值在这一档会全程判成语音。
    func testNoisyRoomStillCuts() {
        let result = cuts(flat(150, 0.15) + flat(90, 0.02) + flat(150, 0.15))
        XCTAssertEqual(result.count, 1)
    }

    /// 关掉自动断句的那条路由在调用方，这里只确认切段后状态会重置：
    /// 持续静音不能反复触发，必须重新累计语音。
    func testOneCutPerPause() {
        let result = cuts(flat(150, 0.08) + flat(300, 0.0009))
        XCTAssertEqual(result.count, 1)
    }
}
