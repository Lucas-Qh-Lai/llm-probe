import AppKit
import SwiftUI
import LLMProbeCore

/// The Settings window (⌘,).
///
/// Built by hand instead of with SwiftUI's `Settings` scene on purpose. That
/// scene lets SwiftUI animate the window to the content's fitting size
/// (`NSHostingView.updateAnimatedWindowSize`), and the grouped `Form` inside a
/// `TabView` re-lays itself out while the window is resizing. The two feed each
/// other until AppKit gives up:
///
///     NSGenericException: The window has been marked as needing another Layout
///     Window pass, but it has already had more Layout Window passes than there
///     are views in the window.
///
/// and the app aborts. `NSHostingController.sizingOptions = []` opts out of the
/// auto-resize; it is the same fix `AppDelegate` uses for its fallback window.
/// The title is kept in sync with `AppDelegate.isSettingsWindow` so the main
/// window's minimum-size guard never touches this one.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    /// The size the documentation screenshot expects. Fixed, because the
    /// hosting controller no longer sizes the window to its content.
    static let contentSize = NSSize(width: 460, height: 420)

    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView().environmentObject(AppModel.shared))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }

        let window = NSWindow(contentViewController: host)
        window.title = L10n.t("设置", "Settings")
        window.styleMask = [.titled, .closable]
        window.setContentSize(Self.contentSize)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
