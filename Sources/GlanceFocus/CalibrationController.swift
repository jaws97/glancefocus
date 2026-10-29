import AppKit

/// Shows a dot on each display in turn and records the user's head pose while they look at it.
///
/// Everything is driven by one 30 fps timer: the phases, the dot's pulse, the progress ring, the
/// fades between screens and the closing checkmark. No other timers or callbacks are involved.
@MainActor
final class CalibrationController: NSObject {
    private let displays: [Display]
    private let completion: (Calibration?) -> Void
    private let window: OverlayWindow
    private let view = OverlayView()
    private var timer: Timer?

    private enum Phase { case settling, collecting, finished, fading }
    /// What to do once the overlay has faded out.
    private enum AfterFade { case nextScreen, close }

    private var phase = Phase.settling
    private var phaseStart = CFAbsoluteTimeGetCurrent()
    private let startTime = CFAbsoluteTimeGetCurrent()
    private var targetAlpha: CGFloat = 1
    private var afterFade: AfterFade?
    private var index = 0
    private var receivedAnyFrame = false
    private var samples: [String: [HeadPose]] = [:]
    private var frames: [String: Int] = [:]
    private var result: Calibration?

    /// Time to turn toward the dot, time spent sampling, and how long the closing message stays up.
    private static let settleTime = 1.2, collectTime = 2.0, messageTime = 2.5
    /// Alpha change per tick, so a fade takes about 0.2 s.
    private static let fadeStep: CGFloat = 1.0 / 6

    init(displays: [Display], completion: @escaping (Calibration?) -> Void) {
        self.displays = displays
        self.completion = completion
        window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.contentView = view
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0 // fades in
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onCancel = { [weak self] in self?.cancel() }
    }

    func start() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        showStep()
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    func add(_ pose: HeadPose?) {
        receivedAnyFrame = true
        guard phase == .collecting else { return }
        let key = displays[index].key
        frames[key, default: 0] += 1
        if let pose { samples[key, default: []].append(pose) }
    }

    func cancel() {
        guard timer != nil else { return }
        // Esc on the closing message just dismisses it early; the calibration still counts.
        let keepResult = phase == .finished || afterFade == .close
        close()
        completion(keepResult ? result : nil)
    }

    private func showStep() {
        window.setFrame(displays[index].screen.frame, display: true)
        view.mark = nil
        view.showsDot = true
        view.pulsing = true
        view.progress = 0
        view.title = receivedAnyFrame ? "Look at the dot" : "Starting the camera…"
        view.subtitle = "Turn your head toward this screen the way you normally would.\nScreen \(index + 1) of \(displays.count) · Esc to cancel"
        window.makeKeyAndOrderFront(nil)
        targetAlpha = 1
        phase = .settling
        phaseStart = CFAbsoluteTimeGetCurrent()
    }

    @objc private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        view.time = now - startTime
        // When a fade finishes this may move to the next screen or close everything; in the
        // second case the controller can be released right after, so stop touching it.
        if fadeTowardTarget() { return }

        let elapsed = now - phaseStart
        switch phase {
        case .settling:
            // Wait for the camera to warm up before the first screen, but don't wait forever.
            if receivedAnyFrame && view.title != "Look at the dot" { view.title = "Look at the dot" }
            if receivedAnyFrame && elapsed >= Self.settleTime {
                phase = .collecting
                phaseStart = now
                view.pulsing = false
            } else if !receivedAnyFrame && elapsed >= 8 {
                finish()
            }
        case .collecting:
            view.progress = min(1, elapsed / Self.collectTime)
            guard elapsed >= Self.collectTime else { return }
            index += 1
            if index < displays.count { fadeOut(then: .nextScreen) } else { finish() }
        case .finished:
            view.markProgress = min(1, elapsed / 0.5)
            if elapsed >= Self.messageTime { fadeOut(then: .close) }
        case .fading:
            break
        }
    }

    private func fadeOut(then next: AfterFade) {
        phase = .fading
        afterFade = next
        targetAlpha = 0
    }

    /// Moves the window's opacity one step toward `targetAlpha`. Returns true if a finished fade-out
    /// ran its follow-up action.
    private func fadeTowardTarget() -> Bool {
        let alpha = window.alphaValue
        if alpha < targetAlpha {
            window.alphaValue = min(targetAlpha, alpha + Self.fadeStep)
        } else if alpha > targetAlpha {
            window.alphaValue = max(targetAlpha, alpha - Self.fadeStep)
        } else if alpha == 0, let next = afterFade {
            afterFade = nil
            switch next {
            case .nextScreen:
                showStep()
            case .close:
                close()
                completion(result)
            }
            return true
        }
        return false
    }

    private func finish() {
        result = Calibration.make(samples: samples, frames: frames)
        view.showsDot = false
        view.pulsing = false
        view.markProgress = 0
        if let result {
            view.mark = .success
            view.title = "All set"
            if let degrees = result.smallestSeparationDegrees, degrees < 6 {
                view.mark = .failure
                view.title = "Saved, with a warning"
                view.subtitle = "Your head barely moved between screens, so switching may be unreliable.\nCalibrate again and turn your head, not just your eyes, toward each dot."
            } else {
                view.subtitle = "Typing now goes to the screen you're looking at."
            }
        } else if !receivedAnyFrame {
            view.mark = .failure
            view.title = "The camera isn't responding"
            view.subtitle = "Close other apps using the camera, then choose Calibrate… again."
        } else {
            view.mark = .failure
            view.title = "Couldn't see your face clearly"
            view.subtitle = "Make sure your face is lit and in view of the camera, then choose Calibrate… again."
        }
        phase = .finished
        phaseStart = CFAbsoluteTimeGetCurrent()
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        afterFade = nil
        window.orderOut(nil)
        NSApp.hide(nil) // hand keyboard focus back to the app the user was in
    }
}

