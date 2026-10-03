import SwiftUI
import AppKit

/// Applies a deterministic window size on launch.
///
/// Without this, macOS window restoration can reopen the app at whatever size a
/// previous session left behind — including a degenerate one. Pinning the size
/// also keeps documentation screenshots reproducible.
struct WindowConfigurator: NSViewRepresentable {
    var size: NSSize = NSSize(width: 1340, height: 880)
    var minimumSize: NSSize = NSSize(width: 1080, height: 680)
    /// When true the window is centred once, on first appearance.
    var center: Bool = true

    func makeNSView(context: Context) -> NSView {
        ConfiguringView(size: size, minimumSize: minimumSize, shouldCenter: center)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ConfiguringView: NSView {
    private let size: NSSize
    private let minimumSize: NSSize
    private let shouldCenter: Bool
    private var didConfigure = false

    init(size: NSSize, minimumSize: NSSize, shouldCenter: Bool) {
        self.size = size
        self.minimumSize = minimumSize
        self.shouldCenter = shouldCenter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didConfigure else { return }
        didConfigure = true
        // Resize on the next runloop turn so SwiftUI finishes its own layout
        // pass first; touching the window synchronously here makes SwiftUI
        // recompute the content size and collapse the window.
        DispatchQueue.main.async {
            window.minSize = self.minimumSize
            let frame = window.frame
            guard frame.width < self.minimumSize.width || frame.height < self.minimumSize.height else { return }
            window.setContentSize(self.size)
            if self.shouldCenter { window.center() }
        }
    }
}
