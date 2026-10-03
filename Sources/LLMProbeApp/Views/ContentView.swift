import SwiftUI
import LLMProbeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            Group {
                if let endpoint = model.selectedEndpoint {
                    EndpointDetail(endpoint: endpoint)
                } else {
                    EmptyStateView()
                }
            }
        }
        .background(WindowConfigurator())
        .sheet(isPresented: $model.showDiscovery) {
            DiscoverySheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showEditor) {
            EndpointEditor(endpoint: model.editorTarget ?? ProbeEndpoint(name: L10n.t("新端点", "New endpoint"), baseURL: "", model: ""))
                .environmentObject(model)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation { model.banner = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.banner?.id)
        .task {
            // `--show-settings` exists for the documentation screenshot
            // pipeline: relying on a simulated ⌘, keystroke needs Accessibility
            // permission, which a fresh machine will not have granted.
            guard LaunchOptions.shared.showSettings else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            openSettings()
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            Text(L10n.t("还没有端点", "No endpoints yet"))
                .font(.title2.weight(.semibold))
            Text(L10n.t("从本机已安装的 Agent 配置中自动探测，或手动添加一个上游。", "Discover one from an agent installed on this Mac, or add an upstream by hand."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 12) {
                Button {
                    model.showDiscovery = true
                    Task { await model.discover() }
                } label: {
                    Label(L10n.t("自动探测配置", "Auto-discover config"), systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    model.beginAdd()
                } label: {
                    Label(L10n.t("手动添加", "Add manually"), systemImage: "plus")
                }
            }
            Text(L10n.t("支持 CC Switch、Codex、Claude Code、opencode、Gemini CLI、Continue、Aider 与本地模型服务", "Reads CC Switch, Codex, Claude Code, opencode, Gemini CLI, Continue, Aider and local model servers"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 460)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

struct BannerView: View {
    let banner: AppModel.Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.kind == .error ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
