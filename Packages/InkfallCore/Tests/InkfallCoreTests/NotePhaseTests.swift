import XCTest
@testable import InkfallCore

/// 落笔会话的阶段走位：起录 → 暂停 → 继续 → 停止。
///
/// 这条路以前只有真机自测走得到（控制器要活的麦克风），而它恰恰是
/// spec/10 A11「落笔绝不丢数据」最集中的一段：暂停不能被当成停止，
/// 停止之后不能还以为自己在录。
final class NotePhaseTests: XCTestCase {

    // MARK: - 完整走位

    func testFullWalk() {
        var phase = NotePhase.editing
        for (event, expected) in [(NotePhaseEvent.start, NotePhase.recording),
                                  (.pause, .paused),
                                  (.resume, .recording),
                                  (.stop, .editing)] {
            phase = NoteSessionMachine.next(phase, on: event) ?? phase
            XCTAssertEqual(phase, expected, "\(event) 之后应该是 \(expected)")
        }
    }

    /// 暂停可以反复来回，每次都回到同一篇会话里。
    func testPauseResumeRepeatedly() {
        var phase = NoteSessionMachine.next(.editing, on: .start)!
        for _ in 0..<10 {
            phase = NoteSessionMachine.next(phase, on: .pause)!
            XCTAssertTrue(NoteSessionMachine.isLive(phase), "暂停**不**结束会话")
            XCTAssertFalse(NoteSessionMachine.microphoneLive(phase), "暂停时麦克风真的停了")
            phase = NoteSessionMachine.next(phase, on: .resume)!
            XCTAssertTrue(NoteSessionMachine.microphoneLive(phase))
        }
    }

    // MARK: - A11：暂停不是停止

    /// 这条是 A11 的核心：暂停期间会话仍然**开着** —— 同一篇笔记、
    /// 同一个粘贴目标、同一把语言锁。判成「已停止」就会在继续录音时
    /// 新起一篇，用户以为丢了半场。
    func testPausedIsStillLive() {
        XCTAssertTrue(NoteSessionMachine.isLive(.recording))
        XCTAssertTrue(NoteSessionMachine.isLive(.paused))
        XCTAssertFalse(NoteSessionMachine.isLive(.editing))
        // 而「麦克风开着吗」是另一根轴 —— 两者不能混用。
        XCTAssertTrue(NoteSessionMachine.microphoneLive(.recording))
        XCTAssertFalse(NoteSessionMachine.microphoneLive(.paused))
        XCTAssertFalse(NoteSessionMachine.microphoneLive(.editing))
    }

    /// 暂停中按停止是常见操作（开完会回来直接结束），必须走得通。
    func testStopWorksFromPaused() {
        XCTAssertEqual(NoteSessionMachine.next(.paused, on: .stop), .editing)
    }

    /// 关面板 = 停止录音（隐私规则），在录和暂停都算。
    func testClosingThePanelStopsRecording() {
        XCTAssertEqual(NoteSessionMachine.next(.recording, on: .closePanel), .editing)
        XCTAssertEqual(NoteSessionMachine.next(.paused, on: .closePanel), .editing)
        XCTAssertNil(NoteSessionMachine.next(.editing, on: .closePanel), "已经停了就什么都不做")
    }

    // MARK: - 不该发生的那些

    /// 手抖重复按不是错误，是**原地忽略**：再按一次停止、在编辑态按继续、
    /// 录着的时候再按开始 —— 一律 nil，调用方保持原状。
    func testIllegalTransitionsAreIgnoredNotErrors() {
        XCTAssertNil(NoteSessionMachine.next(.editing, on: .stop))
        XCTAssertNil(NoteSessionMachine.next(.editing, on: .pause))
        XCTAssertNil(NoteSessionMachine.next(.editing, on: .resume))
        XCTAssertNil(NoteSessionMachine.next(.recording, on: .start))
        XCTAssertNil(NoteSessionMachine.next(.recording, on: .resume))
        XCTAssertNil(NoteSessionMachine.next(.paused, on: .start))
        XCTAssertNil(NoteSessionMachine.next(.paused, on: .pause))
    }

    /// 任意乱按序列都不能走到「不在会话里却还开着麦克风」这种状态。
    func testNoEventSequenceEverStrandsTheMicrophone() {
        var phase = NotePhase.editing
        let events = NotePhaseEvent.allCases
        for step in 0..<200 {
            let event = events[step % events.count]
            phase = NoteSessionMachine.next(phase, on: event) ?? phase
            if !NoteSessionMachine.isLive(phase) {
                XCTAssertFalse(NoteSessionMachine.microphoneLive(phase),
                               "第 \(step) 步（\(event)）：会话结束了麦克风还开着")
            }
        }
    }

    /// 每个阶段至少有一条出路 —— 不能有走进去就出不来的死角。
    func testEveryPhaseHasAWayOut() {
        for phase in NotePhase.allCases {
            let reachable = NotePhaseEvent.allCases
                .compactMap { NoteSessionMachine.next(phase, on: $0) }
            XCTAssertFalse(reachable.isEmpty, "\(phase) 是死角")
        }
    }
}
