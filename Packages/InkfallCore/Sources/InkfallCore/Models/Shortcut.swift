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

public struct PostProcessingEditShortcuts: Codable, Sendable, Hashable {
    public var basic = Shortcut.empty
    public var light = Shortcut.empty
    public var clean = Shortcut.empty
    public var polish = Shortcut.empty
    public var summary = Shortcut.empty
    public var email = Shortcut.empty
    public var notes = Shortcut.empty
    public var meeting = Shortcut.empty
    public var custom = Shortcut.empty

    public init() {}

    public var all: [Shortcut] {
        [basic, light, clean, polish, summary, email, notes, meeting, custom]
    }
}

public struct ShortcutsConfig: Codable, Sendable, Hashable {
    public var overlayHold: Shortcut
    /// 落笔：连续录音进笔记面板。默认 ⌥Space（长录听写下线后腾出来的键）；
    /// ⌥, 作为硬编码别名活在热键监听器里。
    public var noteMode: Shortcut
    public var historyPicker: Shortcut
    public var editBeforeSend: Shortcut
    public var flushSegment: Shortcut
    public var cancelRecording: Shortcut
    public var selectScreenshotRegion: Shortcut
    public var captureScreenshot: Shortcut
    public var editBeforeSendPresets: PostProcessingEditShortcuts

    public init(
        overlayHold: Shortcut = Shortcut([(61, "Right Option")]),
        noteMode: Shortcut = Shortcut([(61, "Right Option"), (49, "Space")]),
        historyPicker: Shortcut = Shortcut([(61, "Right Option"), (33, "[")]),
        editBeforeSend: Shortcut = Shortcut([(61, "Right Option"), (44, "/")]),
        flushSegment: Shortcut = Shortcut([(61, "Right Option"), (47, ".")]),
        cancelRecording: Shortcut = Shortcut([(61, "Right Option"), (53, "Esc")]),
        selectScreenshotRegion: Shortcut = Shortcut([(61, "Right Option"), (41, ";")]),
        captureScreenshot: Shortcut = Shortcut([(61, "Right Option"), (39, "'")]),
        editBeforeSendPresets: PostProcessingEditShortcuts = .init()
    ) {
        self.overlayHold = overlayHold
        self.noteMode = noteMode
        self.historyPicker = historyPicker
        self.editBeforeSend = editBeforeSend
        self.flushSegment = flushSegment
        self.cancelRecording = cancelRecording
        self.selectScreenshotRegion = selectScreenshotRegion
        self.captureScreenshot = captureScreenshot
        self.editBeforeSendPresets = editBeforeSendPresets
    }

    /// 八个主槽（不含 per-preset 编辑快捷键）。
    public var allShortcuts: [Shortcut] {
        [overlayHold, noteMode, historyPicker, editBeforeSend,
         flushSegment, cancelRecording, selectScreenshotRegion, captureScreenshot]
    }

    public var namedShortcuts: [(id: String, shortcut: Shortcut)] {
        [("overlayHold", overlayHold), ("noteMode", noteMode),
         ("historyPicker", historyPicker), ("editBeforeSend", editBeforeSend),
         ("flushSegment", flushSegment), ("cancelRecording", cancelRecording),
         ("selectScreenshotRegion", selectScreenshotRegion),
         ("captureScreenshot", captureScreenshot)]
    }

    /// 有没有任何快捷键（含 per-preset 的）绑了这个 keycode。
    /// 用来决定要不要中和系统的 Fn/Globe 行为 —— 必须检查**全部**槽位。
    public func uses(keycode: UInt16) -> Bool {
        let inKeys = { (s: Shortcut) in s.keys.contains { $0.keycode == keycode } }
        return allShortcuts.contains(where: inKeys)
            || editBeforeSendPresets.all.contains(where: inKeys)
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
        case overlayHold, noteMode, historyPicker, editBeforeSend, flushSegment
        case cancelRecording, selectScreenshotRegion, captureScreenshot
        case editBeforeSendPresets
    }

    /// 任意字段缺失/类型错，只回落**那一个**字段，不丢用户其他自定义。
    /// 另外做落笔键迁移：长录听写下线后，`noteMode` 从旧的 ⌥, 改到 ⌥Space；
    /// 已废弃的 `overlayToggle` 静默忽略。
    public init(from decoder: Decoder) throws {
        let d = ShortcutsConfig()
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        func f(_ key: CodingKeys, _ fallback: Shortcut) -> Shortcut {
            (try? c?.decodeIfPresent(Shortcut.self, forKey: key)) ?? nil ?? fallback
        }
        overlayHold = f(.overlayHold, d.overlayHold)
        historyPicker = f(.historyPicker, d.historyPicker)
        editBeforeSend = f(.editBeforeSend, d.editBeforeSend)
        flushSegment = f(.flushSegment, d.flushSegment)
        cancelRecording = f(.cancelRecording, d.cancelRecording)
        selectScreenshotRegion = f(.selectScreenshotRegion, d.selectScreenshotRegion)
        captureScreenshot = f(.captureScreenshot, d.captureScreenshot)
        editBeforeSendPresets =
            (try? c?.decodeIfPresent(PostProcessingEditShortcuts.self,
                                     forKey: .editBeforeSendPresets)) ?? nil
            ?? d.editBeforeSendPresets

        let decodedNote = (try? c?.decodeIfPresent(Shortcut.self, forKey: .noteMode)) ?? nil
        // 迁移：没有 noteMode（早于落笔），或还停在旧的 ⌥, 默认值 —— 都移到 ⌥Space。
        // ⌥, 靠硬编码别名继续可用，所以什么都没丢。用户自定义的绑定尊重原样。
        let oldDefault = Shortcut([(61, "Right Option"), (43, ",")]).normalizedKeycodes
        if let decodedNote, decodedNote.normalizedKeycodes != oldDefault {
            noteMode = decodedNote
        } else {
            noteMode = d.noteMode
        }
    }

    /// 磁盘上的 shortcuts.json 是否早于 ⌥Space 改绑，因而需要回写一次。
    /// 内存里的迁移不落盘会导致每次启动都重做一遍。
    public static func predatesNoteSpace(json: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return false
        }
        if obj["overlayToggle"] != nil { return true }
        guard let note = obj["noteMode"] as? [String: Any],
              let keys = note["keys"] as? [[String: Any]] else { return true }
        let codes = Set(keys.compactMap { ($0["keycode"] as? NSNumber)?.uint16Value })
        return codes == [61, 43]
    }
}
