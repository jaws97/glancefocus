import AVFoundation
import Vision

/// Which way the user's head is turned, in radians, as reported by Vision.
struct HeadPose: Codable {
    var yaw: Double
    var pitch: Double
}

/// Reads the camera and reports the user's head pose a few times per second.
///
/// Each frame goes straight to Apple's on-device Vision face detector and is dropped as soon as
/// the two head angles have been read from it. Nothing is recorded, kept, or sent anywhere.
final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue for each analysed frame, with nil when no face is visible.
    var onPose: ((HeadPose?) -> Void)?
    private(set) var isRunning = false

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "GlanceFocus.session")
    private let videoQueue = DispatchQueue(label: "GlanceFocus.video")
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3 // continuous yaw and pitch
        return request
    }()

    /// Analysing ~8 frames a second is plenty to follow a head turn and keeps CPU use tiny.
    private let frameInterval = 1.0 / 8
    private var lastFrame: CFAbsoluteTime = 0 // only touched on videoQueue

    /// Cameras that can be used for tracking.
    static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// The camera with `id`, falling back to the built-in camera, then to any camera.
    static func camera(withID id: String?) -> AVCaptureDevice? {
        let cameras = availableCameras()
        return cameras.first { $0.uniqueID == id }
            ?? cameras.first { $0.deviceType == .builtInWideAngleCamera }
            ?? cameras.first
    }

    func start(cameraID: String?) {
        guard !isRunning else { return }
        isRunning = true
        sessionQueue.async { [self] in
            if configure(cameraID: cameraID) { session.startRunning() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionQueue.async { [self] in session.stopRunning() }
    }

    private func configure(cameraID: String?) -> Bool {
        guard let device = Self.camera(withID: cameraID),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        // Small frames are all face detection needs.
        if let preset = [AVCaptureSession.Preset.vga640x480, .medium, .low].first(where: session.canSetSessionPreset) {
            session.sessionPreset = preset
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        lowerFrameRate(of: device)
        return true
    }

    /// Ask the camera itself for fewer frames when it supports it; frames are thinned out below too.
    private func lowerFrameRate(of device: AVCaptureDevice) {
        let fps = 10.0
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }),
              (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrame >= frameInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now

        let pose = headPose(in: pixelBuffer)
        DispatchQueue.main.async { [weak self] in self?.onPose?(pose) }
    }

    private func headPose(in pixelBuffer: CVPixelBuffer) -> HeadPose? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([faceRequest])) != nil,
              // The largest face is the one closest to the camera: the user.
              let face = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let yaw = face.yaw?.doubleValue,
              let pitch = face.pitch?.doubleValue else { return nil }
        return HeadPose(yaw: yaw, pitch: pitch)
    }
}
