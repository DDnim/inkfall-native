import XCTest
@testable import InkfallCore

/// 刘海几何的性质测试。
///
/// 窗口从不改尺寸，所以一个装不下画布的胶囊会被**静默裁掉**，任何地方都不会报错
/// —— 这类问题只能靠断言性质来防。
final class OverlayGeometryTests: XCTestCase {

    /// 一台刘海 MacBook，和一块没有刘海的外接屏。
    private let screens: [(notch: Double, inset: Double)] = [
        (OverlayGeometry.estimatedNotchWidth, 32),
        (0, 0),
    ]

    private func capsule(_ s: OverlayState, _ screen: (notch: Double, inset: Double),
                         armed: Bool = false, note: Bool = false) -> CapsuleSize {
        OverlayGeometry.capsule(state: s, topInset: screen.inset,
                                notchWidth: screen.notch, armed: armed, noteCapsule: note)
    }

    /// | 模式 | 宽 | 高 |
    /// |------|----|----|
    /// | 助手待命 | 是 | 只在说话时 |
    /// | 录音 | 否 | 是 |
    /// | 两者同时 | 是 | 是 |
    ///
    /// 宽度跟「扫描 armed」，高度跟「正在采集」。两者独立，
    /// 所以**先开哪个模式都不改变结果**。
    func testWidthTracksScanningAndHeightTracksCapture() {
        for screen in screens {
            let narrow = capsule(.idle, screen).width
            let wide = capsule(.jarvisStandby, screen, armed: true).width
            let band = capsule(.jarvisStandby, screen, armed: true).height
            let tall = capsule(.recording, screen).height

            XCTAssertGreaterThan(wide, narrow, "arming 应该加宽")
            XCTAssertGreaterThan(tall, band, "采集应该加高")

            // 助手单独：宽，且在有语音之前是矮的。
            XCTAssertEqual(capsule(.jarvisStandby, screen, armed: true),
                           CapsuleSize(width: wide, height: band))
            XCTAssertEqual(capsule(.jarvisListening, screen, armed: true),
                           CapsuleSize(width: wide, height: tall), "说话时掉成 pill")

            // 录音单独：常规宽度，高。
            XCTAssertEqual(capsule(.recording, screen),
                           CapsuleSize(width: narrow, height: tall))

            // 两者同时：又宽又高 —— 无论先开哪个。
            XCTAssertEqual(capsule(.recording, screen, armed: true),
                           CapsuleSize(width: wide, height: tall))
        }
    }

    /// 窗口永不改尺寸，所以装不下的胶囊会被静默裁掉。
    func testEveryCapsuleFitsInsideTheCanvas() {
        for screen in screens {
            let canvasHeight = OverlayGeometry.canvasHeight(topInset: screen.inset)
            for armed in [false, true] {
                for note in [false, true] {
                    for state in OverlayState.allCases {
                        let c = capsule(state, screen, armed: armed, note: note)
                        XCTAssertLessThanOrEqual(c.width, OverlayGeometry.canvasWidth,
                                                 "\(state) armed=\(armed) 宽 \(c.width)")
                        XCTAssertLessThanOrEqual(c.height, canvasHeight,
                                                 "\(state) armed=\(armed) 高 \(c.height)")
                        XCTAssertGreaterThan(c.width, 0)
                        XCTAssertGreaterThan(c.height, 0)
                    }
                }
            }
        }
    }

    /// arming 只会让胶囊变大，绝不缩小。
    func testArmingNeverShrinksTheCapsule() {
        for screen in screens {
            for state in OverlayState.allCases {
                let plain = capsule(state, screen)
                let armed = capsule(state, screen, armed: true)
                XCTAssertGreaterThanOrEqual(armed.width, plain.width, "\(state) armed 后变窄了")
                XCTAssertGreaterThanOrEqual(armed.height, plain.height, "\(state) armed 后变矮了")
            }
        }
    }

    /// 转写中借用录音 pill，等待才看得见。
    /// 不这么做的话，整个供应商往返里刘海一动不动 —— 和没听见完全一样。
    func testTranscribingMatchesTheRecordingPill() {
        for screen in screens {
            XCTAssertEqual(capsule(.transcribing, screen, armed: true),
                           capsule(.recording, screen, armed: true),
                           "转写从 pill 上漂走了")
            XCTAssertGreaterThan(capsule(.transcribing, screen, armed: true).height,
                                 capsule(.jarvisStandby, screen, armed: true).height,
                                 "转写还留在带里")
        }
    }

    /// 待命必须让开路：任何下坠都会把一个空闲会话变成永久黑条，
    /// 有没有刘海都一样。
    func testStandbyNeverDropsBelowTheBand() {
        for screen in screens {
            let expected = screen.inset > 0 ? screen.inset : OverlayGeometry.bandHeight
            XCTAssertEqual(capsule(.jarvisStandby, screen, armed: true).height, expected)
        }
    }

    /// 结果卡去掉了键盘提示行，所以比命中卡矮一档 —— 设计里「自己退场」的那一拍。
    /// 失败卡保持命中卡的高度（它要停着）。
    func testResultCardIsShorterThanHitCard() {
        for screen in screens {
            let hit = capsule(.jarvisPending, screen, armed: true).height
            let done = capsule(.jarvisResult, screen, armed: true).height
            let failed = capsule(.jarvisError, screen, armed: true).height
            XCTAssertLessThan(done, hit)
            XCTAssertEqual(failed, hit)
        }
    }

    /// 暂停的落笔直接借用录音 pill：尺寸完全一致，
    /// 只靠灰化与冻结的计时区分。
    func testNotePausedMatchesTheRecordingPill() {
        for screen in screens {
            for armed in [false, true] {
                XCTAssertEqual(capsule(.notePaused, screen, armed: armed, note: true),
                               capsule(.recording, screen, armed: armed, note: true),
                               "暂停从录音 pill 上漂走了")
            }
        }
    }

    /// 没有硬件刘海的屏幕也要有带，卡片排版在哪儿都一样。
    func testNotchlessScreenStillGetsABand() {
        let withNotch = capsule(.jarvisPending, (OverlayGeometry.estimatedNotchWidth, 32), armed: true).height
        let without = capsule(.jarvisPending, (0, 0), armed: true).height
        XCTAssertEqual(withNotch, without, "卡片不该换形状")
    }

    /// 落笔胶囊要留得下 hover 条，否则条的下半截会被裁掉。
    func testNoteCapsuleReservesRoomForTheHoverStrip() {
        for screen in screens {
            let band = screen.inset > 0 ? screen.inset : OverlayGeometry.bandHeight
            let paused = capsule(.notePaused, screen, note: true)
            XCTAssertGreaterThanOrEqual(paused.height, band + OverlayGeometry.noteHoverStripSpan)
        }
    }

    /// 有刘海时胶囊宽 = 184 + 2×44 = 272，也就是融合柱的宽度。
    func testHuggingWidthMatchesTheFusedPillar() {
        let c = capsule(.recording, (OverlayGeometry.estimatedNotchWidth, 32))
        XCTAssertEqual(c.width, 272)
    }
}
