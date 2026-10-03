import Foundation

/// The languages the interface can render.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Follow whatever the Mac is set to.
    case system
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// Always shown in the language it selects, so the picker stays readable
    /// whichever language is active.
    public var displayName: String {
        switch self {
        case .system: return L10n.pick(zh: "跟随系统", en: "System")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// The two concrete languages the interface has strings for.
public enum ResolvedLanguage: String, Sendable {
    case chinese
    case english

    /// BCP-47 tag, used by Foundation formatters.
    public var localeIdentifier: String {
        switch self {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        }
    }
}

/// The user's language preference, shared by the app and the CLI.
///
/// The display-name helpers on the model types are computed properties, so the
/// active language has to be readable from anywhere. A tiny locked box keeps
/// that shared state `Sendable` and avoids touching the rest of the model.
public final class LanguageSettings: @unchecked Sendable {
    public static let shared = LanguageSettings()

    /// `UserDefaults` key used by the macOS app.
    public static let defaultsKey = "LLMProbe.language"

    private let lock = NSLock()
    private var storedPreference: AppLanguage
    private var cachedResolved: ResolvedLanguage

    private init() {
        let preference = Self.loadPreference()
        storedPreference = preference
        cachedResolved = Self.resolve(preference)
    }

    public var preference: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPreference
        }
        set {
            lock.lock()
            storedPreference = newValue
            cachedResolved = Self.resolve(newValue)
            lock.unlock()
        }
    }

    public var resolved: ResolvedLanguage {
        lock.lock()
        defer { lock.unlock() }
        return cachedResolved
    }

    /// Applies a preference and remembers it for the next launch.
    public func apply(_ preference: AppLanguage, persist: Bool = true) {
        self.preference = preference
        guard persist else { return }
        UserDefaults.standard.set(preference.rawValue, forKey: Self.defaultsKey)
    }

    /// Reads the stored preference (defaults to following the system).
    public static func loadPreference() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let value = AppLanguage(rawValue: raw) else { return .system }
        return value
    }

    /// Maps a preference onto a concrete language.
    ///
    /// `preferredLanguages` is injectable so the mapping can be tested without
    /// changing the reviewer's Mac settings. A Chinese Mac gets Chinese and an
    /// English Mac gets English; every other system language falls back to
    /// English, because those are the only two translations that ship.
    public static func resolve(
        _ preference: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> ResolvedLanguage {
        switch preference {
        case .chinese: return .chinese
        case .english: return .english
        case .system:
            for identifier in preferredLanguages {
                let lowered = identifier.lowercased()
                if lowered.hasPrefix("zh") { return .chinese }
                if lowered.hasPrefix("en") { return .english }
            }
            return .english
        }
    }

    /// Pins the interface to English for the command line interface.
    ///
    /// The GUI is bilingual; the CLI is English only. Agents and scripts match
    /// on probe names, verdicts and column headers, so the vocabulary must not
    /// depend on the reviewer's Mac. The engine renders strings while a probe
    /// executes, so this has to run once at start-up, not at serialisation.
    public func pinCommandLineLanguage() {
        apply(.english, persist: false)
    }
}

/// Two-string localisation helper.
///
/// Every user-facing string is written next to its translation:
///
///     Text(L10n.pick(zh: "还没有端点", en: "No endpoints yet"))
///
/// which keeps the call site honest — a new string cannot be added without an
/// English and a Chinese version in the same line — and avoids shipping a
/// resource bundle that could silently miss a key.
public enum L10n {
    public static var language: ResolvedLanguage { LanguageSettings.shared.resolved }

    public static var isChinese: Bool { language == .chinese }

    public static func pick(zh: String, en: String) -> String {
        isChinese ? zh : en
    }

    /// Shorthand used by the UI layer.
    public static func t(_ zh: String, _ en: String) -> String {
        pick(zh: zh, en: en)
    }
}

// MARK: - Localised names for the model enums

public extension WireAPI {
    /// Language-aware name; `displayName` stays English for logs and exports.
    var localizedName: String {
        L10n.pick(zh: chineseName, en: displayName)
    }

    var localizedShortName: String {
        L10n.pick(zh: chineseName, en: shortName)
    }

    private var chineseName: String {
        switch self {
        case .openAIChat: return "OpenAI Chat 补全"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .googleGemini: return "Google Gemini generateContent"
        case .ollamaChat: return "Ollama Chat"
        }
    }
}

