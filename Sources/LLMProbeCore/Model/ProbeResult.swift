import Foundation

/// The individual checks the engine can run against an endpoint.
public enum ProbeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case connectivity
    case catalog
    case chat
    case streaming
    case tools
    case vision
    case structuredOutput = "structured-output"
    case contextWindow = "context-window"
    case maxOutput = "max-output"
    case reasoning
    case embeddings

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .connectivity: return "Reachability"
        case .catalog: return "Model catalog"
        case .chat: return "Chat completion"
        case .streaming: return "Streaming speed"
        case .tools: return "Tool calling"
        case .vision: return "Vision input"
        case .structuredOutput: return "Structured output"
        case .contextWindow: return "Context window"
        case .maxOutput: return "Max output tokens"
        case .reasoning: return "Reasoning mode"
        case .embeddings: return "Embeddings"
        }
    }

    public var explanation: String {
        switch self {
        case .connectivity: return "Resolves DNS/TLS, reaches the host and reports whether the credential was accepted. Zero completion tokens."
        case .catalog: return "Lists models from the provider catalog and reads context limits from metadata. Zero completion tokens."
        case .chat: return "One tiny non-streaming completion that proves generation works end to end."
        case .streaming: return "Streams a few tokens to measure time-to-first-token and output speed."
        case .tools: return "Forces a single tool call with a one-argument schema and validates the returned JSON."
        case .vision: return "Sends a 16x16 PNG and asks for one token, the smallest image request a provider accepts."
        case .structuredOutput: return "Requests a JSON object constrained by a schema."
        case .contextWindow: return "Uses model metadata, then a zero-output validation probe, then an optional payload search."
        case .maxOutput: return "Reads the declared output limit or asks for an impossible one and reads the error, costing zero completion tokens."
        case .reasoning: return "Checks whether a reasoning/thinking field is accepted and returned."
        case .embeddings: return "Calls the embeddings route, when the provider exposes one."
        }
    }

    /// Rough input-token budget this probe spends, used for the pre-flight estimate.
    public var estimatedInputTokens: Int {
        switch self {
        case .connectivity: return 0
        case .catalog: return 0
        case .chat: return 30
        case .streaming: return 30
        case .tools: return 90
        case .vision: return 120
        case .structuredOutput: return 70
        case .contextWindow: return 0
        case .maxOutput: return 0
        case .reasoning: return 40
        case .embeddings: return 8
        }
    }

    /// Rough output-token budget this probe spends.
    public var estimatedOutputTokens: Int {
        switch self {
        case .connectivity, .catalog, .contextWindow, .maxOutput: return 0
        case .chat: return 16
        case .streaming: return 48
        case .tools: return 64
        case .vision: return 8
        case .structuredOutput: return 48
        case .reasoning: return 64
        case .embeddings: return 0
        }
    }

    /// `contextWindow` in precise mode is the only probe that can spend real input tokens.
    public var isTokenHeavy: Bool {
        self == .contextWindow
    }
}

public enum ProbeStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case unsupported
    case skipped

    public var displayName: String {
        switch self {
        case .passed: return "Passed"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .unsupported: return "Unsupported"
        case .skipped: return "Skipped"
        }
    }

    public var isProblem: Bool { self == .failed || self == .warning }
}

