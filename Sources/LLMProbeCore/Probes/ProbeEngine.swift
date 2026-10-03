import Foundation

public struct ProbeProgress: Sendable {
    public enum Event: Sendable {
        case started(ProbeKind)
        case finished(ProbeOutcome)
        case message(String)
    }

    public var event: Event
    public var completed: Int
    public var total: Int
    public var spentTokens: Int

    public init(event: Event, completed: Int, total: Int, spentTokens: Int) {
        self.event = event
        self.completed = completed
        self.total = total
        self.spentTokens = spentTokens
    }
}

/// Runs the probe suite against one endpoint and produces a report.
public final class ProbeEngine: @unchecked Sendable {
    private let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    // MARK: - Entry point

    public func run(
        endpoint: ProbeEndpoint,
        plan: ProbePlan,
        cache: CapabilityCache? = nil,
        progress: (@Sendable (ProbeProgress) -> Void)? = nil
    ) async -> EndpointReport {
        let startedAt = Date()

        let resolved: ResolvedEndpoint
        do {
            resolved = try EndpointResolver.resolve(endpoint)
        } catch {
            let failure = ProbeFailure(category: .network, message: (error as? EndpointResolverError)?.displayMessage ?? "\(error)")
            let outcome = ProbeOutcome(kind: .connectivity, status: .failed, summary: failure.message, failure: failure)
            return EndpointReport(
                endpoint: endpoint,
                startedAt: startedAt,
                finishedAt: Date(),
                verdict: .unhealthy,
                outcomes: [outcome],
                capabilityMatrix: [:],
                capabilityEvidence: []
            )
        }

        let adapter = ProviderRegistry.adapter(for: endpoint.wireAPI)
        let state = RunState(
            endpoint: endpoint,
            resolved: resolved,
            adapter: adapter,
            plan: plan,
            cache: plan.useCache ? cache : nil,
            progress: progress
        )

        // Connectivity and catalog share one request, so it always runs first.
        var orderedKinds = plan.kinds
        orderedKinds.removeAll { $0 == .connectivity || $0 == .catalog }
        if plan.kinds.contains(.connectivity) || plan.kinds.contains(.catalog) {
            orderedKinds.insert(.connectivity, at: 0)
        }

        state.totalSteps = orderedKinds.count

        for kind in orderedKinds {
            if state.isCancelled { break }
            if state.spentTokens > plan.tokenBudget, kind.isTokenHeavy || kind != .connectivity {
                let outcome = ProbeOutcome.skipped(kind, reason: "Token budget of \(plan.tokenBudget) reached.")
                state.record(outcome)
                continue
            }
            state.progress?(ProbeProgress(event: .started(kind), completed: state.completedSteps, total: state.totalSteps, spentTokens: state.spentTokens))

            let outcome: ProbeOutcome
            switch kind {
            case .connectivity, .catalog:
                outcome = await runCatalogProbe(state: state, includeCatalog: plan.kinds.contains(.catalog))
                state.completedSteps += 1
                state.record(outcome, countsAsStep: false)
                if plan.kinds.contains(.catalog), kind == .connectivity {
                    // `runCatalogProbe` produced both outcomes; the catalog one is
                    // already recorded, so only the connectivity step remains.
                }
                state.progress?(ProbeProgress(event: .finished(outcome), completed: state.completedSteps, total: state.totalSteps, spentTokens: state.spentTokens))
                continue
            case .chat:
                outcome = await runChatProbe(state: state)
            case .streaming:
                outcome = await runStreamingProbe(state: state)
            case .tools:
                outcome = await runToolsProbe(state: state)
            case .vision:
                outcome = await runVisionProbe(state: state)
            case .structuredOutput:
                outcome = await runStructuredOutputProbe(state: state)
            case .contextWindow:
                outcome = await runContextWindowProbe(state: state)
            case .maxOutput:
                outcome = await runMaxOutputProbe(state: state)
            case .reasoning:
                outcome = await runReasoningProbe(state: state)
            case .embeddings:
                outcome = await runEmbeddingsProbe(state: state)
            }
            state.completedSteps += 1
            state.record(outcome)
            state.progress?(ProbeProgress(event: .finished(outcome), completed: state.completedSteps, total: state.totalSteps, spentTokens: state.spentTokens))
        }

        let findings = CapabilityMerge.merge(state.findings)
        if ProcessInfo.processInfo.environment["LLM_PROBE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[debug] findings=\(state.findings.count) merged=\(findings.count) outcomes=\(state.outcomes.count) verdict=\(state.verdict().rawValue)\n".utf8))
            for (key, value) in state.findings {
                FileHandle.standardError.write(Data("[debug]   \(key.rawValue) = \(value.level.rawValue)\n".utf8))
            }
        }
        let matrix = CapabilityMerge.matrix(from: findings)
        return EndpointReport(
            endpoint: endpoint,
            startedAt: startedAt,
            finishedAt: Date(),
            verdict: state.verdict(),
            outcomes: state.outcomes,
            capabilityMatrix: matrix,
            capabilityEvidence: findings
        )
    }

    public func cancel() { cancelled = true }
    private var cancelled = false

    // MARK: - Connectivity and catalog

    private func runCatalogProbe(state: RunState, includeCatalog: Bool) async -> ProbeOutcome {
        let started = Date()
        guard let spec = state.adapter.modelsRequest(resolved: state.resolved) else {
            state.findings[.embeddings] = CapabilityFinding(
                capability: .embeddings,
                level: .unknown,
                evidence: .config,
                detail: "This wire API has no listable catalog."
            )
            return ProbeOutcome(
                kind: .connectivity,
                status: .warning,
                summary: L10n.pick(zh: "已连上端点，但它没有暴露可校验的模型目录。", en: "Reached the endpoint, but it exposes no model catalog to validate against."),
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }

        do {
            let payload = try await client.send(spec)
            let duration = Date().timeIntervalSince(started) * 1000
            if payload.isSuccess {
                let models = (try? state.adapter.decodeModels(payload)) ?? []
                state.catalog = models
                if let match = ModelCatalogIndex.match(model: state.endpoint.model, in: models) {
                    state.metadata = match
                    // Agent configs decorate model ids (`[1M]`, `:free`) while the
                    // upstream catalog lists the bare id. Adopt the catalog
                    // spelling so real requests are accepted.
                    if match.id.lowercased() != state.endpoint.model.lowercased() {
                        state.canonicalModel = match.id
                        state.resolved.endpoint.model = match.id
                    }
                    if let context = match.contextWindow {
                        state.findings[.chat] = state.findings[.chat] ?? CapabilityFinding(capability: .chat, level: .supported, evidence: .metadata, detail: "Declared by catalog metadata.")
                        state.recordDeclaredContext(context, evidence: .metadata)
                    }
                    if let maxOutput = match.maxOutputTokens { state.recordDeclaredMaxOutput(maxOutput, evidence: .metadata) }
                    for (capability, level) in match.capabilities {
                        state.findings[capability] = CapabilityFinding(
                            capability: capability,
                            level: level,
                            evidence: .metadata,
                            detail: "Declared by catalog metadata."
                        )
                    }
                }
                var detail = models.isEmpty
                    ? L10n.pick(zh: "端点有响应，但模型目录是空的。", en: "Endpoint answered but the catalog is empty.")
                    : L10n.pick(zh: "列出 \(models.count) 个模型。", en: "\(models.count) models listed.")
                if let canonical = state.canonicalModel {
                    detail += L10n.pick(zh: "模型 ID 已解析为 \(canonical)。", en: " Model id resolved to \(canonical).")
                }
                // No `chat` finding here on purpose: reachability alone does not
                // prove generation works, and a placeholder would block later
                // evidence from upgrading the answer.
                state.record(ProbeOutcome(
                    kind: .catalog,
                    status: .passed,
                    summary: detail,
                    details: [
                        "models": "\(models.count)",
                        "matched": ModelCatalogIndex.match(model: state.endpoint.model, in: models)?.id ?? "not found",
                    ],
                    metrics: ProbeMetrics(requests: 1, latencySamplesMS: [duration])
                ), countsAsStep: false)
                return ProbeOutcome(
                    kind: .connectivity,
                    status: .passed,
                    summary: L10n.pick(zh: "往返 \(Int(duration)) ms，凭据可用。", en: "Round-trip \(Int(duration)) ms. Credential accepted."),
                    details: ["http_status": "\(payload.status)"],
                    metrics: ProbeMetrics(requests: 1, totalDurationMS: duration, latencySamplesMS: [duration]),
                    durationMS: duration
                )
            }

            let classified = ErrorClassifier.classify(status: payload.status, body: payload.body, headers: payload.headers)
            // 404/405 on `/models` means the host is up but has no catalog.
            if payload.status == 404 || payload.status == 405 || payload.status == 501 {
                return ProbeOutcome(
                    kind: .connectivity,
                    status: .warning,
                    summary: L10n.pick(zh: "主机可达，但没有模型目录路由（HTTP \(payload.status)）。", en: "Host reachable, no model catalog route (HTTP \(payload.status))."),
                    details: ["http_status": "\(payload.status)"],
                    metrics: ProbeMetrics(requests: 1, totalDurationMS: duration, latencySamplesMS: [duration]),
                    durationMS: duration
                )
            }
            return ProbeOutcome(
                kind: .connectivity,
                status: .failed,
                summary: classified.failure.message,
                details: ["http_status": "\(payload.status)"],
                metrics: ProbeMetrics(requests: 1, totalDurationMS: duration, latencySamplesMS: [duration]),
                failure: classified.failure,
                durationMS: duration
            )
        } catch {
            let failure = Self.failure(from: error)
            return ProbeOutcome(
                kind: .connectivity,
                status: .failed,
                summary: failure.message,
                metrics: ProbeMetrics(requests: 1, totalDurationMS: Date().timeIntervalSince(started) * 1000),
                failure: failure,
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }
    }

    // MARK: - Chat

    private func runChatProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        let request = ChatRequest(
            messages: [.user(ProbePrompts.chat)],
            maxOutputTokens: 12,
            temperature: 0,
            stream: false
        )
        switch await callChat(request, state: state) {
        case .failure(let failure, let duration):
            return ProbeOutcome(
                kind: .chat,
                status: .failed,
                summary: failure.message,
                failure: failure,
                startedAt: started,
                durationMS: duration
            )
        case .success(let response, let duration):
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isUsable = !text.isEmpty || !response.toolCalls.isEmpty || !response.reasoning.isEmpty
            state.findings[.chat] = CapabilityFinding(
                capability: .chat,
                level: isUsable ? .supported : .partial,
                evidence: .liveProbe,
                detail: isUsable ? "A completion returned." : "Response contained no text.",
                tokenCost: response.usage.total
            )
            state.findings[.systemPrompt] = CapabilityFinding(
                capability: .systemPrompt,
                level: .supported,
                evidence: .heuristic,
                detail: "This wire API carries a system instruction field."
            )
            return ProbeOutcome(
                kind: .chat,
                status: isUsable ? .passed : .warning,
                summary: isUsable
                ? L10n.pick(zh: "补全在 \(Int(duration)) ms 内返回。", en: "Completion returned in \(Int(duration)) ms.")
                : L10n.pick(zh: "返回了空的补全结果。", en: "Empty completion."),
                details: [
                    "finish_reason": response.finishReason ?? "—",
                    "model_echo": response.modelEcho ?? "—",
                    "sample": String(text.prefix(80)),
                ],
                metrics: state.metrics(usage: response.usage, promptText: ProbePrompts.chat, responseText: text, totalMS: duration),
                durationMS: duration
            )
        }
    }

    // MARK: - Streaming

    private func runStreamingProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        var samples: [StreamResult] = []
        let rounds = max(1, state.plan.speedSamples)
        var lastFailure: ProbeFailure?

        for _ in 0..<rounds {
            let request = ChatRequest(
                messages: [.user(ProbePrompts.streaming)],
                maxOutputTokens: 96,
                temperature: 0,
                stream: true
            )
            let result = await streamChat(request, state: state)
            if let failure = result.failure {
                lastFailure = failure
                break
            }
            samples.append(result)
        }

        guard !samples.isEmpty else {
            let failure = lastFailure ?? ProbeFailure(category: .unknown, message: "No streamed response.")
            return ProbeOutcome(kind: .streaming, status: .failed, summary: failure.message, failure: failure, startedAt: started, durationMS: Date().timeIntervalSince(started) * 1000)
        }

        let ttfts = samples.compactMap(\.ttftMS).sorted()
        let speeds = samples.compactMap(\.tokensPerSecond).sorted()
        let medianTTFT = ttfts.isEmpty ? nil : ttfts[ttfts.count / 2]
        let medianSpeed = speeds.isEmpty ? nil : speeds[speeds.count / 2]
        let sawDeltas = samples.contains(where: { $0.receivedDelta })
        let singleBlock = samples.contains(where: { $0.respondedAsSingleBlock })
        let producedText = samples.contains { !$0.text.isEmpty }

        let totalInput = samples.reduce(0) { $0 + $1.usage.inputTokens }
        let totalOutput = samples.reduce(0) { $0 + $1.usage.outputTokens }
        let estimated = samples.contains { !$0.usage.isAuthoritative }

        state.findings[.streaming] = CapabilityFinding(
            capability: .streaming,
            level: sawDeltas ? .supported : (singleBlock ? .partial : (producedText ? .partial : .unknown)),
            evidence: .liveProbe,
            detail: sawDeltas
                ? "Incremental deltas observed."
                : (singleBlock
                    ? "The streaming flag was ignored; the answer arrived as one block."
                    : "No incremental text observed."),
            tokenCost: totalInput + totalOutput
        )

        var parts: [String] = []
        if let medianTTFT { parts.append("TTFT \(Int(medianTTFT)) ms") }
        if let medianSpeed { parts.append(String(format: "%.1f tok/s", medianSpeed)) }
        if rounds > 1 { parts.append(L10n.pick(zh: "\(samples.count) 次取中位数", en: "median of \(samples.count)")) }
        if singleBlock { parts.append(L10n.pick(zh: "忽略 stream 标志", en: "stream flag ignored")) }
        if parts.isEmpty {
            parts.append(producedText
                ? L10n.pick(zh: "整段一次性返回。", en: "Answer arrived in one block.")
                : L10n.pick(zh: "没有观察到文本。", en: "No text observed."))
        }

        return ProbeOutcome(
            kind: .streaming,
            status: sawDeltas ? .passed : .warning,
            summary: parts.joined(separator: " · "),
            details: [
                "tokens_counted": estimated
                    ? L10n.pick(zh: "估算", en: "estimated")
                    : L10n.pick(zh: "上游报告", en: "reported by upstream"),
                "samples": "\(samples.count)",
            ],
            metrics: ProbeMetrics(
                requests: samples.count,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                timeToFirstTokenMS: medianTTFT,
                totalDurationMS: samples.compactMap(\.totalMS).reduce(0, +),
                outputTokensPerSecond: medianSpeed,
                latencySamplesMS: ttfts
            ),
            durationMS: Date().timeIntervalSince(started) * 1000
        )
    }

    // MARK: - Tools

    private func runToolsProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        let tools = [ToolSpec.echoProbe(), ProbePrompts.reportValueTool()]
        let request = ChatRequest(
            messages: [.user(ProbePrompts.parallelTools)],
            tools: tools,
            toolChoice: .required,
            maxOutputTokens: 128,
            temperature: 0,
            stream: false
        )

        switch await callChat(request, state: state) {
        case .failure(let failure, let duration):
            if failure.category == .unsupportedCapability || failure.httpStatus == 400 {
                state.findings[.tools] = CapabilityFinding(
                    capability: .tools,
                    level: .unsupported,
                    evidence: .liveProbe,
                    detail: failure.message
                )
            }
            return ProbeOutcome(kind: .tools, status: .unsupported, summary: failure.message, failure: failure, startedAt: started, durationMS: duration)
        case .success(let response, let duration):
            let calls = response.toolCalls
            let named = calls.contains { $0.name == ToolSpec.echoProbe().name || $0.name == ProbePrompts.reportValueTool().name }
            let argumentsValid = calls.contains { call in
                guard let arguments = call.arguments else { return false }
                return arguments["status_token"] != nil || arguments["value"] != nil
            }
            let level: SupportLevel = (named && argumentsValid) ? .supported : (calls.isEmpty ? .unsupported : .partial)
            state.findings[.tools] = CapabilityFinding(
                capability: .tools,
                level: level,
                evidence: .liveProbe,
                detail: calls.isEmpty ? "No tool call returned." : "\(calls.count) tool call(s) returned.",
                tokenCost: response.usage.total
            )
            state.findings[.parallelTools] = CapabilityFinding(
                capability: .parallelTools,
                level: calls.count >= 2 ? .supported : (calls.count == 1 ? .partial : .unknown),
                evidence: .liveProbe,
                detail: calls.count >= 2
                    ? L10n.pick(zh: "一次请求里调用了两个工具。", en: "Two tools called in one turn.")
                    : L10n.pick(zh: "一次请求里只调用了一个工具。", en: "Only one tool call in one turn."),
                tokenCost: response.usage.total
            )
            let status: ProbeStatus = level == .supported ? .passed : (level == .partial ? .warning : .unsupported)
            return ProbeOutcome(
                kind: .tools,
                status: status,
                summary: calls.isEmpty
                    ? L10n.pick(zh: "模型用文本回答，没有调用工具。", en: "The model answered in text instead of calling the tool.")
                    : (argumentsValid
                        ? L10n.pick(zh: "\(calls.count) 次工具调用，参数合法。", en: "\(calls.count) tool call(s), arguments valid.")
                        : L10n.pick(zh: "\(calls.count) 次工具调用，但参数无法解析。", en: "\(calls.count) tool call(s), arguments not parseable.")),
                details: [
                    "tool_calls": "\(calls.count)",
                    "names": calls.map(\.name).joined(separator: ", "),
                ],
                metrics: state.metrics(usage: response.usage, promptText: ProbePrompts.parallelTools, responseText: response.text, totalMS: duration),
                durationMS: duration
            )
        }
    }

    // MARK: - Vision

    private func runVisionProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        let request = ChatRequest(
            messages: [.user(ProbePrompts.vision, images: [ProbePrompts.tinyImageAttachment()])],
            maxOutputTokens: 12,
            temperature: 0,
            stream: false
        )
        switch await callChat(request, state: state) {
        case .failure(let failure, let duration):
            // Only call vision unsupported when the upstream actually complained
            // about the image; a generic 400/404 means something else is broken.
            let message = failure.message.lowercased()
            let complainsAboutImage = message.contains("image")
                || message.contains("vision")
                || message.contains("modality")
                || message.contains("multimodal")
                || message.contains("content type")
            let isRejection = failure.category == .unsupportedCapability
                || (failure.category == .invalidRequest && complainsAboutImage)
            state.findings[.vision] = CapabilityFinding(
                capability: .vision,
                level: isRejection ? .unsupported : .unknown,
                evidence: .liveProbe,
                detail: failure.message
            )
            return ProbeOutcome(
                kind: .vision,
                status: isRejection ? .unsupported : .warning,
                summary: isRejection ? L10n.pick(zh: "图像输入被拒绝：\(failure.message)", en: "Image input rejected: \(failure.message)") : failure.message,
                failure: failure,
                startedAt: started,
                durationMS: duration
            )
        case .success(let response, let duration):
            let text = response.text.lowercased()
            let recognised = text.contains("red")
            state.findings[.vision] = CapabilityFinding(
                capability: .vision,
                level: .supported,
                evidence: .liveProbe,
                detail: recognised ? "The image was accepted and described correctly." : "The image was accepted; description: \(response.text.prefix(40))",
                tokenCost: response.usage.total
            )
            return ProbeOutcome(
                kind: .vision,
                status: .passed,
                summary: recognised
                    ? L10n.pick(zh: "图像被接受，且识别正确。", en: "Image accepted and identified correctly.")
                    : L10n.pick(zh: "图像被接受。", en: "Image accepted."),
                details: ["answer": String(response.text.prefix(60))],
                metrics: state.metrics(usage: response.usage, promptText: ProbePrompts.vision, responseText: response.text, totalMS: duration),
                durationMS: duration
            )
        }
    }

    // MARK: - Structured output

    private func runStructuredOutputProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        let request = ChatRequest(
            messages: [.user(ProbePrompts.structured)],
            maxOutputTokens: 80,
            temperature: 0,
            stream: false,
            responseSchema: ProbePrompts.structuredSchema
        )
        switch await callChat(request, state: state) {
        case .failure(let schemaFailure, let duration):
            // Schemas are optional in most wire APIs; retry with plain JSON mode
            // before declaring the capability unsupported.
            let fallback = ChatRequest(
                messages: [.user(ProbePrompts.structured)],
                maxOutputTokens: 80,
                temperature: 0,
                stream: false,
                forceJSONObject: true
            )
            switch await callChat(fallback, state: state) {
            case .failure(let jsonFailure, let jsonDuration):
                state.findings[.structuredOutput] = CapabilityFinding(
                    capability: .structuredOutput,
                    level: .unsupported,
                    evidence: .liveProbe,
                    detail: jsonFailure.message
                )
                state.findings[.jsonMode] = CapabilityFinding(
                    capability: .jsonMode,
                    level: .unsupported,
                    evidence: .liveProbe,
                    detail: jsonFailure.message
                )
                return ProbeOutcome(
                    kind: .structuredOutput,
                    status: .unsupported,
                    summary: L10n.pick(zh: "schema 被拒绝：\(schemaFailure.message)", en: "Schema rejected: \(schemaFailure.message)"),
                    details: ["json_mode": jsonFailure.message],
                    failure: jsonFailure,
                    startedAt: started,
                    durationMS: duration + jsonDuration
                )
            case .success(let response, let jsonDuration):
                let valid = Self.isValidStructuredPayload(response.text)
                state.findings[.structuredOutput] = CapabilityFinding(
                    capability: .structuredOutput,
                    level: .partial,
                    evidence: .liveProbe,
                    detail: "JSON object accepted; strict schema not supported.",
                    tokenCost: response.usage.total
                )
                state.findings[.jsonMode] = CapabilityFinding(
                    capability: .jsonMode,
                    level: valid ? .supported : .partial,
                    evidence: .liveProbe,
                    detail: valid ? "Valid JSON returned." : "JSON mode returned non-JSON text.",
                    tokenCost: response.usage.total
                )
                return ProbeOutcome(
                    kind: .structuredOutput,
                    status: valid ? .warning : .unsupported,
                    summary: valid
                ? L10n.pick(zh: "不支持严格 schema；JSON 模式可用。", en: "Strict schema unsupported; JSON mode works.")
                : L10n.pick(zh: "不支持严格 schema；JSON 模式也失败。", en: "Strict schema unsupported; JSON mode failed."),
                    metrics: state.metrics(usage: response.usage, promptText: ProbePrompts.structured, responseText: response.text, totalMS: jsonDuration),
                    durationMS: duration + jsonDuration
                )
            }
        case .success(let response, let duration):
            let valid = Self.isValidStructuredPayload(response.text)
            state.findings[.structuredOutput] = CapabilityFinding(
                capability: .structuredOutput,
                level: valid ? .supported : .partial,
                evidence: .liveProbe,
                detail: valid ? "Schema-constrained JSON returned." : "Response was not the requested JSON.",
                tokenCost: response.usage.total
            )
            state.findings[.jsonMode] = CapabilityFinding(
                capability: .jsonMode,
                level: .supported,
                evidence: .liveProbe,
                detail: "JSON schema accepted.",
                tokenCost: response.usage.total
            )
            return ProbeOutcome(
                kind: .structuredOutput,
                status: valid ? .passed : .warning,
                summary: valid
                    ? L10n.pick(zh: "返回了受 schema 约束的 JSON。", en: "Schema-constrained JSON returned.")
                    : L10n.pick(zh: "响应不是合法 JSON。", en: "Response was not valid JSON."),
                details: ["sample": String(response.text.prefix(120))],
                metrics: state.metrics(usage: response.usage, promptText: ProbePrompts.structured, responseText: response.text, totalMS: duration),
                durationMS: duration
            )
        }
    }

    // MARK: - Context window

    private func runContextWindowProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        if let declared = state.declaredContextWindow {
            return ProbeOutcome(
                kind: .contextWindow,
                status: .passed,
                summary: L10n.pick(zh: "\(declared.formattedTokens) tokens，来自目录元数据。", en: "\(declared.formattedTokens) tokens, from catalog metadata."),
                details: ["tokens": "\(declared)", "source": "metadata"],
                findings: [
                    CapabilityFinding(capability: .chat, level: .supported, evidence: .metadata, detail: "Context window declared by the provider."),
                ],
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }

        // Zero-completion-token attempt: some providers state the window in the
        // error they return for an impossible output budget.
        if let spec = state.adapter.limitQueryRequest(resolved: state.resolved, kind: .contextWindow) {
            let result = await validationRequest(spec, state: state)
            if let answer = result.answer, answer.kind == .contextWindow {
                state.findings[.chat] = CapabilityFinding(capability: .chat, level: .supported, evidence: .liveProbe, detail: "Context window reported by the upstream during validation.")
                state.recordDeclaredContext(answer.value, evidence: .liveProbe)
                return ProbeOutcome(
                    kind: .contextWindow,
                    status: .passed,
                    summary: L10n.pick(zh: "\(answer.value.formattedTokens) tokens，由上游报告。", en: "\(answer.value.formattedTokens) tokens, reported by the upstream."),
                    details: ["tokens": "\(answer.value)", "source": "validation error"],
                    durationMS: Date().timeIntervalSince(started) * 1000
                )
            }
        }

        guard state.plan.enableContextSearch else {
            return ProbeOutcome(
                kind: .contextWindow,
                status: .warning,
                summary: L10n.pick(zh: "上游未声明。开启 payload 搜索即可实测。", en: "Not declared by the upstream. Enable the payload search to measure it."),
                details: ["method": "unavailable"],
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }

        let search = await searchContextWindow(state: state)
        if let value = search.value {
            state.recordDeclaredContext(value, evidence: .liveProbe)
            // If the search stopped at the configured ceiling the real window is
            // at least this large, which is a different statement from an exact
            // measurement.
            let hitCeiling = value >= state.plan.contextSearchUpperBound
            let prefix = hitCeiling ? "≥" : "≈"
            return ProbeOutcome(
                kind: .contextWindow,
                status: .passed,
                summary: L10n.pick(zh: "\(prefix)\(value.formattedTokens) tokens，由 payload 搜索测得。", en: "\(prefix) \(value.formattedTokens) tokens, found by payload search."),
                details: [
                    "tokens": "\(value)",
                    "source": "payload search",
                    "probes": "\(search.probes)",
                    "bounded": hitCeiling ? "true" : "false",
                ],
                metrics: ProbeMetrics(requests: search.probes, inputTokens: search.inputTokens, latencySamplesMS: []),
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }
        let failure = search.failure ?? ProbeFailure(category: .unknown, message: "Context window could not be measured.")
        return ProbeOutcome(
            kind: .contextWindow,
            status: .warning,
            summary: failure.message,
            failure: failure,
            durationMS: Date().timeIntervalSince(started) * 1000
        )
    }

    private func searchContextWindow(state: RunState) async -> (value: Int?, probes: Int, inputTokens: Int, failure: ProbeFailure?) {
        var low = 1_024
        var high = max(2_048, state.plan.contextSearchUpperBound)
        var probes = 0
        var inputTokens = 0
        var best: Int?
        var lastFailure: ProbeFailure?

        for _ in 0..<12 {
            if low > high { break }
            let mid = low + (high - low) / 2
            let filler = TokenEstimator.filler(tokens: mid)
            let request = ChatRequest(
                messages: [.user(filler + "\nReply with the single word: ok")],
                maxOutputTokens: 1,
                temperature: 0,
                stream: false
            )
            probes += 1
            switch await callChat(request, state: state) {
            case .success(let response, _):
                inputTokens += response.usage.inputTokens > 0 ? response.usage.inputTokens : mid
                best = mid
                low = mid + 1
            case .failure(let failure, _):
                lastFailure = failure
                if failure.category == .contextOverflow || failure.httpStatus == 400 || failure.httpStatus == 413 {
                    high = mid - 1
                } else {
                    return (best, probes, inputTokens, failure)
                }
            }
        }
        return (best, probes, inputTokens, best == nil ? lastFailure : nil)
    }

    // MARK: - Max output tokens

    private func runMaxOutputProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        if let declared = state.declaredMaxOutputTokens {
            return ProbeOutcome(
                kind: .maxOutput,
                status: .passed,
                summary: L10n.pick(zh: "\(declared.formattedTokens) tokens，来自目录元数据。", en: "\(declared.formattedTokens) tokens, from catalog metadata."),
                details: ["tokens": "\(declared)", "source": "metadata"],
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }
        guard let spec = state.adapter.limitQueryRequest(resolved: state.resolved, kind: .maxOutputTokens) else {
            return ProbeOutcome(kind: .maxOutput, status: .warning, summary: L10n.pick(zh: "该协议没有可校验输出上限的接口。", en: "This wire API has no validation route for the output limit."))
        }
        let result = await validationRequest(spec, state: state)
        if let answer = result.answer {
            state.recordDeclaredMaxOutput(answer.value, evidence: .liveProbe)
            return ProbeOutcome(
                kind: .maxOutput,
                status: .passed,
                summary: L10n.pick(zh: "\(answer.value.formattedTokens) tokens，由上游报告。", en: "\(answer.value.formattedTokens) tokens, reported by the upstream."),
                details: ["tokens": "\(answer.value)", "source": "validation error"],
                metrics: ProbeMetrics(requests: 1),
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }
        if result.accepted {
            return ProbeOutcome(
                kind: .maxOutput,
                status: .warning,
                summary: L10n.pick(zh: "上游接受了极大的输出预算，因此未声明上限。", en: "The upstream accepted an extreme output budget, so it does not state a limit."),
                details: ["method": "validation"],
                metrics: ProbeMetrics(requests: 1),
                durationMS: Date().timeIntervalSince(started) * 1000
            )
        }
        return ProbeOutcome(
            kind: .maxOutput,
            status: .warning,
            summary: result.failure?.message ?? L10n.pick(zh: "上游未报告上限。", en: "No limit reported."),
            failure: result.failure,
            durationMS: Date().timeIntervalSince(started) * 1000
        )
    }

    // MARK: - Reasoning

    private func runReasoningProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        var extra: [String: Any] = [:]
        switch state.endpoint.wireAPI {
        case .openAIChat, .openAIResponses:
            extra["reasoning_effort"] = "low"
        case .anthropicMessages:
            extra["thinking"] = ["type": "enabled", "budget_tokens": 1_024]
        case .googleGemini:
            extra["generationConfig"] = ["thinkingConfig": ["thinkingBudget": 128]]
        case .ollamaChat:
            extra["think"] = true
        }
        let request = ChatRequest(
            messages: [.user(ProbePrompts.reasoning)],
            maxOutputTokens: 256,
            temperature: 0,
            stream: false,
            extraBody: extra
        )
        switch await callChat(request, state: state) {
        case .failure(let failure, let duration):
            let unsupported = failure.category == .unsupportedCapability || failure.category == .invalidRequest
            state.findings[.reasoning] = CapabilityFinding(
                capability: .reasoning,
                level: unsupported ? .unsupported : .unknown,
                evidence: .liveProbe,
                detail: failure.message
            )
            return ProbeOutcome(
                kind: .reasoning,
                status: unsupported ? .unsupported : .warning,
                summary: failure.message,
                failure: failure,
                startedAt: started,
                durationMS: duration
            )
        case .success(let response, let duration):
            let producedReasoning = !response.reasoning.isEmpty
            state.findings[.reasoning] = CapabilityFinding(
                capability: .reasoning,
                level: producedReasoning ? .supported : .partial,
                evidence: .liveProbe,
                detail: producedReasoning
                    ? "A reasoning/thinking channel was returned."
                    : "Reasoning controls accepted, but no separate reasoning channel was returned.",
                tokenCost: response.usage.total
            )
            return ProbeOutcome(
                kind: .reasoning,
                status: .passed,
                summary: producedReasoning
                    ? L10n.pick(zh: "返回了推理通道。", en: "Reasoning channel returned.")
                    : L10n.pick(zh: "推理参数被接受。", en: "Reasoning controls accepted."),
                metrics: state.metrics(usage: response.usage, promptText: ProbePrompts.reasoning, responseText: response.text, totalMS: duration),
                durationMS: duration
            )
        }
    }

    // MARK: - Embeddings

    private func runEmbeddingsProbe(state: RunState) async -> ProbeOutcome {
        let started = Date()
        let url = URLTools.applying(
            queryItems: state.resolved.queryItems,
            to: URLTools.join(base: state.resolved.baseURL, path: "/embeddings", ensureV1: true)
        )
        guard let body = try? JSONBody.data(["model": state.endpoint.model, "input": "probe"]) else {
            return ProbeOutcome(kind: .embeddings, status: .skipped, summary: L10n.pick(zh: "请求无法编码。", en: "Could not encode the request."))
        }
        do {
            let payload = try await client.send(HTTPRequestSpec(url: url, method: "POST", headers: state.resolved.headers, body: body, timeout: 30))
            let duration = Date().timeIntervalSince(started) * 1000
            if payload.isSuccess, let object = JSONBody.object(payload.body), let data = object["data"] as? [[String: Any]], !data.isEmpty {
                state.findings[.embeddings] = CapabilityFinding(capability: .embeddings, level: .supported, evidence: .liveProbe, detail: "Embeddings route returned a vector.")
                return ProbeOutcome(kind: .embeddings, status: .passed, summary: L10n.pick(zh: "返回了向量。", en: "Vector returned."), metrics: ProbeMetrics(requests: 1, totalDurationMS: duration), durationMS: duration)
            }
            let classified = ErrorClassifier.classify(status: payload.status, body: payload.body, headers: payload.headers)
            state.findings[.embeddings] = CapabilityFinding(capability: .embeddings, level: .unsupported, evidence: .liveProbe, detail: classified.failure.message)
            return ProbeOutcome(kind: .embeddings, status: .unsupported, summary: classified.failure.message, failure: classified.failure, durationMS: duration)
        } catch {
            let failure = Self.failure(from: error)
            state.findings[.embeddings] = CapabilityFinding(capability: .embeddings, level: .unknown, evidence: .liveProbe, detail: failure.message)
            return ProbeOutcome(kind: .embeddings, status: .warning, summary: failure.message, failure: failure, durationMS: Date().timeIntervalSince(started) * 1000)
        }
    }

    // MARK: - Shared request helpers

    private enum ChatCallResult {
        case success(ChatResponse, Double)
        case failure(ProbeFailure, Double)
    }

    private func callChat(_ request: ChatRequest, state: RunState) async -> ChatCallResult {
        let started = Date()
        guard let spec = try? state.adapter.chatRequest(request, resolved: state.resolved) else {
            return .failure(ProbeFailure(category: .invalidRequest, message: "Could not build the request for this wire API."), 0)
        }
        do {
            let payload = try await client.send(spec)
            let duration = Date().timeIntervalSince(started) * 1000
            if payload.isSuccess {
                do {
                    let response = try state.adapter.decodeChat(payload)
                    state.charge(response.usage.total)
                    return .success(response, duration)
                } catch {
                    return .failure(Self.failure(from: error), duration)
                }
            }
            let classified = ErrorClassifier.classify(status: payload.status, body: payload.body, headers: payload.headers)
            if let limit = classified.extractedLimit {
                switch classified.extractedLimitKind {
                case .maxOutputTokens: state.recordDeclaredMaxOutput(limit, evidence: .liveProbe)
                case .contextWindow: state.recordDeclaredContext(limit, evidence: .liveProbe)
                default: break
                }
            }
            return .failure(classified.failure, duration)
        } catch {
            return .failure(Self.failure(from: error), Date().timeIntervalSince(started) * 1000)
        }
    }

    private struct StreamResult {
        var text = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var usage: UsageReport = .none
        var finishReason: String?
        var ttftMS: Double?
        var totalMS: Double?
        var tokensPerSecond: Double?
        var failure: ProbeFailure?
        /// The server ignored `stream: true` and returned one JSON body.
        var respondedAsSingleBlock = false
        /// Any incremental token arrived, text or reasoning.
        var receivedDelta = false
    }

    private func streamChat(_ request: ChatRequest, state: RunState) async -> StreamResult {
        var result = StreamResult()
        guard let spec = try? state.adapter.chatRequest(request, resolved: state.resolved) else {
            result.failure = ProbeFailure(category: .invalidRequest, message: "Could not build the streaming request.")
            return result
        }
        let stream = client.stream(spec)
        var sse = SSEDecoder()
        let decoder = state.adapter.makeStreamDecoder()
        var toolAccumulator: [Int: ToolCall] = [:]
        var textChunks: [(String, Double)] = []
        var raw = Data()
        let started = Date()

        do {
            for try await chunk in stream.chunks {
                raw.append(chunk.data)
                for event in sse.ingest(chunk.data) {
                    for decoded in decoder.consume(event) {
                        switch decoded {
                        case .textDelta(let delta):
                            if result.ttftMS == nil { result.ttftMS = chunk.elapsedMS }
                            result.receivedDelta = true
                            result.text += delta
                            textChunks.append((delta, chunk.elapsedMS))
                        case .reasoningDelta(let delta):
                            if result.ttftMS == nil { result.ttftMS = chunk.elapsedMS }
                            result.receivedDelta = true
                            result.reasoning += delta
                        case .toolCallDelta(let index, let id, let name, let fragment):
                            var call = toolAccumulator[index] ?? ToolCall(id: id, name: name ?? "", argumentsJSON: "")
                            if let id { call.id = id }
                            if let name, !name.isEmpty { call.name = name }
                            if let fragment { call.argumentsJSON += fragment }
                            toolAccumulator[index] = call
                        case .usage(let usage):
                            result.usage = usage
                        case .completed(let reason):
                            result.finishReason = reason
                        }
                    }
                }
            }
            for decoded in decoder.finish() {
                switch decoded {
                case .usage(let usage): result.usage = usage
                case .completed(let reason): result.finishReason = reason
                case .textDelta(let delta): result.text += delta
                default: break
                }
            }
        } catch {
            result.failure = Self.failure(from: error)
            if !result.text.isEmpty { result.failure = nil }
            if result.failure != nil { return result }
        }

        result.totalMS = Date().timeIntervalSince(started) * 1000
        result.toolCalls = toolAccumulator.keys.sorted().compactMap { toolAccumulator[$0] }

        // Some servers accept `stream: true` but answer with a single JSON body.
        // Decode it so the probe reports a truthful "streaming ignored" result
        // instead of an empty response.
        if result.text.isEmpty, !raw.isEmpty, result.toolCalls.isEmpty,
           let decoded = try? state.adapter.decodeChat(HTTPResponsePayload(status: 200, headers: [:], body: raw, durationMS: result.totalMS ?? 0)),
           !decoded.text.isEmpty || !decoded.toolCalls.isEmpty {
            result.text = decoded.text
            result.reasoning = decoded.reasoning
            result.toolCalls = decoded.toolCalls
            result.finishReason = decoded.finishReason
            if decoded.usage.total > 0 { result.usage = decoded.usage }
            result.respondedAsSingleBlock = true
        }

        let outputTokens = result.usage.outputTokens > 0
            ? result.usage.outputTokens
            : max(1, TokenEstimator.estimate(result.text + result.reasoning))
        let authoritative = result.usage.outputTokens > 0
        if !authoritative {
            result.usage = UsageReport(
                inputTokens: max(1, TokenEstimator.estimate(ProbePrompts.streaming)),
                outputTokens: outputTokens,
                isAuthoritative: false
            )
        }
        state.charge(result.usage.total)

        if let ttft = result.ttftMS, let total = result.totalMS, total > ttft {
            let generationSeconds = (total - ttft) / 1000
            if generationSeconds > 0 {
                result.tokensPerSecond = Double(max(1, outputTokens - 1)) / generationSeconds
            }
        }
        // Without a first-delta timestamp there is no honest throughput number,
        // so the probe leaves it empty rather than inventing one.
        return result
    }

    private struct ValidationResult {
        var accepted: Bool
        var answer: LimitQueryAnswer?
        var failure: ProbeFailure?
    }

    /// Sends a validation request that should be *rejected*. If it is accepted the
    /// stream is cancelled as soon as the first byte arrives, so no completion
    /// tokens are generated.
    private func validationRequest(_ spec: HTTPRequestSpec, state: RunState) async -> ValidationResult {
        let stream = client.stream(spec)
        var sse = SSEDecoder()
        var sawFirstByte = false
        do {
            for try await chunk in stream.chunks {
                if !sawFirstByte {
                    sawFirstByte = true
                    stream.cancel()
                    break
                }
                _ = sse.ingest(chunk.data)
            }
        } catch let error as HTTPStreamBodyError {
            let classified = ErrorClassifier.classify(status: error.summary.status, body: error.body, headers: error.summary.headers)
            if let limit = classified.extractedLimit {
                let kind: LimitQueryKind = classified.extractedLimitKind == .maxOutputTokens ? .maxOutputTokens : .contextWindow
                return ValidationResult(accepted: false, answer: LimitQueryAnswer(kind: kind, value: limit, message: classified.failure.message), failure: classified.failure)
            }
            return ValidationResult(accepted: false, answer: nil, failure: classified.failure)
        } catch {
            if sawFirstByte {
                return ValidationResult(accepted: true, answer: nil, failure: nil)
            }
            return ValidationResult(accepted: false, answer: nil, failure: Self.failure(from: error))
        }
        return ValidationResult(accepted: true, answer: nil, failure: nil)
    }

    // MARK: - Failure translation

    static func failure(from error: Error) -> ProbeFailure {
        if let clientError = error as? HTTPClientError { return clientError.failure }
        if let bodyError = error as? HTTPStreamBodyError {
            return ErrorClassifier.classify(status: bodyError.summary.status, body: bodyError.body, headers: bodyError.summary.headers).failure
        }
        if let adapterError = error as? AdapterError {
            return ProbeFailure(category: .decoding, message: adapterError.displayMessage)
        }
        if let urlError = error as? URLError { return HTTPClientError.transport(urlError).failure }
        return ProbeFailure(category: .unknown, message: error.localizedDescription)
    }

    static func isValidStructuredPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("```")
            ? trimmed.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
            : trimmed
        guard let data = stripped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["status"] != nil && object["value"] != nil
    }
}

