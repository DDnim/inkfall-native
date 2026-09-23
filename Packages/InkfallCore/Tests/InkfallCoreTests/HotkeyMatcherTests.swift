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

    // MARK: - 按住说话

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

    func testRightOptionHoldPressAndRelease() {
        var kb = Keyboard()
        kb.rightOption(down: true, at: 0)
        XCTAssertEqual(kb.drain(), [.overlayHoldPressed])
        XCTAssertFalse(kb.lastSuppressed, "修饰键永不吞")
        kb.rightOption(down: false, at: 3.0)
        XCTAssertEqual(kb.drain(), [.overlayHoldReleased])
    }

    // MARK: - 切换录音（⌥Space）

    func testToggleChordFiresOnOptionSpaceAndSwallowsSpace() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()

        kb.keyDown(49)
        XCTAssertEqual(kb.drain(), [.toggleRecordingPressed])
        XCTAssertTrue(kb.lastSuppressed, "⌥Space 匹配成立，key-down 必须吞掉")

        kb.keyUp(49)
        XCTAssertTrue(kb.lastSuppressed, "只吞一半会让前台 App 收到孤儿 key-up")
    }

    func testToggleFiresOnceWhileKeyRepeats() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(49)
        kb.keyDown(49)   // 自动重复
        kb.keyDown(49)
        XCTAssertEqual(kb.drain(), [.toggleRecordingPressed])
    }

    func testExtraModifiersToleratedButExtraPlainKeyBreaksChord() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        _ = kb.drain()

        // ⌥⇧Space 仍然算切换（额外的修饰键容忍）。
        kb.shift(down: true)
        kb.keyDown(49)
        XCTAssertTrue(kb.drain().contains(.toggleRecordingPressed))
        kb.keyUp(49)
        kb.shift(down: false)

        // 但多按一个普通键就不匹配了。
        kb.keyDown(9)
        _ = kb.drain()
        kb.keyDown(49)
        XCTAssertFalse(kb.drain().contains(.toggleRecordingPressed))
        XCTAssertFalse(kb.lastSuppressed)
    }

    /// 切换键的那个 ⌥ 就是推杆本身：按下先发一次 hold，Space 到了再发 toggle。
    /// 宿主要靠 `abortSpuriousHold` 丢掉那截录音 —— 这里钉住事件顺序。
    func testToggleChordIsPrecededByHoldPress() {
        var kb = Keyboard()
        kb.rightOption(down: true)
        kb.keyDown(49)
        kb.keyUp(49)
        kb.rightOption(down: false)
        XCTAssertEqual(kb.drain(),
                       [.overlayHoldPressed, .toggleRecordingPressed, .overlayHoldReleased])
    }

    func testBareKeysAreUntouched() {
        var kb = Keyboard()
        kb.keyDown(49)
        XCTAssertTrue(kb.drain().isEmpty)
        XCTAssertFalse(kb.lastSuppressed, "没按 ⌥ 的空格必须原样透传")
        kb.keyUp(49)
        kb.keyDown(53)
        XCTAssertTrue(kb.drain().isEmpty)
        XCTAssertFalse(kb.lastSuppressed, "全局吞掉裸 esc 是不可接受的")
    }

    func testEmptiedToggleSlotPassesKeysThrough() {
        var config = ShortcutsConfig()
        config.toggleRecording = .empty
        var kb = Keyboard(HotkeyMatcher(shortcuts: config))

        kb.rightOption(down: true)
        _ = kb.drain()
        kb.keyDown(49)
        XCTAssertTrue(kb.drain().isEmpty)
        XCTAssertFalse(kb.lastSuppressed, "槽位置空后按键必须原样透传给其他 App")
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
        kb.keyDown(49)
        XCTAssertTrue(kb.drain().contains(.toggleRecordingPressed))
    }

    func testStalePlainKeyExpiresAndChordsRecover() {
        var kb = Keyboard(selfHeal: true)
        kb.keyDown(33, at: 0)      // 它的 key-up 在 tap 被禁用期间丢了
        kb.keyUp(9, at: 0)         // 别的键正常收发，幽灵仍在

        kb.rightOption(down: true, at: 1)
        kb.keyDown(49, at: 1)
        XCTAssertFalse(kb.drain().contains(.toggleRecordingPressed), "幽灵键堵住和弦")
        kb.keyUp(49, at: 1)
        kb.rightOption(down: false, at: 1)
        _ = kb.drain()

        // 20 s 后过期。
        kb.rightOption(down: true, at: 30)
        XCTAssertFalse(kb.matcher.debugPressedKeys.contains(33))
        kb.keyDown(49, at: 30)
        XCTAssertTrue(kb.drain().contains(.toggleRecordingPressed))
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
        XCTAssertEqual(kb.drain(), [.overlayHoldReleased], "推杆随之松开")
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
        kb.keyDown(49)
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
        kb.keyDown(49)
        _ = kb.drain()

        var config = ShortcutsConfig()
        config.toggleRecording = Shortcut([(61, "Right Option"), (47, ".")])
        kb.matcher.shortcuts = config
        XCTAssertTrue(kb.matcher.debugPressedKeys.isEmpty,
                      "改绑期间的 key-up 看不见，残留状态不可信")
    }
}
