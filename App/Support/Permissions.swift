import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// 三个 TCC 权限的检测、请求与设置面板跳转。
///
/// ⚠️ 两条与签名相关的硬约束（见 inkfall-docs/spec/10 A17）：
/// 1. 必须带 entitlement `com.apple.security.device.audio-input`，否则签名版的
///    麦克风访问会被**直接拒绝且不弹 TCC 提示** —— 看起来像录音器坏了。
/// 2. 签名身份必须稳定。ad-hoc 签名每次构建 CDHash 都变，辅助功能授权会随之失效。
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case microphone
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .microphone: return "麦克风"
        case .screenRecording: return "屏幕录制"
        }
    }

    public var why: String {
        switch self {
        case .accessibility:
            return "监听全局快捷键，并把转写结果粘贴到你正在用的窗口。没有它，热键和粘贴都无法工作。"
        case .microphone:
            return "录制你说的话。音频只在转写时离开这台机器。"
        case .screenRecording:
            return "截图并嵌进笔记。可选 —— 不开启也不影响听写。"
        }
    }

    /// 必需项没拿到就不该放用户往下走。屏幕录制是可选的。
    public var isRequired: Bool { self != .screenRecording }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

@MainActor
@Observable
public final class PermissionCoordinator {

    public private(set) var granted: [Permission: Bool] = [:]

    private var pollTimer: Timer?

    public init() {
        refresh()
    }

    public func isGranted(_ p: Permission) -> Bool { granted[p] ?? false }

    /// 必需的两项都拿到了吗 —— 引导的「下一步」以此为门禁。
    public var requiredSatisfied: Bool {
        Permission.allCases.filter(\.isRequired).allSatisfy(isGranted)
    }

    public func refresh() {
        granted = [
            .accessibility: AXIsProcessTrusted(),
            .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            .screenRecording: CGPreflightScreenCaptureAccess(),
        ]
    }

    /// 请求授权。辅助功能与屏幕录制只能「提示 + 打开设置面板」，
    /// 麦克风可以走系统弹窗。
    public func request(_ p: Permission) {
        switch p {
        case .accessibility:
            // 带 prompt 的检查会让系统弹出「打开系统设置」的提示，
            // 同时把本 App 登记进辅助功能列表里。
            // 用字符串字面量而不是 kAXTrustedCheckOptionPrompt：那是个 C 全局 var，
            // Swift 6 的严格并发不让跨隔离域引用。键名本身是稳定的公开常量。
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openSettings(p)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .screenRecording:
            // 从没授权过时，这一步会让 App 出现在「屏幕录制」列表里，
            // 系统才可能弹窗。
            CGRequestScreenCaptureAccess()
            openSettings(p)
        }
    }

    public func openSettings(_ p: Permission) {
        NSWorkspace.shared.open(p.settingsURL)
    }

    /// 用户是去系统设置里授权的，回来时没有任何通知 —— 只能轮询。
    /// 与现有实现同频：每 2 秒一次。
    public func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
