import AppKit

/// Briefly outlines a display so the user can see that keyboard focus just moved there.
@MainActor
final class FocusFlash {
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = FlashView()
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }()

    /// Bumped on every flash so an older fade-out doesn't hide a newer flash.
    private var generation = 0

    func show(on display: Display) {
        generation += 1
        let current = generation
        let window = self.window
        window.setFrame(display.screen.frame, display: true)
        window.alphaValue = 1
        window.orderFrontRegardless() // shows it without taking focus from anyone
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.generation == current else { return }
            self.window.orderOut(nil)
        }
    }
}

/// A glowing accent-coloured border around the edge of the screen.
private final class FlashView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        let glow = NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 12, yRadius: 12)
        glow.lineWidth = 14
        accent.withAlphaComponent(0.25).setStroke()
        glow.stroke()

        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
        edge.lineWidth = 6
        accent.withAlphaComponent(0.9).setStroke()
        edge.stroke()
    }
}
