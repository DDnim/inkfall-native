import Foundation

/// 粘贴路径上的时间常数，全部来自 spec/02 §5。
///
/// ⚠️ 这些数字是线上踩出来的，不是估的。特别是 `clipboardRestoreSeconds`：
/// 还原剪贴板必须 debounce 300 ms，让目标 App 先把 pasteboard 读完 ——
/// 早一步还原，用户粘出来的就是他自己的旧剪贴板内容（不变量 A20）。
public enum PasteTiming {
    /// ⌘C 抓选区之后等剪贴板落定。
    public static let selectionCaptureSeconds: Double = 0.140
    /// AXRaise 之后等目标 App 换完 key window。
    public static let raiseWindowSeconds: Double = 0.080
    /// activate 之后、⌘V 之前。
    public static let activateBeforePasteSeconds: Double = 0.120
    /// ⌘V 之后到还原剪贴板之间的 debounce。
    public static let clipboardRestoreSeconds: Double = 0.300
    /// 把焦点还给上一个前台 App 之后等它稳定。
    public static let refocusPreviousSeconds: Double = 0.060
}

/// 一次插入尝试的具体手段，按「越靠前越不打扰用户」排序。
public enum PasteRoute: String, Sendable, Equatable, CaseIterable {
    /// 目标已经在前台：写剪贴板 + ⌘V，零激活。
    case pasteInPlace
    /// AX 直接写 `AXSelectedText`，真·零焦点。很多 App 不支持。
    case accessibility
    /// 回落：切过去、粘、再切回来。会闪一下焦点。
    case activateAndPaste
    /// 不合成任何按键，只把文字留在剪贴板上。
    case clipboardOnly

    /// 这条路要不要动用户的剪贴板 —— 要动就得存/还原（A20）。
    /// `clipboardOnly` 是刻意的例外：把文字**留在**剪贴板上就是它的全部意义。
    public var usesClipboard: Bool {
        self == .pasteInPlace || self == .activateAndPaste
    }
}

/// 一次插入最终发生了什么。调用方靠它决定「说什么」和「算不算已粘贴」。
///
/// 前五个对齐 Tauri 的 `NoteInsertOutcome`（spec/01 §6.3）。
/// `accessibilityDenied` 与 `disabled` 是原生版新增的：
/// 前者原本混在 `failedCopied` 里，而「没授权」是用户唯一能动手解决的那一种失败，
/// 必须能单独识别出来才谈得上引导；后者是新的全局开关关掉时的正常结果，不是失败。
public enum PasteOutcome: String, Sendable, Equatable {
    /// 插进目标了，焦点全程没动。
    case inserted
    /// 插进目标了，中途短暂切走又切回来。
    case insertedRefocus
    /// 没有目标 → 已复制。
    case noTarget
    /// 起录时的目标 App 已经退出 → 已复制。
    case targetClosed
    /// 没有辅助功能授权，合成按键会被系统静默丢弃 → 已复制。
    case accessibilityDenied
    /// 该试的都试了还是没成 → 已复制。
    case failedCopied
    /// 用户关掉了自动粘贴 → 只复制。
    case disabled
    /// 根本没有可粘的内容。
    case nothingToPaste

    /// 文字真的进目标了吗。
    ///
    /// ⚠️ 落笔靠它决定要不要打 `pasted` 标记。只落到剪贴板却标成已粘贴，
    /// 用户再按一次「粘贴所有」就什么都不出来了。
    public var landedInTarget: Bool {
        self == .inserted || self == .insertedRefocus
    }

    /// 要不要把用户引到系统设置去。只有真授权问题才引 —— 其余情况弹面板是骚扰。
    public var needsAccessibilityPrompt: Bool { self == .accessibilityDenied }
}

/// 目标在**做决策那一刻**的真实状况。App 层探测好之后填进来 ——
/// 这样这一层不碰任何系统 API，也就能在单测里走完全部分支。
public struct PasteTargetState: Sendable, Equatable {
    /// 目标进程还活着吗。
    public var isRunning: Bool
    /// 目标现在就是前台吗。
    public var isFrontmost: Bool
    /// 能不能用 AX 写入。AX 写的是**该 App 的焦点元素**，所以钉住的窗口
    /// 不是它当前的焦点窗口时，这一路会把文字送进另一个窗口，必须跳过。
    public var allowsAccessibilityInsert: Bool

