import Foundation

// MARK: - 事件类型常量（CGEventType 的原始值）

public enum HotkeyEventType {
    public static let keyDown: UInt32 = 10
    public static let keyUp: UInt32 = 11
    public static let flagsChanged: UInt32 = 12
}

/// CGEventFlags 位。
public enum HotkeyMask {
    public static let command: UInt64 = 0x100000
    public static let shift: UInt64 = 0x20000
    public static let alternate: UInt64 = 0x80000
    public static let control: UInt64 = 0x40000
    public static let secondaryFn: UInt64 = 0x800000
    /// 只有**右** Option 按下时才置位的设备相关位。
    /// 共享的 alternate 位分不出左右。
    ///
    /// ⚠️ 但**自愈对账时不能用它** —— 跨键盘不可信（见 `selfHealStaleKeys`）。
    public static let rightOptionDevice: UInt64 = 0x40
}

public enum Keycode {
    public static let modifiers: Set<UInt16> = [55, 56, 58, 59, 61, 63]
    public static let rightOption: UInt16 = 61
    public static let escape: UInt16 = 53
    public static let fn: UInt16 = 63
}

public enum HotkeyTiming {
    /// 一个被跟踪的普通键多久没有任何键事件刷新就算幽灵（它的 key-up 在 tap
    /// 被禁用期间丢了）。长按会自动重复，远低于这个值。
    public static let stalePressedKeySeconds: Double = 20
}

// MARK: - 事件

/// 减法版只剩两个手势：按住说话（按下 / 松开）与切换录音（按一下）。
public enum HotkeyEvent: Equatable, Sendable {
    case overlayHoldPressed
    case overlayHoldReleased
    /// 切换录音：按一下开始长录音，再按一下停止并转写。
    case toggleRecordingPressed
}

// MARK: - 和弦状态机

/// 热键的全部判定逻辑，与 CGEventTap 解耦。
///
/// 把它做成纯的，是因为这里的每一条规则都对应一个真实 bug，而这些 bug 全都
/// 只能用**合成事件序列**复现 —— 真机按键测不出「tap 被禁用期间丢了 key-up」。
public struct HotkeyMatcher: Sendable {

    public var shortcuts: ShortcutsConfig {
        didSet { resetMatches() }
    }

    private var pressedKeys: Set<UInt16> = []
    /// 每个被跟踪的**非修饰**键最后一次收到事件的时间（自动重复会刷新），
    /// 驱动幽灵键过期。
    private var pressedAt: [UInt16: Double] = [:]
    private var suppressedKeyUps: Set<UInt16> = []

    private var matched: Set<String> = []

    /// 真实 tap 上开启：每个事件先把跟踪状态与权威来源对账。
    public var systemStateVerify = false

    public init(shortcuts: ShortcutsConfig = ShortcutsConfig()) {
        self.shortcuts = shortcuts
    }

    // MARK: - 主入口

    /// 处理一个事件。
    /// - Returns: 要派发的事件，以及这个事件是否必须被**吞掉**（不给前台 App）。
    public mutating func handle(type: UInt32, keycode: UInt16, flags: UInt64,
                                now: Double) -> (events: [HotkeyEvent], suppress: Bool) {
        let normalized = Shortcut.normalize(keycode)
        var events: [HotkeyEvent] = []
        var suppress = false

        if systemStateVerify { selfHealStaleKeys(type: type, flags: flags, now: now) }

        switch type {
        case HotkeyEventType.keyDown:
            pressedKeys.insert(normalized)
            pressedAt[normalized] = now
        case HotkeyEventType.keyUp:
            pressedKeys.remove(normalized)
            pressedAt.removeValue(forKey: normalized)
            suppress = suppressedKeyUps.remove(normalized) != nil
        case HotkeyEventType.flagsChanged:
            updateModifier(normalized, flags: flags)
        default:
            break
        }

        dispatchMatches(&events)

        if type == HotkeyEventType.keyDown, shouldConsumeKeyDown(normalized) {
            suppressedKeyUps.insert(normalized)
            suppress = true
        }

        return (events, suppress)
    }

    // MARK: - 自愈