public extension ProviderKind {
    var localizedName: String {
        switch self {
        case .google: return "Google Gemini"
        case .azureOpenAI: return "Azure OpenAI"
        case .moonshot: return L10n.pick(zh: "月之暗面 Kimi", en: "Moonshot / Kimi")
        case .zhipu: return L10n.pick(zh: "智谱 GLM", en: "Zhipu GLM")
        case .dashscope: return L10n.pick(zh: "阿里云百炼 DashScope", en: "Alibaba DashScope")
        case .siliconflow: return L10n.pick(zh: "硅基流动 SiliconFlow", en: "SiliconFlow")
        case .oneapi: return L10n.pick(zh: "One API / New API", en: "One API / New API")
        case .mlx: return L10n.pick(zh: "MLX 本地服务", en: "MLX server")
        case .lmstudio: return L10n.pick(zh: "LM Studio 本地服务", en: "LM Studio")
        case .custom: return L10n.pick(zh: "自定义", en: "Custom")
        default: return displayName
        }
    }
}

public extension Capability {
    var localizedName: String {
        L10n.pick(zh: chineseName, en: displayName)
    }

    private var chineseName: String {
        switch self {
        case .chat: return "对话"
        case .streaming: return "流式输出"
        case .tools: return "工具调用"
        case .parallelTools: return "并行工具调用"
        case .vision: return "视觉（图像输入）"
        case .audioInput: return "音频输入"
        case .audioOutput: return "音频输出"
        case .structuredOutput: return "结构化输出"
        case .jsonMode: return "JSON 模式"
        case .reasoning: return "推理 / 思考"
        case .promptCaching: return "提示缓存"
        case .systemPrompt: return "系统提示"
        case .seed: return "确定性种子"
        case .logprobs: return "对数概率"
        case .embeddings: return "向量嵌入"
        }
    }
}

public extension ModalityBucket {
    var localizedName: String {
        switch self {
        case .text: return L10n.pick(zh: "文本", en: "Text")
        case .image: return L10n.pick(zh: "图像", en: "Image")
        case .audio: return L10n.pick(zh: "音频", en: "Audio")
        case .video: return L10n.pick(zh: "视频", en: "Video")
        case .embedding: return L10n.pick(zh: "向量", en: "Embedding")
        }
    }
}

public extension SupportLevel {
    var localizedName: String {
        switch self {
        case .supported: return L10n.pick(zh: "支持", en: "Supported")
        case .partial: return L10n.pick(zh: "部分支持", en: "Partial")
        case .unsupported: return L10n.pick(zh: "不支持", en: "Not supported")
        case .unknown: return L10n.pick(zh: "未知", en: "Unknown")
        }
    }
}

public extension EvidenceKind {
    var localizedName: String {
        switch self {
        case .metadata: return L10n.pick(zh: "上游元数据", en: "Vendor metadata")
        case .liveProbe: return L10n.pick(zh: "实测", en: "Live probe")
        case .config: return L10n.pick(zh: "本地配置", en: "Local config")
        case .heuristic: return L10n.pick(zh: "内置表推断", en: "Built-in table")
        case .unknown: return L10n.pick(zh: "未知", en: "Unknown")
        }
    }
}

public extension ProbeKind {
    var localizedName: String {
        L10n.pick(zh: chineseName, en: displayName)
    }

    private var chineseName: String {
        switch self {
        case .connectivity: return "连通性"
        case .catalog: return "模型目录"
        case .chat: return "对话补全"
        case .streaming: return "流式速度"
        case .tools: return "工具调用"
        case .vision: return "视觉输入"
        case .structuredOutput: return "结构化输出"
        case .contextWindow: return "上下文长度"
        case .maxOutput: return "最大输出"
        case .reasoning: return "推理模式"
        case .embeddings: return "向量嵌入"
        }
    }

