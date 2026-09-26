import XCTest
@testable import InkfallCore

// 自动断句的合成用例（从减法前的 CoreTests 原样搬回）。真实电平序列在 SilenceSegmenterRealTraceTests。

final class SilenceSegmenterTests: XCTestCase {

    private let frame = 0.05          // 50 ms 采样，与协调器一致
    private let speech: Float = 0.05
    private let silence: Float = 0.0

    /// 恒定电平喂 `seconds` 秒，返回这期间有没有切过。
    private func feed(_ seg: inout SilenceSegmenter, _ level: Float, _ seconds: Double) -> Bool {
        var cut = false
        for _ in 0..<Int((seconds / frame).rounded()) {
            if seg.feed(level: level, delta: frame) { cut = true }
        }
        return cut
    }

    func testLeadingSilenceNeverCuts() {
        var seg = SilenceSegmenter()
        XCTAssertFalse(feed(&seg, silence, 30))
    }

    func testPauseAfterSpeechCutsExactlyOnce() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)      // 冷启动播种
        XCTAssertFalse(feed(&seg, speech, 1.0))
        XCTAssertTrue(feed(&seg, silence, 1.5))         // ~1.3 s 静音切一次
        XCTAssertFalse(feed(&seg, silence, 10))         // 持续静音不再触发
    }

    func testShortPauseMidSpeechDoesNotCut() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        XCTAssertFalse(feed(&seg, speech, 1.0))
        XCTAssertFalse(feed(&seg, silence, 0.8))        // < 1.3 s
        XCTAssertFalse(feed(&seg, speech, 1.0))
        XCTAssertFalse(feed(&seg, silence, 0.8))
    }

    func testSpeechAfterCutRearmsForTheNextPause() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        XCTAssertTrue(feed(&seg, silence, 1.5))
        _ = feed(&seg, speech, 1.0)
        XCTAssertTrue(feed(&seg, silence, 1.5))
    }

    func testStrayNoiseBelowMinSpeechDoesNotArm() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        XCTAssertFalse(feed(&seg, speech, 0.2))         // < minSpeechSeconds
        XCTAssertFalse(feed(&seg, silence, 5))
    }

    func testResetSegmentClearsArming() {
        var seg = SilenceSegmenter()
        _ = seg.feed(level: silence, delta: frame)
        _ = feed(&seg, speech, 1.0)
        seg.resetSegment()
        XCTAssertFalse(feed(&seg, silence, 5), "手动切段后，静音不该在空段上再切")
    }

    func testNonPositiveDeltaIsIgnored() {
        var seg = SilenceSegmenter()
        XCTAssertFalse(seg.feed(level: speech, delta: 0))
        XCTAssertFalse(seg.feed(level: speech, delta: -1))
    }
}
