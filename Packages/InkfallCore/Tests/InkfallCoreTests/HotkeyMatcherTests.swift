import XCTest
@testable import InkfallCore

/// 合成事件驱动的热键回归测试。
///
/// 这里每一个用例都对应一个真实事故 —— 而且**全都测不出来于真机按键**：
/// 「tap 被禁用期间丢了 key-up」「Caps Lock 发奇数个 keycode-255」这类
/// 序列只能合成。所以判定逻辑必须留在 InkfallCore 这一侧。
final class HotkeyMatcherTests: XCTestCase {

    // MARK: - 事件合成

    private struct Keyboard {
        var matcher: HotkeyMatcher
        var flags: UInt64 = 0
        private(set) var events: [HotkeyEvent] = []
        private(set) var lastSuppressed = false

        init(_ matcher: HotkeyMatcher = HotkeyMatcher(), selfHeal: Bool = false) {
            self.matcher = matcher
            self.matcher.systemStateVerify = selfHeal
        }

        mutating func modifier(_ keycode: UInt16, _ mask: UInt64, down: Bool, at now: Double = 0) {
            if down { flags |= mask } else { flags &= ~mask }
            emit(HotkeyEventType.flagsChanged, keycode, now)
        }

        mutating func rightOption(down: Bool, at now: Double = 0) {
            modifier(61, HotkeyMask.alternate | HotkeyMask.rightOptionDevice, down: down, at: now)
        }

        mutating func shift(down: Bool, at now: Double = 0) {
            modifier(56, HotkeyMask.shift, down: down, at: now)
        }

        mutating func fn(down: Bool, at now: Double = 0) {
            modifier(63, HotkeyMask.secondaryFn, down: down, at: now)
        }

        mutating func keyDown(_ keycode: UInt16, at now: Double = 0) {
            emit(HotkeyEventType.keyDown, keycode, now)
        }

        mutating func keyUp(_ keycode: UInt16, at now: Double = 0) {
            emit(HotkeyEventType.keyUp, keycode, now)
        }

        mutating func tap(_ keycode: UInt16, at now: Double = 0) {
            keyDown(keycode, at: now)
            keyUp(keycode, at: now)
        }

        /// 原样投递一个事件（用来伪造 Caps Lock 那种畸形 flagsChanged）。
        mutating func raw(_ type: UInt32, _ keycode: UInt16, flags: UInt64, at now: Double = 0) {
            let result = matcher.handle(type: type, keycode: keycode, flags: flags, now: now)
            events += result.events
            lastSuppressed = result.suppress
        }

        private mutating func emit(_ type: UInt32, _ keycode: UInt16, _ now: Double) {
            raw(type, keycode, flags: flags, at: now)
        }

        mutating func drain() -> [HotkeyEvent] {
            defer { events = [] }
            return events
        }
    }

    // MARK: - 边沿触发

    func testFnChatterDoesNotRetriggerHold() {
        var config = ShortcutsConfig()
        config.overlayHold = Shortcut([(63, "Fn")])
        var kb = Keyboard(HotkeyMatcher(shortcuts: config))

        kb.fn(down: true)
        // 真机上 Fn 会连发好几个 flagsChanged（有时还夹着 keyDown 重复）。
        kb.fn(down: true)
        kb.fn(down: true)
        XCTAssertEqual(kb.drain(), [.overlayHoldPressed])

        kb.fn(down: false)
        kb.fn(down: false)
        XCTAssertEqual(kb.drain(), [.overlayHoldReleased])
    }

    func testModifierOnlyHoldIgnoresOtherKeys() {
        var config = ShortcutsConfig()
        config.overlayHold = Shortcut([(63, "Fn")])
        var kb = Keyboard(HotkeyMatcher(shortcuts: config))

        kb.fn(down: true)
        XCTAssertEqual(kb.drain(), [.overlayHoldPressed])
        // 纯修饰键快捷键匹配成立后无视其他按键 —— 按住 Fn 说话时打字不能停录。
        kb.tap(9)
        XCTAssertTrue(kb.drain().isEmpty)
        kb.fn(down: false)
        XCTAssertEqual(kb.drain(), [.overlayHoldReleased])
    }

    func testExtraModifiersToleratedButExtraPlainKeyBreaksChord() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()

        // ⌥⇧[ 仍然算历史选择器（额外的修饰键容忍）。
        kb.shift(down: true)
        kb.keyDown(33)
        XCTAssertTrue(kb.drain().contains(.historyPickerPressed))
        kb.keyUp(33)
        kb.shift(down: false)