    /// 卡住的 `pressedKeys` 自愈（「⌥+逗号 直到重启 App 才恢复」那个 bug）：
    /// tap 被 macOS 禁用期间到达的 key-up 根本没被看见，留下一个幽灵键，
    /// 从此**每一个含普通键的和弦都匹配不上**。
    ///
    /// ⚠️ **刻意保守。**早期版本查过 `CGEventSourceKeyState` 和每个事件的 flags，
    /// 两者在真实键盘上都不可靠（IME 合并的按键事件带着过期 flags；key-state API
    /// 与事件流不一致），反而**造成了**死掉的 ⌥ 和弦。
    private mutating func selfHealStaleKeys(type: UInt32, flags: UInt64, now: Double) {
        if type == HotkeyEventType.flagsChanged {
            // 只在 flagsChanged 上对账修饰键 —— 那时候的 flags 才是权威的。
            // 右⌥(61) 用**共享的** alternate 位判定；设备位 0x40 跨键盘不可信。
            let down: [(UInt16, Bool)] = [
                (55, flags & HotkeyMask.command != 0),
                (56, flags & HotkeyMask.shift != 0),
                (58, flags & HotkeyMask.alternate != 0),
                (59, flags & HotkeyMask.control != 0),
                (61, flags & HotkeyMask.alternate != 0),
                (63, flags & HotkeyMask.secondaryFn != 0),
            ]
            for (keycode, isDown) in down where !isDown {
                pressedKeys.remove(keycode)
                pressedAt.removeValue(forKey: keycode)
            }
        }

        var stale: Set<UInt16> = []
        for (keycode, at) in pressedAt
        where !Keycode.modifiers.contains(keycode)
            && now - at >= HotkeyTiming.stalePressedKeySeconds {
            stale.insert(keycode)
        }
        // 孤儿：在 pressedKeys 里却没有 pressedAt 记录的非修饰键，只可能来自
        // 记账 bug（keycode-255 幽灵就是这么进来的）。它永远不会过期，
        // 会永久堵住和弦，所以立刻扫掉。
        for keycode in pressedKeys
        where !Keycode.modifiers.contains(keycode) && pressedAt[keycode] == nil {
            stale.insert(keycode)
        }
        for keycode in stale {
            pressedKeys.remove(keycode)
            pressedAt.removeValue(forKey: keycode)
            suppressedKeyUps.remove(keycode)
        }
    }

    private mutating func updateModifier(_ keycode: UInt16, flags: UInt64) {
        func set(_ code: UInt16, _ isDown: Bool) {
            if isDown { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        }
        switch keycode {
        case 55: set(55, flags & HotkeyMask.command != 0)
        case 56: set(56, flags & HotkeyMask.shift != 0)
        case 58: set(58, flags & HotkeyMask.alternate != 0)
        case 59: set(59, flags & HotkeyMask.control != 0)
        case 61: set(61, flags & HotkeyMask.rightOptionDevice != 0)
        case 63: set(63, flags & HotkeyMask.secondaryFn != 0)
        default:
            // ⚠️ 未知 keycode 一律**忽略，绝不跟踪**。
            // 这里以前会盲目 toggle 进 pressedKeys，而按一次 Caps Lock
            // （中/英切换）会发出**奇数个** keycode-255 的 flagsChanged 事件，
            // 净出一个永不释放、且两轮自愈都看不见的键（toggle 路径从不写
            // pressedAt），`matches()` 里全线堵死，而纯修饰键的推杆还照常工作。
            // 2026-07-20 事故。
            break
        }
    }

    // MARK: - 匹配与派发

    /// 边沿触发：false→true 才发事件，避免自动重复刷屏。
    private mutating func edge(_ id: String, _ active: Bool, _ onPress: () -> Void) {
        if active, !matched.contains(id) {
            matched.insert(id)
            onPress()
        } else if !active {
            matched.remove(id)
        }
    }

    private mutating func dispatchMatches(_ events: inout [HotkeyEvent]) {
        let hold = matches(shortcuts.overlayHold)
        if hold, !matched.contains("hold") {
            matched.insert("hold")
            events.append(.overlayHoldPressed)
        } else if !hold, matched.contains("hold") {
            matched.remove("hold")
            events.append(.overlayHoldReleased)
        }

        edge("toggle", matches(shortcuts.toggleRecording)) {
            events.append(.toggleRecordingPressed)
        }
    }

    func matches(_ shortcut: Shortcut) -> Bool {
        guard !shortcut.isEmpty else { return false }
        let keys = shortcut.normalizedKeycodes
        guard keys.isSubset(of: pressedKeys) else { return false }
        // 纯修饰键快捷键（如 Fn 推杆）只要那些修饰键按着就算匹配，无视其他键。
        if keys.allSatisfy(Keycode.modifiers.contains) { return true }
        // 含普通键的组合：容忍额外的**修饰**键（⌘⇧L 要能在按着 Fn 推杆时触发），
        // 但多一个普通键就不匹配。
        return pressedKeys.subtracting(keys).allSatisfy(Keycode.modifiers.contains)
    }

    private func shouldConsumeKeyDown(_ keycode: UInt16) -> Bool {
        // 修饰键永不吞 —— 吞了会打断正常输入。
        if Keycode.modifiers.contains(keycode) { return false }
        return consumes(shortcuts.toggleRecording, keycode)
    }

    private func consumes(_ shortcut: Shortcut, _ keycode: UInt16) -> Bool {
        let keys = shortcut.normalizedKeycodes
        guard keys.contains(keycode), !keys.allSatisfy(Keycode.modifiers.contains) else {
            return false
        }
        return matches(shortcut)
    }

    /// 丢掉全部按键状态。`update()` / `stop()` / tap 恢复之后都要调 ——
    /// 禁用期间的 key-up 根本没看见，残留状态不可信。
    public mutating func resetMatches() {
        pressedKeys.removeAll()
        pressedAt.removeAll()
        suppressedKeyUps.removeAll()
        matched.removeAll()
    }

    /// 测试用：当前被跟踪为按下的键。
    public var debugPressedKeys: Set<UInt16> { pressedKeys }

    /// 测试用：伪造「有按下记录、没有时间戳」的记账 bug，验证孤儿清扫。
    public mutating func debugForgetTimestamp(_ keycode: UInt16) {
        pressedAt.removeValue(forKey: keycode)
    }
}
