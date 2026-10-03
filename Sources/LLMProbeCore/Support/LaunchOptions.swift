import Foundation

/// Command line switches understood by the app when it is started through
/// LaunchServices, for example:
///
///     open -n LLMProbe.app --args --state-dir /tmp/demo --autorun
///
/// They exist so the app can be pointed at an isolated state directory for
/// demos, screenshots and tests without touching the real user profile.
public struct LaunchOptions: Sendable {
    public static let shared = LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))

    /// Alternative state directory (`--state-dir <path>`).
    public let stateDirectory: String?
    /// Start a probe run for the selected endpoint right after launch.
    public let autoRun: Bool
    /// Open the discovery sheet on launch.
    public let showDiscovery: Bool
    /// Use the fictional discovery result instead of reading the local machine.
    public let demoDiscovery: Bool
    /// Open the Settings window on launch. Used by the screenshot pipeline so a
    /// documentation image does not depend on simulated keystrokes.
    public let showSettings: Bool
    /// Force the interface language (`--language zh|en`), used for screenshots
    /// so a documentation image never depends on the reviewer's Mac settings.
    public let language: AppLanguage?

    public init(arguments: [String]) {
        var directory: String?
        var autoRun = false
        var showDiscovery = false
        var demoDiscovery = false
        var showSettings = false
        var language: AppLanguage?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--state-dir":
                if index + 1 < arguments.count {
                    directory = arguments[index + 1]
                    index += 1
                }
            case "--autorun":
                autoRun = true
            case "--show-discovery":
                showDiscovery = true
            case "--demo-discovery":
                demoDiscovery = true
            case "--show-settings":
                showSettings = true
            case "--language":
                if index + 1 < arguments.count {
                    language = AppLanguage(commandLineValue: arguments[index + 1])
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        self.stateDirectory = directory
        self.autoRun = autoRun
        self.showDiscovery = showDiscovery
        self.demoDiscovery = demoDiscovery
        self.showSettings = showSettings
        self.language = language
    }
}

public extension AppLanguage {
    /// Parses the loose values a launch argument (or a shell) may carry.
    init?(commandLineValue raw: String) {
        switch raw.lowercased() {
        case "zh", "zh-hans", "cn", "chinese", "zh_cn": self = .chinese
        case "en", "en-us", "english": self = .english
        case "system", "auto": self = .system
        default: return nil
        }
    }
}
