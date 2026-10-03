import AppKit
import SwiftUI
import LLMProbeCore

@main
struct LLMProbeAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("LLMProbe") {
            ContentView()
                .environmentObject(model)
                // `idealWidth/idealHeight` are what SwiftUI turns into the window
                // size. Without them the window collapses to the ideal size of
                // whatever is on screen — which for the empty state is tiny.
                .frame(
                    minWidth: 1080,
                    idealWidth: 1340,
                    maxWidth: .infinity,
                    minHeight: 680,
                    idealHeight: 880,
                    maxHeight: .infinity
                )
        }
        .defaultSize(width: 1340, height: 900)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("添加端点…", "Add endpoint…")) { model.beginAdd() }
                    .keyboardShortcut("n", modifiers: .command)
                Button(L10n.t("从本地配置探测…", "Discover local config…")) {
                    model.showDiscovery = true
                    Task { await model.discover() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.t("探针", "Probe")) {
                Button(L10n.t("运行当前端点", "Run selected endpoint")) { model.runSelected() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button(L10n.t("运行全部端点", "Run all endpoints")) { model.runAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L10n.t("取消", "Cancel")) { model.cancelRun() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Picker(L10n.t("强度", "Plan"), selection: $model.plan) {
                    Text(L10n.t("免费（不消耗 completion tokens）", "Free (no completion tokens)")).tag(ProbePlan.free)
                    Text(L10n.t("快速", "Quick")).tag(ProbePlan.quick)
                    Text(L10n.t("深度", "Deep")).tag(ProbePlan.deep)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