    public init(isRunning: Bool, isFrontmost: Bool, allowsAccessibilityInsert: Bool = true) {
        self.isRunning = isRunning
        self.isFrontmost = isFrontmost
        self.allowsAccessibilityInsert = allowsAccessibilityInsert
    }
}

/// 一次插入的完整计划：按顺序试哪几条路，全失败时报什么。
public struct PastePlan: Sendable, Equatable {
    /// 按顺序尝试，第一条成功的就是结果。空数组 = 没有东西可粘。
    public let attempts: [PasteRoute]
    /// 一条都没成（或压根没得试）时的结果。
    public let fallback: PasteOutcome

    public init(attempts: [PasteRoute], fallback: PasteOutcome) {
        self.attempts = attempts
        self.fallback = fallback
    }

    /// 成功的那条路对应什么结果。`nil` = 全试完了都没成。
    public func outcome(after route: PasteRoute?) -> PasteOutcome {
        switch route {
        case .pasteInPlace, .accessibility: return .inserted
        case .activateAndPaste: return .insertedRefocus
        case .clipboardOnly, nil: return fallback
        }
    }
}

public enum AutoPaste {

    /// 决定这一次怎么插。**不做任何系统调用** —— 探测结果由调用方填进 `target`。
    ///
    /// 判定顺序是有讲究的，每一步都挡住一种「看起来成功了其实没有」：
    /// 1. 空文本：什么都别做。
    /// 2. 开关关着：只复制，一个按键都不合成。
    /// 3. 没目标 / 目标已退出：**绝不能**往下走。死进程 activate 是空操作，
    ///    紧接着那一下 ⌘V 会打进当时恰好在前台的别人窗口。
    /// 4. 没有辅助功能授权：`CGEvent.post` 会被系统静默丢弃，AX 写入也会被拒。
    ///    不在这里拦住，用户看到的就是「已粘回 Xcode」而实际什么都没发生。
    public static func plan(text: String,
                            autoPasteEnabled: Bool,
                            accessibilityTrusted: Bool,
                            target: PasteTargetState?) -> PastePlan {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PastePlan(attempts: [], fallback: .nothingToPaste)
        }
        guard autoPasteEnabled else {
            return PastePlan(attempts: [.clipboardOnly], fallback: .disabled)
        }
        // 未授权排在「没目标」前面：那才是用户唯一能动手解决的那件事，
        // 报「已复制到剪贴板」会把真正的原因盖掉。
        guard accessibilityTrusted else {
            return PastePlan(attempts: [.clipboardOnly], fallback: .accessibilityDenied)
        }
        guard let target else {
            return PastePlan(attempts: [.clipboardOnly], fallback: .noTarget)
        }
        guard target.isRunning else {
            return PastePlan(attempts: [.clipboardOnly], fallback: .targetClosed)
        }
        if target.isFrontmost {
            return PastePlan(attempts: [.pasteInPlace], fallback: .failedCopied)
        }
        let attempts: [PasteRoute] = target.allowsAccessibilityInsert
            ? [.accessibility, .activateAndPaste]
            : [.activateAndPaste]
        return PastePlan(attempts: attempts, fallback: .failedCopied)
    }

    /// 真正送出去的文本。
    ///
    /// `appendNewline`（`pasteAppendNewline`）在 trim **之后**补 ——
    /// 先补后 trim 等于没补，而原文尾部的空白会把换行顶到看不见的地方。
    /// 空文本不补：那会变成「粘一个空行」。
    public static func compose(_ text: String, appendNewline: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appendNewline, !trimmed.isEmpty else { return trimmed }
        return trimmed + "\n"
    }

    /// 给用户看的那一句。降级时必须说清楚**文字去哪儿了**，
    /// 否则用户以为这一段丢了 —— 其实它就在剪贴板上。
    public static func message(_ outcome: PasteOutcome, appName: String?) -> String {
        switch outcome {
        case .inserted, .insertedRefocus:
            return appName.map { "已粘回 \($0)" } ?? "已粘贴"
        case .noTarget, .disabled:
            return "已复制到剪贴板"
        case .targetClosed:
            // 有名字时空一格（"Xcode 已退出"），没名字时不空（"目标已退出"）。
            return (appName.map { "\($0) " } ?? "目标") + "已退出 · 已复制到剪贴板"
        case .accessibilityDenied:
            return "未授权辅助功能 · 已复制到剪贴板"
        case .failedCopied:
            return "粘贴失败 · 已复制到剪贴板"
        case .nothingToPaste:
            return "没听清"
        }
    }
}
