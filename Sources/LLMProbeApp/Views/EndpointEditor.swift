import SwiftUI
import LLMProbeCore

struct EndpointEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProbeEndpoint
    @State private var secretText: String = ""
    @State private var secretKind: SecretKind
    @State private var environmentName: String = ""
    @State private var customHeaderName: String = "Authorization"
    @State private var extraHeadersText: String = ""
    @State private var validationMessage: String?

    enum SecretKind: String, CaseIterable, Identifiable {
        case none, inline, environment, keychain, file
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return L10n.t("无密钥", "No key")
            case .inline: return L10n.t("直接填写", "Paste it")
            case .environment: return L10n.t("环境变量", "Environment variable")
            case .keychain: return L10n.t("钥匙串", "Keychain")
            case .file: return L10n.t("文件", "File")
            }
        }
    }

    init(endpoint: ProbeEndpoint) {
        _draft = State(initialValue: endpoint)
        switch endpoint.auth.secret {
        case .none:
            _secretKind = State(initialValue: .none)
        case .inline(let value):
            _secretKind = State(initialValue: .inline)
            _secretText = State(initialValue: value)
        case .environment(let name):
            _secretKind = State(initialValue: .environment)
            _environmentName = State(initialValue: name)
        case .keychain:
            _secretKind = State(initialValue: .keychain)
        case .file(let path):
            _secretKind = State(initialValue: .file)
            _environmentName = State(initialValue: path)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.name.isEmpty ? L10n.t("编辑端点", "Edit endpoint") : draft.name)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.top, 16)
            Text(L10n.t("所有内容只保存在本机 \(PathTools.abbreviate(model.stateFileURL.path))。", "Everything stays on this Mac: \(PathTools.abbreviate(model.stateFileURL.path))"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 3)

            Form {
                Section(L10n.t("基本信息", "Basics")) {
                    TextField(L10n.t("名称", "Name"), text: $draft.name)
                    Picker(L10n.t("厂商", "Vendor"), selection: $draft.provider) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.localizedName).tag(kind)
                        }
                    }
                    Picker(L10n.t("协议", "Protocol"), selection: $draft.wireAPI) {
                        ForEach(WireAPI.selectable) { api in
                            Text(api.localizedName).tag(api)
                        }
                    }
                    TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.openai.com/v1"))
                    TextField(L10n.t("模型 ID", "Model ID"), text: $draft.model, prompt: Text("gpt-5-mini"))
                }

                Section(L10n.t("鉴权", "Authentication")) {
                    Picker(L10n.t("方式", "Method"), selection: $secretKind) {
                        ForEach(SecretKind.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(L10n.t("位置", "Placement"), selection: $draft.auth.style) {
                        ForEach(AuthConfig.Style.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    if draft.auth.style == .header {
                        TextField(L10n.t("Header 名称", "Header name"), text: Binding(
                            get: { draft.auth.headerName ?? "x-api-key" },
                            set: { draft.auth.headerName = $0 }
                        ))
                    }
                    if draft.auth.style == .query {
                        TextField(L10n.t("参数名", "Parameter name"), text: Binding(
                            get: { draft.auth.queryName ?? "key" },
                            set: { draft.auth.queryName = $0 }
                        ))
                    }
                    switch secretKind {
                    case .inline:
                        SecureField(L10n.t("密钥", "API key"), text: $secretText)
                    case .environment:
                        TextField(L10n.t("环境变量名", "Variable name"), text: $environmentName, prompt: Text("OPENAI_API_KEY"))
                    case .keychain:
                        Text(L10n.t("使用 macOS 钥匙串条目（服务名 / 账户名），请填写为 `service/account`。", "Reads a macOS Keychain item. Enter it as `service/account`."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("service/account", text: $environmentName)
                    case .file:
                        TextField(L10n.t("密钥文件路径", "Key file path"), text: $environmentName, prompt: Text("~/.openai.key"))
                    case .none:
                        Text(L10n.t("该端点不带凭据（适用于本地服务）。", "This endpoint needs no credential (typical for local servers)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L10n.t("高级", "Advanced")) {
                    TextField(L10n.t("额外请求头（每行 Key: Value）", "Extra headers (one Key: Value per line)"), text: $extraHeadersText, axis: .vertical)
                        .lineLimit(2...5)
                    TextField(L10n.t("备注", "Notes"), text: Binding(
                        get: { draft.notes ?? "" },
                        set: { draft.notes = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(1...3)
                    Toggle(L10n.t("启用", "Enabled"), isOn: $draft.enabled)
                }

                if let declared = draft.declaredContextWindow {
                    Section(L10n.t("已知信息", "Known from config")) {
                        LabeledContent(L10n.t("配置声明的上下文", "Declared context"), value: declared.formattedTokens + " tokens")
                        if !draft.knownModels.isEmpty {
                            LabeledContent(L10n.t("目录中的模型数", "Models in catalog"), value: "\(draft.knownModels.count)")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 18)
            }

            Divider()
            HStack {
                Button(L10n.t("恢复", "Revert")) { reset() }
                    .disabled(model.editorTarget == nil)
                Spacer()
                Button(L10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.editorTarget?.name.isEmpty == false ? L10n.t("保存", "Save") : L10n.t("添加", "Add")) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            extraHeadersText = draft.extraHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    private func reset() {
        if let target = model.editorTarget { draft = target }
    }

    private func commit() {
        let trimmedBase = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !trimmedModel.isEmpty else {
            validationMessage = L10n.t("Base URL 与模型 ID 不能为空。", "Base URL and model ID are required.")
            return
        }
        guard URL(string: trimmedBase)?.scheme != nil else {
            validationMessage = L10n.t("Base URL 必须是完整的 http(s) 地址。", "The base URL must be a full http(s) address.")
            return
        }
        draft.baseURL = trimmedBase
        draft.model = trimmedModel
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = "\(draft.provider.displayName) · \(trimmedModel)"
        }

        switch secretKind {
        case .none: draft.auth.secret = .none
        case .inline: draft.auth.secret = secretText.isEmpty ? .none : .inline(secretText)
        case .environment: draft.auth.secret = environmentName.isEmpty ? .none : .environment(environmentName)
        case .file: draft.auth.secret = environmentName.isEmpty ? .none : .file(path: environmentName)
        case .keychain:
            let parts = environmentName.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                draft.auth.secret = .keychain(service: parts[0], account: parts[1])
            } else {
                draft.auth.secret = .none
            }
        }

        var headers: [String: String] = [:]
        for line in extraHeadersText.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        draft.extraHeaders = headers
        if draft.tags.isEmpty { draft.tags = [L10n.t("手动添加", "Manual")] }
        model.commitEditor(draft)
        dismiss()
    }
}
