import AppKit

/// Shows a dot on each display in turn and records the user's head pose while they look at it.
@MainActor
final class CalibrationController: NSObject {
    private let displays: [Display]
    private let completion: (Calibration?) -> Void
    private let window: OverlayWindow
    private let view = OverlayView()
    private var timer: Timer?

    private enum Phase { case settling, collecting, finished }
    private var phase = Phase.settling
    private var phaseStart = CFAbsoluteTimeGetCurrent()
    private var index = 0
    private var receivedAnyFrame = false
    private var samples: [String: [HeadPose]] = [:]
    private var frames: [String: Int] = [:]
    private var result: Calibration?

    /// Time to turn toward the dot, time spent sampling, and how long the closing message stays up.
    private static let settleTime = 1.2, collectTime = 2.0, messageTime = 2.5

    init(displays: [Display], completion: @escaping (Calibration?) -> Void) {
        self.displays = displays
        self.completion = completion
        window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.contentView = view
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
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
        close()
        // Esc on the closing message just dismisses it early; the calibration still counts.
        completion(phase == .finished ? result : nil)
    }

    private func showStep() {
        window.setFrame(displays[index].screen.frame, display: true)
        view.showsDot = true
        view.progress = 0
        view.title = "Look at the dot"
        view.subtitle = "Turn your head toward this screen the way you normally would.\nScreen \(index + 1) of \(displays.count) · Esc to cancel"
        window.makeKeyAndOrderFront(nil)
        phase = .settling
        phaseStart = CFAbsoluteTimeGetCurrent()
    }

    @objc private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - phaseStart
        switch phase {
        case .settling:
            // Wait for the camera to warm up before the first screen, but don't wait forever.
            if receivedAnyFrame && elapsed >= Self.settleTime {
                phase = .collecting
                phaseStart = now
            } else if !receivedAnyFrame && elapsed >= 8 {
                finish()
            }
        case .collecting:
            view.progress = min(1, elapsed / Self.collectTime)
            guard elapsed >= Self.collectTime else { return }
            index += 1
            if index < displays.count { showStep() } else { finish() }
        case .finished:
            guard elapsed >= Self.messageTime else { return }
            close()
            completion(result)
        }
    }

    private func finish() {
        result = Calibration.make(samples: samples, frames: frames)
        view.showsDot = false
        if let result {
            view.title = "All set"
            if let degrees = result.smallestSeparationDegrees, degrees < 6 {
                view.subtitle = "Your head barely moved between screens, so switching may be unreliable.\nCalibrate again and turn your head, not just your eyes, toward each dot."
            } else {
                view.subtitle = "Typing now goes to the screen you're looking at."
            }
        } else if !receivedAnyFrame {
            view.title = "The camera isn't responding"
            view.subtitle = "Close other apps using the camera, then choose Calibrate… again."
        } else {
            view.title = "Couldn't see your face clearly"
            view.subtitle = "Make sure your face is lit and in view of the camera, then choose Calibrate… again."
        }
        phase = .finished
        phaseStart = CFAbsoluteTimeGetCurrent()
    }

    private func close() {
        timer?.invalidate()
        timer = nil
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

/// Dims the display and draws the target dot, a progress ring, and instructions.
final class OverlayView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var progress = 0.0 { didSet { needsDisplay = true } }
    var showsDot = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        bounds.fill()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if showsDot {
            let radius: CGFloat = 36
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 4
            NSColor.white.withAlphaComponent(0.15).setStroke()
            track.stroke()

            if progress > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: CGFloat(90 - 360 * progress), clockwise: true)
                arc.lineWidth = 4
                arc.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                arc.stroke()
            }

            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)).fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let width = min(bounds.width - 80, 680)
        let x = bounds.midX - width / 2
        let titleY = showsDot ? center.y - 110 : center.y + 10
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
}
