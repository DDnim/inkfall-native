import XCTest
@testable import InkfallCore

/// 暂停期间**计时必须冻住**。
///
/// 用 `now - startedAt` 算已录秒数，暂停十分钟回来会看到「已录 12:30」，
/// 而音频里只有 2 分半 —— 那个数字是给用户判断「这段够不够长」用的，
/// 一旦掺进墙钟时间就彻底失去意义。
final class SessionClockTests: XCTestCase {

    func testCountsFromStart() {
        var clock = SessionClock()
        clock.start(at: 100)
        XCTAssertEqual(clock.elapsed(at: 105), 5, accuracy: 0.001)
    }

    func testFreezesWhilePaused() {
        var clock = SessionClock()
        clock.start(at: 100)
        clock.pause(at: 105)
        XCTAssertEqual(clock.elapsed(at: 105), 5, accuracy: 0.001)
        // 暂停里过了 10 分钟，读数一动不动。
        XCTAssertEqual(clock.elapsed(at: 705), 5, accuracy: 0.001)
    }

    func testResumeContinuesFromWhereItStopped() {
        var clock = SessionClock()
        clock.start(at: 100)
        clock.pause(at: 105)
        clock.resume(at: 705)
        XCTAssertEqual(clock.elapsed(at: 705), 5, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(at: 710), 10, accuracy: 0.001)
    }

    func testMultiplePausesAccumulate() {
        var clock = SessionClock()
        clock.start(at: 0)
        clock.pause(at: 10)      // 攒了 10
        clock.resume(at: 100)
        clock.pause(at: 103)     // 攒了 13
        clock.resume(at: 200)
        XCTAssertEqual(clock.elapsed(at: 207), 20, accuracy: 0.001)
    }

    /// 重复调用不该把时间算两遍 —— 暂停有好几个入口（hover 条、面板、快捷键），
    /// 谁都可能在已经暂停的状态下再按一次。
    func testRepeatedPauseAndResumeAreIdempotent() {
        var clock = SessionClock()
        clock.start(at: 0)
        clock.pause(at: 10)
        clock.pause(at: 50)
        XCTAssertEqual(clock.elapsed(at: 60), 10, accuracy: 0.001)
        clock.resume(at: 60)
        clock.resume(at: 90)
        XCTAssertEqual(clock.elapsed(at: 70), 20, accuracy: 0.001)
    }

    func testStartResetsEverything() {
        var clock = SessionClock()
        clock.start(at: 0)
        clock.pause(at: 30)
        clock.start(at: 1000)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 1002), 2, accuracy: 0.001)
    }

    /// 没起过的时钟读 0，不是负数、不是墙钟。
    func testIdleClockReadsZero() {
        let clock = SessionClock()
        XCTAssertEqual(clock.elapsed(at: 12345), 0, accuracy: 0.001)
    }
}
