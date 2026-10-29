import AppKit

/// A connected display. `bounds` uses global display coordinates (origin at the top-left of the
/// main display), the same space as window lists, the Accessibility API and the mouse pointer.
struct Display: Equatable {
    let id: CGDirectDisplayID
    /// Stays the same when the display is unplugged and plugged back in; used to save calibration.
    let key: String
    let name: String
    let bounds: CGRect
    let screen: NSScreen

    static func == (lhs: Display, rhs: Display) -> Bool { lhs.id == rhs.id }
}

@MainActor
enum Displays {
    static func current() -> [Display] {
        var seen: [String: Int] = [:]
        return NSScreen.screens.compactMap { screen -> Display? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            var key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            // Two identical monitors without serial numbers would otherwise share a key.
            let duplicates = seen[key, default: 0]
            seen[key] = duplicates + 1
            if duplicates > 0 { key += "-\(duplicates)" }
            return Display(id: id, key: key, name: screen.localizedName, bounds: CGDisplayBounds(id), screen: screen)
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func isClose(to other: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