        // 但多按一个普通键就不匹配了。
        kb.keyDown(9)
        _ = kb.drain()
        kb.keyDown(33)
        XCTAssertFalse(kb.drain().contains(.historyPickerPressed))
    }

    // MARK: - 吞噬

    func testRightOptionComboSuppressesBothDownAndUp() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        XCTAssertFalse(kb.lastSuppressed, "修饰键永不吞")

        kb.keyDown(33)
        XCTAssertTrue(kb.lastSuppressed, "⌥[ 匹配成立，key-down 必须吞掉")
        XCTAssertTrue(kb.drain().contains(.historyPickerPressed))

        kb.keyUp(33)
        XCTAssertTrue(kb.lastSuppressed, "只吞一半会让前台 App 收到孤儿 key-up")
    }

    func testCommaAliasFiresJarvisAndSwallowsTheComma() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()

        kb.keyDown(43)
        // ⌥, 是贾维斯别名，不是落笔（落笔已改绑 ⌥Space）。
        XCTAssertEqual(kb.drain(), [.jarvisTogglePressed])
        XCTAssertTrue(kb.lastSuppressed, "不吞会往前台漏一个可打印的「≤」")
    }

    func testCommaAliasYieldsWhenUserRebindsThatCombo() {
        var config = ShortcutsConfig()
        config.historyPicker = Shortcut([(61, "Right Option"), (43, ",")])
        var kb = Keyboard(HotkeyMatcher(shortcuts: config))

        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(43)
        let events = kb.drain()
        XCTAssertTrue(events.contains(.historyPickerPressed))
        XCTAssertFalse(events.contains(.jarvisTogglePressed), "用户重绑则用户赢")
    }

    func testEscapeIsUntouchedOutsideJarvisCountdown() {
        var kb = Keyboard()
        kb.keyDown(53)
        XCTAssertTrue(kb.drain().isEmpty)
        XCTAssertFalse(kb.lastSuppressed, "全局吞掉裸 esc 是不可接受的")
    }

    func testJarvisCountdownClaimsBareEscapeAndReturn() {
        var kb = Keyboard()
        kb.matcher.jarvisCountdown = true

        kb.keyDown(53)
        XCTAssertEqual(kb.drain(), [.jarvisUndoPressed])
        XCTAssertTrue(kb.lastSuppressed)
        kb.keyUp(53)

        kb.keyDown(36)
        XCTAssertEqual(kb.drain(), [.jarvisRunNowPressed])
        XCTAssertTrue(kb.lastSuppressed)
        kb.keyUp(36)

        // 倒计时结束 → 立刻交还这两个键。
        kb.matcher.jarvisCountdown = false
        kb.keyDown(53)
        XCTAssertTrue(kb.drain().isEmpty)
        XCTAssertFalse(kb.lastSuppressed)
    }

    func testRightOptionEscapeCancelsRecording() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(53)
        XCTAssertTrue(kb.drain().contains(.cancelRecordingPressed))
        XCTAssertTrue(kb.lastSuppressed)
    }

    // MARK: - lone tap（右 ⌥ 单击）

    func testLoneRightOptionTapFlushesButComboReleaseDoesNot() {
        var kb = Keyboard()

        kb.rightOption(down: true)
        kb.rightOption(down: false)
        XCTAssertTrue(kb.drain().contains(.longRecordingFlushTap))

        // 走过组合键的那一次松开不算单击 —— 否则 ⌥, 开会话会立刻切出空的第一段。
        kb.rightOption(down: true)
        kb.tap(43)
        kb.rightOption(down: false)
        XCTAssertFalse(kb.drain().contains(.longRecordingFlushTap))
    }

    func testFlushTapContaminatedWhenOtherKeyAlreadyHeld() {
        var kb = Keyboard()
        kb.keyDown(9)              // 先按住 V
        kb.rightOption(down: true) // 再按右 ⌥
        kb.rightOption(down: false)
        XCTAssertFalse(kb.drain().contains(.longRecordingFlushTap))
    }

    func testFlushTapRecoversAfterAContaminatedRound() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        kb.tap(43)
        kb.rightOption(down: false)
        _ = kb.drain()

        kb.rightOption(down: true)
        kb.rightOption(down: false)
        XCTAssertTrue(kb.drain().contains(.longRecordingFlushTap), "污染标志必须逐轮清空")
    }

    // MARK: - Ask 双击并按住

    func testDoubleTapAndHoldEntersAskGesture() {
        var kb = Keyboard()
        kb.rightOption(down: true, at: 0)
        kb.rightOption(down: false, at: 0.2)     // 一击（≤ 0.35 s）
        XCTAssertTrue(kb.drain().contains(.overlayHoldReleased))

        kb.rightOption(down: true, at: 0.4)      // 间隔 0.2 s ≤ 0.4 s
        XCTAssertTrue(kb.drain().contains(.askHoldPressed))
        kb.rightOption(down: false, at: 2.0)
        let released = kb.drain()
        XCTAssertTrue(released.contains(.askHoldReleased))
        XCTAssertFalse(released.contains(.overlayHoldReleased))
    }

    func testSingleHoldNeverTriggersAsk() {
        var kb = Keyboard()
        kb.rightOption(down: true, at: 0)
        kb.rightOption(down: false, at: 3.0)
        let events = kb.drain()
        XCTAssertTrue(events.contains(.overlayHoldPressed))
        XCTAssertTrue(events.contains(.overlayHoldReleased))
        XCTAssertFalse(events.contains(.askHoldPressed))
    }

    func testRealHoldFollowedByAnotherHoldDoesNotPrimeAsk() {
        var kb = Keyboard()
        kb.rightOption(down: true, at: 0)
        kb.rightOption(down: false, at: 1.5)     // 真的按住了，不是一击
        _ = kb.drain()
        kb.rightOption(down: true, at: 1.6)
        XCTAssertEqual(kb.drain().filter { $0 == .askHoldPressed }, [])
    }

    func testExpiredTapDoesNotPrimeAsk() {
        var kb = Keyboard()
        kb.rightOption(down: true, at: 0)
        kb.rightOption(down: false, at: 0.2)     // 是一击
        _ = kb.drain()
        kb.rightOption(down: true, at: 1.0)      // 但间隔 0.8 s > 0.4 s
        let events = kb.drain()
        XCTAssertTrue(events.contains(.overlayHoldPressed))
        XCTAssertFalse(events.contains(.askHoldPressed))
    }

    // MARK: - 严格组合

    func testRightOptionDigitsAndFunctionRow() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()

        kb.keyDown(18)
        XCTAssertTrue(kb.drain().contains(.noteQuickPaste(1)))
        XCTAssertTrue(kb.lastSuppressed)
        kb.keyUp(18)

        // 5 和 6 的 keycode 是反的 —— 23 才是 5。
        kb.keyDown(23)
        XCTAssertTrue(kb.drain().contains(.noteQuickPaste(5)))
        kb.keyUp(23)

        kb.keyDown(122)
        XCTAssertTrue(kb.drain().contains(.processingPresetDigit(1)))
        kb.keyUp(122)
    }

    func testDigitComboIgnoresNonStrictCombination() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        kb.shift(down: true)
        _ = kb.drain()

        kb.keyDown(18)
        // ⌥⇧1 必须照常打字。
        XCTAssertFalse(kb.drain().contains(.noteQuickPaste(1)))
        XCTAssertFalse(kb.lastSuppressed)
    }

    func testDigitComboFiresOnceWhileKeyRepeats() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(19)
        kb.keyDown(19)   // 自动重复
        kb.keyDown(19)
        XCTAssertEqual(kb.drain(), [.noteQuickPaste(2)])
    }

    func testNoteTogglesOnlyWhenPanelVisible() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()

        kb.keyDown(9)
        XCTAssertTrue(kb.drain().isEmpty, "面板关着时 V 必须照常打字")
        XCTAssertFalse(kb.lastSuppressed)
        kb.keyUp(9)

        kb.matcher.noteTogglesActive = true
        kb.keyDown(9)
        XCTAssertEqual(kb.drain(), [.noteAutoPasteToggle])
        XCTAssertTrue(kb.lastSuppressed)
        kb.keyUp(9)

        kb.keyDown(35)
        XCTAssertEqual(kb.drain(), [.noteDiarizeToggle])
        kb.keyUp(35)
        kb.keyDown(1)
        XCTAssertEqual(kb.drain(), [.noteAutoSegToggle])
    }

    // MARK: - 自愈

    func testCapsLockPhantomKeycodeIsNeverTracked() {
        var kb = Keyboard(selfHeal: true)
        // 按一次 Caps Lock：**奇数个** keycode-255 的 flagsChanged。
        kb.raw(HotkeyEventType.flagsChanged, 255, flags: 0x10000)
        kb.raw(HotkeyEventType.flagsChanged, 255, flags: 0)
        kb.raw(HotkeyEventType.flagsChanged, 255, flags: 0x10000)
        XCTAssertFalse(kb.matcher.debugPressedKeys.contains(255))

        // 和弦必须照常工作 —— 老代码在这里全线堵死。
        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(33)
        XCTAssertTrue(kb.drain().contains(.historyPickerPressed))
    }

    func testStalePlainKeyExpiresAndChordsRecover() {
        var kb = Keyboard(selfHeal: true)
        kb.keyDown(33, at: 0)      // 它的 key-up 在 tap 被禁用期间丢了
        kb.keyUp(9, at: 0)         // 别的键正常收发，幽灵仍在

        kb.rightOption(down: true, at: 1)
        kb.keyDown(43, at: 1)
        XCTAssertFalse(kb.drain().contains(.jarvisTogglePressed), "幽灵键堵住和弦")
        kb.keyUp(43, at: 1)
        kb.rightOption(down: false, at: 1)
        _ = kb.drain()

        // 20 s 后过期。
        kb.rightOption(down: true, at: 30)
        XCTAssertFalse(kb.matcher.debugPressedKeys.contains(33))
        kb.keyDown(43, at: 30)
        XCTAssertTrue(kb.drain().contains(.jarvisTogglePressed))
    }

    func testSelfHealNeverDropsGenuinelyHeldKeys() {
        var kb = Keyboard(selfHeal: true)
        kb.keyDown(33, at: 0)
        kb.keyDown(33, at: 8)      // 自动重复刷新时间戳
        kb.keyDown(33, at: 16)
        kb.rightOption(down: true, at: 20)
        XCTAssertTrue(kb.matcher.debugPressedKeys.contains(33), "长按远低于 20 s 阈值")
    }

    func testOrphanPlainKeyIsSweptImmediately() {
        var kb = Keyboard(selfHeal: true)
        kb.keyDown(33, at: 0)
        // 伪造记账 bug：有 pressedKeys 记录、没有 pressedAt 记录。
        kb.matcher.debugForgetTimestamp(33)
        kb.rightOption(down: true, at: 0.1)
        XCTAssertFalse(kb.matcher.debugPressedKeys.contains(33),
                       "没有时间戳的普通键永远等不到过期，必须立刻扫掉")
    }

    func testPhantomModifierSelfHealsFromEventFlags() {
        var kb = Keyboard(selfHeal: true)
        kb.rightOption(down: true, at: 0)
        XCTAssertTrue(kb.matcher.debugPressedKeys.contains(61))
        _ = kb.drain()

        // 右 ⌥ 的 key-up 丢了，但下一个 flagsChanged 的 flags 里已经没有 ⌥ 位。
        kb.flags = HotkeyMask.shift
        kb.raw(HotkeyEventType.flagsChanged, 56, flags: HotkeyMask.shift, at: 1)
        XCTAssertFalse(kb.matcher.debugPressedKeys.contains(61))
        XCTAssertTrue(kb.matcher.debugPressedKeys.contains(56))
    }

    func testModifierReconciliationUsesSharedBitNotDeviceBit() {
        var kb = Keyboard(selfHeal: true)
        kb.rightOption(down: true, at: 0)
        _ = kb.drain()
        // 设备位 0x40 跨键盘不可信：只有共享的 alternate 位在，右 ⌥ 也必须留着。
        kb.raw(HotkeyEventType.flagsChanged, 56,
               flags: HotkeyMask.alternate | HotkeyMask.shift, at: 1)
        XCTAssertTrue(kb.matcher.debugPressedKeys.contains(61))
    }

    func testResetClearsEverything() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        kb.keyDown(33)
        _ = kb.drain()

        kb.matcher.resetMatches()
        XCTAssertTrue(kb.matcher.debugPressedKeys.isEmpty)

        // 复位之后重新按下必须重新发一次事件（边沿状态也清了）。
        kb.rightOption(down: true)
        XCTAssertTrue(kb.drain().contains(.overlayHoldPressed))
    }

    func testChangingShortcutsResetsState() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        kb.keyDown(33)
        _ = kb.drain()

        var config = ShortcutsConfig()
        config.historyPicker = Shortcut([(61, "Right Option"), (30, "]")])
        kb.matcher.shortcuts = config
        XCTAssertTrue(kb.matcher.debugPressedKeys.isEmpty,
                      "改绑期间的 key-up 看不见，残留状态不可信")
    }

    // MARK: - 截图槽动态摘除

    func testEmptiedScreenshotSlotPassesKeysThrough() {
        var config = ShortcutsConfig()
        config.selectScreenshotRegion = .empty
        config.captureScreenshot = .empty
        var kb = Keyboard(HotkeyMatcher(shortcuts: config))

        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(41)
        XCTAssertTrue(kb.drain().isEmpty)
        XCTAssertFalse(kb.lastSuppressed, "关掉截图功能后按键必须原样透传给其他 App")
    }

    // MARK: - 落笔

    func testNoteModeChordFiresOnOptionSpace() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(49)
        XCTAssertTrue(kb.drain().contains(.noteModePressed))
        XCTAssertTrue(kb.lastSuppressed)
    }

    func testFlushSegmentWorksWhileHoldKeyHeld() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        XCTAssertTrue(kb.drain().contains(.overlayHoldPressed))
        kb.keyDown(47)
        XCTAssertTrue(kb.drain().contains(.flushSegmentPressed))
    }
}
