import AppKit
import LLMProbeCore

/// Bridges the engine's appearance preference onto AppKit.
///
/// `LLMProbeCore` is Foundation-only (it compiles on Linux), so the mapping to
/// `NSAppearance` lives here. Setting `NSApp.appearance` covers every window,
/// sheet and popover the app will ever open — including the SwiftUI Settings
/// scene — which is why the app does not need a `preferredColorScheme` on each
/// root view.
@MainActor
enum AppearanceController {
    /// Applies a preference to the running application.
    static func apply(_ preference: AppAppearance) {
        // `NSApp` is still nil inside `applicationWillFinishLaunching` — the
        // SwiftUI adapter reports the launch before the global is stamped — so
        // go through `NSApplication.shared`, which creates/returns the instance.
        let application = NSApplication.shared
        application.appearance = nsAppearance(for: preference)
        // The Settings window is created lazily and AppKit keeps the appearance
        // it was born with in some macOS versions; re-stamping every existing
        // window keeps a toggle from leaving a stale window behind.
        for window in application.windows {
            window.appearance = application.appearance
        }
    }

    /// `nil` means "follow the system", which is exactly what AppKit expects.
    static func nsAppearance(for preference: AppAppearance) -> NSAppearance? {
        switch preference {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// The preference a launch should start with: the `--appearance` flag wins
    /// (documentation screenshots), otherwise the stored preference.
    static var launchPreference: AppAppearance {
        LaunchOptions.shared.appearance ?? AppearanceSettings.loadPreference()
    }
}