/// Categorised failure so the UI can explain *why* an upstream misbehaved.
public struct ProbeFailure: Codable, Hashable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case authentication
        case authorization
        case modelNotFound = "model-not-found"
        case invalidRequest = "invalid-request"
        case contextOverflow = "context-overflow"
        case rateLimited = "rate-limited"
        case quotaExceeded = "quota-exceeded"
        case serverError = "server-error"
        case timeout
        case network
        case decoding
        case unsupportedCapability = "unsupported-capability"
        case cancelled
        case unknown

        public var displayName: String {
            switch self {
            case .authentication: return "Authentication failed"
            case .authorization: return "Not authorised"
            case .modelNotFound: return "Model not found"
            case .invalidRequest: return "Invalid request"
            case .contextOverflow: return "Context overflow"
            case .rateLimited: return "Rate limited"
            case .quotaExceeded: return "Quota exceeded"
            case .serverError: return "Upstream server error"
            case .timeout: return "Timed out"
            case .network: return "Network error"
            case .decoding: return "Unreadable response"
            case .unsupportedCapability: return "Capability not supported"
            case .cancelled: return "Cancelled"
            case .unknown: return "Unknown error"
            }
        }

        public var isRetryable: Bool {
            switch self {
            case .rateLimited, .serverError, .timeout, .network: return true
            default: return false
            }
        }

        /// A short operator hint shown under the failure in the UI.
        public var hint: String {
            switch self {
            case .authentication: return "The key is missing, expired or rejected by the upstream."
            case .authorization: return "The key is valid but has no access to this model or route."
            case .modelNotFound: return "Check the model id, or refresh the model catalog."
            case .invalidRequest: return "The upstream rejected the request shape for this wire API."
            case .contextOverflow: return "The prompt exceeded the model context window."
            case .rateLimited: return "Throttled by the upstream or the proxy in front of it."
            case .quotaExceeded: return "Balance or quota exhausted for this credential."
            case .serverError: return "Upstream returned 5xx: retry, or treat the upstream as unhealthy."
            case .timeout: return "No response inside the configured timeout."
            case .network: return "Could not connect: DNS, TLS, proxy or port problem."
            case .decoding: return "Response did not match the declared wire API."
            case .unsupportedCapability: return "This endpoint does not implement the feature."
            case .cancelled: return "Cancelled by the user."
            case .unknown: return "Inspect the raw response for details."
            }
        }
    }

    public var category: Category
    public var httpStatus: Int?
    public var providerCode: String?
    public var message: String
    public var rawBodySnippet: String?

    public init(category: Category, httpStatus: Int? = nil, providerCode: String? = nil, message: String, rawBodySnippet: String? = nil) {
        self.category = category
        self.httpStatus = httpStatus
        self.providerCode = providerCode
        self.message = message
        self.rawBodySnippet = rawBodySnippet
    }
}

/// Token and latency accounting for one probe (or a whole report when summed).
public struct ProbeMetrics: Codable, Hashable, Sendable {
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var reasoningTokens: Int
    /// Time from request start to the first token of the response.
    public var timeToFirstTokenMS: Double?
    /// Wall clock duration of the whole probe.
    public var totalDurationMS: Double?
    public var outputTokensPerSecond: Double?
    public var latencySamplesMS: [Double]

    public init(
        requests: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        reasoningTokens: Int = 0,
        timeToFirstTokenMS: Double? = nil,
        totalDurationMS: Double? = nil,
        outputTokensPerSecond: Double? = nil,
        latencySamplesMS: [Double] = []
    ) {
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
        self.timeToFirstTokenMS = timeToFirstTokenMS
        self.totalDurationMS = totalDurationMS
        self.outputTokensPerSecond = outputTokensPerSecond
        self.latencySamplesMS = latencySamplesMS
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public static let zero = ProbeMetrics()

    public static func + (lhs: ProbeMetrics, rhs: ProbeMetrics) -> ProbeMetrics {
        var merged = ProbeMetrics(
            requests: lhs.requests + rhs.requests,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            timeToFirstTokenMS: rhs.timeToFirstTokenMS ?? lhs.timeToFirstTokenMS,
            totalDurationMS: (lhs.totalDurationMS ?? 0) + (rhs.totalDurationMS ?? 0),
            outputTokensPerSecond: rhs.outputTokensPerSecond ?? lhs.outputTokensPerSecond,
            latencySamplesMS: lhs.latencySamplesMS + rhs.latencySamplesMS
        )
        if merged.totalDurationMS == 0 { merged.totalDurationMS = nil }
        return merged
    }

    public static func += (lhs: inout ProbeMetrics, rhs: ProbeMetrics) { lhs = lhs + rhs }
}

/// Result of a single probe.
public struct ProbeOutcome: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ProbeKind
    public var status: ProbeStatus
    public var summary: String
    public var details: [String: String]
    public var findings: [CapabilityFinding]
    public var metrics: ProbeMetrics
    public var failure: ProbeFailure?
    public var startedAt: Date
    public var durationMS: Double

    public init(
        id: UUID = UUID(),
        kind: ProbeKind,
        status: ProbeStatus,
        summary: String,
        details: [String: String] = [:],
        findings: [CapabilityFinding] = [],
        metrics: ProbeMetrics = .zero,
        failure: ProbeFailure? = nil,
        startedAt: Date = Date(),
        durationMS: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.summary = summary
        self.details = details
        self.findings = findings
        self.metrics = metrics
        self.failure = failure
        self.startedAt = startedAt
        self.durationMS = durationMS
    }

    public static func skipped(_ kind: ProbeKind, reason: String) -> ProbeOutcome {
        ProbeOutcome(kind: kind, status: .skipped, summary: reason)
    }
}

