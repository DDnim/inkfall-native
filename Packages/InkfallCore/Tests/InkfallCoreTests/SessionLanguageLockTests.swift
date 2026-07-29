import XCTest
@testable import InkfallCore

final class SessionLanguageLockTests: XCTestCase {

    private let auto = TranscriptionLanguagePolicy(
        mode: .auto, fixed: .zh, preferred: [])

    private func feed(_ languages: [TranscriptionLanguage?],
                      policy: TranscriptionLanguagePolicy? = nil)
        -> SessionLanguageLock {
        var lock = SessionLanguageLock()
        for language in languages {
            lock.observe(language, policy: policy ?? auto)
        }
        return lock
    }

    /// 前两段一致 → 第二段就锁。
    func testTwoAgreeingSegmentsLock() {
        let lock = feed([.zh, .zh])
        XCTAssertEqual(lock.locked, .zh)
    }

    /// 一段还不够 —— 这正是这次要改掉的旧行为。
    func testSingleSegmentDoesNotLock() {
        XCTAssertNil(feed([.zh]).locked)
    }

    /// 第一句被判成韩文（误判），后两句是中文 → 锁中文，不被第一句带偏。
    /// 这就是用户报的那个场景。
    func testFirstSegmentMisdetectionDoesNotWin() {
        let lock = feed([.ko, .zh, .zh])
        XCTAssertEqual(lock.locked, .zh)
    }

    /// 判不出语言的段不算票，也不该把投票搅乱。
    func testNilDetectionsAreIgnored() {
        let lock = feed([.zh, nil, nil, .zh])
        XCTAssertEqual(lock.locked, .zh)
        XCTAssertEqual(lock.votes, [.zh, .zh])
    }

    /// 锁定之后不再改 —— 后面判成别的语言也不动摇。
    func testLockIsStickyOnceSet() {
        var lock = feed([.ja, .ja])
        lock.observe(.en, policy: auto)
        lock.observe(.en, policy: auto)
        XCTAssertEqual(lock.locked, .ja)
    }

    /// 每段都判成不同语言：到上限按多数决收敛，绝不无限期飘着。
    func testConvergesAtMaxVotes() {
        let lock = feed([.ko, .ja, .en, .fr, .de])
        XCTAssertNotNil(lock.locked)
        XCTAssertEqual(lock.votes.count, SessionLanguageLock.maxVotes)
    }

    /// 固定语言模式压根不投票。
    func testFixedModeNeverLocks() {
        let fixed = TranscriptionLanguagePolicy(mode: .fixed, fixed: .zh, preferred: [])
        XCTAssertNil(feed([.ko, .ko], policy: fixed).locked)
    }

    /// preferred 模式只让候选表里的语言投票 ——
    /// 一句噪声被判成越南语不该把整场会锁过去。
    func testPreferredModeFiltersVotes() {
        let preferred = TranscriptionLanguagePolicy(
            mode: .preferred, fixed: .zh, preferred: [.zh, .en])
        let lock = feed([.vi, .vi, .zh, .zh], policy: preferred)
        XCTAssertEqual(lock.locked, .zh)
        XCTAssertFalse(lock.votes.contains(.vi))
    }

    func testResetClearsEverything() {
        var lock = feed([.zh, .zh])
        lock.reset()
        XCTAssertNil(lock.locked)
        XCTAssertTrue(lock.votes.isEmpty)
    }
}
