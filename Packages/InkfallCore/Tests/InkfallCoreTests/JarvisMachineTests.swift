import XCTest
@testable import InkfallCore

/// 贾维斯的四个纯函数与倒计时记账。
///
/// spec/10 B1 说得很直白：`route_take` / `jarvis_toggle_action` /
/// `sink_after_release` / `may_stop_segmenter` 这四个纯函数**已经是**正确的
/// 抽象核心，重写要做的是把它们提出来做成一个真正的状态机类型。
final class JarvisMachineTests: XCTestCase {

    // MARK: - ⌥, 的动作表（spec/01 §1.2）

    func testDisabledFeatureRefusesWithoutChangingAnything() {
        let shape = SessionShape(recording: true, sink: .noteWindow, scanning: true)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: shape, featureEnabled: false), .refuse)
    }

    func testScanningAloneStopsTheWholeSession() {
        let shape = SessionShape(recording: true, sink: .discard, scanning: true)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: shape, featureEnabled: true),
                       .stopRecording)
    }

    /// 还有别的 sink 要这条流：只撤过滤器，录音继续 —— 正交性的全部意义。
    func testScanningOverANoteSessionOnlyDisarms() {
        let shape = SessionShape(recording: true, sink: .noteWindow, scanning: true)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: shape, featureEnabled: true),
                       .disarmKeepRecording)
    }

    /// ⌥, 必然先按下 ⌥，所以按到逗号时已经有一截 hold 听写占着麦克风了。
    func testNascentHoldIsConvertedIntoStandby() {
        let shape = SessionShape(recording: true, hold: true, sink: .paste)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: shape, featureEnabled: true),
                       .convertHold)
    }

    func testScanningIsArmedOverAnExistingSink() {
        let shape = SessionShape(recording: true, sink: .noteWindow)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: shape, featureEnabled: true),
                       .armOverExisting)
    }

    func testNothingRunningStartsStandby() {
        XCTAssertEqual(JarvisMachine.toggleAction(shape: SessionShape(), featureEnabled: true),
                       .startStandby)
    }

    /// 表是有顺序的：hold **且** 已经在扫描时，先命中的是「撤扫描」那两行。
    func testScanningWinsOverHold() {
        let discard = SessionShape(recording: true, hold: true, sink: .discard, scanning: true)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: discard, featureEnabled: true),
                       .stopRecording)
        let paste = SessionShape(recording: true, hold: true, sink: .paste, scanning: true)
        XCTAssertEqual(JarvisMachine.toggleAction(shape: paste, featureEnabled: true),
                       .disarmKeepRecording)
    }

    // MARK: - 命中的那一段仍然落进笔记（spec/01 §1.1）

    /// 扫描是 filter 不是 sink：命中之后那句话照样进笔记，只是标成指令。
    func testACommandHitIsStillWrittenIntoTheNote() {
        XCTAssertEqual(SessionMachine.noteBody(transcript: "克劳德，跑一下测试",
                                               wasCommandHit: true),
                       ">> 克劳德，跑一下测试")
        XCTAssertEqual(SessionMachine.noteBody(transcript: " 今天讨论了三件事 ",
                                               wasCommandHit: false),
                       "今天讨论了三件事")
        // 共跑时 scan 是 filter、note 是 destination —— 两者互不干扰。
        let routing = SessionMachine.routeTake(sink: .noteWindow, scanning: true)
        XCTAssertTrue(routing.scanForCommand)
        XCTAssertEqual(routing.destination, .note)
    }

    // MARK: - 结果行

    func testTakeResultLineTruncatesTo24Chars() {
        let long = String(repeating: "一", count: JarvisTiming.takeResultChars + 10)
        let line = JarvisMachine.takeResultLine(long)
        XCTAssertEqual(line.count, JarvisTiming.takeResultChars + 1)
        XCTAssertTrue(line.hasSuffix("…"))

        let exact = String(repeating: "一", count: JarvisTiming.takeResultChars)
        XCTAssertEqual(JarvisMachine.takeResultLine(exact), exact)
        XCTAssertEqual(JarvisMachine.takeResultLine("  你好\n世界  "), "你好 世界")
    }

    // MARK: - A12：esc / ↩ 的抢占绝不能遗留

    func testCountdownImpliesScanning() {
        var runtime = JarvisRuntime()
        XCTAssertNil(runtime.schedule(), "没在扫描时不该登记得出倒计时")
        XCTAssertFalse(runtime.grabsEscapeAndReturn)

        runtime.arm()
        let id = runtime.schedule()
        XCTAssertNotNil(id)
        XCTAssertTrue(runtime.grabsEscapeAndReturn)
    }

    func testStalePendingIdsCannotFire() {
        var runtime = JarvisRuntime()
        runtime.arm()
        let first = runtime.schedule()!
        XCTAssertTrue(runtime.cancel(id: first))
        let second = runtime.schedule()!
        XCTAssertNotEqual(first, second)
        // 第一条的定时器到点了，但它已经被撤销 —— 绝不能执行。
        XCTAssertFalse(runtime.take(id: first))
        XCTAssertTrue(runtime.take(id: second))
        XCTAssertFalse(runtime.grabsEscapeAndReturn)
    }

    /// 穷举全状态的 property test（对齐 Tauri 版的
    /// `scenario_the_key_grab_is_never_left_behind`）。
    ///
    /// 不变量两条：
    /// 1. 抢占 ⟹ 正在扫描（有倒计时一定有扫描）
    /// 2. 扫描一结束，抢占必须立刻没了 —— 遗留 = 用户的 Escape 键全系统失效，
    ///    而屏幕上没有任何解释。
    func testTheKeyGrabIsNeverLeftBehind() {
        enum Step: CaseIterable {
            case arm, disarm, schedule, fire, cancel, discard
        }
        var runtime = JarvisRuntime()
        var lastID: UInt64 = 0

        // 四步深度的全排列：6^4 = 1296 条路径，覆盖所有转移组合。
        func walk(depth: Int, state: JarvisRuntime, id: UInt64) {
            XCTAssertFalse(state.grabsEscapeAndReturn && !state.scanning,
                           "抢占被遗留在了没有扫描的状态上")
            guard depth > 0 else { return }
            for step in Step.allCases {
                var next = state
                var nextID = id
                switch step {
                case .arm: next.arm()
                case .disarm: next.disarm()
                case .schedule: if let new = next.schedule() { nextID = new }
                case .fire: _ = next.take(id: nextID)
                case .cancel: _ = next.cancel(id: nextID)
                case .discard: _ = next.countDiscarded()
                }
                walk(depth: depth - 1, state: next, id: nextID)
            }
        }
        walk(depth: 4, state: runtime, id: lastID)

        // 顺带钉住最常见的那条真实路径：命中 → 用户去干别的 → ⌥, 关掉扫描。
        runtime.arm()
        lastID = runtime.schedule()!
        XCTAssertTrue(runtime.grabsEscapeAndReturn)
        runtime.disarm()
        XCTAssertFalse(runtime.grabsEscapeAndReturn, "结束扫描必须同时清掉倒计时")
        XCTAssertFalse(runtime.take(id: lastID), "撤掉扫描之后那条命令不能再执行")
    }

    func testDiscardCountResetsOnEachStandby() {
        var runtime = JarvisRuntime()
        runtime.arm()
        XCTAssertEqual(runtime.countDiscarded(), 1)
        XCTAssertEqual(runtime.countDiscarded(), 2)
        runtime.disarm()
        runtime.arm()
        XCTAssertEqual(runtime.countDiscarded(), 1)
    }
}
