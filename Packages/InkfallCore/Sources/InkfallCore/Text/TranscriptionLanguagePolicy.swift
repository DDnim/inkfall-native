import Foundation

/// 决定每一段转写请求带哪个语言码，以及一次会话里的语言怎么锁定。
///
/// 语言不是可有可无的参数。Whisper 在「自动检测」下对短句经常判错 ——
/// 一句两个字的中文被当成英文，输出就是一串音译垃圾。所以：
/// 固定模式直接给码；自动模式则用**第一段检测到的语言锁住整段会话**，
/// 后面的段不再各判各的。
public struct TranscriptionLanguagePolicy: Sendable, Equatable {

    public let mode: TranscriptionLanguageMode
    public let fixed: TranscriptionLanguage
    /// preferred 模式的候选表；空表等价于自动。
    public let preferred: [TranscriptionLanguage]

    public init(mode: TranscriptionLanguageMode,
                fixed: TranscriptionLanguage,
                preferred: [TranscriptionLanguage]) {
        self.mode = mode
        self.fixed = fixed
        self.preferred = preferred
    }

    public init(settings: AppSettings) {
        self.init(mode: settings.transcriptionLanguageMode,
                  fixed: settings.fixedTranscriptionLanguage,
                  preferred: settings.preferredTranscriptionLanguages)
    }

    /// 这一段要请求的语言码。
    ///
    /// - Parameters:
    ///   - override: 用户对这一段的显式指定（快速切换），优先级最高。
    ///   - locked: 本次会话已经锁定的语言（第一段的检测结果）。
    /// - Returns: ISO 639-1 码；`nil` 表示交给模型自动检测。
    public func requested(override: TranscriptionLanguage? = nil,
                          locked: TranscriptionLanguage? = nil) -> String? {
        if let override { return override.apiCode }
        switch mode {
        case .fixed:
            return fixed.apiCode
        case .auto, .preferred:
            // 锁定只对自动/偏好生效 —— 固定模式本来就每段都给同一个码。
            return locked?.apiCode
        }
    }

    /// 这一段的检测结果该不该用来锁定整段会话。
    ///
    /// 固定模式没有可锁的东西；preferred 模式只接受候选表里的语言 ——
    /// 一句噪声被判成越南语不该把整场会都锁到越南语上。
    public func shouldLock(detected: TranscriptionLanguage?, locked: TranscriptionLanguage?) -> Bool {
        guard locked == nil, let detected else { return false }
        switch mode {
        case .fixed: return false
        case .auto: return true
        case .preferred: return preferred.isEmpty || preferred.contains(detected)
        }
    }
}
