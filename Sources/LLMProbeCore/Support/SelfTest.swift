import Foundation

/// One failed check produced by ``SelfTest``.
public struct SelfTestFailure: Sendable, Hashable {
    /// Stable identifier of the check that failed.
    public var check: String
    /// Human readable explanation of the mismatch.
    public var detail: String

    public init(check: String, detail: String) {
        self.check = check
        self.detail = detail
    }
}

/// Offline self check for the parsing and classification layers.
///
/// The probe engine leans on a handful of pure functions that are easy to get
/// subtly wrong: TOML parsing, SSE framing, secret redaction, token budgeting
/// and the error classifier that turns an HTTP failure into capability
/// evidence. Those functions are covered here so the tool can verify itself
/// without a network, without credentials and without an Xcode installation:
///
///     swift run llmprobe selftest
///
/// The same routine is called from `Tests/LLMProbeCoreTests` when a full
/// toolchain with XCTest is available.
public enum SelfTest {
    public struct Report: Sendable {
        public var checksRun: Int
        public var failures: [SelfTestFailure]
        public var durationMS: Double

        public var passed: Bool { failures.isEmpty }
    }

    /// Runs every check and reports all failures instead of stopping at the first.
    public static func run() -> Report {
        let started = Date()
        var checksRun = 0
        var failures: [SelfTestFailure] = []

        for check in allChecks {
            checksRun += 1
            if let detail = check.body() {
                failures.append(SelfTestFailure(check: check.name, detail: detail))
            }
        }

        return Report(
            checksRun: checksRun,
            failures: failures,
            durationMS: Date().timeIntervalSince(started) * 1000
        )
    }

    struct Check {
        var name: String
        var body: () -> String?
    }

