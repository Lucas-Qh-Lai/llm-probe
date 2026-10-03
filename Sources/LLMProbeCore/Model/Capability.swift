import Foundation

/// Things an upstream may or may not support.
public enum Capability: String, Codable, CaseIterable, Sendable, Identifiable {
    case chat
    case streaming
    case tools
    case parallelTools = "parallel-tools"
    case vision
    case audioInput = "audio-input"
    case audioOutput = "audio-output"
    case structuredOutput = "structured-output"
    case jsonMode = "json-mode"
    case reasoning
    case promptCaching = "prompt-caching"
    case systemPrompt = "system-prompt"
    case seed
    case logprobs
    case embeddings

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .streaming: return "Streaming"
        case .tools: return "Tool calling"
        case .parallelTools: return "Parallel tools"
        case .vision: return "Vision (image input)"
        case .audioInput: return "Audio input"
        case .audioOutput: return "Audio output"
        case .structuredOutput: return "Structured output"
        case .jsonMode: return "JSON mode"
        case .reasoning: return "Reasoning / thinking"
        case .promptCaching: return "Prompt caching"
        case .systemPrompt: return "System prompt"
        case .seed: return "Deterministic seed"
        case .logprobs: return "Log probabilities"
        case .embeddings: return "Embeddings"
        }
    }

    /// The modality buckets requested in the report.
    public var modalityBucket: ModalityBucket? {
        switch self {
        case .chat, .streaming, .tools, .parallelTools, .structuredOutput, .jsonMode,
             .reasoning, .promptCaching, .systemPrompt, .seed, .logprobs, .embeddings:
            return .text
        case .vision:
            return .image
        case .audioInput:
            return .audio
        case .audioOutput:
            return .audio
        }
    }

    public static let orderedForDisplay: [Capability] = [
        .chat, .streaming, .tools, .parallelTools, .vision, .audioInput, .audioOutput,
        .structuredOutput, .jsonMode, .reasoning, .promptCaching, .systemPrompt,
        .seed, .logprobs, .embeddings,
    ]
}

public enum ModalityBucket: String, Codable, CaseIterable, Sendable, Identifiable {
    case text
    case image
    case audio
    case video
    case embedding

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .embedding: return "Embedding"
        }
    }
}

/// Tri-state support answer. `unknown` means "we could not decide", which is a
/// different (and honest) answer from "no".
public enum SupportLevel: String, Codable, CaseIterable, Sendable {
    case supported
    case partial
    case unsupported
    case unknown

    public var displayName: String {
        switch self {
        case .supported: return "Supported"
        case .partial: return "Partial"
        case .unsupported: return "Not supported"
        case .unknown: return "Unknown"
        }
    }

    /// How confident the answer is, used to sort rows in the capability matrix.
    public var rank: Int {
        switch self {
        case .supported: return 3
        case .partial: return 2
        case .unknown: return 1
        case .unsupported: return 0
        }
    }
}

/// How a support answer was obtained.
public enum EvidenceKind: String, Codable, Sendable {
    /// Declared by the vendor's model metadata endpoint.
    case metadata
    /// Observed from a live request.
    case liveProbe = "live-probe"
    /// Inferred from the local agent config.
    case config
    /// Known from a built-in model family table.
    case heuristic
    case unknown
}

/// One capability answer plus the evidence behind it.
public struct CapabilityFinding: Codable, Hashable, Sendable {
    public var capability: Capability
    public var level: SupportLevel
    public var evidence: EvidenceKind
    public var detail: String?
    /// Tokens billed to obtain this answer (0 for metadata answers).
    public var tokenCost: Int

    public init(capability: Capability, level: SupportLevel, evidence: EvidenceKind, detail: String? = nil, tokenCost: Int = 0) {
        self.capability = capability
        self.level = level
        self.evidence = evidence
        self.detail = detail
        self.tokenCost = tokenCost
    }
}