/// Overall health verdict for an endpoint.
public enum HealthVerdict: String, Codable, Sendable {
    case healthy
    case degraded
    case unhealthy
    case unknown

    public var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .unhealthy: return "Unhealthy"
        case .unknown: return "Unknown"
        }
    }
}

/// Full report for one endpoint.
public struct EndpointReport: Codable, Sendable, Identifiable {
    public var id: UUID { endpoint.id }
    public var endpoint: ProbeEndpoint
    public var startedAt: Date
    public var finishedAt: Date
    public var verdict: HealthVerdict
    public var outcomes: [ProbeOutcome]
    public var capabilityMatrix: [Capability: SupportLevel]
    public var capabilityEvidence: [CapabilityFinding]

    public init(
        endpoint: ProbeEndpoint,
        startedAt: Date,
        finishedAt: Date,
        verdict: HealthVerdict,
        outcomes: [ProbeOutcome],
        capabilityMatrix: [Capability: SupportLevel],
        capabilityEvidence: [CapabilityFinding]
    ) {
        self.endpoint = endpoint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.verdict = verdict
        self.outcomes = outcomes
        self.capabilityMatrix = capabilityMatrix
        self.capabilityEvidence = capabilityEvidence
    }

    public var totalMetrics: ProbeMetrics {
        var merged = outcomes.map(\.metrics).reduce(.zero, +)
        // Speed and TTFT must come from the streaming probe; summing latencies
        // from the other probes would understate both.
        if let streaming = outcome(.streaming)?.metrics {
            merged.outputTokensPerSecond = streaming.outputTokensPerSecond
            merged.timeToFirstTokenMS = streaming.timeToFirstTokenMS
        }
        return merged
    }

    public var durationMS: Double {
        finishedAt.timeIntervalSince(startedAt) * 1000
    }

    public var failures: [ProbeFailure] { outcomes.compactMap(\.failure) }

    public func outcome(_ kind: ProbeKind) -> ProbeOutcome? {
        outcomes.first { $0.kind == kind }
    }
}

/// User-selectable probe configuration.
public struct ProbePlan: Codable, Hashable, Sendable {
    public var kinds: [ProbeKind]
    /// Repeats for latency/speed probes; the median is reported.
    public var speedSamples: Int
    public var requestTimeout: TimeInterval
    /// Upper bound used by the payload-based context search.
    public var contextSearchUpperBound: Int
    /// Context search spends real input tokens, so it stays opt-in.
    public var enableContextSearch: Bool
    /// Hard cap: stop the run once this many tokens have been spent.
    public var tokenBudget: Int
    /// Capability answers are merged into a cache so repeat runs cost nothing.
    public var useCache: Bool

    public init(
        kinds: [ProbeKind] = ProbePlan.quick.kinds,
        speedSamples: Int = 1,
        requestTimeout: TimeInterval = 45,
        contextSearchUpperBound: Int = 1_000_000,
        enableContextSearch: Bool = false,
        tokenBudget: Int = 20_000,
        useCache: Bool = true
    ) {
        self.kinds = kinds
        self.speedSamples = speedSamples
        self.requestTimeout = requestTimeout
        self.contextSearchUpperBound = contextSearchUpperBound
        self.enableContextSearch = enableContextSearch
        self.tokenBudget = tokenBudget
        self.useCache = useCache
    }

    /// Everything that costs no completion tokens.
    public static let free: ProbePlan = {
        ProbePlan(kinds: [.connectivity, .catalog, .contextWindow, .maxOutput], tokenBudget: 2_000)
    }()

    /// Cheap but complete: the default one-click run.
    public static let quick: ProbePlan = {
        ProbePlan(kinds: [.connectivity, .chat, .streaming, .tools, .vision, .maxOutput, .contextWindow], tokenBudget: 5_000)
    }()

    /// Everything, including the payload search.
    public static let deep: ProbePlan = {
        ProbePlan(
            kinds: ProbeKind.allCases,
            speedSamples: 3,
            contextSearchUpperBound: 1_000_000,
            enableContextSearch: true,
            tokenBudget: 60_000
        )
    }()

    public var estimatedTokens: Int {
        let fixed = kinds.reduce(0) { $0 + $1.estimatedInputTokens + $1.estimatedOutputTokens }
        return fixed * max(1, speedSamples)
    }

    /// Probes grouped for the UI.
    public static func preset(for id: String) -> ProbePlan? {
        switch id {
        case "free": return .free
        case "quick": return .quick
        case "deep": return .deep
        default: return nil
        }
    }
}
