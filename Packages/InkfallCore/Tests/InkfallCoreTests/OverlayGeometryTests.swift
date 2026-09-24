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
                         note: Bool = false) -> CapsuleSize {
        OverlayGeometry.capsule(state: s, topInset: screen.inset,
                                notchWidth: screen.notch, compact: note)
    }

    /// 窗口永不改尺寸，所以装不下的胶囊会被静默裁掉。
    func testEveryCapsuleFitsInsideTheCanvas() {
        for screen in screens {
            let canvasHeight = OverlayGeometry.canvasHeight(topInset: screen.inset)
            for note in [false, true] {
                for state in OverlayState.allCases {
                    let c = capsule(state, screen, note: note)
                    XCTAssertLessThanOrEqual(c.width, OverlayGeometry.canvasWidth,
                                             "\(state) 宽 \(c.width)")
                    XCTAssertLessThanOrEqual(c.height, canvasHeight,
                                             "\(state) 高 \(c.height)")
                    XCTAssertGreaterThan(c.width, 0)
                    XCTAssertGreaterThan(c.height, 0)
                }
            }
        }
    }

    /// 转写中借用录音 pill，等待才看得见。
    /// 不这么做的话，整个供应商往返里刘海一动不动 —— 和没听见完全一样。
    func testTranscribingMatchesTheRecordingPill() {
        for screen in screens {
            XCTAssertEqual(capsule(.transcribing, screen), capsule(.recording, screen),
                           "转写从 pill 上漂走了")
        }
    }

    /// 暂停直接借用录音 pill：尺寸完全一致，只靠灰化与冻结的计时区分。
    func testNotePausedMatchesTheRecordingPill() {
        for screen in screens {
            XCTAssertEqual(capsule(.notePaused, screen, note: true),
                           capsule(.recording, screen, note: true),
                           "暂停从录音 pill 上漂走了")
        }
    }

    /// 紧凑胶囊（录音中）只排一行（计时），要明显比普通状态矮 ——
    /// 它常驻在屏幕顶部，占多少高度是有代价的。
    func testCompactCapsuleIsShorterThanOrdinaryStates() {
        for screen in screens {
            let note = capsule(.recording, screen, note: true)
            let ordinary = capsule(.recording, screen)
            XCTAssertLessThan(note.height, ordinary.height)
            XCTAssertEqual(note.height,
                           OverlayGeometry.compactContentHeight + screen.inset)
            // 宽度不受影响：它仍然要贴住刘海两翼。
            XCTAssertEqual(note.width, ordinary.width)
        }
    }

    /// 有刘海时胶囊宽 = 184 + 2×44 = 272，也就是融合柱的宽度。
    func testHuggingWidthMatchesTheFusedPillar() {
        let c = capsule(.recording, (OverlayGeometry.estimatedNotchWidth, 32))
        XCTAssertEqual(c.width, 272)
    }
}
