import Foundation
import SwiftUI
import LLMProbeCore

/// The app's single source of truth.
@MainActor
final class AppModel: ObservableObject {
    /// Shared by the SwiftUI scenes and the AppDelegate fallback window.
    static let shared = AppModel()

    @Published private(set) var state: AppState
    @Published var selection: UUID?
    @Published var reports: [UUID: EndpointReport] = [:]
    @Published private(set) var runningID: UUID?
    @Published private(set) var progress: ProbeProgress?
    @Published var plan: ProbePlan = .quick
    @Published private(set) var discovery: DiscoveryResult?
    @Published private(set) var isDiscovering = false
    @Published var searchText = ""
    @Published var showDiscovery = false
    @Published var showEditor = false
    @Published var editorTarget: ProbeEndpoint?
    @Published var banner: Banner?
    @Published var includeLocalServers = true

    /// Interface language. Changing it re-renders every view that observes the
    /// model and is persisted for the next launch.
    @Published var language: AppLanguage {
        didSet {
            guard !isApplyingInitialLanguage else { return }
            LanguageSettings.shared.apply(language)
        }
    }

    /// Interface appearance (System / Light / Dark). Changing it re-applies the
    /// AppKit appearance immediately and is persisted for the next launch.
    @Published var appearance: AppAppearance {
        didSet {
            guard !isApplyingInitialAppearance else { return }
            AppearanceSettings.shared.apply(appearance)
            AppearanceController.apply(appearance)
        }
    }

    private var currentEngine: ProbeEngine?
    private var runTask: Task<Void, Never>?
    private var isApplyingInitialLanguage = true
    private var isApplyingInitialAppearance = true

    struct Banner: Identifiable {
        enum Kind { case info, error }
        let id = UUID()
        var kind: Kind
        var title: String
        var message: String
    }

    init() {
        // `--language zh|en` wins (documentation screenshots), otherwise the
        // stored preference, otherwise the system language.
        let preference = LaunchOptions.shared.language ?? LanguageSettings.loadPreference()
        LanguageSettings.shared.apply(preference, persist: false)
        self.language = preference
        let appearancePreference = AppearanceController.launchPreference
        AppearanceSettings.shared.apply(appearancePreference, persist: false)
        self.appearance = appearancePreference
        AppearanceController.apply(appearancePreference)
        self.state = EndpointStoreFile.load()
        selection = state.selectedID ?? state.endpoints.first?.id
        isApplyingInitialLanguage = false
        isApplyingInitialAppearance = false
        startLaunchActions()
    }

    /// Injection point used by the screenshot renderer so documentation images
    /// never read the real profile.
    init(state: AppState) {
        let preference = LaunchOptions.shared.language ?? LanguageSettings.loadPreference()
        LanguageSettings.shared.apply(preference, persist: false)
        self.language = preference
        let appearancePreference = AppearanceController.launchPreference
        AppearanceSettings.shared.apply(appearancePreference, persist: false)
        self.appearance = appearancePreference
        AppearanceController.apply(appearancePreference)
        self.state = state
        selection = state.selectedID ?? state.endpoints.first?.id
        isApplyingInitialLanguage = false
        isApplyingInitialAppearance = false
    }

    /// Applies a language chosen in the settings pane.
    func setLanguage(_ value: AppLanguage) {
        language = value
    }

    /// Applies an appearance chosen in the settings pane.
    func setAppearance(_ value: AppAppearance) {
        appearance = value
    }

