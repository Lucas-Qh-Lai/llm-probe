import SwiftUI
import LLMProbeCore

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.groupedEndpoints, id: \.group) { group in
                    Section {
                        ForEach(group.items) { endpoint in
                            SidebarRow(
                                endpoint: endpoint,
                                verdict: model.reports[endpoint.id]?.verdict,
                                isRunning: model.runningID == endpoint.id
                            )
                            .tag(endpoint.id)
                            .contextMenu {
                                Button(L10n.t("运行探针", "Run probe")) { model.run(endpoint) }
                                Button(L10n.t("编辑…", "Edit…")) { model.beginEdit(endpoint) }
                                Button(L10n.t("复制", "Duplicate")) { model.duplicate(endpoint) }
                                Divider()
                                Button(L10n.t("删除", "Delete"), role: .destructive) { model.delete(endpoint) }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(group.group)
                            Spacer()
                            Text("\(group.items.count)")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $model.searchText, placement: .sidebar, prompt: L10n.t("搜索端点或模型", "Search endpoints or models"))

            Divider()
            footer
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(L10n.t("\(model.endpoints.count) 个端点", "\(model.endpoints.count) endpoints"), systemImage: "circle.grid.2x2")
            if model.totalTokensSpent > 0 {
                Label("\(Fmt.tokens(model.totalTokensSpent)) tokens", systemImage: "number")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                model.showDiscovery = true
                Task { await model.discover() }
            } label: {
                Label(L10n.t("自动探测", "Auto-discover"), systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .help(L10n.t("读取 CC Switch、Codex、Claude Code、opencode 等本地配置", "Reads local configs from CC Switch, Codex, Claude Code, opencode and more"))

            SettingsButton()

            Button {
                model.beginAdd()
            } label: {
                Image(systemName: "plus")
            }
            .help(L10n.t("手动添加端点", "Add an endpoint by hand"))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct SettingsButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "gearshape")
        }
        .help(L10n.t("设置", "Settings"))
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            SettingsPopover()
                .environmentObject(model)
        }
    }
}

struct SettingsPopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("设置", "Settings")).font(.headline)

            Toggle(L10n.t("打开应用时自动探测当前端点", "Probe the selected endpoint on launch"), isOn: Binding(
                get: { model.state.autoRunOnLaunch },
                set: { newValue in
                    model.setAutoRun(newValue)
                }
            ))
            .toggleStyle(.switch)

            Toggle(L10n.t("自动探测时扫描本地模型服务", "Scan local model servers while discovering"), isOn: $model.includeLocalServers)
                .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("数据位置", "Data location")).font(.caption.weight(.semibold))
                Text(PathTools.abbreviate(model.stateFileURL.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(L10n.t("文件权限 0600，仅保存在本机。", "File mode 0600. Stored on this Mac only."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            HStack {
                Button(L10n.t("清空历史", "Clear history")) { model.clearHistory() }
                    .controlSize(.small)
                Spacer()
                Button(L10n.t("移除全部端点", "Remove all endpoints"), role: .destructive) {
                    model.removeAll()
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}


struct SidebarRow: View {
    let endpoint: ProbeEndpoint
    let verdict: HealthVerdict?
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill((verdict?.color ?? .secondary).opacity(0.16))
                    .frame(width: 26, height: 26)
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: verdict?.symbolName ?? "circle.dashed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(verdict?.color ?? .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(endpoint.name)
                    .lineLimit(1)
                    .font(.callout)
                HStack(spacing: 5) {
                    Text(endpoint.provider.localizedName)
                    Text("·")
                    Text(endpoint.wireAPI.localizedShortName)
                    if endpoint.isLocalHost {
                        Text("·")
                        Image(systemName: "house.fill").font(.system(size: 8))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
