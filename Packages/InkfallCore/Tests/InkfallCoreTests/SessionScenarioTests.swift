import XCTest
@testable import InkfallCore

/// 多步场景：**按几下之后**状态还对不对。
///
/// 对应 Tauri 版 `coordinator.rs` 里那组 `scenario_*`。单步的动作表
/// （`JarvisMachineTests`）只回答「这一下该干什么」，而真正会出事的是几步之后
/// 的状态 —— 「共跑时先停笔记，麦克风还开着吗」这种问题一步一步断言是断言
/// 不出来的，而它错了的表现是**麦克风卡在开着**或者**把另一个消费者从句子
/// 中间切断**。
///
/// 两条轴（spec/01 §1）：`sink` 决定文字去哪，`scanning` 决定要不要扫关键词。
/// 贾维斯原本*是*一个 sink，改成 filter 之后 `noteWindow + scanning` 才成为
/// 合法状态 —— 下面几乎每一条都在守这个正交性。
final class SessionScenarioTests: XCTestCase {

    private func pressNote(_ shape: SessionShape) -> SessionShape {
        SessionMachine.pressNote(shape)
    }

    private func pressJarvis(_ shape: SessionShape,
                             enabled: Bool = true) -> SessionShape {
        JarvisMachine.pressJarvis(shape, featureEnabled: enabled)
    }

    private let idle = SessionShape.idle

    // MARK: - 单独跑

    func testJarvisAloneStartsAndStops() {
        let armed = pressJarvis(idle)
        XCTAssertEqual(armed, SessionShape(recording: true, sink: .discard, scanning: true))
        XCTAssertEqual(pressJarvis(armed), idle, "再按一次整个会话结束")
    }

    func testNoteAloneStartsAndStops() {
        let live = pressNote(idle)
        XCTAssertEqual(live, SessionShape(recording: true, sink: .noteWindow))
        XCTAssertEqual(pressNote(live), idle)
    }

    // MARK: - 共跑（正交性）

    /// 先贾维斯后落笔：扫描已经开着，⌥Space 应该**挂上去**而不是另起一场。
    func testJarvisFirstThenNoteReachesCoRunning() {
        let coRunning = pressNote(pressJarvis(idle))
        XCTAssertEqual(coRunning,
                       SessionShape(recording: true, sink: .noteWindow, scanning: true))
    }

    /// 先落笔后贾维斯，再撤扫描：录音必须**继续**，只是不扫了。
    func testNoteThenJarvisThenDisarmKeepsRecording() {
        let coRunning = pressJarvis(pressNote(idle))
        XCTAssertEqual(coRunning,
                       SessionShape(recording: true, sink: .noteWindow, scanning: true))

        let disarmed = pressJarvis(coRunning)
        XCTAssertTrue(disarmed.recording, "撤扫描不该把笔记的录音一起停掉")
        XCTAssertFalse(disarmed.scanning)
        XCTAssertEqual(disarmed.sink, .noteWindow)
    }

    /// 共跑时**先停笔记**：贾维斯还要这条流，所以录音继续，只是什么都不留。
    /// 这条就是引用计数（`sinkAfterRelease`）—— 写错等于把待命中的贾维斯
    /// 从句子中间切断。
    func testNoteStopsFirstAndJarvisSurvives() {
        let coRunning = pressNote(pressJarvis(idle))
        let afterNoteStops = pressNote(coRunning)
        XCTAssertTrue(afterNoteStops.recording, "扫描还在，流不能停")
        XCTAssertTrue(afterNoteStops.scanning)
        XCTAssertEqual(afterNoteStops.sink, .discard, "没有 sink 了 = 什么都不留")

        // 最后一个消费者撤了才真正停掉。
        XCTAssertEqual(pressJarvis(afterNoteStops), idle)
    }

    /// 反过来：**先停贾维斯**，笔记继续录；再停笔记才真正结束。
    func testNoteStopsLastEndsEverything() {
        let coRunning = pressNote(pressJarvis(idle))
        let afterJarvisStops = pressJarvis(coRunning)
        XCTAssertTrue(afterJarvisStops.recording)
        XCTAssertEqual(afterJarvisStops.sink, .noteWindow)
        XCTAssertEqual(pressNote(afterJarvisStops), idle)
    }

    /// ⚠️ Tauri 有、原生这边一直缺的一条：笔记 sink 可以**摘下来再挂回去**，
    /// 中间那条流一秒都不断。
    func testNoteCanDetachAndReattachWithoutLosingTheStream() {
        let coRunning = pressNote(pressJarvis(idle))

        let detached = pressNote(coRunning)
        XCTAssertTrue(detached.recording && detached.scanning, "贾维斯守着这条流")
        XCTAssertEqual(detached.sink, .discard)

        let reattached = pressNote(detached)
        XCTAssertEqual(reattached.sink, .noteWindow)
        XCTAssertTrue(reattached.recording && reattached.scanning, "全程没有重启过录音")
    }

    // MARK: - hold 听写这条边

    /// ⌥, 必然先按下 ⌥，所以按到逗号时已经有一截 hold 听写占着麦。
    func testHoldDictationConvertsToStandby() {
        let nascentHold = SessionShape(recording: true, hold: true, sink: .paste)
        let standby = pressJarvis(nascentHold)
        XCTAssertEqual(standby, SessionShape(recording: true, sink: .discard, scanning: true))
    }

