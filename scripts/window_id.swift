// Prints the window id of a running app, for `screencapture -l <id>`.
//
// Usage: swift scripts/window_id.swift LLMProbe [--info | --list]
//
// `--info` also prints the window size, which is how the "the window opens at a
// degenerate size" regression is checked.
// `--list` prints every window of the app as "<id> <width>x<height> <title>",
// which the screenshot script uses to find the Settings panel.
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "LLMProbe"
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not read the window list\n".utf8))
    exit(1)
}

var found: [(id: Int, area: Double, width: Double, height: Double, title: String)] = []
for window in info {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == target else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }
    let width = (bounds["Width"] as? Double) ?? 0
    let height = (bounds["Height"] as? Double) ?? 0
    // Skip tiny helper windows; keep the largest.
    guard width > 400, height > 300 else { continue }
    let area = width * height
    let title = (window[kCGWindowName as String] as? String) ?? ""
    found.append((number, area, width, height, title))
}

guard let best = found.max(by: { $0.area < $1.area }) else {
    FileHandle.standardError.write(Data("no window found for \(target)\n".utf8))
    exit(1)
}
if CommandLine.arguments.contains("--list") {
    for window in found.sorted(by: { $0.area > $1.area }) {
        print("\(window.id) \(Int(window.width))x\(Int(window.height)) \(window.title)")
    }
} else if CommandLine.arguments.contains("--info") {
    print("\(best.id) \(Int(best.width))x\(Int(best.height))")
} else {
    print(best.id)
}
