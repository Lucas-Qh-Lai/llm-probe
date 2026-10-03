import AppKit
import SwiftUI
import LLMProbeCore

/// Guarantees a main window and gives it a deterministic size.
///
/// SwiftUI's `defaultSize` is only a hint. Two situations produce a degenerate
/// window instead:
///
/// * macOS window restoration reopens the app at whatever size a previous
///   session left behind, including a collapsed one.
/// * The window is created *after* launch, and it shrinks a second time when
///   the restored state finishes loading and the detail view (charts, matrix,
///   probe rows) replaces the empty state. A single delayed fix-up runs too
///   early and misses that second collapse.
///
/// The pin therefore runs on several delayed passes. It only ever acts when the
/// window is smaller than `minSize`, which the user cannot do either, so it
/// never fights a deliberate resize.
///
/// Delayed passes alone are still not enough: a window that the framework
/// resizes *after* the last pass is never examined again, and the app has no use
/// for a window below `minSize`. `installMinimumSizeGuard` therefore keeps
/// checking every resize for the whole session, which also covers a window that
/// SwiftUI shrinks to the fitting size of fresh content while the state load
/// finishes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferredSize = NSSize(width: 1340, height: 880)
    private let minimumSize = NSSize(width: 1080, height: 680)
    private let pinDelays: [Double] = [0.35, 0.9, 1.6, 2.6, 4.0, 6.0, 8.0]
    private weak var fallbackWindow: NSWindow?
    private var resizeGuard: NSObjectProtocol?
    /// Set while a repair is in flight so the repair's own resize notification
    /// cannot re-enter and start a shrink/repair loop with SwiftUI.
    private var isRepairingSize = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        startWindowTraceIfRequested()
        observeMainWindowCreation()
        installMinimumSizeGuard()
        schedulePin(pass: 0)
        scheduleFallbackWindow()
    }

    /// `LLM_PROBE_WINDOW_DEBUG=1` traces every resize and window creation.
    /// It exists because the collapse this class defends against is a race that
    /// only shows up on real launches, never in a debugger.
    private func startWindowTraceIfRequested() {
        guard ProcessInfo.processInfo.environment["LLM_PROBE_WINDOW_DEBUG"] != nil else { return }
        let started = Date()
        // When the app is started by LaunchServices (`open -n`) its stderr goes
        // nowhere, so the trace can also be pointed at a file. Set it on the GUI
        // session with `launchctl setenv LLM_PROBE_DEBUG_LOG /tmp/win.log`.
        let logPath = ProcessInfo.processInfo.environment["LLM_PROBE_DEBUG_LOG"]
        if let logPath, !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        nonisolated func trace(_ text: String) {
            let stamp = String(format: "%.3f", Date().timeIntervalSince(started))
            let line = "WINTRACE +\(stamp)s \(text)\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard let logPath else { return }
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
        trace("launch, windows=\(NSApp.windows.count)")
        trace("argv=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
        let argDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        trace("argumentDomain=\(argDomain)")
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                trace("\(name.rawValue) frame=\(window.frame) visible=\(window.isVisible) title=\(window.title)")
            }
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                trace("\(name.rawValue) frame=\(window.frame) title=\(window.title)")
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard Date().timeIntervalSince(started) < 20 else { timer.invalidate(); return }
            let dump = NSApp.windows.map { "\($0.frame.size)" }.joined(separator: " ")
            trace("tick windows[\(NSApp.windows.count)] \(dump)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Repairs a main window that has been shrunk below the declared minimum.
    ///
    /// `minSize` already stops a *user* from resizing this small, so any window
    /// under the minimum was resized by the framework, not by a person. The
    /// check runs for the lifetime of the process because the shrink is driven
    /// by content changes that can happen at any time.
    private func installMinimumSizeGuard() {
        resizeGuard = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                self?.repairIfTooSmall(window)
            }
        }
    }

    private func repairIfTooSmall(_ window: NSWindow) {
        guard !isRepairingSize,
              window.canBecomeMain,
              !window.isSheet,
              !isSettingsWindow(window),
              window !== fallbackWindow else { return }
        window.minSize = minimumSize
        let size = window.frame.size
        guard size.width < minimumSize.width || size.height < minimumSize.height else { return }
        isRepairingSize = true
        window.setContentSize(preferredSize)
        isRepairingSize = false
        if ProcessInfo.processInfo.environment["LLM_PROBE_WINDOW_DEBUG"] != nil {
            let line = "WINDOWDEBUG repaired window \(size) -> \(window.frame.size)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func schedulePin(pass: Int) {
        guard pass < pinDelays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pinDelays[pass]) { [weak self] in
            self?.pinMainWindow()
            self?.schedulePin(pass: pass + 1)
        }
    }

    /// macOS re-delivers a launch as a "reopen" to an app it still considers
    /// running, and a reopen with no windows to restore leaves an app that is
    /// running but shows nothing at all. Make sure that never sticks.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let windows = sender.windows.filter { $0.canBecomeMain }
            if let window = windows.first {
                window.makeKeyAndOrderFront(nil)
            } else {
                createFallbackWindowIfNeeded()
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// SwiftUI normally creates the `WindowGroup` window during launch. On real
    /// Macs that path can fail without throwing: the process stays alive while
    /// `NSApp.windows` remains empty and the content closure is never evaluated.
    /// A delayed AppKit-hosted window is the deterministic escape hatch. It is
    /// created only when no main-capable window exists, so the normal path never
    /// gets a second window.
    private func scheduleFallbackWindow() {
        let forced = ProcessInfo.processInfo.environment["LLM_PROBE_FORCE_FALLBACK_WINDOW"] != nil
        let delay: Double = forced ? 0.15 : 0.85
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.createFallbackWindowIfNeeded(force: forced)
        }
    }

    private func createFallbackWindowIfNeeded(force: Bool = false) {
        guard fallbackWindow == nil else { return }
        let existingMainWindows = NSApp.windows.filter {
            $0.canBecomeMain && !$0.isSheet && !self.isSettingsWindow($0)
        }
        guard force || existingMainWindows.isEmpty else { return }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("dev.llmprobe.app.fallback-window")
        window.title = "LLMProbe"
        window.minSize = minimumSize
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: ContentView().environmentObject(AppModel.shared))
        // Without this the hosting controller resizes the window to the content's
        // fitting size as soon as the state load replaces what the detail view
        // shows, which is the collapse this class exists to prevent.
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        window.contentViewController = host
        window.center()
        fallbackWindow = window
        FileHandle.standardError.write(Data("WINDOWDEBUG fallback-created\n".utf8))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if force {
            existingMainWindows.filter { $0 !== window }.forEach { $0.close() }
        }
    }

    /// If the regular SwiftUI window appears after the fallback was installed,
    /// keep the regular one and remove only the fallback. Settings windows are
    /// intentionally retained: they can coexist with the main window.
    private func observeMainWindowCreation() {
        for name in [NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self,
                          let window = note.object as? NSWindow,
                          window !== self.fallbackWindow,
                          window.canBecomeMain,
                          !window.isSheet,
                          !self.isSettingsWindow(window) else { return }
                    self.fallbackWindow?.close()
                    self.fallbackWindow = nil
                }
            }
        }
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        ["Settings", "设置"].contains(window.title)
    }

    private func pinMainWindow() {
        // SwiftUI can defer creating the WindowGroup window until the app is
        // activated. A launch that never becomes active then shows nothing at
        // all — the process is alive, `NSApp.windows` stays empty and the user
        // sees the app "not opening". Activating again is what breaks the tie.
        if !NSApp.windows.contains(where: { $0.canBecomeMain }) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }
        if ProcessInfo.processInfo.environment["LLM_PROBE_WINDOW_DEBUG"] != nil {
            let dump = NSApp.windows.map { w in
                "\(type(of: w)) frame=\(w.frame) visible=\(w.isVisible) canBecomeMain=\(w.canBecomeMain) sheet=\(w.isSheet) title=\(w.title)"
            }.joined(separator: " | ")
            let line = "WINDOWDEBUG \(dump)\n"
            FileHandle.standardError.write(Data(line.utf8))
            if let logPath = ProcessInfo.processInfo.environment["LLM_PROBE_DEBUG_LOG"],
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
        let windows = NSApp.windows.filter { $0.canBecomeMain }
        guard let window = windows.first(where: { $0 !== fallbackWindow })
                ?? fallbackWindow
                ?? NSApp.windows.first else { return }
        window.minSize = minimumSize
        let frame = window.frame
        if frame.width < minimumSize.width || frame.height < minimumSize.height {
            window.setContentSize(preferredSize)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
