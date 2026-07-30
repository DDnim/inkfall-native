import AppKit
import Foundation
import InkfallCore

/// 在终端里跑一行 shell。
///
/// **刻意不用 Apple Events**（spec/01 §7.4）：命令写进一个 `0700` 的临时
/// `.command` 脚本，再交给 `/usr/bin/open`。这条路不需要「自动化」权限，
/// 也不需要终端预先在跑。只有「新标签页」那一种模式绕不开 osascript。
enum TerminalLauncher {

    enum Failure: LocalizedError {
        case writeScript(String)
        case open(String)
        case newTabUnsupported

        var errorDescription: String? {
            switch self {
            case .writeScript(let detail): return "写命令脚本失败：\(detail)"
            case .open(let detail): return "打开终端失败：\(detail)"
            case .newTabUnsupported: return "Ghostty 没有开新标签页的脚本接口"
            }
        }
    }

    /// 焦点归还的两个时刻。冷启动的终端会在第一次归还之后**又抢一次**，
    /// 所以必须还两遍（spec/01 §7.4）。
    private static let focusRestoreDelays: [Double] = [0.6, 1.6]

    /// - Parameters:
    ///   - keepFocus: 后台打开（`open -g`），前台 App 保住键盘焦点。
    ///   - newTab: 在终端当前窗口开新标签页（走 osascript）。与 `keepFocus` 互斥。
    static func run(_ shellCommand: String, in terminal: TerminalApp,
                    keepFocus: Bool, newTab: Bool) throws {
        let previousFront = MacAutomation.frontmostPID()

        // 终端开在哪个目录是不确定的，所以锚在 $HOME；需要进项目目录的模板
        // 自己 `cd`。
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkfall-voice-command-\(stamp).command")
        let script = "#!/bin/zsh\ncd \"$HOME\"\n\(shellCommand)\n"
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: path.path)
        } catch {
            throw Failure.writeScript("\(error)")
        }

        // 开标签必须激活终端，所以 keepFocus 在这条路上不可能成立；
        // 焦点靠下面的归还来补。
        let useNewTab = newTab && terminal.supportsNewTab
        let keepFocus = keepFocus && !useNewTab

        if useNewTab {
            try openInNewTab(terminal, script: path)
        } else {
            try openScript(terminal, script: path, background: keepFocus)
        }

        // `-g` 是后台打开，本来就没抢焦点，不需要还。
        guard !keepFocus, let previousFront else { return }
        for delay in focusRestoreDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSRunningApplication(processIdentifier: previousFront)?.activate()
            }
        }
    }

    private static func openScript(_ terminal: TerminalApp, script: URL,
                                   background: Bool) throws {
        var arguments: [String] = []
        if background { arguments.append("-g") }
        switch terminal {
        case .terminal, .iterm:
            arguments += ["-b", terminal.bundleID, script.path]
        case .ghostty:
            // Ghostty 不认 `.command` 文档；`-n` 强制新实例，否则 `--args -e`
            // 会被已经在跑的那个实例忽略掉。
            arguments += ["-nb", terminal.bundleID, "--args", "-e", script.path]
        }
        let (status, stderr) = shell("/usr/bin/open", arguments)
        guard status == 0 else { throw Failure.open(stderr) }
    }

    /// 新标签页。第一次用会弹 macOS 的「自动化」权限
    /// （「Inkfall 想控制终端」；Terminal 开标签还要 System Events）。
    /// 脚本路径来自 `temp_dir()` + 我们自己的文件名，不会含引号。
    private static func openInNewTab(_ terminal: TerminalApp, script: URL) throws {
        let line = "zsh '\(script.path)'"
        let applescript: String
        switch terminal {
        case .terminal:
            applescript = """
            tell application "Terminal" to activate
            tell application "System Events" to tell process "Terminal" to keystroke "t" using command down
            delay 0.4
            tell application "Terminal" to do script "\(line)" in selected tab of front window
            """
        case .iterm:
            applescript = """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile
                    tell current session of current window to write text "\(line)"
                else
                    tell current window
                        create tab with default profile
                        tell current session to write text "\(line)"
                    end tell
                end if
            end tell
            """
        case .ghostty:
            throw Failure.newTabUnsupported
        }
        let (status, stderr) = shell("/usr/bin/osascript", ["-e", applescript])
        guard status == 0 else { throw Failure.open(stderr) }
    }

    private static func shell(_ executable: String, _ arguments: [String])
        -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    /// 连续对话要靠它判断「那个窗口还在不在」——退了就该重新起一条命令，
    /// 而不是把话粘给一个已经不存在的进程。
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// 把某个 App 当成粘贴目标。连续对话往它的窗口里粘。
    static func target(bundleID: String) -> PasteTarget? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let pid = app.processIdentifier
        return PasteTarget(bundleID: bundleID, processID: pid,
                           appName: app.localizedName ?? bundleID,
                           window: MacAutomation.focusedWindow(pid: pid))
    }
}
