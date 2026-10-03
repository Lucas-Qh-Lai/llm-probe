import AppKit
import LLMProbeCore

/// Gives the window a deterministic size and brings it to the front.
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferredSize = NSSize(width: 1340, height: 880)
    private let minimumSize = NSSize(width: 1080, height: 680)
    private let pinDelays: [Double] = [0.35, 0.9, 1.6, 2.6, 4.0, 6.0, 8.0]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        startWindowTraceIfRequested()
        schedulePin(pass: 0)
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
        func trace(_ text: String) {
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
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
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
        guard let window = windows.first ?? NSApp.windows.first else { return }
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
