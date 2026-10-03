import SwiftUI
import Charts
import AppKit
import LLMProbeCore

struct EndpointDetail: View {
    @EnvironmentObject private var model: AppModel
    let endpoint: ProbeEndpoint

    private var report: EndpointReport? { model.reports[endpoint.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.runningID == endpoint.id { runningStrip }
                if let report {
                    stats(report)
                    capabilities(report)
                    probes(report)
                    historySection
                } else {
                    idleHint
                }
            }
            .padding(18)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbar }
        .navigationTitle(endpoint.name)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.accentColor.opacity(0.85), .accentColor.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 46, height: 46)
                    Image(systemName: verdictSymbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(endpoint.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    ProviderBadge(endpoint: endpoint)
                }
                Spacer(minLength: 0)
                if let report {
                    VerdictPill(verdict: report.verdict, detail: Fmt.relative(report.finishedAt))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    DetailLine(label: L10n.t("模型", "Model"), value: endpoint.model, icon: "cube")
                }
                GridRow {
                    DetailLine(label: L10n.t("端点", "Endpoint"), value: endpoint.baseURL, icon: "link")
                }
                if let origin = endpoint.origin {
                    GridRow {
                        DetailLine(label: L10n.t("来源", "Source"), value: origin.shortDescription, icon: "doc.text.magnifyingglass")
                    }
                }
                GridRow {
                    DetailLine(label: L10n.t("鉴权", "Auth"), value: endpoint.auth.label, icon: "key")
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var verdictSymbol: String {
        report?.verdict.symbolName ?? "waveform.path.ecg"
    }

    // MARK: - Running

    private var runningStrip: some View {
        SectionCard(title: L10n.t("正在探测", "Probing"), systemImage: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 8) {
                if let progress = model.progress {
                    let total = max(1, progress.total)
                    ProgressView(value: Double(progress.completed), total: Double(total))
                    HStack {
                        switch progress.event {
                        case .started(let kind):
                            Text(L10n.t("正在执行：\(kind.localizedName)", "Running: \(kind.localizedName)"))
                        case .finished(let outcome):
                            Text(L10n.t("完成：\(outcome.kind.localizedName) · \(outcome.summary)", "Done: \(outcome.kind.localizedName) · \(outcome.summary)"))
                        case .message(let text):
                            Text(text)
                        }
                        Spacer()
                        Text(L10n.t("\(progress.completed)/\(progress.total) · 已用 \(progress.spentTokens) tokens", "\(progress.completed)/\(progress.total) · \(progress.spentTokens) tokens spent"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    ProgressView(L10n.t("准备中…", "Preparing…"))
                        .font(.caption)
                }
            }
        }
    }

    private var idleHint: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.t("尚未运行探针", "No probe run yet"), systemImage: "play.circle")
                    .font(.headline)
                Text(L10n.t("当前强度：\(planName)。免费强度不消耗 completion tokens；快速强度约 \(model.plan.estimatedTokens) tokens 的预算。", "Plan: \(planName). The free plan spends no completion tokens; the quick plan budgets about \(model.plan.estimatedTokens) tokens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        model.run(endpoint)
                    } label: {
                        Label(L10n.t("开始探测", "Run probe"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        model.beginEdit(endpoint)
                    } label: {
                        Label(L10n.t("编辑端点", "Edit endpoint"), systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
    }

    private var planName: String {
        switch model.plan.kinds.count {
        case ProbePlan.free.kinds.count where model.plan.kinds == ProbePlan.free.kinds: return L10n.t("免费", "Free")
        case ProbePlan.deep.kinds.count where model.plan.kinds == ProbePlan.deep.kinds: return L10n.t("深度", "Deep")
        default: return L10n.t("快速", "Quick")
        }
    }

    // MARK: - Stats

    private func stats(_ report: EndpointReport) -> some View {
        let metrics = report.totalMetrics
        let context = report.outcome(.contextWindow)
        let declared = endpoint.declaredContextWindow ?? context?.details["tokens"].flatMap(Int.init)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatCard(
                    title: L10n.t("首 token 延迟", "Time to first token"),
                    value: Fmt.duration(metrics.timeToFirstTokenMS).replacingOccurrences(of: " ", with: ""),
                    unit: nil,
                    symbol: "timer",
                    tint: .blue,
                    caption: L10n.t("流式请求发出到第一个 token", "Request sent to first streamed token")
                )
                StatCard(
                    title: L10n.t("输出速度", "Output speed"),
                    value: Fmt.speed(metrics.outputTokensPerSecond),
                    unit: "tok/s",
                    symbol: "speedometer",
                    tint: .purple,
                    caption: metrics.outputTokensPerSecond == nil ? L10n.t("未测到增量输出", "No streamed output measured") : L10n.t("按上游 usage 计算", "Computed from upstream usage")
                )
                StatCard(
                    title: L10n.t("上下文窗口", "Context window"),
                    value: declared.map { Fmt.tokens($0) } ?? "—",
                    unit: declared == nil ? nil : "tokens",
                    symbol: "arrow.left.and.right.text.vertical",
                    tint: .teal,
                    caption: context?.details["source"] ?? L10n.t("上游未声明", "Not declared by the upstream")
                )
                StatCard(
                    title: L10n.t("本次消耗", "Tokens spent"),
                    value: Fmt.tokens(metrics.totalTokens),
                    unit: "tokens",
                    symbol: "number",
                    tint: .orange,
                    caption: L10n.t("输入 \(metrics.inputTokens) / 输出 \(metrics.outputTokens)", "in \(metrics.inputTokens) / out \(metrics.outputTokens)")
                )
                StatCard(
                    title: L10n.t("总耗时", "Total duration"),
                    value: Fmt.duration(report.durationMS),
                    unit: nil,
                    symbol: "clock",
                    tint: .gray,
                    caption: L10n.t("\(report.outcomes.count) 个探针", "\(report.outcomes.count) probes")
                )
            }
        }
    }

    // MARK: - Capabilities

    private func capabilities(_ report: EndpointReport) -> some View {
        let findings = report.capabilityEvidence
        return SectionCard(
            title: L10n.t("能力矩阵", "Capability matrix"),
            systemImage: "checklist",
            accessory: AnyView(
                Text(L10n.t("\(findings.filter { $0.level == .supported }.count) 项支持", "\(findings.filter { $0.level == .supported }.count) supported"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            )
        ) {
            if findings.isEmpty {
                Text(L10n.t("本次没有产生能力结论。", "This run produced no capability conclusions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 8)], spacing: 8) {
                    ForEach(findings.sorted { $0.capability.rawValue < $1.capability.rawValue }, id: \.capability) { finding in
                        CapabilityChip(
                            capability: finding.capability,
                            level: finding.level,
                            evidence: finding.evidence,
                            detail: finding.detail
                        )
                    }
                }
            }
        }
    }

    // MARK: - Probes

    private func probes(_ report: EndpointReport) -> some View {
        SectionCard(
            title: L10n.t("探针结果", "Probe results"),
            systemImage: "list.bullet.clipboard",
            accessory: AnyView(
                HStack(spacing: 8) {
                    Text(L10n.t("\(report.outcomes.filter { $0.status == .passed }.count) 通过 · \(report.outcomes.filter { $0.status.isProblem }.count) 异常", "\(report.outcomes.filter { $0.status == .passed }.count) passed · \(report.outcomes.filter { $0.status.isProblem }.count) failed"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            )
        ) {
            VStack(spacing: 6) {
                ForEach(report.outcomes) { outcome in
                    ProbeRow(outcome: outcome)
                }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        let samples = Array(model.history.suffix(40))
        return SectionCard(
            title: L10n.t("速度趋势", "Speed trend"),
            systemImage: "chart.xyaxis.line",
            accessory: AnyView(
                Button(L10n.t("清空", "Clear")) { model.clearHistory() }
                    .font(.caption2)
                    .buttonStyle(.link)
                    .disabled(samples.isEmpty)
            )
        ) {
            if samples.count < 2 {
                Text(L10n.t("再运行几次即可看到趋势（当前 \(samples.count) 次记录）。", "Run a few more probes to see a trend (\(samples.count) samples so far)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        if let speed = sample.outputTokensPerSecond {
                            LineMark(
                                x: .value(L10n.t("时间", "Time"), sample.date),
                                y: .value("tok/s", speed)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.purple)
                            PointMark(
                                x: .value(L10n.t("时间", "Time"), sample.date),
                                y: .value("tok/s", speed)
                            )
                            .foregroundStyle(sample.verdict.color)
                            .symbolSize(28)
                        }
                    }
                }
                .chartYAxisLabel("tok/s")
                .frame(height: 170)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(L10n.t("强度", "Plan"), selection: $model.plan) {
                Text(L10n.t("免费", "Free")).tag(ProbePlan.free)
                Text(L10n.t("快速", "Quick")).tag(ProbePlan.quick)
                Text(L10n.t("深度", "Deep")).tag(ProbePlan.deep)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help(L10n.t("免费：不消耗 completion tokens；快速：默认；深度：含上下文载荷搜索，会消耗输入 tokens", "Free: no completion tokens. Quick: default. Deep: adds the payload context search, which spends input tokens"))

            if model.runningID == endpoint.id {
                Button {
                    model.cancelRun()
                } label: {
                    Label(L10n.t("取消", "Cancel"), systemImage: "stop.fill")
                }
            } else {
                Button {
                    model.run(endpoint)
                } label: {
                    Label(L10n.t("运行探针", "Run probe"), systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }

            Menu {
                Button(L10n.t("编辑端点…", "Edit endpoint…")) { model.beginEdit(endpoint) }
                Button(L10n.t("复制端点", "Duplicate endpoint")) { model.duplicate(endpoint) }
                Divider()
                if let report {
                    Button(L10n.t("复制报告（Markdown）", "Copy report (Markdown)")) {
                        let text = model.exportReport(report)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        model.banner = AppModel.Banner(kind: .info, title: L10n.t("已复制", "Copied"), message: L10n.t("报告 Markdown 已放入剪贴板。", "The Markdown report is on your clipboard."))
                    }
                    Button(L10n.t("保存报告…", "Save report…")) { saveReport(report) }
                }
                Divider()
                Button(L10n.t("删除端点", "Delete endpoint"), role: .destructive) { model.delete(endpoint) }
            } label: {
                Label(L10n.t("更多", "More"), systemImage: "ellipsis.circle")
            }
        }
    }

    private func saveReport(_ report: EndpointReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "llmprobe-\(endpoint.model.replacingOccurrences(of: "/", with: "-")).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try model.exportReport(report).write(to: url, atomically: true, encoding: .utf8)
                model.banner = AppModel.Banner(
                    kind: .info,
                    title: L10n.t("已保存", "Saved"),
                    message: L10n.t("报告已写入所选位置。", "The report was written to the selected location.")
                )
            } catch {
                model.banner = AppModel.Banner(
                    kind: .error,
                    title: L10n.t("保存失败", "Save failed"),
                    message: Redactor.scrub(error.localizedDescription)
                )
            }
        }
    }
}

struct VerdictPill: View {
    let verdict: HealthVerdict
    var detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: verdict.symbolName)
                .foregroundStyle(verdict.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(verdict.localizedName)
                    .font(.callout.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(verdict.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(verdict.color.opacity(0.3), lineWidth: 0.5))
    }
}

struct DetailLine: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        } label: {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
        }
    }
}
