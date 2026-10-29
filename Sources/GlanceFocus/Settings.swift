import Foundation

/// Menu preferences, stored in the app's standard preferences file.
enum Settings {
    private static let store = UserDefaults.standard

    /// Whether focus should follow the user's head at all.
    static var enabled: Bool {
        get { store.object(forKey: "enabled") as? Bool ?? true }
        set { store.set(newValue, forKey: "enabled") }
    }

    /// Seconds the user must keep looking at a display before it takes focus.
    static var dwell: Double {
        get { store.object(forKey: "dwell") as? Double ?? 0.4 }
        set { store.set(newValue, forKey: "dwell") }
    }

    /// Whether the pointer moves to the newly focused display too.
    static var movePointer: Bool {
        get { store.object(forKey: "movePointer") as? Bool ?? true }
        set { store.set(newValue, forKey: "movePointer") }
    }

    /// Whether the newly focused display briefly glows.
    static var flashOnSwitch: Bool {
        get { store.object(forKey: "flashOnSwitch") as? Bool ?? true }
        set { store.set(newValue, forKey: "flashOnSwitch") }
    }

    /// Debug aid: live head angles in the menu bar and calibrated angles in the menu.
    static var showHeadAngles: Bool {
        get { store.object(forKey: "showHeadAngles") as? Bool ?? false }
        set { store.set(newValue, forKey: "showHeadAngles") }
    }

    /// The camera picked in the menu; nil means the built-in camera.
    static var cameraID: String? {
        get { store.string(forKey: "cameraID") }
        set { store.set(newValue, forKey: "cameraID") }
    }
}
