import SwiftUI
import AppKit
import LLMProbeCore

/// Renders an app view straight into a PNG, without a visible window.
///
/// Used by `scripts/render_layout_check.sh`. `ImageRenderer` draws in process,
/// so the check works on a machine whose screen is locked — a state where
/// `screencapture` refuses and `CGWindowList` reports unusable window geometry.
/// It is a layout regression tool, not a screenshot pipeline: the published
/// screenshots still come from `scripts/capture_screenshots.sh`, which needs a
/// real window and an unlocked screen.
@MainActor
enum ViewRenderer {
    /// Handles `--render-view <name> --render-to <path> [--render-size WxH]`.
    /// Returns `true` when the process was started for rendering and must exit.
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let name = value(of: "--render-view", in: arguments) else { return false }
        guard let path = value(of: "--render-to", in: arguments) else {
            FileHandle.standardError.write(Data("--render-view requires --render-to <path>\n".utf8))
            exit(2)
        }
        let size = parseSize(value(of: "--render-size", in: arguments)) ?? NSSize(width: 1080, height: 680)
        // The appearance is already applied by AppDelegate from `--appearance`;
        // `LLM_PROBE_RENDER_APPEARANCE` overrides it for a one-off layout check.
        if let raw = ProcessInfo.processInfo.environment["LLM_PROBE_RENDER_APPEARANCE"],
           let override = AppAppearance(commandLineValue: raw) {
            NSApp.appearance = AppearanceController.nsAppearance(for: override)
        }

        let content: AnyView
        switch name {
        case "empty-state":
            content = AnyView(EmptyStateView().environmentObject(AppModel.shared))
        case "sidebar":
            content = AnyView(Sidebar().environmentObject(AppModel.shared).frame(width: 300))
        default:
            FileHandle.standardError.write(Data("unknown view '\(name)'; expected empty-state or sidebar\n".utf8))
            exit(2)
        }

        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("rendering '\(name)' produced no image\n".utf8))
            exit(3)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
            exit(3)
        }
        print("rendered \(name) \(Int(size.width))x\(Int(size.height)) -> \(path)")
        return true
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func parseSize(_ raw: String?) -> NSSize? {
        guard let raw else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return NSSize(width: width, height: height)
    }
}