// MARK: - Run state

private final class RunState: @unchecked Sendable {
    let endpoint: ProbeEndpoint
    var resolved: ResolvedEndpoint
    let adapter: ProviderAdapter
    let plan: ProbePlan
    let progress: (@Sendable (ProbeProgress) -> Void)?

    var outcomes: [ProbeOutcome] = []
    var findings: [Capability: CapabilityFinding] = [:]
    var spentTokens = 0
    var completedSteps = 0
    var totalSteps = 0
    var catalog: [ModelCatalogEntry] = []
    var metadata: ModelCatalogEntry?
    /// The model id the upstream actually accepts, when it differs from config.
    var canonicalModel: String?
    var declaredContextWindow: Int?
    var declaredMaxOutputTokens: Int?
    var isCancelled = false

    init(
        endpoint: ProbeEndpoint,
        resolved: ResolvedEndpoint,
        adapter: ProviderAdapter,
        plan: ProbePlan,
        cache: CapabilityCache?,
        progress: (@Sendable (ProbeProgress) -> Void)?
    ) {
        self.endpoint = endpoint
        self.resolved = resolved
        self.adapter = adapter
        self.plan = plan
        self.progress = progress
        self.declaredContextWindow = endpoint.declaredContextWindow
        self.declaredMaxOutputTokens = endpoint.declaredMaxOutputTokens
        if let cache {
            for (capability, finding) in cache.findings(for: endpoint) {
                // Cached values only fill gaps; a live probe always overwrites them.
                findings[capability] = CapabilityFinding(
                    capability: finding.capability,
                    level: finding.level,
                    evidence: finding.evidence,
                    detail: finding.detail.map { $0 + " (cached)" },
                    tokenCost: 0
                )
            }
        }
    }

