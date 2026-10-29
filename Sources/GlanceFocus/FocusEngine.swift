import AppKit

/// Turns the stream of head poses into focus changes.
///
/// A display takes focus once the user has looked at it for `Settings.dwell` seconds. The switch is
/// skipped when the user was typing as their head turned (they're glancing at the other screen
/// while typing here), or when they click after turning (they're choosing focus themselves).
@MainActor
final class FocusEngine {
    var onGazeChange: (() -> Void)?
    /// Called after keyboard focus has moved to a display.
    var onSwitch: ((Display) -> Void)?
    /// The display the user is settled on (after the switch delay).
    private(set) var gaze: Display? {
        didSet { if gaze != oldValue { onGazeChange?() } }
    }
    /// The display the latest frame points at, before the switch delay; nil when unsure.
    private(set) var looking: Display?

    /// A key press this recent when the head turns counts as "still typing".
    private let typingGap = 0.4

    private var smoothed: HeadPose?
    private var faceLostSince: CFAbsoluteTime?
    private var candidate: (display: Display, since: CFAbsoluteTime, whileTyping: Bool)?
    private var pendingSwitch: (display: Display, since: CFAbsoluteTime)?

    func reset() {
        smoothed = nil
        faceLostSince = nil
        candidate = nil
        pendingSwitch = nil
        looking = nil
        gaze = nil
    }

    func process(_ pose: HeadPose?, calibration: Calibration, displays: [Display]) {
        let now = CFAbsoluteTimeGetCurrent()
        looking = classify(pose, calibration: calibration, displays: displays, now: now)
        if let looked = looking {
            if candidate?.display != looked {
                candidate = (looked, now, InputActivity.sinceKeyPress < typingGap)
            }
            if let candidate, candidate.display != gaze, now - candidate.since >= Settings.dwell {
                gaze = candidate.display
                pendingSwitch = candidate.whileTyping ? nil : (display: candidate.display, since: candidate.since)
            }
        }
        if let pendingSwitch { attemptSwitch(pendingSwitch, displays: displays, now: now) }
    }

    /// The display the pose points at, or nil when it can't tell (keep whatever was there).
    private func classify(_ pose: HeadPose?, calibration: Calibration, displays: [Display], now: CFAbsoluteTime) -> Display? {
        guard let pose else {
            // No face: a brief detection dropout, or the user turned so far toward a display that
            // the camera can't see their face any more.
            smoothed = nil
            let since = faceLostSince ?? now
            faceLostSince = since
            guard now - since >= 0.6 else { return nil }
            return displays.first { $0.key == calibration.faceLostDisplay }
        }
        faceLostSince = nil

        let current = smoothed.map { HeadPose(yaw: ($0.yaw + pose.yaw) / 2, pitch: ($0.pitch + pose.pitch) / 2) } ?? pose
        smoothed = current

        let scored = displays.compactMap { display in
            calibration.distance(from: current, to: display.key).map { (display: display, distance: $0) }
        }
        guard let best = scored.min(by: { $0.distance < $1.distance }) else { return nil }
        // Hysteresis: only leave the display being looked at when another one is clearly closer.
        if let looking = scored.first(where: { $0.display == gaze }),
           looking.display != best.display,
           best.distance > 0.6 * looking.distance {
            return looking.display
        }
        return best.display
    }

    private func attemptSwitch(_ request: (display: Display, since: CFAbsoluteTime), displays: [Display], now: CFAbsoluteTime) {
        let elapsed = now - request.since
        if InputActivity.sinceClick < elapsed {
            pendingSwitch = nil // clicked since the head turn: the user picked focus themselves
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else { return } // wait for a drag to finish
        pendingSwitch = nil
        if FocusSwitcher.focus(request.display) { onSwitch?(request.display) }
        // Leave the pointer alone if the user is already moving it themselves.
        if Settings.movePointer && InputActivity.sinceMouseMove >= elapsed {
            FocusSwitcher.movePointer(to: request.display, displays: displays)
        }
    }
}

/// How long ago the user last typed, clicked, or moved the mouse. macOS reports only the time
/// since the last event of each kind; which keys were pressed is never seen.
enum InputActivity {
    static var sinceKeyPress: Double { secondsSince(.keyDown) }
    static var sinceClick: Double { secondsSince(.leftMouseDown, .rightMouseDown, .otherMouseDown) }
    static var sinceMouseMove: Double { secondsSince(.mouseMoved, .leftMouseDragged, .scrollWheel) }
    static var sinceAnyInput: Double { min(sinceKeyPress, sinceClick, sinceMouseMove) }

    private static func secondsSince(_ types: CGEventType...) -> Double {
        types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }
}