    /// 同理，⌥Space 的那个 ⌥ 也会先起一截 hold —— 转成笔记录音，
    /// 而不是「已经在录了，拒绝」。
    func testHoldDictationConvertsToNote() {
        let nascentHold = SessionShape(recording: true, hold: true, sink: .paste)
        XCTAssertEqual(pressNote(nascentHold),
                       SessionShape(recording: true, sink: .noteWindow))
    }

    /// ⚠️ 另一条 Tauri 有、原生缺的：**真听写**（不是刚起头的 hold）占着麦时，
    /// ⌥Space 必须说清楚「正在听写」，并且**一个字段都不许动**。
    /// 组合逻辑绝不能把它没打算覆盖的情况一并吞掉。
    func testRealDictationStillBlocksNoteMode() {
        let dictating = SessionShape(recording: true, hold: false, sink: .paste)
        XCTAssertEqual(SessionMachine.noteToggle(dictating), .busyDictating)
        XCTAssertEqual(pressNote(dictating), dictating, "状态原封不动")
    }

    /// 听写 + 扫描共跑时，那一段仍然要粘出去（扫描是 filter，不改去向）。
    func testDictationWithScanningStillPastes() {
        let dictating = SessionShape(recording: true, sink: .paste, scanning: true)
        let routing = SessionMachine.routeTake(sink: dictating.sink,
                                               scanning: dictating.scanning)
        XCTAssertEqual(routing.destination, .paste)
        XCTAssertTrue(routing.scanForCommand)
    }

    // MARK: - 反复横跳

    /// 连按贾维斯 20 次不该把录音器搁浅：要么在录且在扫，要么彻底空闲，
    /// **绝不能出现「还在录但没人要」**。
    func testTogglingJarvisRepeatedlyNeverStrandsTheRecorder() {
        var shape = idle
        for step in 1...20 {
            shape = pressJarvis(shape)
            let stranded = shape.recording && !shape.scanning && shape.sink == .discard
            XCTAssertFalse(stranded, "第 \(step) 次之后录音器被搁浅了：\(shape)")
        }
        XCTAssertEqual(shape, idle, "偶数次之后回到空闲")
    }

    /// 笔记也一样反复横跳。
    func testTogglingNoteRepeatedlyNeverStrandsTheRecorder() {
        var shape = idle
        for step in 1...20 {
            shape = pressNote(shape)
            let stranded = shape.recording && shape.sink == .discard && !shape.scanning
            XCTAssertFalse(stranded, "第 \(step) 次之后录音器被搁浅了：\(shape)")
        }
        XCTAssertEqual(shape, idle)
    }

    /// 共跑状态下两个键交替乱按，也不该出现搁浅或「不录却还挂着 sink」。
    func testInterleavedTogglesStayConsistent() {
        var shape = idle
        for step in 0..<40 {
            shape = step.isMultiple(of: 2) ? pressNote(shape) : pressJarvis(shape)
            if !shape.recording {
                XCTAssertFalse(shape.scanning, "第 \(step) 步：没在录却还扫着")
                XCTAssertEqual(shape.sink, .paste, "第 \(step) 步：没在录却还挂着 sink")
            }
            let stranded = shape.recording && !shape.scanning && shape.sink == .discard
            XCTAssertFalse(stranded, "第 \(step) 步：录音器被搁浅")
        }
    }

    // MARK: - 功能没开

    /// 功能开关关着时 ⌥, 只提示，**状态一点都不动** —— 包括不能把
    /// 正在跑的笔记会话弄停。
    func testSettingsOffRefusesWithoutTouchingTheSession() {
        let noteLive = SessionShape(recording: true, sink: .noteWindow)
        XCTAssertEqual(pressJarvis(noteLive, enabled: false), noteLive)
        XCTAssertEqual(pressJarvis(idle, enabled: false), idle)
    }

    // MARK: - 命中的那一段

    /// 共跑时命中关键词：那一段仍然写进笔记（不能悄悄扣下用户说过的话），
    /// 但标成指令。
    func testCommandHitWhileCoRunningIsKeptButMarked() {
        let coRunning = pressNote(pressJarvis(idle))
        let routing = SessionMachine.routeTake(sink: coRunning.sink,
                                               scanning: coRunning.scanning)
        XCTAssertEqual(routing.destination, .note)
        XCTAssertTrue(routing.scanForCommand)
        XCTAssertEqual(SessionMachine.noteBody(transcript: "克劳德，看一下这段",
                                               wasCommandHit: true),
                       ">> 克劳德，看一下这段")
    }

    // MARK: - 切段器

    /// **切段是关键词可见的前提**：只要扫描还在，无论谁要求停止，
    /// 分段器都不能拆。
    func testSegmenterSurvivesWhileScanning() {
        let coRunning = pressNote(pressJarvis(idle))
        XCTAssertFalse(SessionMachine.mayStopSegmenter(scanning: coRunning.scanning))

        let afterNoteStops = pressNote(coRunning)
        XCTAssertTrue(afterNoteStops.scanning)
        XCTAssertFalse(SessionMachine.mayStopSegmenter(scanning: afterNoteStops.scanning),
                       "笔记停了但扫描还在 —— 切段器仍然不能拆")

        let allStopped = pressJarvis(afterNoteStops)
        XCTAssertTrue(SessionMachine.mayStopSegmenter(scanning: allStopped.scanning))
    }
}
