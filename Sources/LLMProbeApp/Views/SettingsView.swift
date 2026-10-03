import AppKit
import SwiftUI
import LLMProbeCore

/// The macOS Settings window (⌘,).
///
/// The language picker is the reason this window exists: switching it applies
/// immediately, without a relaunch, because every view reads its strings through
/// `L10n` while observing `AppModel`.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            general
                .tabItem { Label(L10n.t("通用", "General"), systemImage: "gearshape") }
            data
                .tabItem { Label(L10n.t("数据", "Data"), systemImage: "internaldrive") }
            about
                .tabItem { Label(L10n.t("关于", "About"), systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }

    private var general: some View {
        Form {
            Section {
                Picker(L10n.t("界面语言", "Interface language"), selection: Binding(
                    get: { model.language },
                    set: { model.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(L10n.t(
                    "切换后立即生效，并会记住选择。",
                    "Applies immediately and is remembered for the next launch."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("语言", "Language"))
            }

            Section {
                Toggle(L10n.t("打开应用时探测当前端点", "Probe the selected endpoint on launch"), isOn: Binding(
                    get: { model.state.autoRunOnLaunch },
                    set: { model.setAutoRun($0) }
                ))
                Toggle(L10n.t("自动探测时扫描本地模型服务", "Scan local model servers while discovering"), isOn: $model.includeLocalServers)
            } header: {
                Text(L10n.t("探测", "Probing"))
            }
        }
        .formStyle(.grouped)
    }

    private var data: some View {
        Form {
            Section {
                LabeledContent(L10n.t("状态文件", "State file")) {
                    Text(PathTools.abbreviate(model.stateFileURL.path))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(L10n.t("在访达中显示", "Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.stateFileURL])
                    }
                    Spacer()
                    Button(L10n.t("清空历史", "Clear history")) { model.clearHistory() }
                    Button(L10n.t("移除全部端点", "Remove all endpoints"), role: .destructive) {
                        model.removeAll()
                    }
                }
                .controlSize(.small)
            } header: {
                Text(L10n.t("本机数据", "Local data"))
            } footer: {
                Text(L10n.t(
                    "文件权限 0600。密钥只保存在本机，不会上传到任何服务器。",
                    "File mode 0600. Credentials stay on this Mac and are never uploaded."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 3) {
                Text("LLMProbe \(LLMProbeVersion.short)")
                    .font(.title3.weight(.semibold))
                Text(L10n.t(
                    "完全本地运行的上游检测工具。除探针请求本身外，不发送任何数据。",
                    "A fully local upstream probe. Nothing but the probe requests themselves leaves this Mac."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            }

            VStack(spacing: 6) {
                Link(destination: Self.repositoryURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text(Self.repositoryDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(Self.repositoryURL.absoluteString)

                Text(L10n.t("作者：Lucas-Qh-Lai", "Author: Lucas-Qh-Lai"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(destination: Self.sponsorsURL) {
                    Text(L10n.t(
                        "如果这个工具帮到了你，欢迎请我喝杯咖啡 ☕️",
                        "If LLMProbe helped you, you are welcome to buy me a coffee ☕️"
                    ))
                    .font(.caption)
                }
                .help(L10n.t("打开 GitHub Sponsors", "Open GitHub Sponsors"))
            }

            Text(L10n.t("MIT 许可 · 完全开源", "MIT licensed · fully open source"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Project links

    /// Kept in one place so the About pane, the README and the release notes
    /// cannot drift apart.
    static let repositoryURL = URL(string: "https://github.com/Lucas-Qh-Lai/llm-probe")!
    static let sponsorsURL = URL(string: "https://github.com/sponsors/Lucas-Qh-Lai")!
    static let repositoryDisplay = "github.com/Lucas-Qh-Lai/llm-probe"
}
