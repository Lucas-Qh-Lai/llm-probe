import SwiftUI
import LLMProbeCore

struct DiscoverySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isDiscovering {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.t("正在读取本地配置…", "Reading local configuration…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = model.discovery {
                content(result)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text(L10n.t("点击“开始探测”读取本机 Agent 配置", "Click Scan to read this Mac's agent configuration"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("自动探测本地配置", "Discover local configuration"))
                .font(.title3.weight(.semibold))
            Text(L10n.t("只读取本机文件，全部解析在本机完成，不会上传任何内容。", "Reads local files only. Everything is parsed on this Mac, nothing is uploaded."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(
                L10n.t(
                    "部分 Agent 工具自动识别配置功能未经过验证，仅供参考。",
                    "Auto-configuration detection for some agent tools is unverified and provided for reference only."
                ),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func content(_ result: DiscoveryResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("检测到的来源", "Sources checked"))
                        .font(.subheadline.weight(.semibold))
                    ForEach(result.sources) { source in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: source.status))
                                .foregroundStyle(color(for: source.status))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(source.name).font(.callout.weight(.medium))
                                    Text(source.status.localizedName)
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(color(for: source.status).opacity(0.15), in: Capsule())
                                        .foregroundStyle(color(for: source.status))
                                    if source.endpointCount > 0 {
                                        Text(L10n.t("\(source.endpointCount) 个端点", "\(source.endpointCount) endpoints"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(source.abbreviatedPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let message = source.message {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("将导入的端点（\(result.endpoints.count)）", "Endpoints to import (\(result.endpoints.count))"))
                        .font(.subheadline.weight(.semibold))
                    ForEach(result.endpoints) { endpoint in
                        HStack(spacing: 10) {
                            Image(systemName: "cube")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(endpoint.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(endpoint.model) · \(endpoint.baseURL)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Text(endpoint.wireAPI.localizedShortName)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            if endpoint.tags.contains("active") {
                                Text(L10n.t("当前使用", "In use"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.16), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Toggle(L10n.t("同时扫描本地模型服务", "Also scan local model servers"), isOn: $model.includeLocalServers)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button(L10n.t("关闭", "Close")) { dismiss() }
            Button {
                Task { await model.discover() }
            } label: {
                Label(model.discovery == nil ? L10n.t("开始探测", "Scan") : L10n.t("重新探测", "Scan again"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDiscovering)
        }
        .padding(14)
    }

    private func icon(for status: DiscoverySource.Status) -> String {
        switch status {
        case .found: return "checkmark.circle.fill"
        case .notFound: return "circle.dashed"
        case .unreadable: return "exclamationmark.triangle.fill"
        case .unsupported: return "minus.circle"
        }
    }

    private func color(for status: DiscoverySource.Status) -> Color {
        switch status {
        case .found: return .green
        case .notFound: return .secondary
        case .unreadable: return .orange
        case .unsupported: return .secondary
        }
    }
}
