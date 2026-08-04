import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import InkfallCore

/// 粘贴目标：录音**开始那一刻**的前台 App 与焦点窗口。
///
/// ⚠️ 必须在起录时就抓好。转写要几百毫秒到几秒，等结果回来时用户很可能已经
/// 切走了 —— 那时候再看「前台是谁」，文字就粘到别人窗口里去了。
/// `AXUIElement` 是 CF 类型，跨线程传引用是安全的；插入路径全程阻塞式，
/// 必须能丢到后台队列上跑（见 `frontmostPID` 的注释）。
struct PasteTarget: @unchecked Sendable {
    let bundleID: String?
    let processID: pid_t
    let appName: String
    /// 具体那一个窗口的 AX 引用。跨窗口插入时用来 raise 正确的窗口，
    /// 而不是把 App 的随便哪个窗口拽到前面。
    let window: AXUIElement?

    static func current() -> PasteTarget? {
        guard let pid = MacAutomation.frontmostPID(),
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return PasteTarget(
            bundleID: app.bundleIdentifier,
            processID: pid,
            appName: app.localizedName ?? "?",
            window: MacAutomation.focusedWindow(pid: pid))
    }

    var isFrontmost: Bool { MacAutomation.frontmostPID() == processID }

    /// 目标进程还活着吗。
    ///
    /// ⚠️ 转写要几百毫秒到几秒，这段时间里目标 App 完全可能已经退出。
    /// 死进程 `activate` 是空操作，紧接着那一下 ⌘V 会打进**当时恰好在前台**的
    /// 别人窗口 —— 用户的口述凭空出现在一个无关的输入框里。
    var isRunning: Bool {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return false }
        return !app.isTerminated
    }

    /// 抓到的那个窗口，现在还是这个 App 的焦点窗口吗。
    ///
    /// AX 写入写的是 App 的**焦点元素**，不认我们抓的是哪个窗口。用户在同一个
    /// App 里换过窗口的话，这一路会把文字送进另一个窗口，所以得先对一下身份。
    /// 没抓到窗口引用时放行 —— 那本来就退化成 App 级目标了。
    var allowsAccessibilityInsert: Bool {
        guard let window else { return true }
        guard let focused = MacAutomation.focusedWindow(pid: processID) else { return false }
        return CFEqual(focused, window)
    }

    /// 交给 InkfallCore 做决策用的快照。三个探测各要一次跨进程 AX/NSWorkspace
    /// 调用，所以一次性取齐，避免决策过程中状态自己变了。
    var state: PasteTargetState {
        let running = isRunning
        return PasteTargetState(
            isRunning: running,
            isFrontmost: running && isFrontmost,
            // 只在真要用到时才问 —— 目标已在前台时这一路根本不会走。
            allowsAccessibilityInsert: running && allowsAccessibilityInsert)
    }
}

/// 一次插入调用的可选行为。默认值 = 听写与落笔的常规插入。
struct PasteOptions {
    /// 用户的自动粘贴总开关。关着时只复制，一个按键都不合成。
    var autoPasteEnabled = true
    /// 末尾补一个换行（`pasteAppendNewline`）。
    var appendNewline = false

    init(autoPasteEnabled: Bool = true, appendNewline: Bool = false) {
        self.autoPasteEnabled = autoPasteEnabled
        self.appendNewline = appendNewline
    }

    /// 从设置里取这两个开关。
    init(settings: AppSettings) {
        self.init(autoPasteEnabled: settings.autoPasteEnabled,
                  appendNewline: settings.pasteAppendNewline)
    }
}

/// 一次插入的结果。`outcome` 是给用户看的那一层，`route` 是给日志看的。
struct PasteResult {
    /// 真正跑成的那条路。`nil` = 一条都没成。
    let route: PasteRoute?
    let outcome: PasteOutcome

    /// 文字真的进目标了吗（决定要不要打 `pasted` 标记）。
    var landedInTarget: Bool { outcome.landedInTarget }
}

enum MacAutomation {

    // MARK: - 键盘事件合成

    private static let keyC: CGKeyCode = 8
    private static let keyV: CGKeyCode = 9
    /// 连续对话粘完要敲的那一下回车。
    static let keyReturn: CGKeyCode = 36

