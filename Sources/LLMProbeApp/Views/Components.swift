import SwiftUI
import LLMProbeCore

/// A rounded, material-backed container used for every block of the detail view.
struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        systemImage: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.tint)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if let accessory { accessory }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var unit: String?
    let symbol: String
    var tint: Color = .accentColor
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

struct CapabilityChip: View {
    let capability: Capability
    let level: SupportLevel
    var evidence: EvidenceKind?
    var detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: capability.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(level.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(capability.localizedName)
                    .font(.caption.weight(.medium))
                if let evidence {
                    Text(evidenceLabel(evidence))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: level.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(level.color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(level.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(level.color.opacity(0.22), lineWidth: 0.5)
        )
        .help(detail ?? level.localizedName)
    }

    private func evidenceLabel(_ evidence: EvidenceKind) -> String {
        switch evidence {
        case .metadata: return L10n.t("来自元数据", "From metadata")
        case .liveProbe: return L10n.t("实测", "Live probe")
        case .config: return L10n.t("来自配置", "From config")
        case .heuristic: return L10n.t("推断", "Inferred")
        case .unknown: return L10n.t("未知", "Unknown")
        }
    }
}

struct ProbeRow: View {
    let outcome: ProbeOutcome
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: outcome.status.symbolName)
                    .foregroundStyle(outcome.status.color)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(outcome.kind.localizedName)
                            .font(.callout.weight(.medium))
                        Text(outcome.status.localizedName)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(outcome.status.color.opacity(0.15), in: Capsule())
                            .foregroundStyle(outcome.status.color)
                        Spacer(minLength: 0)
                        if outcome.durationMS > 0 {
                            Text(Fmt.duration(outcome.durationMS))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if outcome.metrics.totalTokens > 0 {
                            Text("\(outcome.metrics.totalTokens) tok")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(outcome.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure = outcome.failure {
                        Text(failure.category.localizedHint)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !outcome.details.isEmpty || outcome.failure?.rawBodySnippet != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcome.details.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 8) {
                            Text(key)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(value)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let body = outcome.failure?.rawBodySnippet {
                        Text(Redactor.scrub(body))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ProviderBadge: View {
    let endpoint: ProbeEndpoint

    var body: some View {
        HStack(spacing: 6) {
            Text(endpoint.provider.localizedName)
            Text(endpoint.wireAPI.localizedShortName)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            if endpoint.isLocalHost {
                Label(L10n.t("本地", "Local"), systemImage: "house.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(.green)
            }
            if endpoint.auth.secret.isNone {
                Text(L10n.t("无密钥", "No key"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
}