/// Borderless full-screen window that can take key focus so Esc cancels calibration.
final class OverlayWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Dims the display and draws the target dot, progress ring, result mark and instructions.
final class OverlayView: NSView {
    enum Mark { case success, failure }

    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var progress = 0.0 { didSet { needsDisplay = true } }
    var showsDot = true { didSet { needsDisplay = true } }
    /// A breathing dot with a ripple, while the camera starts and the user turns toward the screen.
    var pulsing = false { didSet { needsDisplay = true } }
    var mark: Mark? { didSet { needsDisplay = true } }
    /// 0…1 as the result mark draws itself in.
    var markProgress = 0.0 { didSet { needsDisplay = true } }
    /// Seconds since calibration began; drives the pulse.
    var time = 0.0 { didSet { if pulsing && !reduceMotion { needsDisplay = true } } }
    /// Follows the system "Reduce motion" setting: no pulsing, marks appear without drawing in.
    var reduceMotion = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        bounds.fill()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if showsDot { drawTarget(at: center) }
        if let mark { drawMark(mark, at: center) }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let width = min(bounds.width - 80, 680)
        let x = bounds.midX - width / 2
        let titleY = center.y - 110
        (title as NSString).draw(in: NSRect(x: x, y: titleY, width: width, height: 36), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        (subtitle as NSString).draw(in: NSRect(x: x, y: titleY - 60, width: width, height: 56), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            .paragraphStyle: paragraph,
        ])
    }

    private func drawTarget(at center: NSPoint) {
        let ringRadius: CGFloat = 36
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
        track.lineWidth = 4
        NSColor.white.withAlphaComponent(0.15).setStroke()
        track.stroke()

        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: ringRadius, startAngle: 90,
                          endAngle: CGFloat(90 - 360 * progress), clockwise: true)
            arc.lineWidth = 4
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
        }

        var dotRadius: CGFloat = 9
        if pulsing && !reduceMotion {
            let cycle = 1.4
            let phase = time.truncatingRemainder(dividingBy: cycle) / cycle
            // A ripple that grows outward and fades, like a ping, to draw the eye to the dot.
            let rippleRadius = CGFloat(12 + 44 * phase)
            let ripple = NSBezierPath(ovalIn: NSRect(x: center.x - rippleRadius, y: center.y - rippleRadius,
                                                     width: rippleRadius * 2, height: rippleRadius * 2))
            ripple.lineWidth = 2
            NSColor.white.withAlphaComponent(CGFloat(0.45 * (1 - phase))).setStroke()
            ripple.stroke()
            // The dot itself breathes in time with the ripple.
            dotRadius += CGFloat(2.5 * sin(phase * 2 * .pi))
        }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                    width: dotRadius * 2, height: dotRadius * 2)).fill()
    }

    /// A coloured disc that grows in, then a white checkmark (or "!") that draws itself.
    private func drawMark(_ mark: Mark, at center: NSPoint) {
        let p = CGFloat(reduceMotion ? 1 : markProgress)

        let grow = min(1, p / 0.4)
        let remaining = 1 - grow
        let radius = 32 * (1 - remaining * remaining * remaining) // ease out
        let color: NSColor = mark == .success ? .systemGreen : .systemOrange
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()

        let draw = max(0, min(1, (p - 0.4) / 0.6))
        guard draw > 0 else { return }
        let path = NSBezierPath()
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch mark {
        case .success:
            let points = [CGPoint(x: -13, y: 1), CGPoint(x: -4, y: -9), CGPoint(x: 14, y: 10)]
                .map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
            let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            var left = lengths.reduce(0, +) * draw
            path.move(to: points[0])
            for (i, length) in lengths.enumerated() where left > 0 {
                let t = min(1, left / length)
                let a = points[i], b = points[i + 1]
                path.line(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                left -= length
            }
            NSColor.white.setStroke()
        case .failure:
            path.move(to: CGPoint(x: center.x, y: center.y + 14))
            path.line(to: CGPoint(x: center.x, y: center.y - 1))
            path.move(to: CGPoint(x: center.x, y: center.y - 10))
            path.line(to: CGPoint(x: center.x, y: center.y - 10.5))
            NSColor.white.withAlphaComponent(draw).setStroke()
        }
        path.stroke()
    }
}