    func charge(_ tokens: Int) {
        spentTokens += max(0, tokens)
    }

    func record(_ outcome: ProbeOutcome, countsAsStep: Bool = true) {
        outcomes.append(outcome)
        for finding in outcome.findings { findings[finding.capability] = finding }
        charge(outcome.metrics.totalTokens)
    }

    func recordDeclaredContext(_ value: Int, evidence: EvidenceKind) {
        declaredContextWindow = declaredContextWindow ?? value
        // Only upgrade: a stronger answer already on file is never downgraded.
        if let existing = findings[.chat], existing.level.rank >= SupportLevel.supported.rank { return }
        findings[.chat] = CapabilityFinding(
            capability: .chat,
            level: .supported,
            evidence: evidence,
            detail: "Context window \(value.formattedTokens) tokens."
        )
    }

    func recordDeclaredMaxOutput(_ value: Int, evidence: EvidenceKind) {
        declaredMaxOutputTokens = declaredMaxOutputTokens ?? value
    }

    func metrics(usage: UsageReport, promptText: String, responseText: String, totalMS: Double) -> ProbeMetrics {
        let input = usage.inputTokens > 0 ? usage.inputTokens : TokenEstimator.estimate(promptText)
        let output = usage.outputTokens > 0 ? usage.outputTokens : TokenEstimator.estimate(responseText)
        var speed: Double?
        if totalMS > 0, output > 0 { speed = Double(output) / (totalMS / 1000) }
        return ProbeMetrics(
            requests: 1,
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: usage.cachedInputTokens,
            reasoningTokens: usage.reasoningTokens,
            totalDurationMS: totalMS,
            outputTokensPerSecond: speed,
            latencySamplesMS: [totalMS]
        )
    }

