import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

/// The menu bar item, plus the rules for when the camera is allowed to run.
///
/// The camera is only on while it is useful: focus-following is enabled, at least two calibrated
/// displays are connected, the screen is awake and unlocked, and the user has been active recently.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = HeadTracker()
    private let engine = FocusEngine()
    private let flash = FocusFlash()
    private var pauseHotkey: Hotkey?
    private var calibration = Calibration.load()
    private var calibrator: CalibrationController?
    private var displays: [Display] = []
    private var screensAsleep = false
    private var screenLocked = false
    private var userIdle = false
    private var askedForAccessibility = false
    private var iconPulse: Timer?
    private var iconPulseStart = CFAbsoluteTimeGetCurrent()

    /// Turn the camera off after this long without keyboard or mouse input.
    private let idleTimeout: TimeInterval = 5 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        displays = Displays.current()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        tracker.onPose = { [weak self] pose in self?.handle(pose) }
        engine.onGazeChange = { [weak self] in self?.updateIcon() }
        engine.onSwitch = { [weak self] display in
            if Settings.flashOnSwitch { self?.flash.show(on: display) }
        }
        // ⌃⌥⌘G pauses and resumes from anywhere.
        pauseHotkey = Hotkey(keyCode: kVK_ANSI_G, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggleEnabled()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(checkIdle), userInfo: nil, repeats: true)

        updateTracking()
        requestCameraAccess { [weak self] in
            guard let self else { return }
            if self.calibration == nil && self.displays.count > 1 {
                self.calibrate()
            } else {
                self.askForAccessibilityIfNeeded()
                self.updateTracking()
            }
        }
    }

    // MARK: - Tracking

    private var shouldTrack: Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return false }
        if calibrator != nil { return true }
        guard Settings.enabled, !screensAsleep, !screenLocked, !userIdle, let calibration else { return false }
        return calibration.usableDisplays(in: displays).count >= 2
    }

    private func updateTracking() {
        let wasRunning = tracker.isRunning
        if shouldTrack {
            tracker.start(cameraID: Settings.cameraID)
        } else {
            tracker.stop()
            engine.reset()
        }
        if tracker.isRunning && !wasRunning { startIconPulse() }
        if !tracker.isRunning { stopIconPulse() }
        updateIcon()
    }

    /// While the camera warms up, the menu bar eye gently pulses until the first frame arrives.
    private func startIconPulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        iconPulse?.invalidate()
        iconPulseStart = CFAbsoluteTimeGetCurrent()
        iconPulse = Timer.scheduledTimer(timeInterval: 1.0 / 20, target: self, selector: #selector(pulseIcon), userInfo: nil, repeats: true)
    }

    private func stopIconPulse() {
        iconPulse?.invalidate()
        iconPulse = nil
        statusItem.button?.alphaValue = 1
    }

    @objc private func pulseIcon() {
        let elapsed = CFAbsoluteTimeGetCurrent() - iconPulseStart
        statusItem.button?.alphaValue = CGFloat(0.6 + 0.4 * cos(elapsed * 2 * .pi / 1.2))
    }

    private func handle(_ pose: HeadPose?) {
        guard tracker.isRunning else { return }
        if iconPulse != nil { stopIconPulse() } // the camera is up
        if let calibrator {
            calibrator.add(pose)
        } else if let calibration {
            engine.process(pose, calibration: calibration, displays: displays)
        }
        if Settings.showHeadAngles { showReadout(pose) }
    }

    /// Debug readout next to the menu bar icon: "turn°, tilt° → screen number".
    private func showReadout(_ pose: HeadPose?) {
        guard let pose else {
            statusItem.button?.title = " no face"
            return
        }
        let screen = calibrator == nil ? engine.looking.flatMap { displays.firstIndex(of: $0) } : nil
        let target = screen.map { " → \($0 + 1)" } ?? ""
        statusItem.button?.title = " \(degrees(pose.yaw))°, \(degrees(pose.pitch))°\(target)"
    }

    private func degrees(_ radians: Double) -> Int {
        Int((radians * 180 / .pi).rounded())
    }

    @objc private func calibrate() {
        guard calibrator == nil, displays.count > 1 else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            openPrivacySettings("Privacy_Camera")
            return
        }
        engine.reset()
        let controller = CalibrationController(displays: displays) { [weak self] result in
            guard let self else { return }
            self.calibrator = nil
            if let result {
                result.save()
                self.calibration = result
            }
            self.askForAccessibilityIfNeeded()
            self.updateTracking()
        }
        calibrator = controller
        updateTracking()
        controller.start()
    }

    private func requestCameraAccess(then next: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            next()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { next() } else { self.updateTracking() }
                }
            }
        default:
            break
        }
    }

    private func askForAccessibilityIfNeeded() {
        guard !FocusSwitcher.isTrusted, !askedForAccessibility else { return }
        askedForAccessibility = true
        FocusSwitcher.requestTrust()
    }

    // MARK: - System events

    @objc private func screensChanged() {
        let updated = Displays.current()
        if updated.map(\.key) != displays.map(\.key) { calibrator?.cancel() }
        displays = updated
        engine.reset()
        updateTracking()
    }

    @objc private func screensDidSleep() { screensAsleep = true; updateTracking() }
    @objc private func screensDidWake() { screensAsleep = false; updateTracking() }
    @objc private func screenDidLock() { screenLocked = true; updateTracking() }
    @objc private func screenDidUnlock() { screenLocked = false; updateTracking() }

    @objc private func checkIdle() {
        let idle = InputActivity.sinceAnyInput > idleTimeout
        guard idle != userIdle else { return }
        userIdle = idle
        updateTracking()
    }

    // MARK: - Menu

    private var statusText: String {
        if calibrator != nil { return "Calibrating…" }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: return "Waiting for camera permission"
        default: return "Camera access is turned off"
        }
        if displays.count < 2 { return "Only one display connected" }
        guard let calibration else { return "Not calibrated yet" }
        if calibration.usableDisplays(in: displays).count < 2 { return "Calibrate for these displays" }
        if !Settings.enabled { return "Paused" }
        if screensAsleep || screenLocked || userIdle { return "Resting until you're back" }
        if !FocusSwitcher.isTrusted { return "Needs Accessibility access" }
        if let gaze = engine.gaze { return "Looking at \(gaze.name)" }
        return "Looking for your face…"
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: tracker.isRunning ? "eye" : "eye.slash",
                               accessibilityDescription: "GlanceFocus")
        button.toolTip = "GlanceFocus: \(statusText)"

        let readout = Settings.showHeadAngles && tracker.isRunning
        statusItem.length = readout ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.imagePosition = readout ? .imageLeft : .imageOnly
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        if !readout { button.title = "" }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(label(statusText))
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            menu.addItem(item("Allow Camera Access…", #selector(openCameraSettings)))
        default:
            break
        }
        if !FocusSwitcher.isTrusted {
            menu.addItem(item("Allow Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        let follow = item("Follow My Gaze", #selector(toggleEnabled), checked: Settings.enabled, key: "g")
        follow.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(follow)
        let calibrateItem = item("Calibrate…", #selector(calibrate))
        calibrateItem.isEnabled = displays.count > 1 && calibrator == nil
        menu.addItem(calibrateItem)
        menu.addItem(.separator())

        let delays = NSMenu()
        for (title, seconds) in [("Quick (0.25 s)", 0.25), ("Normal (0.4 s)", 0.4), ("Relaxed (0.7 s)", 0.7), ("Slow (1 s)", 1.0)] {
            let option = item(title, #selector(setDelay(_:)), checked: abs(Settings.dwell - seconds) < 0.01)
            option.representedObject = seconds
            delays.addItem(option)
        }
        menu.addItem(submenu("Switch Delay", delays))

        let cameras = HeadTracker.availableCameras()
        if cameras.count > 1 {
            let selected = HeadTracker.camera(withID: Settings.cameraID)?.uniqueID
            let cameraMenu = NSMenu()
            for camera in cameras {
                let option = item(camera.localizedName, #selector(selectCamera(_:)), checked: camera.uniqueID == selected)
                option.representedObject = camera.uniqueID
                cameraMenu.addItem(option)
            }
            menu.addItem(submenu("Camera", cameraMenu))
        }

        menu.addItem(item("Move Pointer With Focus", #selector(toggleMovePointer), checked: Settings.movePointer))
        menu.addItem(item("Flash Screen on Switch", #selector(toggleFlash), checked: Settings.flashOnSwitch))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())

        menu.addItem(item("Show Head Angles", #selector(toggleHeadAngles), checked: Settings.showHeadAngles))
        if Settings.showHeadAngles {
            menu.addItem(label("Menu bar shows: turn°, tilt° → screen"))
            if let calibration {
                for (index, display) in displays.enumerated() {
                    let angles = calibration.centers[display.key].map { "\(degrees($0.yaw))°, \(degrees($0.pitch))°" } ?? "not calibrated"
                    let hidden = display.key == calibration.faceLostDisplay ? " (face out of view)" : ""
                    menu.addItem(label("\(index + 1). \(display.name): \(angles)\(hidden)"))
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(label("Video is analysed on this Mac and never saved"))
        menu.addItem(item("Quit GlanceFocus", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        updateTracking()
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Double { Settings.dwell = seconds }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id != HeadTracker.camera(withID: Settings.cameraID)?.uniqueID else { return }
        Settings.cameraID = id
        // A camera in a different spot sees different head angles, so calibration starts over.
        Calibration.clear()
        calibration = nil
        tracker.stop()
        updateTracking()
        calibrate()
    }

    @objc private func toggleMovePointer() { Settings.movePointer.toggle() }
    @objc private func toggleFlash() { Settings.flashOnSwitch.toggle() }

    @objc private func toggleHeadAngles() {
        Settings.showHeadAngles.toggle()
        updateIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
    }

    @objc private func openCameraSettings() { openPrivacySettings("Privacy_Camera") }
    @objc private func openAccessibilitySettings() { openPrivacySettings("Privacy_Accessibility") }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