    static func sendKey(_ keycode: CGKeyCode, command: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = command ? .maskCommand : []
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keycode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 抓选区

    /// 用 ⌘C 偷一份当前选区，然后**无条件**把剪贴板还原。
    ///
    /// 起录时并发做。判据是 `changeCount` 真的变了 —— 只看内容非空会把
    /// 「没有选区、剪贴板里恰好有旧文字」误判成选区。
    static func captureSelection() -> String? {
        let pasteboard = NSPasteboard.general
        let old = pasteboard.string(forType: .string)
        let oldCount = pasteboard.changeCount

        sendKey(keyC, command: true)
        Thread.sleep(forTimeInterval: PasteTiming.selectionCaptureSeconds)

        let changed = pasteboard.changeCount != oldCount
        let new = pasteboard.string(forType: .string)

        // 不管抓没抓到，用户的剪贴板都必须原样还回去。
        if changed, let old {
            pasteboard.clearContents()
            pasteboard.setString(old, forType: .string)
        }

        guard changed, let new else { return nil }
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 剪贴板

    /// 当前剪贴板文本。语音命令模板里的 `{clipboard}` 用它。
    static func clipboardText() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    /// 明确地把文字放上剪贴板（**不**还原）。
    /// 命令执行失败时用它 —— 刘海是 click-through 的，没有按钮可点，
    /// 那条没跑成的命令只能这样交回给用户。
    static func copyToClipboard(_ text: String) {
        setPasteboard(text)
    }

    // MARK: - 插入

    /// 自动粘贴。三层路线，越靠前越不打扰用户；走哪条由 `InkfallCore.AutoPaste`
    /// 决定（纯逻辑，有单测），这里只负责执行和探测。
    ///
    /// ⚠️ 全程阻塞（一连串 `Thread.sleep`），**必须**在后台队列上调用。
    /// 而且同一时间只能有一次在跑：并发插入会把剪贴板的存/还原搅成一团。
    @discardableResult
    static func insert(_ text: String, into target: PasteTarget?,
                       options: PasteOptions = PasteOptions()) -> PasteResult {
        let payload = AutoPaste.compose(text, appendNewline: options.appendNewline)
        let plan = AutoPaste.plan(text: payload,
                                  autoPasteEnabled: options.autoPasteEnabled,
                                  // AX 授权当场问，不用缓存的值 ——
                                  // 用户完全可能刚在系统设置里把它打开或关掉。
                                  accessibilityTrusted: AXIsProcessTrusted(),
                                  target: target?.state)

        for route in plan.attempts {
            switch route {
            case .clipboardOnly:
                // 唯一**不还原**剪贴板的一条：把文字留在那儿就是它的全部意义。
                setPasteboard(payload)
                return PasteResult(route: route, outcome: plan.outcome(after: route))
            case .pasteInPlace:
                pasteInPlace(payload)
                return PasteResult(route: route, outcome: plan.outcome(after: route))
            case .accessibility:
                guard let target, writeViaAccessibility(payload, target: target) else { continue }
                return PasteResult(route: route, outcome: plan.outcome(after: route))
            case .activateAndPaste:
                guard let target else { continue }
                activateAndPaste(payload, target: target)
                return PasteResult(route: route, outcome: plan.outcome(after: route))
            }
        }
        // 该试的都试完了还是没成：文字仍然要留在剪贴板上，否则这一段就丢了。
        if !plan.attempts.isEmpty { setPasteboard(payload) }
        return PasteResult(route: nil, outcome: plan.outcome(after: nil))
    }

    /// 当前前台 App 的 pid。
    ///
    /// ⚠️ **不能用 `NSWorkspace.frontmostApplication`**：它靠主线程 run loop 上的
    /// 通知更新，而插入路径里全是 `Thread.sleep` —— 主线程一被堵住，它就停在
    /// 切换之前的旧值上，于是跨 App 插入会被误判成「目标已在前台」，
    /// ⌘V 打到别人窗口里去。AX 是直接问系统，永远是当下的真相。
    static func frontmostPID() -> pid_t? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    /// A：目标已在前台，⌘V 直接落进去，焦点一点都不动。
    private static func pasteInPlace(_ text: String) {
        let saved = savedClipboard()
        setPasteboard(text)
        sendKey(keyV, command: true)
        restoreClipboard(saved)
    }

    /// B2：切过去、粘、再切回来。会闪一下焦点，是最后的回落。
    private static func activateAndPaste(_ text: String, target: PasteTarget) {
        let previousPID = frontmostPID()
        // 先把目标那**一个**窗口抬起来，否则粘的可能是同 App 的另一个窗口。
        // ⚠️ 经 `raise(window:pid:)` 走 —— 自家窗口时这一步必须回主线程，
        // 否则 AppKit 直接 trap（见 `onMainIfSelf`）。
        if let window = target.window {
            raise(window: window, pid: target.processID)
            Thread.sleep(forTimeInterval: PasteTiming.raiseWindowSeconds)
        }
        let saved = savedClipboard()
        setPasteboard(text)
        activate(target)
        Thread.sleep(forTimeInterval: PasteTiming.activateBeforePasteSeconds)
        sendKey(keyV, command: true)
        // ⚠️ 还原前的 debounce 必须先等掉，再把焦点还回去 —— 顺序反了的话，
        // 前一个 App 拿到焦点时剪贴板里还是我们塞进去的文字。
        Thread.sleep(forTimeInterval: PasteTiming.clipboardRestoreSeconds)
        if let previousPID, previousPID != target.processID {
            NSRunningApplication(processIdentifier: previousPID)?.activate()
            Thread.sleep(forTimeInterval: PasteTiming.refocusPreviousSeconds)
        }
        restoreClipboard(saved, alreadyWaited: true)
    }

    // MARK: - 剪贴板卫生（不变量 A20）

    /// ⌘V 前先把用户的剪贴板存下来。
    ///
    /// 存的是**字符串**而不是整块 pasteboard：图片/富文本还原不了是已知取舍
    /// （Tauri 版同样如此），但绝不能因为我们粘了一次，用户的文字剪贴板就没了。
    private static func savedClipboard() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// ⚠️ 还原必须 debounce 300 ms —— 目标 App 是**异步**读 pasteboard 的，
    /// 早还原一步，它读到的就是用户的旧内容，粘出来的文字整个不对。
    private static func restoreClipboard(_ saved: String?, alreadyWaited: Bool = false) {
        if !alreadyWaited { Thread.sleep(forTimeInterval: PasteTiming.clipboardRestoreSeconds) }
        guard let saved else { return }
        setPasteboard(saved)
    }

    private static func setPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 自家进程也走 `onMainIfSelf`：`activate()` 对自己等价于
    /// `NSApp.activate`，同样是主线程才该碰的东西。
    private static func activate(_ target: PasteTarget) {
        onMainIfSelf(target.processID) {
            NSRunningApplication(processIdentifier: target.processID)?.activate()
        }
    }

    // MARK: - AX

    /// 目标是**我们自己**的进程。
    ///
    /// 起录那一刻前台是落笔面板或设置窗时就会这样 —— 面板开着说一段、
    /// 逐段自动粘贴打开，这是条日常路径，不是边角情况。
    static func targetsThisProcess(_ pid: pid_t) -> Bool { pid == getpid() }

    /// 目标是自家进程时把这一步搬回主线程。
    ///
    /// ⚠️ 这是一次真实崩溃换来的（2026-08-04 10:04:34，`Inkfall-…-100434.ips`）：
    /// AX 对**跨进程**目标是消息传递，后台线程调完全安全；但目标在**本进程**时
    /// 请求会被**就地派发** —— `kAXRaiseAction` 于是变成在调用线程上跑
    /// `-[NSWindow makeKeyAndOrderFront:]`，而整条插入路径都在后台队列上
    /// （全是 `Thread.sleep`，不能占主线程），AppKit 当场 trap：
    /// `Must only be used from the main thread`，整个 App 挂掉。
    ///
    /// 放在最底层的几个 AX 助手里而不是各个调用点：这样以后新加的 AX 调用
    /// 自动被覆盖，不必每次都记得判一下自家进程。
    private static func onMainIfSelf<T>(_ pid: pid_t, _ work: () -> T) -> T {
        guard targetsThisProcess(pid), !Thread.isMainThread else { return work() }
        // 主线程从不同步等待粘贴队列，所以这里不会死锁。
        return DispatchQueue.main.sync(execute: work)
    }

    /// 把目标那**一个**窗口抬到前面。
    static func raise(window: AXUIElement, pid: pid_t) {
        onMainIfSelf(pid) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    }

    /// 往焦点元素的 `AXSelectedText` 里写 —— 等价于「替换选中内容」，
    /// 没有选中时就是在光标处插入。
    private static func writeViaAccessibility(_ text: String, target: PasteTarget) -> Bool {
        guard let element = focusedElement(pid: target.processID) else { return false }
        return onMainIfSelf(target.processID) {
            // 先确认这个元素真的可写，再动手；不做探测的话很多只读控件会静默吞掉写入。
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(
                element, kAXSelectedTextAttribute as CFString, &settable) == .success,
                settable.boolValue else { return false }
            return AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
        }
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        onMainIfSelf(pid) {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value else { return nil }
            // CFTypeRef → AXUIElement 只能靠运行时类型判定，没有编译期保证。
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        onMainIfSelf(pid) {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }
}
