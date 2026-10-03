import Foundation

/// Runs a short-lived local command and captures its output.
///
/// Used only to read local databases through the system `sqlite3` binary, which
/// keeps the app dependency-free. Nothing is written and nothing leaves the Mac.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public var isSuccess: Bool { status == 0 }
    }

    public static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 10) -> Output? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Keep the environment minimal so no credentials leak into a child process.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.lowercased().contains("key") || key.lowercased().contains("token")
            || key.lowercased().contains("secret") || key.lowercased().contains("password") {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Output(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    public static let sqlitePath = "/usr/bin/sqlite3"
}
