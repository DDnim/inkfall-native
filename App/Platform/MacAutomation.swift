import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
        Thread.sleep(forTimeInterval: 0.140)

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

    enum InsertRoute: String {
        /// 目标已经在前台：写剪贴板 + ⌘V，零激活。
        case pasteInPlace
        /// AX 直接写 AXSelectedText，真·零焦点。很多 App 不支持。
        case accessibility
        /// 回落：切过去、粘、再切回来。会闪一下焦点。
        case activateAndPaste
        case clipboardOnly
    }

    /// 三层插入。越靠前越不打扰用户。
    @discardableResult
    static func insert(_ text: String, into target: PasteTarget?) -> InsertRoute {
        guard !text.isEmpty else { return .clipboardOnly }
        guard let target else {
            setPasteboard(text)
            return .clipboardOnly
        }

        // A：目标已经在前台 —— 直接粘，焦点一点都不动。
        if target.isFrontmost {
            pasteInPlace(text)
            return .pasteInPlace
        }

        // B1：AX 写选中文本。成功的话焦点完全没动过。
        if writeViaAccessibility(text, target: target) { return .accessibility }

        // B2：切过去粘完再切回来。
        let previousPID = frontmostPID()
        // 钉了具体窗口就先抬它，避免粘到同 App 的另一个窗口。
        if let window = target.window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Thread.sleep(forTimeInterval: 0.080)
        }
        setPasteboard(text)
        activate(target)
        Thread.sleep(forTimeInterval: 0.120)
        sendKey(keyV, command: true)
        Thread.sleep(forTimeInterval: 0.300)
        if let previousPID, previousPID != target.processID {
            NSRunningApplication(processIdentifier: previousPID)?.activate()
            Thread.sleep(forTimeInterval: 0.060)
        }
        return .activateAndPaste
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

    private static func pasteInPlace(_ text: String) {
        setPasteboard(text)
        sendKey(keyV, command: true)
        // ⚠️ 还原剪贴板必须等目标 App 读完 pasteboard，否则粘出来的是旧内容。
        Thread.sleep(forTimeInterval: 0.300)
    }

    private static func setPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func activate(_ target: PasteTarget) {
        NSRunningApplication(processIdentifier: target.processID)?.activate()
    }

    // MARK: - AX

    /// 往焦点元素的 `AXSelectedText` 里写 —— 等价于「替换选中内容」，
    /// 没有选中时就是在光标处插入。
    private static func writeViaAccessibility(_ text: String, target: PasteTarget) -> Bool {
        guard let element = focusedElement(pid: target.processID) else { return false }
        // 先确认这个元素真的可写，再动手；不做探测的话很多只读控件会静默吞掉写入。
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value else { return nil }
        // CFTypeRef → AXUIElement 只能靠运行时类型判定，没有编译期保证。
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