    private func startLaunchActions() {
        if state.autoRunOnLaunch || LaunchOptions.shared.autoRun || ProcessInfo.processInfo.environment["LLM_PROBE_AUTORUN"] != nil {
            // Give SwiftUI one runloop turn to lay out before the first request.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self?.runSelected()
            }
        }
        if LaunchOptions.shared.showDiscovery {
            showDiscovery = true
            Task { [weak self] in await self?.discover() }
        }
    }

    // MARK: - Derived data

    var endpoints: [ProbeEndpoint] { state.endpoints }

    var selectedEndpoint: ProbeEndpoint? {
        guard let selection else { return nil }
        return state.endpoints.first { $0.id == selection }
    }

    var selectedReport: EndpointReport? {
        guard let selection else { return nil }
        return reports[selection]
    }

    var history: [HistorySample] {
        guard let endpoint = selectedEndpoint else { return [] }
        return state.history[endpoint.dedupeKey] ?? []
    }

    /// Endpoints grouped for the sidebar, by where they were discovered.
    var groupedEndpoints: [(group: String, items: [ProbeEndpoint])] {
        let filtered: [ProbeEndpoint]
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            filtered = state.endpoints
        } else {
            let needle = searchText.lowercased()
            filtered = state.endpoints.filter {
                $0.name.lowercased().contains(needle)
                    || $0.model.lowercased().contains(needle)
                    || $0.baseURL.lowercased().contains(needle)
                    || $0.provider.localizedName.lowercased().contains(needle)
            }
        }
        var groups: [String: [ProbeEndpoint]] = [:]
        for endpoint in filtered {
            let group = endpoint.tags.first ?? L10n.t("手动添加", "Manual")
            groups[group, default: []].append(endpoint)
        }
        return groups
            .map { (group: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                if lhs.group.contains("CC Switch") != rhs.group.contains("CC Switch") {
                    return lhs.group.contains("CC Switch")
                }
                return lhs.group < rhs.group
            }
    }

    var totalTokensSpent: Int {
        reports.values.reduce(0) { $0 + $1.totalMetrics.totalTokens }
    }

    // MARK: - Discovery

    func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        let result: DiscoveryResult
        if LaunchOptions.shared.demoDiscovery {
            // Documentation / screenshot mode: never read the real machine.
            try? await Task.sleep(nanoseconds: 600_000_000)
            result = DemoDiscovery.result()
        } else {
            result = await ConfigDiscovery.scan(includeLocalServers: includeLocalServers)
        }
        // Discovery never writes to the endpoint list by itself. The result is
        // held until the user confirms it, so closing the sheet with "Cancel"
        // leaves the list exactly as it was.
        discovery = result
        state.lastDiscovery = result.scannedAt
        save()
        let found = result.sources.filter { $0.status == .found }.count
        banner = Banner(
            kind: .info,
            title: L10n.t("探测完成", "Discovery finished"),
            message: L10n.t(
                "在 \(found) 个来源中找到 \(result.endpoints.count) 个端点，确认后才会加入列表。",
                "Found \(result.endpoints.count) endpoints across \(found) sources. They are added only after you confirm."
            )
        )
    }

    /// How many endpoints the pending discovery result would add.
    var pendingDiscoveryCount: Int { discovery?.endpoints.count ?? 0 }

    /// Applies the pending discovery result to the endpoint list.
    @discardableResult
    func importDiscovered() -> Int {
        guard let result = discovery else { return 0 }
        mergeDiscovered(result.endpoints)
        state.lastDiscovery = result.scannedAt
        save()
        let found = result.sources.filter { $0.status == .found }.count
        banner = Banner(
            kind: .info,
            title: L10n.t("已导入", "Imported"),
            message: L10n.t(
                "已从 \(found) 个来源导入 \(result.endpoints.count) 个端点。",
                "Imported \(result.endpoints.count) endpoints from \(found) sources."
            )
        )
        return result.endpoints.count
    }

    /// Drops the pending discovery result without touching the endpoint list.
    func cancelDiscovery() {
        discovery = nil
    }

    /// Adds newly discovered endpoints while preserving local edits, and keeps
    /// the user's manual entries untouched.
    private func mergeDiscovered(_ discovered: [ProbeEndpoint]) {
        var byKey: [String: Int] = [:]
        for (index, endpoint) in state.endpoints.enumerated() {
            byKey[endpoint.dedupeKey] = index
        }
        for endpoint in discovered {
            if let index = byKey[endpoint.dedupeKey] {
                var existing = state.endpoints[index]
                // Refresh what discovery owns, keep what the user changed.
                existing.baseURL = endpoint.baseURL
                existing.auth = endpoint.auth.secret.isNone ? existing.auth : endpoint.auth
                existing.declaredContextWindow = existing.declaredContextWindow ?? endpoint.declaredContextWindow
                existing.declaredMaxOutputTokens = existing.declaredMaxOutputTokens ?? endpoint.declaredMaxOutputTokens
                existing.knownModels = endpoint.knownModels.isEmpty ? existing.knownModels : endpoint.knownModels
                existing.origin = endpoint.origin ?? existing.origin
                existing.tags = Array(Set(existing.tags + endpoint.tags)).sorted()
                existing.updatedAt = Date()
                state.endpoints[index] = existing
            } else {
                byKey[endpoint.dedupeKey] = state.endpoints.count
                state.endpoints.append(endpoint)
            }
        }
        if selection == nil { selection = state.endpoints.first?.id }
    }

    // MARK: - Probing

    func runSelected() {
        guard let endpoint = selectedEndpoint else { return }
        run(endpoint)
    }

    func run(_ endpoint: ProbeEndpoint) {
        guard runningID == nil else { return }
        runningID = endpoint.id
        progress = nil
        let engine = ProbeEngine()
        currentEngine = engine
        let plan = self.plan
        let cache = state.cache

        runTask = Task { [weak self] in
            guard let model = self else { return }
            let report = await engine.run(endpoint: endpoint, plan: plan, cache: cache) { update in
                Task { @MainActor in
                    guard model.runningID == endpoint.id else { return }
                    model.progress = update
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reports[endpoint.id] = report
                self.state.cache.store(report)
                self.appendHistory(report)
                self.runningID = nil
                self.progress = nil
                self.currentEngine = nil
                self.save()
            }
        }
    }

    func runAll() {
        guard runningID == nil else { return }
        let targets = state.endpoints
        Task { [weak self] in
            guard let model = self else { return }
            for endpoint in targets {
                guard model.runningID == nil else { break }
                model.run(endpoint)
                // Wait for the current run to finish before starting the next.
                while model.runningID != nil {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    func cancelRun() {
        currentEngine?.cancel()
        runTask?.cancel()
        runningID = nil
        progress = nil
    }

    private func appendHistory(_ report: EndpointReport) {
        let sample = HistorySample(
            date: report.finishedAt,
            timeToFirstTokenMS: report.totalMetrics.timeToFirstTokenMS,
            outputTokensPerSecond: report.totalMetrics.outputTokensPerSecond,
            tokens: report.totalMetrics.totalTokens,
            verdict: report.verdict
        )
        var list = state.history[report.endpoint.dedupeKey] ?? []
        list.append(sample)
        // Keep the file small: the last 60 runs per endpoint is plenty for a chart.
        if list.count > 60 { list.removeFirst(list.count - 60) }
        state.history[report.endpoint.dedupeKey] = list
    }

    func clearHistory() {
        guard let endpoint = selectedEndpoint else { return }
        state.history[endpoint.dedupeKey] = []
        save()
    }

    func setAutoRun(_ enabled: Bool) {
        state.autoRunOnLaunch = enabled
        save()
    }

    // MARK: - CRUD

    func beginAdd() {
        editorTarget = ProbeEndpoint(
            name: L10n.t("新端点", "New endpoint"),
            provider: .custom,
            wireAPI: .openAIChat,
            baseURL: "http://127.0.0.1:11434/v1",
            model: "llama3.1",
            tags: [L10n.t("手动添加", "Manual")]
        )
        showEditor = true
    }

    func beginEdit(_ endpoint: ProbeEndpoint) {
        editorTarget = endpoint
        showEditor = true
    }

    func commitEditor(_ endpoint: ProbeEndpoint) {
        var value = endpoint
        value.updatedAt = Date()
        if let index = state.endpoints.firstIndex(where: { $0.id == value.id }) {
            state.endpoints[index] = value
        } else {
            state.endpoints.append(value)
        }
        selection = value.id
        state.selectedID = value.id
        save()
    }

    func delete(_ endpoint: ProbeEndpoint) {
        state.endpoints.removeAll { $0.id == endpoint.id }
        reports[endpoint.id] = nil
        if selection == endpoint.id { selection = state.endpoints.first?.id }
        save()
    }

    func duplicate(_ endpoint: ProbeEndpoint) {
        var copy = endpoint
        copy.id = UUID()
        copy.name += L10n.t(" 副本", " copy")
        copy.createdAt = Date()
        copy.updatedAt = Date()
        state.endpoints.append(copy)
        selection = copy.id
        save()
    }

    func removeAll() {
        state.endpoints.removeAll()
        reports.removeAll()
        selection = nil
        save()
    }

    // MARK: - Persistence

    func save() {
        state.selectedID = selection
        _ = EndpointStoreFile.save(state)
    }

    var stateFileURL: URL { EndpointStoreFile.stateURL }

    // MARK: - Export

    func exportReport(_ report: EndpointReport) -> String {
        ReportExporter.markdown(report, history: state.history[report.endpoint.dedupeKey] ?? [])
    }
}

/// Renders a report as Markdown or JSON for sharing.
enum ReportExporter {
    static func markdown(_ report: EndpointReport, history: [HistorySample]) -> String {
        var lines: [String] = []
        lines.append(L10n.t("# LLMProbe 报告 · \(report.endpoint.name)", "# LLMProbe report · \(report.endpoint.name)"))
        lines.append("")
        lines.append(L10n.t("- 协议：\(report.endpoint.wireAPI.localizedName)", "- Protocol: \(report.endpoint.wireAPI.localizedName)"))
        lines.append(L10n.t("- Base URL：`\(report.endpoint.baseURL)`", "- Base URL: `\(report.endpoint.baseURL)`"))
        lines.append(L10n.t("- 模型：`\(report.endpoint.model)`", "- Model: `\(report.endpoint.model)`"))
        if let origin = report.endpoint.origin { lines.append(L10n.t("- 来源：\(origin.shortDescription)", "- Source: \(origin.shortDescription)")) }
        lines.append(L10n.t("- 结论：**\(report.verdict.localizedName)**", "- Verdict: **\(report.verdict.localizedName)**"))
        lines.append(L10n.t("- 时间：\(ISO8601DateFormatter().string(from: report.startedAt))", "- Started: \(ISO8601DateFormatter().string(from: report.startedAt))"))
        let metrics = report.totalMetrics
        lines.append(L10n.t("- 耗时：\(Fmt.duration(report.durationMS))，消耗 \(metrics.totalTokens) tokens", "- Duration: \(Fmt.duration(report.durationMS)), \(metrics.totalTokens) tokens spent"))
        if let ttft = metrics.timeToFirstTokenMS { lines.append(L10n.t("- 首 token：\(Fmt.duration(ttft))", "- Time to first token: \(Fmt.duration(ttft))")) }
        if let speed = metrics.outputTokensPerSecond { lines.append(L10n.t("- 输出速度：\(Fmt.speed(speed)) tok/s", "- Output speed: \(Fmt.speed(speed)) tok/s")) }
        lines.append("")
        lines.append(L10n.t("## 探针结果", "## Probe results"))
        lines.append("")
        lines.append(L10n.t("| 探针 | 状态 | 结果 | 耗时 | tokens |", "| Probe | Status | Result | Duration | tokens |"))
        lines.append("| --- | --- | --- | --- | --- |")
        for outcome in report.outcomes {
            let detail = outcome.summary.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(outcome.kind.localizedName) | \(outcome.status.localizedName) | \(detail) | \(Fmt.duration(outcome.durationMS)) | \(outcome.metrics.totalTokens) |")
        }
        lines.append("")
        lines.append(L10n.t("## 能力矩阵", "## Capability matrix"))
        lines.append("")
        for finding in report.capabilityEvidence {
            lines.append(L10n.t("- \(finding.capability.localizedName)：\(finding.level.localizedName)（\(finding.evidence.localizedName)）", "- \(finding.capability.localizedName): \(finding.level.localizedName) (\(finding.evidence.localizedName))"))
        }
        if !history.isEmpty {
            lines.append("")
            lines.append(L10n.t("## 历史", "## History"))
            lines.append("")
            for sample in history.suffix(10) {
                let speed = Fmt.speed(sample.outputTokensPerSecond)
                lines.append(L10n.t("- \(ISO8601DateFormatter().string(from: sample.date))：\(speed) tok/s，\(sample.tokens) tokens，\(sample.verdict.localizedName)", "- \(ISO8601DateFormatter().string(from: sample.date)): \(speed) tok/s, \(sample.tokens) tokens, \(sample.verdict.localizedName)"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
