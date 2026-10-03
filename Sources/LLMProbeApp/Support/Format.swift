import SwiftUI
import LLMProbeCore

/// Formatting helpers shared by every view.
enum Fmt {
    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds < 1 { return "<1 ms" }
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
        if milliseconds < 60_000 { return String(format: "%.2f s", milliseconds / 1000) }
        return String(format: "%.1f min", milliseconds / 60_000)
    }

    static func speed(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func relative(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 5 { return L10n.t("刚刚", "just now") }
        if elapsed < 60 {
            let seconds = Int(elapsed.rounded())
            return L10n.t("\(seconds) 秒前", "\(seconds)s ago")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: LanguageSettings.shared.resolved.localeIdentifier)
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ProbeStatus {
    var color: Color {
        switch self {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .unsupported: return .secondary
        case .skipped: return .secondary.opacity(0.7)
        }
    }

    var symbolName: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .unsupported: return "slash.circle.fill"
        case .skipped: return "minus.circle"
        }
    }
}

extension HealthVerdict {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .degraded: return .orange
        case .unhealthy: return .red
        case .unknown: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.seal.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unhealthy: return "xmark.seal.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

}

extension SupportLevel {
    var color: Color {
        switch self {
        case .supported: return .green
        case .partial: return .orange
        case .unsupported: return .secondary
        case .unknown: return .secondary.opacity(0.55)
        }
    }

    var symbolName: String {
        switch self {
        case .supported: return "checkmark"
        case .partial: return "circle.lefthalf.filled"
        case .unsupported: return "xmark"
        case .unknown: return "questionmark"
        }
    }

}

extension Capability {
    var symbolName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .streaming: return "waveform.path.ecg"
        case .tools: return "wrench.and.screwdriver.fill"
        case .parallelTools: return "square.stack.3d.up.fill"
        case .vision: return "eye.fill"
        case .audioInput: return "waveform"
        case .audioOutput: return "speaker.wave.2.fill"
        case .structuredOutput: return "curlybraces"
        case .jsonMode: return "doc.text.fill"
        case .reasoning: return "brain.head.profile"
        case .promptCaching: return "bolt.horizontal.fill"
        case .systemPrompt: return "gearshape.fill"
        case .seed: return "dice.fill"
        case .logprobs: return "chart.bar.fill"
        case .embeddings: return "point.3.connected.trianglepath.dotted"
        }
    }
}

extension ProbeKind {
    var symbolName: String {
        switch self {
        case .connectivity: return "antenna.radiowaves.left.and.right"
        case .catalog: return "list.bullet.rectangle"
        case .chat: return "bubble.left.fill"
        case .streaming: return "waveform.path.ecg"
        case .tools: return "wrench.and.screwdriver.fill"
        case .vision: return "eye.fill"
        case .structuredOutput: return "curlybraces"
        case .contextWindow: return "arrow.left.and.right.text.vertical"
        case .maxOutput: return "arrow.up.to.line"
        case .reasoning: return "brain.head.profile"
        case .embeddings: return "point.3.connected.trianglepath.dotted"
        }
    }
}
