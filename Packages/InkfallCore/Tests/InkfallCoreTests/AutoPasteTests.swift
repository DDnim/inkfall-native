import XCTest
@testable import InkfallCore

// 自动粘贴的决策与时序。系统调用（CGEvent / NSPasteboard / AX）在 App 层，
// 这里覆盖的是「该走哪条路、失败了怎么说」——那部分不需要活的 App 环境。

final class AutoPasteTests: XCTestCase {

    private let frontmost = PasteTargetState(isRunning: true, isFrontmost: true)
    private let background = PasteTargetState(isRunning: true, isFrontmost: false)

    // MARK: - 路线选择

    /// 目标已经在前台：唯一该做的事就是原地粘，焦点一点都不该动。
    func testFrontmostTargetPastesInPlace() {
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: frontmost)
        XCTAssertEqual(plan.attempts, [.pasteInPlace])
        XCTAssertEqual(plan.outcome(after: .pasteInPlace), .inserted)
    }

    /// 跨 App：先试真·零焦点的 AX 写入，不行才退到「切过去粘再切回来」。
    func testCrossAppTriesAccessibilityBeforeActivating() {
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: background)
        XCTAssertEqual(plan.attempts, [.accessibility, .activateAndPaste])
        XCTAssertEqual(plan.outcome(after: .accessibility), .inserted)
        // 走到 B2 说明焦点闪了一下，结果要跟零焦点区分开。
        XCTAssertEqual(plan.outcome(after: .activateAndPaste), .insertedRefocus)
    }

    /// 钉住的窗口不是该 App 当前的焦点窗口时，AX 写入会落进**另一个**窗口 ——
    /// 那一路必须整个跳过，直接用 activate 把钉住的窗口顶到前面。
    func testAccessibilityIsSkippedWhenThePinnedWindowIsNotFocused() {
        let elsewhere = PasteTargetState(isRunning: true, isFrontmost: false,
                                         allowsAccessibilityInsert: false)
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: elsewhere)
        XCTAssertEqual(plan.attempts, [.activateAndPaste])
    }

    // MARK: - 降级

    /// 没抓到目标：文字必须留在剪贴板上，绝不能凭空消失。
    func testNoTargetFallsBackToClipboard() {
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: nil)
        XCTAssertEqual(plan.attempts, [.clipboardOnly])
        XCTAssertEqual(plan.outcome(after: .clipboardOnly), .noTarget)
    }

    /// 起录时的目标 App 在转写期间退出了。**这条最要命**：
    /// 死进程 activate 是空操作，之后那一下 ⌘V 会打进当时恰好在前台的别人窗口。
    func testQuitTargetNeverPastesIntoWhoeverIsFrontmostNow() {
        let dead = PasteTargetState(isRunning: false, isFrontmost: false)
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: dead)
        XCTAssertEqual(plan.attempts, [.clipboardOnly])
        XCTAssertEqual(plan.outcome(after: .clipboardOnly), .targetClosed)
        XCTAssertFalse(plan.attempts.contains(.activateAndPaste))
    }

    /// 没有辅助功能授权时，`CGEvent.post` 会**静默什么都不做**。
    /// 不提前拦住的话，用户看到的是「已粘回 Xcode」而实际上什么都没发生。
    func testWithoutAccessibilityEverythingDegradesAndSaysWhy() {
        for target in [frontmost, background, nil] {
            let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                      accessibilityTrusted: false, target: target)
            XCTAssertEqual(plan.attempts, [.clipboardOnly])
        }
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: false, target: frontmost)
        XCTAssertEqual(plan.outcome(after: .clipboardOnly), .accessibilityDenied)
        XCTAssertTrue(plan.outcome(after: .clipboardOnly).needsAccessibilityPrompt)
    }

    /// 没授权但也没目标：仍然报「未授权」——那才是用户要处理的那件事。
    func testAccessibilityDeniedOutranksNoTarget() {
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: false, target: nil)
        XCTAssertEqual(plan.outcome(after: .clipboardOnly), .accessibilityDenied)
    }

    /// 用户在设置里关掉了自动粘贴：只复制，不合成任何按键。
    func testDisabledCopiesWithoutSynthesizingKeys() {
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: false,
                                  accessibilityTrusted: true, target: frontmost)
        XCTAssertEqual(plan.attempts, [.clipboardOnly])
        XCTAssertEqual(plan.outcome(after: .clipboardOnly), .disabled)
        XCTAssertFalse(plan.outcome(after: .clipboardOnly).needsAccessibilityPrompt)
    }

    /// 三层全试完都没成：文字要落到剪贴板，并且**不能**标记成已粘贴。
    func testAllAttemptsExhaustedReportsFailedCopied() {
        let plan = AutoPaste.plan(text: "你好", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: background)
        XCTAssertEqual(plan.outcome(after: nil), .failedCopied)
        XCTAssertFalse(PasteOutcome.failedCopied.landedInTarget)
    }

    func testEmptyTextIsNotAPaste() {
        let plan = AutoPaste.plan(text: "   \n ", autoPasteEnabled: true,
                                  accessibilityTrusted: true, target: frontmost)
        XCTAssertTrue(plan.attempts.isEmpty)
        XCTAssertEqual(plan.outcome(after: nil), .nothingToPaste)
    }

    // MARK: - 结果语义

    /// 「粘进去了」和「只落到剪贴板」必须分得开 —— 落笔靠它决定要不要打
    /// `pasted` 标记；只复制却标成已粘贴的话，用户再按一次就什么都不出来了。
    func testOnlyRealInsertionsCountAsPasted() {
        XCTAssertTrue(PasteOutcome.inserted.landedInTarget)
        XCTAssertTrue(PasteOutcome.insertedRefocus.landedInTarget)
        for outcome: PasteOutcome in [.noTarget, .targetClosed, .accessibilityDenied,
                                      .failedCopied, .disabled, .nothingToPaste] {
            XCTAssertFalse(outcome.landedInTarget, "\(outcome.rawValue) 不该算已粘贴")
        }
    }

    /// 只有真授权问题才把用户往系统设置里引。别的降级弹设置面板是骚扰。
    func testOnlyAccessibilityDeniedPromptsForPermission() {
        XCTAssertTrue(PasteOutcome.accessibilityDenied.needsAccessibilityPrompt)
        for outcome: PasteOutcome in [.inserted, .insertedRefocus, .noTarget,
                                      .targetClosed, .failedCopied, .disabled, .nothingToPaste] {
            XCTAssertFalse(outcome.needsAccessibilityPrompt)
        }
    }

    /// 每条降级都要说清楚**去哪儿找那段文字**。
    func testEveryOutcomeTellsTheUserWhereTheTextWent() {
        XCTAssertEqual(AutoPaste.message(.inserted, appName: "Xcode"), "已粘回 Xcode")
        XCTAssertEqual(AutoPaste.message(.insertedRefocus, appName: "Xcode"), "已粘回 Xcode")
        XCTAssertEqual(AutoPaste.message(.noTarget, appName: nil), "已复制到剪贴板")
        XCTAssertEqual(AutoPaste.message(.disabled, appName: "Xcode"), "已复制到剪贴板")
        XCTAssertEqual(AutoPaste.message(.targetClosed, appName: "Xcode"),
                       "Xcode 已退出 · 已复制到剪贴板")
        XCTAssertEqual(AutoPaste.message(.accessibilityDenied, appName: "Xcode"),
                       "未授权辅助功能 · 已复制到剪贴板")
        XCTAssertEqual(AutoPaste.message(.failedCopied, appName: "Xcode"),
                       "粘贴失败 · 已复制到剪贴板")
        XCTAssertEqual(AutoPaste.message(.nothingToPaste, appName: nil), "没听清")
    }

    /// 目标名字丢了也不能把「已粘回 」这种半截话给用户看。
    func testInsertedWithoutAnAppNameStillReadsCleanly() {
        XCTAssertEqual(AutoPaste.message(.inserted, appName: nil), "已粘贴")
        XCTAssertEqual(AutoPaste.message(.targetClosed, appName: nil),
                       "目标已退出 · 已复制到剪贴板")
    }

    // MARK: - 文本组装

    func testComposeTrimsAndOptionallyEndsTheLine() {
        XCTAssertEqual(AutoPaste.compose("  你好  ", appendNewline: false), "你好")
        XCTAssertEqual(AutoPaste.compose("  你好  ", appendNewline: true), "你好\n")
        // 先 trim 再补，否则原文尾部的空白会把换行顶开。
        XCTAssertEqual(AutoPaste.compose("你好\n\n", appendNewline: true), "你好\n")
        XCTAssertEqual(AutoPaste.compose("   ", appendNewline: true), "",
                       "空文本补了换行就成了「粘一个空行」")
    }

    // MARK: - 时序常数（spec/02 §5）

    /// 这些数字全是踩坑换来的，改一个就是改行为。尤其 300 ms ——
    /// 剪贴板还原得等目标 App 先读完 pasteboard，早还原粘出来的就是旧内容（A20）。
    func testTimingsMatchTheSpec() {
        XCTAssertEqual(PasteTiming.selectionCaptureSeconds, 0.140, accuracy: 1e-9)
        XCTAssertEqual(PasteTiming.raiseWindowSeconds, 0.080, accuracy: 1e-9)
        XCTAssertEqual(PasteTiming.activateBeforePasteSeconds, 0.120, accuracy: 1e-9)
        XCTAssertEqual(PasteTiming.clipboardRestoreSeconds, 0.300, accuracy: 1e-9)
        XCTAssertEqual(PasteTiming.refocusPreviousSeconds, 0.060, accuracy: 1e-9)
    }

    /// 每条**合成按键**的路线都必须经过存/还原剪贴板（A20）；
    /// 只复制那一条相反 —— 它的全部意义就是把文字留在剪贴板上。
    func testEverySyntheticKeyRouteIsClipboardHygienic() {
        XCTAssertTrue(PasteRoute.pasteInPlace.usesClipboard)
        XCTAssertTrue(PasteRoute.activateAndPaste.usesClipboard)
        XCTAssertFalse(PasteRoute.accessibility.usesClipboard, "AX 写入根本不碰剪贴板")
        XCTAssertFalse(PasteRoute.clipboardOnly.usesClipboard)
    }
}
