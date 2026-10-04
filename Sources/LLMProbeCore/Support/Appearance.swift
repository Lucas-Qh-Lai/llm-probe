import Foundation

/// The interface appearance the app should render.
///
/// `system` defers to the Mac's own light/dark setting; the other two pin the
/// interface so a documentation screenshot never depends on the reviewer's Mac.
public enum AppAppearance: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// Always shown in the language currently active, so the picker reads
    /// naturally whichever language is selected.
    public var displayName: String {
        switch self {
        case .system: return L10n.pick(zh: "跟随系统", en: "System")
        case .light: return L10n.pick(zh: "浅色", en: "Light")
        case .dark: return L10n.pick(zh: "深色", en: "Dark")
        }
    }
}

/// The concrete appearance an interface is drawn in. `system` has no meaning
/// once the preference is resolved, so it never appears here.
public enum ResolvedAppearance: String, Sendable {
    case light
    case dark

    /// `true` when the appearance wants a dark canvas.
    public var isDark: Bool { self == .dark }
}

/// The user's appearance preference, shared by the app and the CLI helpers.
///
/// It lives next to `LanguageSettings` and uses the same shape: a small locked
/// box so the value can be read from anywhere without becoming a `Sendable`
/// headache. The AppKit mapping (`NSAppearance`) stays in the app target —
/// `LLMProbeCore` is Foundation-only and compiles on Linux.
public final class AppearanceSettings: @unchecked Sendable {
    public static let shared = AppearanceSettings()

    /// `UserDefaults` key used by the macOS app.
    public static let defaultsKey = "LLMProbe.appearance"

    private let lock = NSLock()
    private var storedPreference: AppAppearance

    private init() {
        storedPreference = Self.loadPreference()
    }

    public var preference: AppAppearance {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPreference
        }
        set {
            lock.lock()
            storedPreference = newValue
            lock.unlock()
        }
    }

    /// Applies a preference and remembers it for the next launch.
    public func apply(_ preference: AppAppearance, persist: Bool = true) {
        self.preference = preference
        guard persist else { return }
        UserDefaults.standard.set(preference.rawValue, forKey: Self.defaultsKey)
    }

    /// Reads the stored preference (defaults to following the system).
    public static func loadPreference() -> AppAppearance {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let value = AppAppearance(rawValue: raw) else { return .system }
        return value
    }

    /// Maps a preference onto a concrete appearance.
    ///
    /// `systemIsDark` is injectable so the mapping can be checked without
    /// changing the reviewer's Mac settings — the same reason
    /// `LanguageSettings.resolve` takes its language list as a parameter.
    public static func resolve(_ preference: AppAppearance, systemIsDark: Bool) -> ResolvedAppearance {
        switch preference {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    /// Reads whether the Mac is currently running the dark appearance.
    ///
    /// `NSApp.effectiveAppearance` is the authoritative answer once AppKit is
    /// up; this `UserDefaults` key is the only signal available before that, so
    /// it is what the command line and the early launch path use. A Mac that has
    /// never switched appearance has no key at all, which means light.
    public static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
}

public extension AppAppearance {
    /// Parses the loose values a launch argument (or a shell) may carry.
    init?(commandLineValue raw: String) {
        switch raw.lowercased() {
        case "system", "auto": self = .system
        case "light", "aqua": self = .light
        case "dark", "darkaqua": self = .dark
        default: return nil
        }
    }
}
