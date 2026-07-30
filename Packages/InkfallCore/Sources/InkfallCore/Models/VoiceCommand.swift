import Foundation

/// 语音命令在哪个终端里跑。三者都走 `/usr/bin/open`（**刻意不用 Apple Events**，
/// 所以不会弹「自动化」权限），只有「新标签页」那条路才需要 osascript。
public enum TerminalApp: String, Codable, Sendable, CaseIterable {
    case terminal, iterm, ghostty

    /// 命令跑在哪个 App 里 —— 连续对话拿它作句柄，也拿它判断目标是不是已经退了。
    public var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    public var label: String {
        switch self {
        case .terminal: return "终端"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    /// Ghostty 没有脚本接口，「新标签页」对它只能回落成新窗口。
    public var supportsNewTab: Bool { self != .ghostty }
}

/// 关键词允许出现在口述文本的哪个位置。`anywhere`（默认）逻辑上覆盖其余三种。
public enum KeywordPosition: String, Codable, Sendable, CaseIterable {
    case start, end, startOrEnd, anywhere

    public var label: String {
        switch self {
        case .start: return "开头"
        case .end: return "结尾"
        case .startOrEnd: return "开头或结尾"
        case .anywhere: return "文中任意位置"
        }
    }
}

/// 一条自定义语音命令：口述文本里出现 `keyword`（且位置被 `keywordPosition`
/// 允许）时，把 `commandTemplate` 里的占位符替换掉，在 `terminal` 里执行，
/// 而**不是**把转写粘贴出去。
public struct VoiceCommand: Codable, Sendable, Equatable {
    public var keyword: String
    /// 模板。
    ///
    /// - `terminal`：一行 shell。
    /// - `claudeCode`：**提问模板**，展开之后整个当作 `claude -p` 的提示词。
    public var commandTemplate: String
    /// 谁来执行。
    public var runner: VoiceCommandRunner
    public var terminal: TerminalApp
    public var enabled: Bool
    public var keywordPosition: KeywordPosition
    /// `claudeCode` 专用：命令跑在哪个目录（空 = `$HOME`）。
    /// 对一个编码助手来说这一项决定了它能看见什么。
    public var workingDirectory: String
    /// `claudeCode` 专用：放行只读的联网工具（WebSearch / WebFetch）。
    ///
    /// **默认开**。`-p` 是非交互的，需要确认的工具弹不出确认框会被直接拒掉，
    /// 模型只回一句「我没拿到权限」——「今天 4419 多少钱」这种问题于是永远
    /// 答不了，看起来像助手根本不能上网。这两个工具只读不写，和「跳过权限确认」
    /// 完全不是一个风险量级。
    public var allowWebTools: Bool
    /// `claudeCode` 专用：`--dangerously-skip-permissions`。
    ///
    /// **默认关**。语音是会误触的输入方式，而这个开关等于把「改文件、跑命令」
    /// 的确认全免掉；关着时 Claude 仍然能读能查能答，只是不动手。
    public var skipPermissions: Bool
    /// 后台打开（`open -g`），前台 App 保住键盘焦点。
    public var keepFocus: Bool
    /// 在终端当前窗口开一个**新标签页**而不是新窗口。走 osascript（第一次会弹
    /// 「自动化」权限），而开标签必须激活终端 —— 所以它与 `keepFocus` 互斥。
    public var openInNewTab: Bool
    /// 连续对话：第一次命中启动命令之后，后续命中只把口述文本粘进那个窗口 + 回车，
    /// 不再重新启动模板。没有撤销倒计时 —— 载荷是聊天内容，不是新的 shell 命令。
    public var continuousConversation: Bool

    public init(keyword: String = "", commandTemplate: String = "",
                runner: VoiceCommandRunner = .terminal,
                terminal: TerminalApp = .terminal, enabled: Bool = true,
                keywordPosition: KeywordPosition = .anywhere,
                workingDirectory: String = "", allowWebTools: Bool = true,
                skipPermissions: Bool = false,
                keepFocus: Bool = false, openInNewTab: Bool = false,
                continuousConversation: Bool = false) {
        self.keyword = keyword
        self.commandTemplate = commandTemplate
        self.runner = runner
        self.terminal = terminal
        self.enabled = enabled
        self.keywordPosition = keywordPosition
        self.workingDirectory = workingDirectory
        self.allowWebTools = allowWebTools
        self.skipPermissions = skipPermissions
        self.keepFocus = keepFocus
        self.openInNewTab = openInNewTab
        self.continuousConversation = continuousConversation
    }

    /// 内置示例：说「克劳德，帮我看看这段」→ 后台起一场 `claude -p`，
    /// 之后同一个关键词的每一句都 `--resume` 接回这场对话。
    ///
    /// 走 `claudeCode` 而不是开终端窗口：这才是「语音助手」该有的样子 ——
    /// 问一句答一句，不用每次都弹一个新窗口，上下文也不会每次从头开始。
    public static let defaultClaude = VoiceCommand(
        keyword: "克劳德",
        commandTemplate: "{text}\n\n{selection}",
        runner: .claudeCode,
        continuousConversation: true)

    /// 这条命令是不是能用。空关键词/空模板的行不该被扫到。
    public var isUsable: Bool {
        enabled
            && !keyword.trimmingCharacters(in: .whitespaces).isEmpty
            && !commandTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 展开成一行 shell。
    ///
    /// 替换值按**双引号 shell 上下文**转义（提示文案要求用户把占位符包在 `"` 里），
    /// 换行压成空格 —— 无论选中了什么、剪贴板里是什么，脚本正文都必须是单行。
    public func shellCommand(spoken: String, selection: String, clipboard: String) -> String {
        let s = Self.escapeForDoubleQuotes(spoken)
        let sel = Self.escapeForDoubleQuotes(selection)
        let clip = Self.escapeForDoubleQuotes(clipboard)
        return commandTemplate
            .replacingOccurrences(of: "{text}", with: s)
            .replacingOccurrences(of: "{selection}", with: sel)
            .replacingOccurrences(of: "{selected text}", with: sel)
            .replacingOccurrences(of: "{selected_text}", with: sel)
            .replacingOccurrences(of: "{clipboard}", with: clip)
    }

    /// 展开成一段**提示词**（`claudeCode` 走这条）。
    ///
    /// 与 `shellCommand` 的区别是**不做 shell 转义、也不压掉换行**：这段文字
    /// 是说给模型听的，引号和分行都是内容的一部分。真正进 shell 那一步的引号
    /// 由脚本组装时统一处理。
    ///
    /// 占位符落空时（比如什么都没选中）会留下一串空行，所以最后收一收。
    public func prompt(spoken: String, selection: String, clipboard: String) -> String {
        let expanded = commandTemplate
            .replacingOccurrences(of: "{text}", with: spoken)
            .replacingOccurrences(of: "{selection}", with: selection)
            .replacingOccurrences(of: "{selected text}", with: selection)
            .replacingOccurrences(of: "{selected_text}", with: selection)
            .replacingOccurrences(of: "{clipboard}", with: clipboard)
        // 三个以上连续换行压成两个（模板里的空行 + 落空的占位符会叠出来）。
        var collapsed = expanded
        while collapsed.contains("\n\n\n") {
            collapsed = collapsed.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        // 模板整个落空时（比如模板就是 `{selection}` 而什么都没选），
        // 回落到口述内容本身 —— 发一句空提示词只会浪费一轮。
        return trimmed.isEmpty ? spoken.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    /// `\ " $ \`` 前面加反斜杠；`\r` 删除；`\n` 变空格。
    ///
    /// ⚠️ 逐 **unicode scalar** 走，不是逐 `Character`。Swift 的 `Character` 是
    /// 字形簇，`"\r\n"` 会被当成**一个**字符 —— 按 Character 匹配时它既不等于
    /// `"\r"` 也不等于 `"\n"`，于是 Windows 换行原样落进脚本，把命令截成两行。
    public static func escapeForDoubleQuotes(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\", "\"", "$", "`":
                out.append("\\")
                out.unicodeScalars.append(scalar)
            case "\r":
                continue
            case "\n":
                out.append(" ")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - 容错解码

    private enum K: String, CodingKey {
        case keyword, commandTemplate, runner, terminal, enabled, keywordPosition
        case workingDirectory, allowWebTools, skipPermissions
        case keepFocus, openInNewTab, continuousConversation
    }

    /// 任一字段缺失/类型错只回落**那一个**字段（spec/10 A16）。
    /// 这些配置是用户一条条敲出来的，不能因为多了一个新字段就整表丢掉。
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: K.self) else { return }
        func f<T: Decodable>(_ key: K, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        keyword = f(.keyword, keyword)
        commandTemplate = f(.commandTemplate, commandTemplate)
        // 老配置没有 runner 这个键 —— 它们写的都是一行 shell，所以回落 terminal。
        runner = f(.runner, .terminal)
        workingDirectory = f(.workingDirectory, workingDirectory)
        allowWebTools = f(.allowWebTools, allowWebTools)
        skipPermissions = f(.skipPermissions, skipPermissions)
        terminal = f(.terminal, terminal)
        enabled = f(.enabled, enabled)
        keywordPosition = f(.keywordPosition, keywordPosition)
        keepFocus = f(.keepFocus, keepFocus)
        openInNewTab = f(.openInNewTab, openInNewTab)
        continuousConversation = f(.continuousConversation, continuousConversation)
    }
}
