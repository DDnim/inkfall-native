import ApplicationServices
import CoreGraphics
import Foundation
import InkfallCore

/// 全局热键监听：CGEventTap 管道。
///
/// 判定逻辑全在 `InkfallCore.HotkeyMatcher` 里（合成事件可测）；这里只负责
/// 三件难搞的系统事：**专用线程**、**被禁用后的恢复**、**吞噬**。
///
/// ⚠️ **不能挂主 run loop。** tap 回调有硬性超时，主线程一被 SwiftUI 布局或
/// 磁盘 I/O 卡住，macOS 就直接把 tap 禁掉 —— 症状是热键毫无征兆地整体失灵。
/// 所以它跑在自己的 `app.inkfall.hotkey-tap` 线程上，回调里只做匹配，
/// 真正的动作 async 回主线程。
final class HotkeyMonitor: @unchecked Sendable {

    /// tap 被禁用的两条恢复路径缺一不可：
    /// 通知路径立刻恢复（毫秒级），看门狗兜住那些**根本没发通知**的禁用。
    private static let watchdogInterval: TimeInterval = 3

    private let lock = NSLock()
    private var matcher: HotkeyMatcher
    private let handler: @Sendable ([HotkeyEvent]) -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var watchdog: DispatchSourceTimer?
    private var stopping = false

    /// 诊断计数：tap 被禁用后恢复了多少次，分别由谁救回来的。
    private(set) var recoveriesByNotification = 0
    private(set) var recoveriesByWatchdog = 0

    init(shortcuts: ShortcutsConfig, handler: @escaping @Sendable ([HotkeyEvent]) -> Void) {
        self.matcher = HotkeyMatcher(shortcuts: shortcuts)
        self.matcher.systemStateVerify = true
        self.handler = handler
    }

    // MARK: - 生命周期

    /// - Returns: tap 是否建起来了。没有辅助功能授权时必然失败。
    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return tap != nil }
        guard AXIsProcessTrusted() else {
            Log.write("hotkey: 未授权辅助功能，不建 tap")
            return false
        }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in self?.runTapLoop(ready: ready) }
        thread.name = "app.inkfall.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()

        // 等线程真的把 tap 建起来再回报成败 —— 否则调用方拿到的是「还没试过」。
        _ = ready.wait(timeout: .now() + 2)
        let created = lock.withLock { tap != nil }
        if created { startWatchdog() } else { self.thread = nil }
        return created
    }

    func stop() {
        lock.withLock { stopping = true }
        watchdog?.cancel()
        watchdog = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        // 禁用期间到达的 key-up 根本没看见，残留状态不可信。
        lock.withLock { matcher.resetMatches() }
    }

    /// 换绑快捷键。同样清空按键状态：改绑那一瞬间的 key-up 属于旧配置。
    func update(shortcuts: ShortcutsConfig) {
        lock.withLock { matcher.shortcuts = shortcuts }
    }

    var jarvisCountdown: Bool {
        get { lock.withLock { matcher.jarvisCountdown } }
        set { lock.withLock { matcher.jarvisCountdown = newValue } }
    }

    var noteTogglesActive: Bool {
        get { lock.withLock { matcher.noteTogglesActive } }
        set { lock.withLock { matcher.noteTogglesActive = newValue } }
    }

    var isEnabled: Bool {
        guard let tap = lock.withLock({ tap }) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: - tap 线程

    private func runTapLoop(ready: DispatchSemaphore) {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // defaultTap = 可以吞事件；listenOnly 不行
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.write("hotkey: tapCreate 失败（辅助功能授权可能刚被撤销）")
            ready.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.withLock {
            self.tap = tap
            self.source = source
            self.runLoop = CFRunLoopGetCurrent()
        }
        Log.write("hotkey: tap 已启用（线程 app.inkfall.hotkey-tap）")
        ready.signal()

        // 定期返回，好让 stop() 的 CFRunLoopStop 之外还有一条退出路径。
        while !lock.withLock({ stopping }) {
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }

        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        lock.withLock {
            self.tap = nil
            self.source = nil
            self.runLoop = nil
        }
        Log.write("hotkey: tap 已停止")
    }

    /// 在 tap 线程上跑。**必须快** —— 超时会让 macOS 直接禁掉 tap。
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // 恢复路径一：macOS 发一个一次性伪事件通知你 tap 被禁了。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoveriesByNotification += 1
            let reason = type == .tapDisabledByTimeout ? "超时" : "用户输入"
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.withLock { matcher.resetMatches() }
            Log.write("hotkey: tap 被禁用（\(reason)），已重新启用并复位按键状态")
            return false
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let now = CFAbsoluteTimeGetCurrent()

        let result = lock.withLock {
            matcher.handle(type: UInt32(type.rawValue), keycode: keycode,
                           flags: flags, now: now)
        }

        if !result.events.isEmpty {
            let events = result.events
            let handler = self.handler
            // 绝不在 tap 线程上做实际动作：录音启停、窗口显示都可能阻塞，
            // 一阻塞就是整套热键被系统禁掉。
            DispatchQueue.main.async { handler(events) }
        }
        return result.suppress
    }

    // MARK: - 看门狗

    /// 恢复路径二：3 秒轮询。tap 有时被禁用得**不发任何通知**，
    /// 只靠通知路径的话热键会一直死到重启 App。
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "app.inkfall.hotkey-watchdog", qos: .utility))
        timer.schedule(deadline: .now() + Self.watchdogInterval,
                       repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let tap = self.lock.withLock({ self.tap }) else { return }
            guard !CGEvent.tapIsEnabled(tap: tap) else { return }
            self.recoveriesByWatchdog += 1
            CGEvent.tapEnable(tap: tap, enable: true)
            self.lock.withLock { self.matcher.resetMatches() }
            Log.write("hotkey: 看门狗发现 tap 已禁用（无通知），已重新启用")
        }
        timer.resume()
        watchdog = timer
    }
}

/// C 回调。`refcon` 里是未持有的 `HotkeyMonitor`，其生命周期由 App 委托保证。
private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // 返回 nil = 吞掉，事件不会到达前台 App。
    return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
