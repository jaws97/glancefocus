import AppKit
import ApplicationServices

/// Moves keyboard focus (and optionally the pointer) to a display, using the Accessibility API.
@MainActor
enum FocusSwitcher {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings › Privacy & Security › Accessibility.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Focuses the frontmost window on `display`, unless keyboard focus is already on it.
    /// Returns true when focus moved.
    static func focus(_ display: Display) -> Bool {
        guard isTrusted else { return false }
        if let focused = focusedWindowFrame(), display.bounds.contains(focused.center) { return false }
        guard let target = frontmostWindow(on: display) else { return false }
        return raise(pid: target.pid, frame: target.frame, on: display)
    }

    /// Where the pointer last was on each display, so it returns there instead of jumping to the
    /// middle. Kept in memory only.
    private static var lastPointer: [CGDirectDisplayID: CGPoint] = [:]

    static func movePointer(to display: Display, displays: [Display]) {
        guard let current = CGEvent(source: nil)?.location, !display.bounds.contains(current) else { return }
        if let from = displays.first(where: { $0.bounds.contains(current) }) {
            lastPointer[from.id] = current
        }
        let remembered = lastPointer[display.id].flatMap { display.bounds.contains($0) ? $0 : nil }
        _ = CGWarpMouseCursorPosition(remembered ?? display.bounds.center)
        _ = CGAssociateMouseAndMouseCursorPosition(1) // keep the pointer responsive right after warping
    }

    private static func focusedWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window: AXUIElement = appElement(pid).value(of: kAXFocusedWindowAttribute) else { return nil }
        return window.frame
    }

    /// The topmost ordinary window whose centre is on `display`. The window list is front to back.
    private static func frontmostWindow(on display: Display) -> (pid: pid_t, frame: CGRect)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 40, frame.height > 40,
                  display.bounds.contains(frame.center) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            return (pid, frame)
        }
        return nil
    }

    private static func raise(pid: pid_t, frame: CGRect, on display: Display) -> Bool {
        let app = appElement(pid)
        guard let windows: [AXUIElement] = app.value(of: kAXWindowsAttribute) else { return false }
        let candidates = windows.filter { $0.value(of: kAXMinimizedAttribute) != true }
        let match = candidates.first { $0.frame?.isClose(to: frame) == true }
            ?? candidates.first { $0.frame.map { display.bounds.contains($0.center) } == true }
        guard let window = match else { return false }

        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.5) // never let a frozen app stall GlanceFocus
        return app
    }
}

private extension AXUIElement {
    func value<T>(of attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var frame: CGRect? {
        guard let position: AXValue = value(of: kAXPositionAttribute),
              let size: AXValue = value(of: kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
