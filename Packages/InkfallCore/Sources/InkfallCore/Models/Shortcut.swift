import Foundation

public struct ShortcutKey: Codable, Sendable, Hashable {
    public var keycode: UInt16
    public var label: String

    public init(keycode: UInt16, label: String) {
        self.keycode = keycode
        self.label = label
    }
}

public struct Shortcut: Codable, Sendable, Hashable {
    public var keys: [ShortcutKey]

    public init(keys: [ShortcutKey] = []) { self.keys = keys }

    public init(_ pairs: [(UInt16, String)]) {
        self.keys = pairs.map { ShortcutKey(keycode: $0.0, label: $0.1) }
    }

    public static let empty = Shortcut()

    public var isEmpty: Bool { keys.isEmpty }

    public var normalizedKeycodes: Set<UInt16> {
        Set(keys.map { Shortcut.normalize($0.keycode) })
    }

    /// 左右修饰键合并。**注意 61（右 ⌥）不归一到 58** —— 右 Option 是
    /// 独立可绑定的键，整个默认方案都建立在它上面。
    public static func normalize(_ keycode: UInt16) -> UInt16 {
        switch keycode {
        case 54: return 55   // 右 ⌘ → ⌘
        case 60: return 56   // 右 ⇧ → ⇧
        case 62: return 59   // 右 ⌃ → ⌃
        default: return keycode
        }
    }

    public var displayLabel: String {
        keys.isEmpty ? "" : keys.map(\.label).joined(separator: " + ")
    }
}

/// macOS 上 Fn / Globe 键的 keycode。中和掉系统默认的「按 Globe 切输入法」
/// 之后（`defaults write com.apple.HIToolbox AppleFnUsageType -int 0`），
/// 它可以当作普通推杆修饰键用。
public let fnKeycode: UInt16 = 63

public struct ShortcutsConfig: Codable, Sendable, Hashable {
    /// 按住说话：按下起录，松开转写并插回。
    public var overlayHold: Shortcut
    /// 切换录音：按一下开始长录音，再按一下停止并转写。默认 ⌥Space。
    public var toggleRecording: Shortcut

    public init(
        overlayHold: Shortcut = Shortcut([(61, "Right Option")]),
        toggleRecording: Shortcut = Shortcut([(61, "Right Option"), (49, "Space")])
    ) {
        self.overlayHold = overlayHold
        self.toggleRecording = toggleRecording
    }

    public var allShortcuts: [Shortcut] { [overlayHold, toggleRecording] }

    public var namedShortcuts: [(id: String, shortcut: Shortcut)] {
        [("overlayHold", overlayHold), ("toggleRecording", toggleRecording)]
    }

    /// 有没有任何快捷键绑了这个 keycode。
    /// 用来决定要不要中和系统的 Fn/Globe 行为 —— 必须检查**全部**槽位。
    public func uses(keycode: UInt16) -> Bool {
        allShortcuts.contains { $0.keys.contains { $0.keycode == keycode } }
    }

    public var usesFn: Bool { uses(keycode: fnKeycode) }

    /// `candidate` 会和哪个已有主槽冲突（跳过 `skip`）。绑定同一组归一化键集合
    /// 即冲突 —— 监听器会对同一个组合同时匹配两者。空快捷键永不冲突。
    public func conflictingSlot(_ candidate: Shortcut, skip: String = "") -> String? {
        guard !candidate.isEmpty else { return nil }
        let keys = candidate.normalizedKeycodes
        return namedShortcuts.first {
            $0.id != skip && !$0.shortcut.isEmpty && $0.shortcut.normalizedKeycodes == keys
        }?.id
    }

    /// 是否撞上众所周知的 macOS 系统组合。不穷举 —— 够用来在用户绑一个
    /// 会被系统先截走的组合之前提醒他。只警告，不阻止。
    public static func isSystemReserved(_ candidate: Shortcut) -> Bool {
        guard !candidate.isEmpty else { return false }
        let cmd: UInt16 = 55, opt: UInt16 = 58, shift: UInt16 = 56
        let space: UInt16 = 49, tab: UInt16 = 48, esc: UInt16 = 53, q: UInt16 = 12
        let reserved: [Set<UInt16>] = [
            [cmd, space],          // 聚焦
            [cmd, opt, space],     // Finder 搜索
            [cmd, shift, space],
            [cmd, tab],            // 切换 App
            [cmd, shift, tab],
            [cmd, opt, esc],       // 强制退出
            [cmd, opt, q],         // 注销
        ]
        return reserved.contains(candidate.normalizedKeycodes)
    }

    // MARK: - 容错解码 + 迁移

    private enum CodingKeys: String, CodingKey {
        case overlayHold, toggleRecording
        /// 减法之前「落笔」的槽。用户自定义过的绑定迁到 toggleRecording。
        case noteMode
    }

    /// 任意字段缺失/类型错，只回落**那一个**字段，不丢用户其他自定义。
    /// 减法之前的其他槽（historyPicker / flushSegment / 截图 …）静默忽略。
    public init(from decoder: Decoder) throws {
        let d = ShortcutsConfig()
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        func f(_ key: CodingKeys) -> Shortcut? {
            (try? c?.decodeIfPresent(Shortcut.self, forKey: key)) ?? nil
        }
        overlayHold = f(.overlayHold) ?? d.overlayHold
        // 老的 ⌥, 默认值不迁：那是贾维斯别名腾出来之前的历史，不是用户的选择。
        let oldComma = Shortcut([(61, "Right Option"), (43, ",")]).normalizedKeycodes
        if let toggle = f(.toggleRecording) {
            toggleRecording = toggle
        } else if let note = f(.noteMode), note.normalizedKeycodes != oldComma {
            toggleRecording = note
        } else {
            toggleRecording = d.toggleRecording
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overlayHold, forKey: .overlayHold)
        try c.encode(toggleRecording, forKey: .toggleRecording)
    }
}
