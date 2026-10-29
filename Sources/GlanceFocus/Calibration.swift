import Foundation

/// What calibration learns: the average head pose while looking at each display.
///
/// These few numbers (two angles per display) are the only thing GlanceFocus remembers about you,
/// kept in its preferences file next to the menu settings. No images are ever stored.
struct Calibration: Codable {
    /// Average head pose while looking at each display, keyed by `Display.key`.
    var centers: [String: HeadPose]
    /// Typical jitter of each angle during calibration, used to weigh yaw against pitch.
    var spread: HeadPose
    /// A display the user turns so far toward that the camera loses sight of their face, if any.
    var faceLostDisplay: String?

    /// Noise-normalised squared distance from `pose` to the display's calibrated pose.
    func distance(from pose: HeadPose, to key: String) -> Double? {
        guard let center = centers[key] else { return nil }
        let yaw = (pose.yaw - center.yaw) / spread.yaw
        let pitch = (pose.pitch - center.pitch) / spread.pitch
        return yaw * yaw + pitch * pitch
    }

    /// The connected displays this calibration can tell apart.
    func usableDisplays(in displays: [Display]) -> [Display] {
        displays.filter { centers[$0.key] != nil || $0.key == faceLostDisplay }
    }

    /// Smallest angle between any two displays' calibrated poses. Tiny values mean the user moved
    /// only their eyes during calibration, which the camera can't reliably see.
    var smallestSeparationDegrees: Double? {
        let poses = Array(centers.values)
        var smallest: Double?
        for i in poses.indices {
            for j in poses.indices where j > i {
                let degrees = hypot(poses[i].yaw - poses[j].yaw, poses[i].pitch - poses[j].pitch) * 180 / .pi
                smallest = min(smallest ?? degrees, degrees)
            }
        }
        return smallest
    }

    /// Builds a calibration from the poses seen while the user looked at each display.
    /// `frames` counts every analysed frame per display, including ones where no face was found.
    static func make(samples: [String: [HeadPose]], frames: [String: Int]) -> Calibration? {
        var centers: [String: HeadPose] = [:]
        var squaredYaw = 0.0, squaredPitch = 0.0, degreesOfFreedom = 0
        for (key, poses) in samples where poses.count >= 5 {
            let count = Double(poses.count)
            let mean = HeadPose(yaw: poses.reduce(0) { $0 + $1.yaw } / count,
                                pitch: poses.reduce(0) { $0 + $1.pitch } / count)
            centers[key] = mean
            for pose in poses {
                squaredYaw += (pose.yaw - mean.yaw) * (pose.yaw - mean.yaw)
                squaredPitch += (pose.pitch - mean.pitch) * (pose.pitch - mean.pitch)
            }
            degreesOfFreedom += poses.count - 1
        }

        // Floor of ~3.4° so neither angle dominates just because the user held very still.
        let minimumSpread = 0.06
        let dof = Double(max(degreesOfFreedom, 1))
        let spread = HeadPose(yaw: max(minimumSpread, (squaredYaw / dof).squareRoot()),
                              pitch: max(minimumSpread, (squaredPitch / dof).squareRoot()))

        // The display where the face was missing most of the time, if it was missing at least half of it.
        let faceLost = frames
            .map { key, total in (key: key, rate: Double(samples[key]?.count ?? 0) / Double(max(total, 1))) }
            .filter { $0.rate < 0.5 }
            .min { $0.rate < $1.rate }?.key

        var usable = Set(centers.keys)
        if let faceLost { usable.insert(faceLost) }
        guard usable.count >= 2 else { return nil }
        return Calibration(centers: centers, spread: spread, faceLostDisplay: faceLost)
    }

    // MARK: - Persistence

    private static let defaultsKey = "calibration"

    static func load() -> Calibration? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Calibration.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
