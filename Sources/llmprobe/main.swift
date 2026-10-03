import Foundation
import LLMProbeCore

// LLMProbe command line interface.
//
// The CLI shares the whole engine with the macOS app, which keeps behaviour
// identical and makes the tool scriptable (CI smoke tests, cron health checks).

let arguments = Array(CommandLine.arguments.dropFirst())

/// Pins the CLI to English before anything is printed.
///
/// LLMProbe is bilingual in the macOS app and English only on the command line.
/// The engine builds its summaries while a probe executes rather than while
/// serialising, so the language is pinned once here at start-up: half a report
/// in each language is worse than either.
func pinEnglishOutput() {
    LanguageSettings.shared.pinCommandLineLanguage()
}

func printUsage() {
    let text = """
    LLMProbe \(LLMProbeVersion.short) — local upstream health, speed and capability probe

    USAGE
    llmprobe discover [--json] [--no-local] [--no-env]
      llmprobe import [--no-local] [--no-env]
      llmprobe probe --index <n> [--plan free|quick|deep] [--json] [--context-search]
      llmprobe probe --all [--plan quick] [--json]
      llmprobe probe --url <base-url> --model <model> [options]
      llmprobe list-sources
      llmprobe selftest [--json]
      llmprobe version
      llmprobe help

    Every command that reads the machine takes the same safety switches:
    nothing is written unless you pass --save or use `import`, and no output ever
    contains a credential (`Redactor` masks them on the way out).

    PROBE OPTIONS
      --url <url>            Base URL, for example https://api.openai.com/v1
      --model <model>        Model id
      --wire <api>           openai-chat | openai-responses | anthropic-messages | google-gemini | ollama
      --key <secret>         Inline credential (prefer --key-env)
      --key-env <NAME>       Read the credential from an environment variable
      --plan <name>          free (no completion tokens), quick (default), deep
      --samples <n>          Streaming samples for the speed median
      --context-search       Measure the context window with a payload search (spends input tokens)
      --timeout <seconds>    Per-request timeout, default 45
      --json                 Machine readable output
      --save                 Remember the endpoint in ~/Library/Application Support/LLMProbe

    LANGUAGE
      The CLI prints English only, so scripts and agents can match on stable
      strings whatever the Mac is set to. The bilingual interface, including
      Chinese, lives in the macOS app.

    EXIT CODES
      0 healthy · 1 degraded or unhealthy · 2 usage or discovery error

    AGENT USAGE
      `llmprobe probe --url ... --model ... --plan free --json` is safe to call
      from an agent or a cron job: it spends no completion tokens, prints one
      JSON document and never asks a question.
    """
    print(text)
}

