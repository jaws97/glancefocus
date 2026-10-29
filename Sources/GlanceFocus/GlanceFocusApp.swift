import AppKit

@main
@MainActor
enum GlanceFocusApp {
    static func main() {
        // GlanceFocus lives in the menu bar only: no Dock icon, no main window.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
