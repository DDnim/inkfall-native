import SwiftUI
import InkfallCore

/// 首启引导。三步：欢迎 → 权限 → 完成。
///
/// **权限那一步卡住「下一步」**，辅助功能与麦克风都拿到才放行 ——
/// 这两个没有，产品的核心动作（热键 + 粘贴 + 录音）一个都做不了，
/// 与其让用户走完引导再发现是坏的，不如在这里挡住。
struct OnboardingView: View {

    enum Step: Int, CaseIterable {
        case welcome, permissions, done

        var title: String {
            switch self {
            case .welcome: return "落音 Inkfall"
            case .permissions: return "三个权限"
            case .done: return "可以开始了"
            }
        }
    }

    @State private var step: Step = .welcome
    let permissions: PermissionCoordinator
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Ink.hair)

            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissionList
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 22)

            footer
        }
        .background(Ink.paper1)
        .frame(width: 620, height: 560)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    // MARK: -

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Ink.cinnabar)
            Text(step.title)
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(Ink.ink1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 18)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按住右 ⌥ 说话，松手，文字就落在光标处。")
                .font(.system(size: 15))
                .foregroundStyle(Ink.ink1)
            Text("所有状态都画在刘海里 —— 那块黑色胶囊就是这个产品本身。")
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.ink3)

            capsulePreview.padding(.vertical, 10)

            Text("这是原生 Swift 重写版。下一步要先把三个系统权限交代清楚 —— 没有它们，热键和粘贴都无法工作。")
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一个静态的刘海胶囊示意，让用户在授权之前就认识这个形状。
    private var capsulePreview: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.23)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 96)
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(Ink.inkBlock)
                .frame(width: 272, height: 78)
                .overlay(alignment: .top) {
                    HStack {
                        Circle().fill(Ink.cinnabar).frame(width: 9, height: 9)
                        Spacer()
                        Text("00:14")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Ink.paperOnInk.opacity(0.7))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                }
                .overlay(alignment: .bottom) {
                    Text("润色 · 正在录音")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.paperOnInk)
                        .padding(.bottom, 14)
                }
        }
    }

    private var permissionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("授权后回到这里，状态会自己变绿（每 2 秒检查一次）。")
                .font(.system(size: 12))
                .foregroundStyle(Ink.ink3)
                .padding(.bottom, 4)

            ForEach(Permission.allCases, id: \.self) { permission in
                PermissionRow(permission: permission,
                              granted: permissions.isGranted(permission),
                              onGrant: { permissions.request(permission) },
                              onOpenSettings: { permissions.openSettings(permission) })
            }

            if !permissions.requiredSatisfied {
                Label("辅助功能与麦克风是必需的，授权后才能继续。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.amber)
                    .padding(.top, 6)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("权限已就绪", systemImage: "checkmark.seal.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.teal)

            Text("落音会常驻菜单栏，没有 Dock 图标。从菜单栏图标可以打开笔记与设置。")
                .font(.system(size: 12.5))
                .foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                shortcutRow("按住 右⌥", "说话，松手粘贴")
                shortcutRow("⌥Space", "落笔 —— 连续录音进笔记面板")
                shortcutRow("⌥[", "快速粘贴最近的笔记")
                shortcutRow("⌥Esc", "取消录音 / 收起面板")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.paper3, in: RoundedRectangle(cornerRadius: Ink.rMD))
            .overlay(RoundedRectangle(cornerRadius: Ink.rMD).stroke(Ink.hair))

            Text("这一版是重写的骨架：权限、菜单栏与设计 token 已就位，录音与转写还没接上。")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.ink4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Ink.ink1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Ink.paper4, in: RoundedRectangle(cornerRadius: Ink.rSM))
                .overlay(RoundedRectangle(cornerRadius: Ink.rSM).stroke(Ink.hair))
                .frame(width: 92, alignment: .leading)
            Text(desc).font(.system(size: 12)).foregroundStyle(Ink.ink2)
        }
    }

    private var footer: some View {
        HStack {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? Ink.cinnabar : Ink.ink4.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
            Spacer()
            if step != .welcome {
                Button("上一步") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.ink3)
                    .padding(.trailing, 6)
            }
            Button(step == .done ? "开始使用" : "下一步") {
                if step == .done {
                    onFinish()
                } else {
                    step = Step(rawValue: step.rawValue + 1) ?? .done
                }
            }
            .keyboardShortcut(.defaultAction)
            // 权限没齐就不放行 —— 走完引导才发现是坏的，比在这里被挡住更糟。
            .disabled(step == .permissions && !permissions.requiredSatisfied)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(Ink.paper0)
        .overlay(alignment: .top) { Divider().overlay(Ink.hair) }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15))
                .foregroundStyle(granted ? Ink.teal : Ink.ink4)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.ink1)
                    if !permission.isRequired {
                        Text("可选")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Ink.ink3)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Ink.hair, in: Capsule())
                    }
                }
                Text(permission.why)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Text("已授权")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ink.teal)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("授权", action: onGrant)
                    Button("打开设置", action: onOpenSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.ink3)
                }
            }
        }
        .padding(13)
        .background(Ink.paper3, in: RoundedRectangle(cornerRadius: Ink.rMD))
        .overlay(RoundedRectangle(cornerRadius: Ink.rMD)
            .stroke(granted ? Ink.teal.opacity(0.35) : Ink.hair))
    }
}
