import XCTest
@testable import InkfallCore

/// 悬停响应。
///
/// 窗口永久 click-through，所以悬停靠**轮询全局鼠标 + 当前绘制的胶囊矩形**
/// 命中 —— 判据是胶囊，不是画布。画布 520×168 里绝大部分是透明的，
/// 拿画布当热区会让鼠标一飘到屏幕顶端就触发。
final class OverlayHoverTests: XCTestCase {

    private let canvas = CGRect(x: 1000, y: 900, width: 520, height: 168)
    private let capsule = CapsuleSize(width: 272, height: 62)

    func testCapsuleIsTopCenteredInTheCanvas() {
        let rect = OverlayGeometry.capsuleRect(canvas: canvas, capsule: capsule)
        XCTAssertEqual(rect.midX, canvas.midX, accuracy: 0.001)
        // Cocoa 左下原点：贴顶 = 上沿与画布上沿齐平。
        XCTAssertEqual(rect.maxY, canvas.maxY, accuracy: 0.001)
        XCTAssertEqual(rect.width, capsule.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, capsule.height, accuracy: 0.001)
    }

    /// 热区是胶囊不是画布：画布的角落必须**不**命中。
    func testCanvasCornersAreNotHot() {
        let rect = OverlayGeometry.capsuleRect(canvas: canvas, capsule: capsule)
        XCTAssertFalse(rect.contains(CGPoint(x: canvas.minX + 2, y: canvas.maxY - 2)))
        XCTAssertFalse(rect.contains(CGPoint(x: canvas.midX, y: canvas.minY + 2)))
        XCTAssertTrue(rect.contains(CGPoint(x: canvas.midX, y: canvas.maxY - 2)))
    }

    // MARK: - 响应

    /// 普通状态：淡化让路。落笔胶囊**反过来** —— 展开 hover 条，绝不淡化，
    /// 因为那条上有按钮，淡化的按钮既难认也难点。
    func testNoteCapsuleExpandsWhileOthersDim() {
        XCTAssertEqual(OverlayHover.response(hovering: true, stripAvailable: false), .dim)
        XCTAssertEqual(OverlayHover.response(hovering: true, stripAvailable: true), .strip)
    }

    func testLeavingAlwaysClearsTheResponse() {
        XCTAssertEqual(OverlayHover.response(hovering: false, stripAvailable: false), .none)
        XCTAssertEqual(OverlayHover.response(hovering: false, stripAvailable: true), .none)
    }

    /// ⚠️ 只有展开 hover 条时才收鼠标事件。其余一切情况都必须放回
    /// click-through —— overlay 卡在「接受点击」是能把整个屏幕顶端点死的。
    func testOnlyTheStripTakesMouseEvents() {
        XCTAssertTrue(OverlayHover.wantsMouseEvents(.strip))
        XCTAssertFalse(OverlayHover.wantsMouseEvents(.dim))
        XCTAssertFalse(OverlayHover.wantsMouseEvents(.none))
    }

    // MARK: - 撑高

    /// hover 条要 30pt 的按钮 + 余量，比紧凑胶囊的一行计时高 ——
    /// 不撑高的话条的下半截会被胶囊裁掉。
    func testHoverStripMakesRoomForItself() {
        let inset: Double = 32
        let plain = OverlayGeometry.capsule(state: .recording, topInset: inset,
                                            notchWidth: OverlayGeometry.estimatedNotchWidth,
                                            armed: false, compact: true)
        let hovered = OverlayGeometry.capsule(state: .recording, topInset: inset,
                                              notchWidth: OverlayGeometry.estimatedNotchWidth,
                                              armed: false, compact: true, hoverStrip: true)
        XCTAssertGreaterThan(hovered.height, plain.height)
        XCTAssertEqual(hovered.height, OverlayGeometry.noteHoverStripSpan + inset)
        XCTAssertEqual(hovered.width, plain.width, "hover 不该改宽度")
    }

    /// 暂停态同样要能展开 —— 不然暂停之后就再也点不到「继续」了。
    func testPausedCapsuleAlsoMakesRoom() {
        let hovered = OverlayGeometry.capsule(state: .notePaused, topInset: 32,
                                              notchWidth: OverlayGeometry.estimatedNotchWidth,
                                              armed: false, compact: true, hoverStrip: true)
        XCTAssertEqual(hovered.height, OverlayGeometry.noteHoverStripSpan + 32)
    }

    /// 非紧凑状态（转写中、结果卡）不受 hover 条影响：那些状态没有条。
    func testHoverStripDoesNotResizeOrdinaryStates() {
        for state in [OverlayState.transcribing, .success, .jarvisPending] {
            let plain = OverlayGeometry.capsule(state: state, topInset: 32,
                                                notchWidth: 184, armed: true, compact: false)
            let hovered = OverlayGeometry.capsule(state: state, topInset: 32,
                                                  notchWidth: 184, armed: true, compact: false,
                                                  hoverStrip: true)
            XCTAssertEqual(plain, hovered, "\(state) 被 hover 条改了尺寸")
        }
    }

    /// 撑高之后仍然要装得进固定画布。
    func testHoveredCapsuleStillFitsTheCanvas() {
        for inset in [0.0, 32.0] {
            let c = OverlayGeometry.capsule(state: .recording, topInset: inset,
                                            notchWidth: inset > 0 ? 184 : 0,
                                            armed: true, compact: true, hoverStrip: true)
            XCTAssertLessThanOrEqual(c.height, OverlayGeometry.canvasHeight(topInset: inset))
            XCTAssertLessThanOrEqual(c.width, OverlayGeometry.canvasWidth)
        }
    }
}