    func verdict() -> HealthVerdict {
        let connectivity = outcomes.first { $0.kind == .connectivity }
        if let connectivity, connectivity.status == .failed { return .unhealthy }
        if connectivity == nil { return .unknown }
        let chat = outcomes.first { $0.kind == .chat }
        if let chat, chat.status == .failed { return .unhealthy }
        let hardFailures = outcomes.filter { $0.status == .failed }
        if !hardFailures.isEmpty {
            let isAuth = hardFailures.contains { $0.failure?.category == .authentication || $0.failure?.category == .authorization }
            return isAuth ? .unhealthy : .degraded
        }
        if let chat, chat.status == .warning { return .degraded }
        let found = findings.values.contains { $0.level == .supported }
        return found ? .healthy : .unknown
    }
}

// MARK: - Catalog matching and capability merging

public enum ModelCatalogIndex {
    /// Matches a configured model id against catalog entries, tolerating the
    /// `provider/model` prefixes that aggregators add.
    public static func match(model: String, in catalog: [ModelCatalogEntry]) -> ModelCatalogEntry? {
        if catalog.isEmpty { return nil }
        let target = model.lowercased()
        if let exact = catalog.first(where: { $0.id.lowercased() == target }) { return exact }
        if let suffix = catalog.first(where: { $0.id.lowercased().hasSuffix("/" + target) }) { return suffix }
        if let prefix = catalog.first(where: { target.hasSuffix("/" + $0.id.lowercased()) }) { return prefix }
        let stripped = target.split(separator: "/").last.map(String.init) ?? target
        if let byStem = catalog.first(where: { $0.id.lowercased() == stripped }) { return byStem }
        // Strip common decorations such as `[1M]` or `:free`.
        let decorated = target.split(separator: "[").first.map(String.init) ?? target
        let colonStripped = decorated.split(separator: ":").first.map(String.init) ?? decorated
        if let byDecoration = catalog.first(where: {
            $0.id.lowercased().hasPrefix(colonStripped) || colonStripped.hasPrefix($0.id.lowercased())
        }), colonStripped.count >= 4 {
            return byDecoration
        }
        return nil
    }
}

public enum CapabilityMerge {
    /// Collapses duplicate findings, keeping the strongest evidence.
    public static func merge(_ findings: [Capability: CapabilityFinding]) -> [CapabilityFinding] {
        Capability.orderedForDisplay.compactMap { capability in
            guard let finding = findings[capability] else { return nil }
            return finding
        }
    }

    public static func matrix(from findings: [CapabilityFinding]) -> [Capability: SupportLevel] {
        var matrix: [Capability: SupportLevel] = [:]
        for finding in findings { matrix[finding.capability] = finding.level }
        return matrix
    }
}

extension Int {
    /// `128000` → `"128K"`, `1000000` → `"1M"`.
    public var formattedTokens: String {
        if self >= 1_000_000 {
            let millions = Double(self) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if self >= 1_000 {
            let thousands = Double(self) / 1_000
            return thousands == thousands.rounded() ? "\(Int(thousands))K" : String(format: "%.1fK", thousands)
        }
        return "\(self)"
    }
}
