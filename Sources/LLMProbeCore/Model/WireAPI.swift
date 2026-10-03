import Foundation

/// The HTTP contract used to talk to an upstream endpoint.
///
/// A single vendor can expose several of these (for example the OpenAI API
/// exposes both `openai-chat` and `openai-responses`), and a single wire API is
/// reused by many vendors (DeepSeek, Groq, vLLM, LM Studio and friends are all
/// `openai-chat`).
public enum WireAPI: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAIChat = "openai-chat"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
    case googleGemini = "google-gemini"
    case ollamaChat = "ollama-chat"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAIChat: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .googleGemini: return "Google Gemini generateContent"
        case .ollamaChat: return "Ollama Chat"
        }
    }

    public var shortName: String {
        switch self {
        case .openAIChat: return "Chat"
        case .openAIResponses: return "Responses"
        case .anthropicMessages: return "Messages"
        case .googleGemini: return "Gemini"
        case .ollamaChat: return "Ollama"
        }
    }

    /// Wire APIs whose request/response envelope is OpenAI-shaped. These share
    /// an SSE frame format (`data: {...}` + `data: [DONE]`).
    public var isOpenAICompatible: Bool {
        self == .openAIChat || self == .openAIResponses
    }

    public static let selectable: [WireAPI] = [.openAIChat, .openAIResponses, .anthropicMessages, .googleGemini, .ollamaChat]
}

/// Well known upstream vendors, used for sensible defaults and grouping in the UI.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openai
    case anthropic
    case google
    case azureOpenAI = "azure-openai"
    case openrouter
    case deepseek
    case moonshot
    case zhipu
    case dashscope
    case minimax
    case xiaomi
    case iflow
    case siliconflow
    case groq
    case mistral
    case xai
    case together
    case fireworks
    case perplexity
    case cerebras
    case ollama
    case lmstudio
    case mlx
    case vllm
    case litellm
    case oneapi
    case commandCode = "command-code"
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        case .azureOpenAI: return "Azure OpenAI"
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Moonshot / Kimi"
        case .zhipu: return "Zhipu GLM"
        case .dashscope: return "Alibaba DashScope"
        case .minimax: return "MiniMax"
        case .xiaomi: return "Xiaomi MiMo"
        case .iflow: return "iFlow"
        case .siliconflow: return "SiliconFlow"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .xai: return "xAI"
        case .together: return "Together AI"
        case .fireworks: return "Fireworks AI"
        case .perplexity: return "Perplexity"
        case .cerebras: return "Cerebras"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .mlx: return "MLX server"
        case .vllm: return "vLLM"
        case .litellm: return "LiteLLM"
        case .oneapi: return "One API / New API"
        case .commandCode: return "Command Code"
        case .custom: return "Custom"
        }
    }

    /// Default base URL, kept as a hint only: discovered endpoints always win.
    public var defaultBaseURL: String? {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .minimax: return "https://api.minimax.io/v1"
        case .xiaomi: return "https://api.xiaomimimo.com/v1"
        case .iflow: return "https://apis.iflow.cn/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .xai: return "https://api.x.ai/v1"
        case .together: return "https://api.together.xyz/v1"
        case .fireworks: return "https://api.fireworks.ai/inference/v1"
        case .perplexity: return "https://api.perplexity.ai"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .lmstudio: return "http://127.0.0.1:1234/v1"
        case .mlx: return "http://127.0.0.1:8080/v1"
        case .vllm: return "http://127.0.0.1:8000/v1"
        case .litellm: return "http://127.0.0.1:4000/v1"
        case .oneapi: return "http://127.0.0.1:3000/v1"
        case .commandCode: return "http://127.0.0.1:3050/v1"
        case .azureOpenAI, .custom: return nil
        }
    }

    public var defaultWireAPI: WireAPI {
        switch self {
        case .anthropic: return .anthropicMessages
        case .google: return .googleGemini
        case .ollama: return .ollamaChat
        default: return .openAIChat
        }
    }

    /// Environment variables that conventionally hold a key for this vendor.
    public var keyEnvironmentNames: [String] {
        switch self {
        case .openai: return ["OPENAI_API_KEY"]
        case .anthropic: return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        case .google: return ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"]
        case .azureOpenAI: return ["AZURE_OPENAI_API_KEY"]
        case .openrouter: return ["OPENROUTER_API_KEY"]
        case .deepseek: return ["DEEPSEEK_API_KEY"]
        case .moonshot: return ["MOONSHOT_API_KEY", "KIMI_API_KEY"]
        case .zhipu: return ["ZHIPUAI_API_KEY", "ZHIPU_API_KEY", "GLM_API_KEY"]
        case .dashscope: return ["DASHSCOPE_API_KEY", "QWEN_API_KEY"]
        case .minimax: return ["MINIMAX_API_KEY", "MINIMAX_CN_API_KEY"]
        case .xiaomi: return ["XIAOMI_API_KEY", "MIMO_API_KEY"]
        case .iflow: return ["IFLOW_API_KEY"]
        case .siliconflow: return ["SILICONFLOW_API_KEY"]
        case .groq: return ["GROQ_API_KEY"]
        case .mistral: return ["MISTRAL_API_KEY"]
        case .xai: return ["XAI_API_KEY"]
        case .together: return ["TOGETHER_API_KEY", "TOGETHERAI_API_KEY"]
        case .fireworks: return ["FIREWORKS_API_KEY"]
        case .perplexity: return ["PERPLEXITY_API_KEY", "PPLX_API_KEY"]
        case .cerebras: return ["CEREBRAS_API_KEY"]
        case .commandCode: return ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"]
        default: return []
        }
    }

    public var keyEnvironmentPrefixes: [String] {
        let base = rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
        return ["\(base)_API_KEY", "\(base)_KEY", "\(base)_AUTH_TOKEN"]
    }
}
