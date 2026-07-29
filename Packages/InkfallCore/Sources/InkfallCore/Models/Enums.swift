import Foundation

// MARK: - 转写模式

public enum TranscriptionMode: String, Codable, Sendable, CaseIterable {
    case openai, groq, gemini, local
    /// 落音云：服务端持 Groq key，客户端只带会话令牌。
    case groqProxy

    /// 自测时对应的云供应商；local 与 groqProxy 没有客户端 key 可测。
    public var cloudProviderForSelfTest: CloudProvider? {
        switch self {
        case .openai: return .openai
        case .groq: return .groq
        case .gemini: return .gemini
        case .local, .groqProxy: return nil
        }
    }
}

public enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case openai, groq, gemini

    public var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .gemini: return "Gemini"
        }
    }

    public var transcriptionMode: TranscriptionMode {
        switch self {
        case .openai: return .openai
        case .groq: return .groq
        case .gemini: return .gemini
        }
    }
}

// MARK: - 语言

/// 最初三种（zh/en/ja）是听写语言；其余是**翻译目标**语言（按全球使用人口排序）。
/// 转写选择器只给 zh/en/ja。rawValue 即 ISO 639-1 码。
public enum TranscriptionLanguage: String, Codable, Sendable, CaseIterable {
    case en, zh, hi, es, fr, ar, bn, pt, ru, ur, id, de, ja, tr, vi, ko, it, th

    /// 原生名，用于「检测到中文」这类状态提示。
    public var nativeLabel: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .hi: return "हिन्दी"
        case .es: return "Español"
        case .fr: return "Français"
        case .ar: return "العربية"
        case .bn: return "বাংলা"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .ur: return "اردو"
        case .id: return "Indonesia"
        case .de: return "Deutsch"
        case .tr: return "Türkçe"
        case .vi: return "Tiếng Việt"
        case .ko: return "한국어"
        case .it: return "Italiano"
        case .th: return "ไทย"
        }
    }

    public var apiCode: String { rawValue }

    /// 英文名，喂给模型的语言指令用。
    public var englishName: String {
        switch self {
        case .en: return "English"
        case .zh: return "Chinese"
        case .hi: return "Hindi"
        case .es: return "Spanish"
        case .fr: return "French"
        case .ar: return "Arabic"
        case .bn: return "Bengali"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        case .ur: return "Urdu"
        case .id: return "Indonesian"
        case .de: return "German"
        case .ja: return "Japanese"
        case .tr: return "Turkish"
        case .vi: return "Vietnamese"
        case .ko: return "Korean"
        case .it: return "Italian"
        case .th: return "Thai"
        }
    }

    /// 归一化供应商返回的语言标记。Whisper / Groq 的标签写法不统一，
    /// 所以原始三种语言吃一份很宽的别名表；其余按前导 ISO 639-1 段匹配
    /// （`pt-BR` → `pt`），保证翻译气泡落到正确的一侧。
    public static func detected(_ raw: String?) -> TranscriptionLanguage? {
        guard let raw else { return nil }
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !n.isEmpty else { return nil }

        let zhAliases: Set<String> = ["cn", "chi", "zho", "cmn", "yue",
                                      "chinese", "mandarin", "cantonese", "中文", "中国語"]
        if n.hasPrefix("zh") || zhAliases.contains(n) { return .zh }
        let enAliases: Set<String> = ["eng", "english", "英語", "英文"]
        if n.hasPrefix("en") || enAliases.contains(n) { return .en }
        let jaAliases: Set<String> = ["jp", "jpn", "japanese", "日本語", "日语", "日文"]
        if n.hasPrefix("ja") || jaAliases.contains(n) { return .ja }

        let code = n.split(separator: "-").first.map(String.init) ?? n
        // 原始三种已在上面用别名表处理，这里只认翻译目标。
        let targets: [TranscriptionLanguage] = [.hi, .es, .fr, .ar, .bn, .pt, .ru,
                                                .ur, .id, .de, .tr, .vi, .ko, .it, .th]
        return targets.first { $0.rawValue == code }
    }
}

public enum TranscriptionLanguageMode: String, Codable, Sendable {
    case auto, fixed, preferred
}

public enum AppLanguage: String, Codable, Sendable {
    case system, zh, en, ja
}

// MARK: - 加工

public enum PostProcessingPreset: String, Codable, Sendable, CaseIterable {
    case basic, light, clean, polish, summary, email, notes, meeting, custom

    /// 快档（`basic/light/clean/polish`）用小模型，其余用大模型。
    public var prefersFastModel: Bool {
        switch self {
        case .basic, .light, .clean, .polish: return true
        default: return false
        }
    }
}

