import Foundation

/// Path helpers shared by discovery, storage and the CLI.
public enum PathTools {
    public static var homeDirectory: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        return NSHomeDirectory()
    }

    /// Expands a leading `~` and any environment variable form `$VAR`.
    public static func expand(_ path: String) -> String {
        var value = (path as NSString).expandingTildeInPath
        let environment = ProcessInfo.processInfo.environment
        if value.contains("$") {
            for (key, replacement) in environment.sorted(by: { $0.key.count > $1.key.count }) {
                value = value.replacingOccurrences(of: "$\(key)", with: replacement)
                value = value.replacingOccurrences(of: "${\(key)}", with: replacement)
            }
        }
        return value
    }

    /// `~/Library/...` style short form, for display only.
    public static func abbreviate(_ path: String) -> String {
        let home = homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func appSupportDirectory(appName: String = "LLMProbe") -> URL {
        let base: URL
        #if os(macOS)
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Application Support")
        #else
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config")
        }
        #endif
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// True when the file exists and is readable.
    public static func isReadableFile(_ path: String) -> Bool {
        let expanded = expand(path)
        return FileManager.default.isReadableFile(atPath: expanded)
    }

    public static func readText(_ path: String) -> String? {
        let expanded = expand(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func readJSON(_ path: String) -> Any? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expand(path))) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func relativeToHome(_ path: String) -> String {
        abbreviate(expand(path))
    }
}