/// Orders verdicts from best to worst so batch runs can report the worst one.
func severity(_ verdict: HealthVerdict) -> Int {
    switch verdict {
    case .healthy: return 0
    case .degraded: return 1
    case .unhealthy: return 2
    case .unknown: return 3
    }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

struct Options {
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        let valueFlags: Set<String> = ["url", "model", "wire", "key", "key-env", "plan", "index", "samples", "timeout", "context-upper", "name"]
        while index < raw.count {
            let token = raw[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let name = String(token.dropFirst(2))
            if valueFlags.contains(name) {
                if index + 1 < raw.count {
                    values[name] = raw[index + 1]
                    index += 2
                    continue
                }
                fail("Missing value for --\(name)")
            }
            flags.insert(name)
            index += 1
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
}

func plan(from options: Options) -> ProbePlan {
    let name = options.value("plan") ?? "quick"
    var selected: ProbePlan
    switch name {
    case "free": selected = .free
    case "deep": selected = .deep
    case "quick": selected = .quick
    default: fail("Unknown plan '\(name)'. Use free, quick or deep.")
    }
    if let samples = options.int("samples") { selected.speedSamples = max(1, min(10, samples)) }
    if let timeout = options.double("timeout") { selected.requestTimeout = timeout }
    if options.has("context-search") { selected.enableContextSearch = true }
    if let upper = options.int("context-upper") { selected.contextSearchUpperBound = max(2_048, upper) }
    return selected
}

func wireAPI(from raw: String?) -> WireAPI? {
    guard let raw else { return nil }
    switch raw.lowercased() {
    case "openai-chat", "chat", "chat-completions": return .openAIChat
    case "openai-responses", "responses": return .openAIResponses
    case "anthropic-messages", "anthropic", "messages": return .anthropicMessages
    case "google-gemini", "gemini", "google": return .googleGemini
    case "ollama": return .ollamaChat
    default: return nil
    }
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return Redactor.scrub(text)
}

func endpointJSON(_ endpoint: ProbeEndpoint) -> [String: Any] {
    var object: [String: Any] = [
        "id": endpoint.id.uuidString,
        "name": endpoint.name,
        "provider": endpoint.provider.rawValue,
        "wire_api": endpoint.wireAPI.rawValue,
        "base_url": endpoint.baseURL,
        "model": endpoint.model,
        "auth": endpoint.auth.label,
        "local": endpoint.isLocalHost,
    ]
    if let context = endpoint.declaredContextWindow { object["declared_context_window"] = context }
    if let maxOutput = endpoint.declaredMaxOutputTokens { object["declared_max_output_tokens"] = maxOutput }
    if let origin = endpoint.origin { object["origin"] = origin.shortDescription }
    if !endpoint.tags.isEmpty { object["tags"] = endpoint.tags }
    return object
}

/// Terminal columns a string occupies. CJK and full-width forms take two cells.
func displayWidth(_ text: String) -> Int {
    var width = 0
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            width += 2
        default:
            width += 1
        }
    }
    return width
}

func outcomeLine(_ outcome: ProbeOutcome) -> String {
    let symbol: String
    switch outcome.status {
    case .passed: symbol = "PASS"
    case .warning: symbol = "WARN"
    case .failed: symbol = "FAIL"
    case .unsupported: symbol = "N/A "
    case .skipped: symbol = "SKIP"
    }
    // `displayName` stays English for logs and JSON; the human report follows the
    // active language, like every other string on this line. Padding uses
    // display width so the Chinese column lines up in a terminal: a CJK glyph
    // occupies two cells, `String.count` counts it as one.
    let name = outcome.kind.localizedName
    let pad = String(repeating: " ", count: max(0, 24 - displayWidth(name)))
    return "  \(symbol)  \(name)\(pad)\(outcome.summary)"
}

func reportJSON(_ report: EndpointReport) -> [String: Any] {
    var capabilities: [String: String] = [:]
    for (capability, level) in report.capabilityMatrix { capabilities[capability.rawValue] = level.rawValue }
    var outcomes: [[String: Any]] = []
    for outcome in report.outcomes {
        var entry: [String: Any] = [
            "kind": outcome.kind.rawValue,
            "status": outcome.status.rawValue,
            "summary": outcome.summary,
            "duration_ms": (outcome.durationMS * 10).rounded() / 10,
            "input_tokens": outcome.metrics.inputTokens,
            "output_tokens": outcome.metrics.outputTokens,
        ]
        if let ttft = outcome.metrics.timeToFirstTokenMS { entry["ttft_ms"] = (ttft * 10).rounded() / 10 }
        if let speed = outcome.metrics.outputTokensPerSecond { entry["output_tokens_per_second"] = (speed * 10).rounded() / 10 }
        if let failure = outcome.failure {
            entry["failure_category"] = failure.category.rawValue
            if let status = failure.httpStatus { entry["http_status"] = status }
            entry["failure_message"] = failure.message
        }
        outcomes.append(entry)
    }
    let metrics = report.totalMetrics
    return [
        "endpoint": endpointJSON(report.endpoint),
        "verdict": report.verdict.rawValue,
        "started_at": ISO8601DateFormatter().string(from: report.startedAt),
        "duration_ms": (report.durationMS * 10).rounded() / 10,
        "tokens": [
            "input": metrics.inputTokens,
            "output": metrics.outputTokens,
            "total": metrics.totalTokens,
        ],
        "capabilities": capabilities,
        "outcomes": outcomes,
    ]
}

func printReport(_ report: EndpointReport, json: Bool) {
    if json {
        print(jsonString(reportJSON(report)))
        return
    }
    print("")
    print("\(report.endpoint.name)")
    print("  \(report.endpoint.wireAPI.localizedName) · \(report.endpoint.baseURL) · \(report.endpoint.model)")
    if let origin = report.endpoint.origin { print("  from \(origin.shortDescription)") }
    print("")
    for outcome in report.outcomes { print(outcomeLine(outcome)) }
    print("")
    let metrics = report.totalMetrics
    var parts: [String] = [report.verdict.localizedName]
    parts.append("\(Int(report.durationMS)) ms")
    parts.append("\(metrics.totalTokens) tokens")
    if let ttft = metrics.timeToFirstTokenMS { parts.append("TTFT \(Int(ttft)) ms") }
    if let speed = metrics.outputTokensPerSecond { parts.append(String(format: "%.1f tok/s", speed)) }
    print("  " + L10n.pick(zh: "结论：", en: "Verdict: ") + parts.joined(separator: " · "))

    let supported = report.capabilityEvidence.filter { $0.level == .supported }.map { $0.capability.localizedName }
    let unsupported = report.capabilityEvidence.filter { $0.level == .unsupported }.map { $0.capability.localizedName }
    if !supported.isEmpty {
        print("  " + L10n.pick(zh: "支持：", en: "Supported:   ") + supported.joined(separator: ", "))
    }
    if !unsupported.isEmpty {
        print("  " + L10n.pick(zh: "不支持：", en: "Not supported: ") + unsupported.joined(separator: ", "))
    }
    print("")
}

// MARK: - Commands

let options = Options(arguments)
let command = arguments.first(where: { !$0.hasPrefix("--") }) ?? "help"
pinEnglishOutput()

switch command {
case "help", "-h", "--help":
    printUsage()

case "version", "--version":
    print("LLMProbe \(LLMProbeVersion.short)")

case "list-sources":
    for source in ConfigDiscovery.knownSources() {
        let present = source.path == "process environment" || source.path == "127.0.0.1" || PathTools.isReadableFile(source.path)
        let mark = present ? "found" : "—"
        print(String(format: "%-22s %-8s %@", (source.name as NSString).utf8String!, (mark as NSString).utf8String!, PathTools.abbreviate(source.path)))
    }

case "selftest":
    // Verifies the offline half of the engine (parsing, redaction, budgeting,
    // error classification). No network, no credentials, nothing leaves the Mac.
    let report = SelfTest.run()
    if options.has("json") {
        let failures = report.failures.map { ["check": $0.check, "detail": $0.detail] }
        print(jsonString([
            "passed": report.passed,
            "checks_run": report.checksRun,
            "failures": failures,
            "duration_ms": (report.durationMS * 100).rounded() / 100,
        ]))
    } else {
        for failure in report.failures {
            print("FAIL  \(failure.check)\n      \(failure.detail)")
        }
        let status = report.passed ? "passed" : "failed"
        print("selftest \(status): \(report.checksRun - report.failures.count)/\(report.checksRun) checks in \(Int(report.durationMS)) ms")
    }
    exit(report.passed ? 0 : 1)

case "discover":
    let result = await ConfigDiscovery.scan(
        includeLocalServers: !options.has("no-local"),
        includeEnvironment: !options.has("no-env")
    )
    if options.has("json") {
        print(jsonString([
            "endpoints": result.endpoints.map(endpointJSON),
            "sources": result.sources.map { source in
                [
                    "id": source.id,
                    "name": source.name,
                    "path": source.abbreviatedPath,
                    "status": source.status.rawValue,
                    "endpoints": source.endpointCount,
                    "message": source.message ?? "",
                ] as [String: Any]
            },
        ]))
        break
    }

    print("")
    print(L10n.pick(zh: "检测到的 Agent 配置", en: "Detected agent configurations"))
    print("")
    for source in result.sources {
        let status = source.status.localizedName
        let path = source.abbreviatedPath
        var line = "  \(source.name.padding(toLength: 22, withPad: " ", startingAt: 0))\(status.padding(toLength: 14, withPad: " ", startingAt: 0))\(source.endpointCount) " + L10n.pick(zh: "个端点", en: "endpoint(s)")
        if source.status == .notFound { line += "   \(path)" } else { line += "   \(path)" }
        print(line)
        if let message = source.message, source.status != .notFound { print("      \(message)") }
    }

    print("")
    print(L10n.pick(zh: "端点（\(result.endpoints.count)）", en: "Endpoints (\(result.endpoints.count))"))
    print("")
    let header = L10n.pick(zh: "  #   厂商               协议        模型                               Base URL", en: "  #   provider           wire        model                              base URL")
    print(header)
    for (index, endpoint) in result.endpoints.enumerated() {
        let provider = endpoint.provider.localizedName.padding(toLength: 17, withPad: " ", startingAt: 0)
        let wire = endpoint.wireAPI.localizedShortName.padding(toLength: 12, withPad: " ", startingAt: 0)
        let model = String(endpoint.model.prefix(32)).padding(toLength: 35, withPad: " ", startingAt: 0)
        print("  \(String(format: "%-3d", index)) \(provider)\(wire)\(model)\(endpoint.baseURL)")
    }
    print("")
    print(L10n.pick(zh: "运行 `llmprobe probe --index <n> --plan quick` 测试其中一个。", en: "Run `llmprobe probe --index <n> --plan quick` to test one."))
    print("")

case "import":
    // Persists everything discovery finds into the same state file the app uses,
    // so the GUI opens with the machine's real configuration already loaded.
    let result = await ConfigDiscovery.scan(
        includeLocalServers: !options.has("no-local"),
        includeEnvironment: !options.has("no-env")
    )
    var state = EndpointStoreFile.load()
    var byKey: [String: Int] = [:]
    for (index, endpoint) in state.endpoints.enumerated() { byKey[endpoint.dedupeKey] = index }
    var added = 0
    for endpoint in result.endpoints where byKey[endpoint.dedupeKey] == nil {
        byKey[endpoint.dedupeKey] = state.endpoints.count
        state.endpoints.append(endpoint)
        added += 1
    }
    state.lastDiscovery = Date()
    if state.selectedID == nil { state.selectedID = state.endpoints.first?.id }
    let saved = EndpointStoreFile.save(state)
    print("Imported \(added) new endpoint(s); \(state.endpoints.count) total.")
    print("State file: \(PathTools.abbreviate(EndpointStoreFile.stateURL.path))")
    exit(saved ? 0 : 2)

case "probe":
    let selectedPlan = plan(from: options)
    var state = EndpointStoreFile.load()
    var targets: [ProbeEndpoint] = []

    if let url = options.value("url") {
        guard let model = options.value("model"), !model.isEmpty else { fail("--url requires --model") }
        let provider = ProviderInference.kind(from: url, baseURL: url)
        let resolvedWire = wireAPI(from: options.value("wire")) ?? ProviderInference.wireAPI(hint: nil, provider: provider, baseURL: url)
        var secret: SecretSource = .none
        if let envName = options.value("key-env") { secret = .environment(envName) }
        else if let key = options.value("key") { secret = .inline(key) }
        var auth = AuthConfig(style: .bearer, secret: secret)
        if resolvedWire == .anthropicMessages {
            auth.style = .header
            auth.headerName = "x-api-key"
        } else if resolvedWire == .googleGemini {
            auth.style = .header
            auth.headerName = "x-goog-api-key"
        }
        targets = [ProbeEndpoint(
            name: options.value("name") ?? "\(provider.displayName) · \(model)",
            provider: provider,
            wireAPI: resolvedWire,
            baseURL: url,
            model: model,
            auth: auth,
            tags: [L10n.pick(zh: "CLI 导入", en: "CLI import")]
        )]
    } else {
        let discovery = await ConfigDiscovery.scan()
        if options.has("all") {
            targets = discovery.endpoints
        } else if let index = options.int("index") {
            guard index >= 0, index < discovery.endpoints.count else { fail("Index \(index) is out of range (0..<\(discovery.endpoints.count))") }
            targets = [discovery.endpoints[index]]
        } else if let id = options.value("id"), let uuid = UUID(uuidString: id) {
            guard let match = discovery.endpoints.first(where: { $0.id == uuid }) ?? state.endpoints.first(where: { $0.id == uuid }) else {
                fail("No endpoint with id \(id)")
            }
            targets = [match]
        } else {
            fail("Specify --index <n>, --all, --id <uuid>, or --url with --model. Run `llmprobe discover` first.")
        }
    }

    // `--all --json` has to stay parseable, so every report is collected and
    // printed as a single document instead of one JSON object per endpoint.
    let json = options.has("json")
    var collected: [EndpointReport] = []
    var worst = HealthVerdict.healthy
    for target in targets {
        let engine = ProbeEngine()
        let report = await engine.run(endpoint: target, plan: selectedPlan, cache: state.cache)
        if json && targets.count > 1 {
            collected.append(report)
        } else {
            printReport(report, json: json)
        }
        state.cache.store(report)
        // Keep the worst verdict so a batch exit code still means something.
        if severity(report.verdict) > severity(worst) { worst = report.verdict }
        if options.has("save") {
            if !state.endpoints.contains(where: { $0.dedupeKey == target.dedupeKey }) {
                state.endpoints.append(target)
            }
        }
    }
    if json && targets.count > 1 {
        let payload: [String: Any] = [
            "verdict": worst.rawValue,
            "count": collected.count,
            "reports": collected.map { reportJSON($0) },
        ]
        print(jsonString(payload))
    }
    if options.has("save") {
        state.lastDiscovery = Date()
        _ = EndpointStoreFile.save(state)
    }
    switch worst {
    case .healthy: exit(0)
    case .degraded, .unhealthy: exit(1)
    case .unknown: exit(1)
    }

default:
    printUsage()
    exit(2)
}