    /// Long-form help text for the detail pane.
    var localizedExplanation: String {
        guard L10n.isChinese else { return explanation }
        switch self {
        case .connectivity: return "解析 DNS/TLS 并访问主机，报告是否可达以及链路耗时。"
        case .catalog: return "读取厂商的模型列表接口，确认模型 ID 是否存在以及是否被正确暴露。"
        case .chat: return "发送一次极短的补全请求，确认返回结构可解析。"
        case .streaming: return "用流式请求测量首 token 延迟和输出速度。"
        case .tools: return "带工具定义请求一次，确认上游是否真的返回工具调用。"
        case .vision: return "发送一个极小的图像块，确认是否接受图像输入。"
        case .structuredOutput: return "要求返回 JSON，确认是遵守 schema 还是仅靠提示。"
        case .contextWindow: return "优先读取元数据；只有深度模式才会用真实 payload 试探上限。"
        case .maxOutput: return "用一次故意超限的请求，从报错里读出真实的最大输出 token。"
        case .reasoning: return "检查是否返回思维链或推理 token 统计。"
        case .embeddings: return "调用一次向量接口，确认维度与返回结构。"
        }
    }
}

public extension ProbeStatus {
    var localizedName: String {
        switch self {
        case .passed: return L10n.pick(zh: "通过", en: "Passed")
        case .warning: return L10n.pick(zh: "警告", en: "Warning")
        case .failed: return L10n.pick(zh: "失败", en: "Failed")
        case .unsupported: return L10n.pick(zh: "不支持", en: "Unsupported")
        case .skipped: return L10n.pick(zh: "已跳过", en: "Skipped")
        }
    }
}

public extension HealthVerdict {
    var localizedName: String {
        switch self {
        case .healthy: return L10n.pick(zh: "健康", en: "Healthy")
        case .degraded: return L10n.pick(zh: "降级", en: "Degraded")
        case .unhealthy: return L10n.pick(zh: "异常", en: "Unhealthy")
        case .unknown: return L10n.pick(zh: "未知", en: "Unknown")
        }
    }
}

public extension ProbeFailure.Category {
    var localizedName: String {
        L10n.pick(zh: chineseName, en: displayName)
    }

    /// Operator hint shown under a failed probe. `hint` stays English for logs.
    var localizedHint: String {
        guard L10n.isChinese else { return hint }
        switch self {
        case .authentication: return "密钥缺失、过期，或被上游拒绝。"
        case .authorization: return "密钥有效，但没有访问该模型或路由的权限。"
        case .modelNotFound: return "检查模型 ID，或刷新模型目录。"
        case .invalidRequest: return "上游拒绝了该协议的请求结构。"
        case .contextOverflow: return "提示词超过了模型上下文窗口。"
        case .rateLimited: return "被上游或其前面的代理限流。"
        case .quotaExceeded: return "该凭据的余额或配额已耗尽。"
        case .serverError: return "上游返回 5xx：可以重试，或视为上游不健康。"
        case .timeout: return "在设定的超时时间内没有响应。"
        case .network: return "无法连接：DNS、TLS、代理或端口问题。"
        case .decoding: return "响应与声明的协议不匹配。"
        case .unsupportedCapability: return "该端点没有实现这项能力。"
        case .cancelled: return "已被用户取消。"
        case .unknown: return "请查看原始响应了解详情。"
        }
    }

    private var chineseName: String {
        switch self {
        case .authentication: return "鉴权失败"
        case .authorization: return "无权限"
        case .modelNotFound: return "模型不存在"
        case .invalidRequest: return "请求无效"
        case .contextOverflow: return "上下文超限"
        case .rateLimited: return "被限流"
        case .quotaExceeded: return "额度不足"
        case .serverError: return "上游服务错误"
        case .timeout: return "超时"
        case .network: return "网络错误"
        case .decoding: return "响应无法解析"
        case .unsupportedCapability: return "能力不支持"
        case .cancelled: return "已取消"
        case .unknown: return "未知错误"
        }
    }
}

public extension DiscoverySource.Status {
    var localizedName: String {
        switch self {
        case .found: return L10n.pick(zh: "已找到", en: "Found")
        case .notFound: return L10n.pick(zh: "未安装", en: "Not installed")
        case .unreadable: return L10n.pick(zh: "无法读取", en: "Unreadable")
        case .unsupported: return L10n.pick(zh: "已跳过", en: "Skipped")
        }
    }
}

public extension AuthConfig.Style {
    var localizedName: String {
        switch self {
        case .bearer: return L10n.pick(zh: "Bearer Token", en: "Bearer token")
        case .xApiKey: return L10n.pick(zh: "x-api-key 请求头", en: "x-api-key header")
        case .header: return L10n.pick(zh: "自定义请求头", en: "Custom header")
        case .query: return L10n.pick(zh: "URL 查询参数", en: "Query parameter")
        case .none: return L10n.pick(zh: "不带鉴权", en: "No authentication")
        }
    }
}