    static let allChecks: [Check] = [
        Check(name: "redactor.mask-keeps-shape") {
            let masked = Redactor.mask("sk-abcdefghijklmnop")
            if masked.contains("efghijkl") { return "the middle of the secret survived: \(masked)" }
            if !masked.contains("…") { return "expected an ellipsis marker, got \(masked)" }
            if Redactor.mask("") != "—" { return "an empty secret should render as an em dash" }
            return nil
        },
        Check(name: "redactor.scrubs-bearer-token") {
            let scrubbed = Redactor.scrub("Authorization: Bearer abcdefghijklmnopqrst\n")
            if scrubbed.contains("abcdefghijklmnopqrst") { return "the bearer token leaked: \(scrubbed)" }
            return nil
        },
        Check(name: "redactor.scrubs-labelled-key") {
            let scrubbed = Redactor.scrub("{\"api_key\":\"sk-verysecretvalue123\"}")
            if scrubbed.contains("verysecretvalue") { return "the labelled api key leaked: \(scrubbed)" }
            return nil
        },
        Check(name: "redactor.scrubs-known-secret") {
            let secret = "totally-custom-secret-value"
            let scrubbed = Redactor.scrub("token=\(secret) done", knownSecrets: [secret])
            if scrubbed.contains(secret) { return "the known secret leaked: \(scrubbed)" }
            return nil
        },
        Check(name: "redactor.masks-auth-headers") {
            let safe = Redactor.safeHeaders([
                "Authorization": "Bearer supersecrettoken",
                "x-api-key": "another-secret",
                "content-type": "application/json",
            ])
            if safe["Authorization"]?.contains("supersecrettoken") == true { return "the authorization header leaked" }
            if safe["x-api-key"]?.contains("another-secret") == true { return "the x-api-key header leaked" }
            if safe["content-type"] != "application/json" { return "content-type should pass through untouched" }
            return nil
        },
        Check(name: "tokens.latin-granularity") {
            let estimate = TokenEstimator.estimate("The quick brown fox jumps over the lazy dog")
            if estimate < 5 || estimate > 20 { return "expected 5...20 tokens, got \(estimate)" }
            return nil
        },
        Check(name: "tokens.cjk-one-per-character") {
            let estimate = TokenEstimator.estimate(String(repeating: "上", count: 100))
            if estimate < 95 || estimate > 105 { return "expected about 100 tokens, got \(estimate)" }
            return nil
        },
        Check(name: "tokens.filler-matches-request") {
            let filler = TokenEstimator.filler(tokens: 400)
            let estimate = TokenEstimator.estimate(filler)
            if Double(estimate) < 400 * 0.7 || Double(estimate) > 400 * 1.3 {
                return "a filler of 400 tokens was estimated at \(estimate)"
            }
            return nil
        },
        Check(name: "version.is-set") {
            if LLMProbeVersion.short.isEmpty { return "the version string is empty" }
            return nil
        },
        Check(name: "toml.tables-dotted-keys-arrays") {
            let sample = """
            # a comment with a "quoted hash" inside
            model = "gpt-4o-mini"          # trailing comment
            approval_policy = 'on-request'
            enabled = true
            retries = 3
            window = 128000
            tags = ["alpha", "beta"]
            limits = { context = 200000, output = 8192 }

            [model_providers.gateway]
            name = "gateway"
            base_url = "http://127.0.0.1:9999/v1"
            wire_api = "responses"
            """
            let parsed = MiniTOML.parse(sample)
            if parsed["model"] as? String != "gpt-4o-mini" { return "the model string was not parsed" }
            if parsed["approval_policy"] as? String != "on-request" { return "the literal string was not parsed" }
            if parsed["enabled"] as? Bool != true { return "the boolean was not parsed" }
            if parsed["retries"] as? Int != 3 { return "the integer was not parsed" }
            if parsed["window"] as? Int != 128_000 { return "the large integer was not parsed" }
            guard let tags = parsed["tags"] as? [Any], tags.count == 2 else { return "the array was not parsed" }
            guard let limits = parsed["limits"] as? [String: Any] else { return "the inline table was not parsed" }
            if limits["output"] as? Int != 8192 { return "the inline table integer was not parsed" }
            guard let providers = parsed["model_providers"] as? [String: Any],
                  let gateway = providers["gateway"] as? [String: Any] else { return "the nested table was not parsed" }
            if gateway["base_url"] as? String != "http://127.0.0.1:9999/v1" { return "the nested base_url was not parsed" }
            return nil
        },
        Check(name: "toml.hash-inside-string-is-kept") {
            let parsed = MiniTOML.parse(#"token = "abc#def" # trailing comment"#)
            if parsed["token"] as? String != "abc#def" { return "a hash inside a string was treated as a comment" }
            return nil
        },
        Check(name: "sse.reassembles-split-frames") {
            var decoder = SSEDecoder()
            let firstChunk = #"data: {"choices":["#
            if !decoder.ingest(Data(firstChunk.utf8)).isEmpty { return "a premature event was emitted" }
            let secondChunk = "{\"delta\":\"hi\"}]}\n\ndata: next\n\n"
            let events = decoder.ingest(Data(secondChunk.utf8))
            if events.count != 2 { return "expected 2 events, got \(events.count)" }
            if events[0].data != #"{"choices":[{"delta":"hi"}]}"# { return "the frame was not reassembled: \(events[0].data)" }
            if events[1].data != "next" { return "the second frame is wrong: \(events[1].data)" }
            return nil
        },
        Check(name: "sse.done-and-comments") {
            var decoder = SSEDecoder()
            let events = decoder.ingest(Data(": keep-alive\ndata: [DONE]\n\n".utf8))
            if events.count != 1 { return "expected 1 event, got \(events.count)" }
            if !events[0].isDone { return "the [DONE] sentinel was not detected" }
            return nil
        },
        Check(name: "sse.joins-multi-line-data") {
            var decoder = SSEDecoder()
            let events = decoder.ingest(Data("data: line one\ndata: line two\n\n".utf8))
            if events.first?.data != "line one\nline two" { return "multi-line data was not joined with a newline" }
            return nil
        },
        Check(name: "endpoint.dedupe-normalises-v1-suffix") {
            let first = ProbeEndpoint(name: "a", baseURL: "http://127.0.0.1:9999", model: "demo-1")
            let second = ProbeEndpoint(name: "b", baseURL: "http://127.0.0.1:9999/v1/", model: "demo-1")
            if first.dedupeKey != second.dedupeKey { return "the /v1 suffix was not normalised away" }
            let merged = DiscoveryResult.dedupe([first, second])
            if merged.count != 1 { return "expected one merged endpoint, got \(merged.count)" }
            return nil
        },
        Check(name: "endpoint.dedupe-prefers-credentialed-entry") {
            let bare = ProbeEndpoint(name: "config", baseURL: "http://example.test/v1", model: "m")
            var rich = ProbeEndpoint(
                name: "cc-switch",
                baseURL: "http://example.test/v1",
                model: "m",
                auth: AuthConfig(style: .bearer, secret: .inline("discovered"))
            )
            rich.declaredContextWindow = 200_000
            let merged = DiscoveryResult.dedupe([bare, rich])
            guard let only = merged.first else { return "dedupe returned nothing" }
            if only.auth.secret.isNone { return "the credentialed entry should have won" }
            if only.declaredContextWindow != 200_000 { return "the declared context window was dropped" }
            return nil
        },
        Check(name: "endpoint.local-host-detection") {
            if !ProbeEndpoint(name: "l", baseURL: "http://127.0.0.1:1234/v1", model: "m").isLocalHost {
                return "127.0.0.1 should count as local"
            }
            if !ProbeEndpoint(name: "l", baseURL: "http://localhost:11434", model: "m").isLocalHost {
                return "localhost should count as local"
            }
            if ProbeEndpoint(name: "r", baseURL: "https://api.example.com/v1", model: "m").isLocalHost {
                return "a public host must not be reported as local"
            }
            return nil
        },
        Check(name: "inference.wire-api-and-provider") {
            if ProviderInference.wireAPI(hint: nil, provider: .anthropic, baseURL: "https://api.anthropic.com/v1") != .anthropicMessages {
                return "anthropic should map to the Messages API"
            }
            if ProviderInference.wireAPI(hint: nil, provider: .google, baseURL: "https://generativelanguage.googleapis.com/v1beta") != .googleGemini {
                return "the generativelanguage host should map to generateContent"
            }
            if ProviderInference.wireAPI(hint: nil, provider: .custom, baseURL: "http://127.0.0.1:9999/v1") != .openAIChat {
                return "unknown hosts should fall back to Chat Completions"
            }
            if ProviderInference.wireAPI(hint: "responses", provider: .custom, baseURL: nil) != .openAIResponses {
                return "an explicit hint should win"
            }
            if ProviderInference.kind(from: "moonshot", baseURL: nil) != .moonshot { return "moonshot was not inferred" }
            if ProviderInference.kind(from: "unknown-id", baseURL: "https://openrouter.ai/api/v1") != .openrouter {
                return "openrouter was not inferred from the base URL"
            }
            return nil
        },
        Check(name: "classifier.treats-max-tokens-400-as-evidence") {
            let body = Data("{\"error\":{\"message\":\"max_tokens is too large: 999999. This model supports at most 8192 completion tokens.\",\"type\":\"invalid_request_error\"}}".utf8)
            let classified = ErrorClassifier.classify(status: 400, body: body)
            if !classified.isValidationOnly { return "a parameter range error should be validation-only" }
            if classified.extractedLimit != 8192 { return "expected 8192, got \(String(describing: classified.extractedLimit))" }
            if classified.extractedLimitKind != .maxOutputTokens { return "the limit was not classified as max output" }
            return nil
        },
        Check(name: "classifier.extracts-context-window") {
            let body = Data("{\"error\":{\"message\":\"This model's maximum context length is 32768 tokens.\",\"type\":\"invalid_request_error\"}}".utf8)
            let classified = ErrorClassifier.classify(status: 400, body: body)
            if classified.failure.category != .contextOverflow { return "expected a context overflow category" }
            if classified.extractedLimit != 32768 { return "expected 32768, got \(String(describing: classified.extractedLimit))" }
            return nil
        },
        Check(name: "classifier.maps-http-status") {
            if ErrorClassifier.classify(status: 401, body: Data("{}".utf8)).failure.category != .authentication {
                return "401 should map to authentication"
            }
            if ErrorClassifier.classify(status: 404, body: Data("{}".utf8)).failure.category != .modelNotFound {
                return "404 should map to model not found"
            }
            if ErrorClassifier.classify(status: 429, body: Data("{}".utf8)).failure.category != .rateLimited {
                return "429 should map to rate limited"
            }
            if ErrorClassifier.classify(status: 503, body: Data("{}".utf8)).failure.category != .serverError {
                return "503 should map to a server error"
            }
            return nil
        },
        Check(name: "plans.free-spends-no-completion-tokens") {
            let free = ProbePlan.free
            if free.enableContextSearch { return "the free plan must not run the payload search" }
            for kind in free.kinds where kind.estimatedOutputTokens > 0 {
                return "the free plan includes \(kind.rawValue), which bills completion tokens"
            }
            if free.estimatedTokens != 0 { return "expected a zero-token estimate, got \(free.estimatedTokens)" }
            return nil
        },
        Check(name: "plans.quick-stays-cheap") {
            if ProbePlan.quick.estimatedTokens > 600 { return "the quick plan grew past its budget" }
            if ProbePlan.quick.enableContextSearch { return "the quick plan must not spend input tokens on the payload search" }
            if !ProbePlan.deep.enableContextSearch { return "the deep plan should include the payload search" }
            return nil
        },
        Check(name: "cache.prefers-live-evidence") {
            let endpoint = ProbeEndpoint(name: "e", baseURL: "http://127.0.0.1:9999/v1", model: "m")
            let report = EndpointReport(
                endpoint: endpoint,
                startedAt: Date(),
                finishedAt: Date(),
                verdict: .healthy,
                outcomes: [],
                capabilityMatrix: [.tools: .supported],
                capabilityEvidence: [CapabilityFinding(capability: .tools, level: .supported, evidence: .liveProbe)]
            )
            var cache = CapabilityCache(entries: [
                CapabilityCache.key(for: endpoint): [
                    .tools: CapabilityFinding(capability: .tools, level: .unsupported, evidence: .heuristic)
                ]
            ])
            cache.store(report)
            let finding = cache.findings(for: endpoint)[.tools]
            if finding?.level != .supported { return "live evidence failed to replace the cached guess" }
            if finding?.evidence != .liveProbe { return "expected live-probe evidence to be recorded" }
            return nil
        },
        Check(name: "state.round-trips-through-json") {
            let endpoint = ProbeEndpoint(
                name: "round trip",
                provider: .custom,
                wireAPI: .openAIChat,
                baseURL: "http://127.0.0.1:9999/v1",
                model: "demo",
                auth: AuthConfig(style: .bearer, secret: .inline("not-a-real-key")),
                declaredContextWindow: 65_536
            )
            let state = AppState(endpoints: [endpoint], selectedID: endpoint.id, autoRunOnLaunch: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? encoder.encode(state),
                  let restored = try? decoder.decode(AppState.self, from: data) else {
                return "the state file failed to encode or decode"
            }
            if restored.endpoints.first?.declaredContextWindow != 65_536 { return "fields were lost in the round trip" }
            if restored.autoRunOnLaunch != true { return "preferences were lost in the round trip" }
            return nil
        },
        Check(name: "capability.every-entry-has-a-modality-bucket") {
            var missing: [String] = []
            for capability in Capability.allCases where capability.modalityBucket == nil {
                missing.append(capability.rawValue)
            }
            if !missing.isEmpty { return "capabilities without a modality bucket: \(missing.joined(separator: ", "))" }
            return nil
        },
        Check(name: "localization.switches-between-chinese-and-english") {
            let original = LanguageSettings.shared.preference
            defer { LanguageSettings.shared.apply(original, persist: false) }

            LanguageSettings.shared.apply(.english, persist: false)
            if L10n.t("中文", "English") != "English" { return "the English branch was not selected" }
            if Capability.tools.localizedName != "Tool calling" { return "expected the English capability name, got \(Capability.tools.localizedName)" }
            if HealthVerdict.healthy.localizedName != "Healthy" { return "the verdict name did not follow the language" }

            LanguageSettings.shared.apply(.chinese, persist: false)
            if L10n.t("中文", "English") != "中文" { return "the Chinese branch was not selected" }
            if Capability.tools.localizedName != "工具调用" { return "expected the Chinese capability name, got \(Capability.tools.localizedName)" }
            if HealthVerdict.healthy.localizedName != "健康" { return "the Chinese verdict name was not applied" }
            if ProviderKind.custom.localizedName != "自定义" { return "the Chinese vendor name was not applied" }
            return nil
        },
        Check(name: "localization.covers-every-enum-entry") {
            var missing: [String] = []
            for capability in Capability.allCases where capability.localizedName.isEmpty { missing.append("capability:\(capability.rawValue)") }
            for kind in ProbeKind.allCases where kind.localizedName.isEmpty { missing.append("probe:\(kind.rawValue)") }
            for level in SupportLevel.allCases where level.localizedName.isEmpty { missing.append("support:\(level.rawValue)") }
            for verdict in [HealthVerdict.healthy, .degraded, .unhealthy, .unknown] where verdict.localizedName.isEmpty {
                missing.append("verdict:\(verdict.rawValue)")
            }
            for provider in ProviderKind.allCases where provider.localizedName.isEmpty { missing.append("provider:\(provider.rawValue)") }
            for api in WireAPI.allCases where api.localizedName.isEmpty || api.localizedShortName.isEmpty { missing.append("wire:\(api.rawValue)") }
            for status in [ProbeStatus.passed, .warning, .failed, .unsupported, .skipped] where status.localizedName.isEmpty { missing.append("status:\(status.rawValue)") }
            for bucket in ModalityBucket.allCases where bucket.localizedName.isEmpty { missing.append("modality:\(bucket.rawValue)") }
            if !missing.isEmpty { return "missing names: \(missing.joined(separator: ", "))" }
            return nil
        },
        Check(name: "localization.transport-messages-follow-the-language") {
            let original = LanguageSettings.shared.preference
            defer { LanguageSettings.shared.apply(original, persist: false) }

            // Foundation localises `URLError.localizedDescription` with the system
            // language, so a report rendered in the other language used to mix
            // two languages in one line.
            LanguageSettings.shared.apply(.chinese, persist: false)
            let chinese = transportMessage(for: URLError(.cannotConnectToHost))
            LanguageSettings.shared.apply(.english, persist: false)
            let english = transportMessage(for: URLError(.cannotConnectToHost))
            if chinese == english { return "the transport message ignored the language" }
            if chinese.contains("Could not") { return "the Chinese transport message leaked the system string" }
            if !english.contains("connect") { return "unexpected English transport message: \(english)" }
            if ProbeFailure.Category.network.localizedHint != ProbeFailure.Category.network.hint {
                return "the English hint should be the canonical one"
            }
            LanguageSettings.shared.apply(.chinese, persist: false)
            if ProbeFailure.Category.network.localizedHint.isEmpty { return "the Chinese failure hint is missing" }
            if ProbeFailure.Category.network.localizedHint.contains("Could not") {
                return "the English hint leaked into the Chinese interface"
            }
            return nil
        },
        Check(name: "localization.parses-launch-argument") {
            if AppLanguage(commandLineValue: "zh") != .chinese { return "zh was not parsed" }
            if AppLanguage(commandLineValue: "zh-Hans") != .chinese { return "zh-Hans was not parsed" }
            if AppLanguage(commandLineValue: "EN") != .english { return "EN was not parsed" }
            if AppLanguage(commandLineValue: "system") != .system { return "system was not parsed" }
            if AppLanguage(commandLineValue: "klingon") != nil { return "an unknown language should not parse" }
            return nil
        },
        Check(name: "localization.follows-the-system-language") {
            // The rule the product promises: a Chinese Mac is Chinese, an
            // English Mac is English, and anything else falls back to English
            // because those are the only two translations that ship.
            let cases: [(list: [String], expected: ResolvedLanguage)] = [
                (["zh-Hans-CN", "en-US"], .chinese),
                (["zh-Hant-TW"], .chinese),
                (["en-GB", "zh-Hans-CN"], .english),
                (["ja-JP", "en-US"], .english),
                (["ja-JP"], .english),
                (["de-DE"], .english),
                (["ko-KR", "zh-Hans"], .chinese),
                ([], .english),
            ]
            for item in cases {
                let resolved = LanguageSettings.resolve(.system, preferredLanguages: item.list)
                if resolved != item.expected {
                    return "\(item.list) resolved to \(resolved.rawValue), expected \(item.expected.rawValue)"
                }
            }
            // An explicit choice always beats the system list.
            if LanguageSettings.resolve(.chinese, preferredLanguages: ["en-US"]) != .chinese {
                return "an explicit Chinese choice was overridden by the system list"
            }
            if LanguageSettings.resolve(.english, preferredLanguages: ["zh-Hans-CN"]) != .english {
                return "an explicit English choice was overridden by the system list"
            }
            return nil
        },
        Check(name: "appearance.parses-launch-argument") {
            if AppAppearance(commandLineValue: "light") != .light { return "light was not parsed" }
            if AppAppearance(commandLineValue: "DARK") != .dark { return "DARK was not parsed" }
            if AppAppearance(commandLineValue: "darkAqua") != .dark { return "darkAqua was not parsed" }
            if AppAppearance(commandLineValue: "system") != .system { return "system was not parsed" }
            if AppAppearance(commandLineValue: "auto") != .system { return "auto was not parsed" }
            if AppAppearance(commandLineValue: "solarized") != nil { return "an unknown appearance should not parse" }
            return nil
        },
        Check(name: "appearance.resolves-the-preference") {
            // The rule the screenshots and the picker both rely on: an explicit
            // choice always wins, and `system` follows the Mac.
            if AppearanceSettings.resolve(.light, systemIsDark: true) != .light {
                return "an explicit light choice was overridden by a dark Mac"
            }
            if AppearanceSettings.resolve(.dark, systemIsDark: false) != .dark {
                return "an explicit dark choice was overridden by a light Mac"
            }
            if AppearanceSettings.resolve(.system, systemIsDark: true) != .dark {
                return "a dark Mac did not resolve to dark"
            }
            if AppearanceSettings.resolve(.system, systemIsDark: false) != .light {
                return "a light Mac did not resolve to light"
            }
            if ResolvedAppearance.dark.isDark != true || ResolvedAppearance.light.isDark != false {
                return "isDark does not follow the resolved appearance"
            }
            if LaunchOptions(arguments: ["--appearance", "dark"]).appearance != .dark {
                return "--appearance dark did not reach the launch options"
            }
            if LaunchOptions(arguments: ["--appearance", "nocturnal"]).appearance != nil {
                return "an unknown --appearance value should be ignored"
            }
            for appearance in AppAppearance.allCases where appearance.displayName.isEmpty {
                return "appearance '\(appearance.rawValue)' has no display name"
            }
            return nil
        },
        Check(name: "cli.prints-english-only") {
            // The macOS app is bilingual, the CLI is not: the engine renders its
            // summaries through `L10n`, so the CLI pins the language once at
            // start-up and every report follows.
            let original = LanguageSettings.shared.preference
            defer { LanguageSettings.shared.apply(original, persist: false) }

            LanguageSettings.shared.apply(.chinese, persist: false)
            LanguageSettings.shared.pinCommandLineLanguage()
            if L10n.isChinese { return "the CLI is not pinned to English" }
            if L10n.t("中文", "English") != "English" { return "CLI strings are not English" }
            if ProbeStatus.passed.localizedName != "Passed" { return "CLI probe status is not English" }
            if Capability.tools.localizedName != "Tool calling" { return "CLI capability names are not English" }
            return nil
        },
        Check(name: "jsonc.strips-comments-and-trailing-commas") {
            let parsed = MiniJSONC.parse("""
            {
              // line comment
              "provider": {
                /* block comment */
                "baseUrl": "https://api.example.com/v1",
                "models": ["alpha", "beta",],
              },
            }
            """)
            let provider = parsed?["provider"] as? [String: Any]
            let models = provider?["models"] as? [String]
            if provider?["baseUrl"] as? String != "https://api.example.com/v1" { return "the JSONC field was not parsed" }
            if models != ["alpha", "beta"] { return "trailing commas or arrays were parsed incorrectly" }
            return nil
        },
        Check(name: "yaml.parses-nested-provider-sequence") {
            let parsed = MiniYAML.parse("""
            plugins:
              - id: llm-provider
                config:
                  providers:
                    acme:
                      api: openai-completions
                      baseURL: https://api.example.com/v1
                      apiKeyEnv: ACME_API_KEY
                      models:
                        - id: alpha
                        - id: beta
            """)
            let plugins = parsed?["plugins"] as? [Any]
            let first = plugins?.first as? [String: Any]
            let config = first?["config"] as? [String: Any]
            let providers = config?["providers"] as? [String: Any]
            let acme = providers?["acme"] as? [String: Any]
            let models = acme?["models"] as? [Any]
            if acme?["baseURL"] as? String != "https://api.example.com/v1" { return "nested YAML mapping was lost" }
            if models?.count != 2 { return "nested YAML sequence was parsed incorrectly" }
            return nil
        },
        Check(name: "yaml.top-level-sequence-is-wrapped-for-extraction") {
            let root = ConfigDecoding.dictionary(
                text: """
                - id: provider-plugin
                  config:
                    providers:
                      acme:
                        api: openai-completions
                        baseURL: https://api.example.com/v1
                        models:
                          - id: alpha
                """,
                path: "/tmp/profile.patch.yml"
            )
            let endpoints = AgentConfigExtractor.endpoints(
                root: root ?? [:],
                context: AgentConfigExtractor.EndpointContext(
                    sourceID: "fixture",
                    displayName: "Fixture",
                    path: "/tmp/profile.patch.yml",
                    includeFlatEndpoint: false,
                    environment: [:]
                )
            )
            if endpoints.count != 1 { return "top-level YAML sequence was not extracted" }
            if endpoints.first?.knownModels != ["alpha"] { return "sequence provider models were lost" }
            return nil
        },
        Check(name: "yaml.indentless-sequence-belongs-to-mapping-key") {
            let parsed = MiniYAML.parse("""
            custom_providers:
            - api: openai-completions
              base_url: https://api.example.com/v1
              model: alpha
            - api: anthropic-messages
              base_url: https://api.example.com/v1
              model: beta
            top_level: value
            """)
            let providers = parsed?["custom_providers"] as? [Any]
            let first = providers?.first as? [String: Any]
            if providers?.count != 2 { return "indentless sequence was not attached to its mapping key" }
            if first?["base_url"] as? String != "https://api.example.com/v1" { return "sequence item mapping was lost" }
            if parsed?["top_level"] as? String != "value" { return "mapping parsing did not resume after the sequence" }
            return nil
        },
        Check(name: "agent-config.extractor-builds-provider-endpoints") {
            let root: [String: Any] = [
                "model": [
                    "providers": [
                        "acme": [
                            "api": "openai-completions",
                            "baseURL": "https://api.example.com/v1",
                            "apiKeyEnv": "ACME_API_KEY",
                            "models": [["id": "alpha"], ["id": "beta"]]
                        ]
                    ]
                ]
            ]
            let endpoints = AgentConfigExtractor.endpoints(
                root: root,
                context: AgentConfigExtractor.EndpointContext(
                    sourceID: "fixture",
                    displayName: "Fixture",
                    path: "/tmp/fixture.json",
                    includeFlatEndpoint: false
                )
            )
            guard let endpoint = endpoints.first else { return "no endpoint was extracted" }
            if endpoint.wireAPI != .openAIChat { return "the API hint was not mapped" }
            if endpoint.knownModels != ["alpha", "beta"] { return "provider models were not preserved" }
            if endpoint.auth.secret.label != "$ACME_API_KEY" { return "the environment credential reference was lost" }
            return nil
        },
        Check(name: "agent-config.extractor-does-not-infer-vendor-from-model-id") {
            let root: [String: Any] = [
                "providers": [
                    "custom": [
                        "api": "openai-completions",
                        "baseURL": "https://gateway.example/v1",
                        "models": [["id": "claude-looking-model-name"]]
                    ]
                ]
            ]
            let endpoints = AgentConfigExtractor.endpoints(
                root: root,
                context: AgentConfigExtractor.EndpointContext(
                    sourceID: "fixture",
                    displayName: "Fixture",
                    path: "/tmp/fixture.json",
                    includeFlatEndpoint: false,
                    environment: [:]
                )
            )
            if endpoints.first?.provider != .custom { return "the model id incorrectly selected a vendor" }
            return nil
        },
        Check(name: "provider-inference.recognizes-added-vendors-and-wires") {
            if ProviderInference.kind(from: "minimax", baseURL: nil) != .minimax { return "MiniMax was not recognized" }
            if ProviderInference.kind(from: "mimo", baseURL: nil) != .xiaomi { return "MiMo was not recognized" }
            if ProviderInference.kind(from: "iflow", baseURL: nil) != .iflow { return "iFlow was not recognized" }
            if ProviderInference.kind(from: "zai", baseURL: nil) != .zhipu { return "Z.ai was not recognized" }
            if ProviderInference.wireAPI(hint: "codex_responses", provider: .custom, baseURL: nil) != .openAIResponses {
                return "Codex Responses hint was not mapped"
            }
            if ProviderInference.wireAPI(hint: "anthropic_messages", provider: .custom, baseURL: nil) != .anthropicMessages {
                return "Anthropic Messages hint was not mapped"
            }
            return nil
        },
        Check(name: "discovery.product-names-use-approved-capitalization") {
            let names = ConfigDiscovery.knownSources(environment: [:]).map(\.1)
            let expected = [
                "Codex CLI", "Claude Code", "OpenCode", "Gemini CLI", "Qwen Code",
                "DeepSeek Harness", "Kimi Code CLI", "MiniMax Code", "ZCode",
                "MiMo Code", "iFlow CLI", "Trae Agent", "GitHub Copilot CLI",
                "Cursor CLI", "Amazon Q Developer CLI", "Pi", "OpenClaw", "Hermes Agent", "Aider"
            ]
            let missing = expected.filter { !names.contains($0) }
            if !missing.isEmpty { return "missing approved names: \(missing.joined(separator: ", "))" }
            if names.contains("opencode") || names.contains("OpenAI Codex") {
                return "an outdated product capitalization remains"
            }
            return nil
        },
    ]
}