public enum PostProcessMode: Sendable {
    case transcript
    case selectionCommand
}

// MARK: - 录音

public enum RecordingMode: Sendable, Equatable {
    /// 按住说话。
    case hold
    /// 按一次开、再按一次停。落笔与（未来的）待命扫描在用。
    case toggle
}

public enum CompletionAction: Sendable, Equatable {
    case paste
    case editBeforeSend
    /// 把口述问题（连同选区上下文）交给 LLM 作答，展示而不是粘贴。
    case answer
}

// MARK: - 本地模型

public enum LocalModelRuntime: String, Codable, Sendable {
    /// OpenAI Whisper 权重（快，无说话人分离）。
    case whisper
    /// MOSS 转写 + 说话人分离 —— 唯一能产出说话人标签的管线。
    case moss
}

public struct LocalModelDefinition: Sendable, Equatable {
    public let id: String
    public let name: String
    /// HuggingFace 仓库；权重按需下载到 App 容器，**不打进 .app**。
    public let repo: String
    /// 仓库里的变体目录名。CoreML 权重按设备芯片编译，所以每个尺寸是一个目录
    /// 而不是单个文件。
    public let variant: String
    public let sizeLabel: String
    public let runtime: LocalModelRuntime

    public init(id: String, name: String, repo: String, variant: String,
                sizeLabel: String, runtime: LocalModelRuntime) {
        self.id = id
        self.name = name
        self.repo = repo
        self.variant = variant
        self.sizeLabel = sizeLabel
        self.runtime = runtime
    }
}

public enum LocalModels {
    /// 唯一能产出说话人标签的模型 id（落笔的「区分人物」以此为准）。
    public static let mossID = "moss-transcribe-diarize"
    public static let mossRepo = "OpenMOSS-Team/MOSS-Transcribe-Diarize"

    /// 原生版换成了随 App 编译进去的 CoreML 运行时，权重取 WhisperKit 官方仓库
    /// （不再是 mlx-community 的 MLX 权重，也不再需要用户自建 venv）。
    public static let repo = "argmaxinc/whisperkit-coreml"

    public static let all: [LocalModelDefinition] = [
        .init(id: "whisper-tiny", name: "Whisper Tiny", repo: repo,
              variant: "openai_whisper-tiny", sizeLabel: "~75 MB", runtime: .whisper),
        .init(id: "whisper-base", name: "Whisper Base", repo: repo,
              variant: "openai_whisper-base", sizeLabel: "~145 MB", runtime: .whisper),
        .init(id: "whisper-small", name: "Whisper Small", repo: repo,
              variant: "openai_whisper-small", sizeLabel: "~480 MB", runtime: .whisper),
        .init(id: "whisper-turbo", name: "Whisper Large v3 Turbo", repo: repo,
              variant: "openai_whisper-large-v3-v20240930_turbo", sizeLabel: "~1.5 GB",
              runtime: .whisper),
        // 完整的 large v3：解码器是 turbo 的 8 倍层数，慢不少，但对口音、
        // 专有名词和嘈杂环境更稳。体积也几乎翻倍（实测仓库里 2.88 GB）。
        // 放在 turbo 后面 —— 绝大多数人该用 turbo，这一条是给「宁可等」的场合。
        .init(id: "whisper-large", name: "Whisper Large v3", repo: repo,
              variant: "openai_whisper-large-v3", sizeLabel: "~2.9 GB",
              runtime: .whisper),
    ]

    public static func definition(id: String) -> LocalModelDefinition? {
        all.first { $0.id == id }
    }

    /// 旧 id → 新 id。Tauri 版的 `whisper-medium` 在 CoreML 仓库里没有对应尺寸，
    /// 落到体积相近但更快更准的 turbo；不认识的一律回落 base。
    ///
    /// 注意 `whisper-large` 现在是**真实存在的一条**，会被上面那句直接放行 ——
    /// 老配置里选了它的用户拿到的就是完整的 large v3，而不再被改判成 turbo。
    public static func migrate(id: String) -> String {
        if definition(id: id) != nil { return id }
        switch id {
        case "whisper-medium", mossID: return "whisper-turbo"
        default: return "whisper-base"
        }
    }
}

// MARK: - 供应商模型白名单

public enum ProviderModels {
    public static let openAITranscription = ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"]
    public static let openAIPostProcess = ["gpt-4.1-mini", "gpt-4.1", "gpt-5.5", "gpt-4o-mini"]
    public static let groqTranscription = ["whisper-large-v3-turbo", "whisper-large-v3"]
    public static let groqPostProcess = ["openai/gpt-oss-20b", "qwen/qwen3-32b"]
    public static let gemini = [
        "gemini-3.1-flash-lite-preview",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-live-preview",
    ]
}
