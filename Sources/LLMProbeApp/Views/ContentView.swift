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
        // A linear layout instead of `ContentUnavailableView` + a bottom
        // overlay: the previous version pinned the support note on top of the
        // action buttons whenever the window was shorter than the ideal size,
        // so the two drew over each other. Everything below is in one stack,
        // which cannot overlap no matter how tall the window is.
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 14) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 46, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(L10n.t("还没有端点", "No endpoints yet"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.t(
                        "从本机已安装的 Agent 配置中自动探测，或手动添加一个上游。",
                        "Discover one from an agent installed on this Mac, or add an upstream by hand."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                }

                HStack(spacing: 12) {
                    Button {
                        model.showDiscovery = true
                        Task { await model.discover() }
                    } label: {
                        Label(L10n.t("自动探测配置", "Auto-discover config"), systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                    Button {
                        model.beginAdd()
                    } label: {
                        Label(L10n.t("手动添加", "Add manually"), systemImage: "plus")
                    }
                }
                .controlSize(.large)
                .padding(.top, 6)
            }

            Spacer(minLength: 28)

            Text(L10n.t(
                "支持 Codex CLI、Claude Code、OpenCode、Qwen Code、DeepSeek Harness、Pi、OpenClaw、Hermes Agent 等本地配置",
                "Reads local configuration from Codex CLI, Claude Code, OpenCode, Qwen Code, DeepSeek Harness, Pi, OpenClaw, Hermes Agent and more"
            ))
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 22)
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
