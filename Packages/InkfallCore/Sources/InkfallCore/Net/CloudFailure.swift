import Foundation

/// 一次云端调用失败的粗分类 —— 粗到足以驱动降级决策，细到不会让
/// 鉴权/配额问题被一次静默的本地重试掩盖掉。
public enum CloudFailureKind: Sendable, Equatable {
    /// 传输层失败：无网络、DNS/TLS 错、拒连、超时。云端不可达。
    case network
    /// 服务端 5xx —— 能连上，但是坏的。
    case serverError
    /// 401/403：账号或凭据本身有问题。
    case auth
    /// 402：会员额度用尽。
    case quota
    /// 其他非成功状态（如 400），或解不出来的响应。
    case other

    /// 只有网络中断和服务端故障才降级：云端做不了这活儿，本地模型顶上。
    /// 鉴权 / 配额 / 其他**刻意不合格** —— 静默的本地重试会掩盖一个
    /// 用户必须处理的问题。
    public var isFallbackEligible: Bool {
        self == .network || self == .serverError
    }

    public static func classify(status: Int) -> CloudFailureKind {
        switch status {
        case 500...599: return .serverError
        case 401, 403: return .auth
        case 402: return .quota
        default: return .other
        }
    }

    /// 任何传输层的发送/读取错误都意味着云端不可达，具体原因（超时、连接、
    /// DNS…）不影响降级决策。
    public static let sendError: CloudFailureKind = .network
}

public enum FallbackPolicy {
    /// 转写失败要不要降级到本地模型。
    /// 除了失败类型合格，还要求用户没关掉自动降级、且本地模型确实可用。
    public static func shouldFallbackTranscription(
        autoLocalFallbackEnabled: Bool,
        kind: CloudFailureKind,
        localModelReady: Bool
    ) -> Bool {
        autoLocalFallbackEnabled && kind.isFallbackEligible && localModelReady
    }

    /// 加工失败要不要降级到本地 basic 润色。
    /// basic 是纯规则、全本地，所以**不需要**任何已下载的模型。
    public static func shouldFallbackPostProcessing(
        autoLocalFallbackEnabled: Bool,
        kind: CloudFailureKind
    ) -> Bool {
        autoLocalFallbackEnabled && kind.isFallbackEligible
    }
}
