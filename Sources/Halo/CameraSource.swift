// CameraSource.swift
// AVCaptureSession-backed webcam capture. Produces plain rectangular frames
// (no circle mask — that is Compositor's job) on a dedicated delivery queue,
// plus a "latest frame" latch so a puller can always get *something* without
// blocking on the AsyncStream.
//
// BUFFER LIFETIME: this file deliberately retains exactly ONE delivered
// pixel buffer (the latch). AVCaptureVideoDataOutput vends from a small
// fixed pool; a client that holds a ring of 30+ delivered buffers drains
// that pool, after which AVFoundation stops vending and routes every
// subsequent sample to `didDrop:` — the webcam bubble freezes with no error
// anywhere. Camera-offset compensation (project notes item 5) is implemented
// in RecordingEngine by delaying the SCREEN side instead, which needs no
// camera history at all.
//
// Concurrency: this is a plain (non-actor) class because AVCaptureSession and
// its delegate callbacks are queue-based, not actor-based. All mutable state
// lives behind `lock`; the class is therefore `@unchecked Sendable`.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class CameraSource: NSObject, CameraSourcing, @unchecked Sendable {

    // MARK: - Device discovery

    /// Every camera the system can offer us: the built-in FaceTime camera
    /// ("MacBook Air Camera" on the target machine), USB/external cameras,
    /// iPhone Continuity Cameras, and Desk View.
    public static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera,
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Preferred camera: an exact `localizedName` match when `name` is given,
    /// otherwise the system default video device, otherwise the first camera
    /// discovery returns.
    public static func defaultDevice(named name: String? = nil) -> AVCaptureDevice? {
        let devices = availableDevices()
        if let name, let match = devices.first(where: { $0.localizedName == name }) {
            return match
        }
        return AVCaptureDevice.default(for: .video) ?? devices.first
    }

    // MARK: - Stream plumbing

    public let videoFrames: AsyncStream<VideoFrame>
    private let continuation: AsyncStream<VideoFrame>.Continuation

    /// Serial queue owning AVCaptureSession configuration/start/stop.
    /// `startRunning()` blocks, so it must never run on the caller's thread.
    private let sessionQueue = DispatchQueue(label: "com.halo.camera.session")
    /// Separate queue for sample delivery so a slow consumer cannot stall
    /// session control (and vice versa).
    private let bufferQueue = DispatchQueue(
        label: "com.halo.camera.buffers",
        qos: .userInitiated
    )

    // MARK: - Locked state

    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var isRunning = false
    /// First camera PTS, subtracted from every subsequent one so the stream's
    /// `presentationTime` starts at .zero (project notes item 3). The raw PTS
    /// is preserved separately as `captureHostTime`.
    private var firstSampleTime: CMTime?
    /// Newest frame, for consumers that want a latch rather than a stream.
    /// This is the ONLY delivered buffer this class retains — see the file
    /// header on why a deeper history starves AVCaptureVideoDataOutput's pool.
    private var latest: VideoFrame?

    // MARK: - Init

    public override init() {
        var cont: AsyncStream<VideoFrame>.Continuation!
        // .bufferingNewest(2): the compositor only ever wants the freshest
        // camera frame; queueing stale ones would just add latency on top of
        // the pipeline lag we are already compensating for.
        self.videoFrames = AsyncStream(VideoFrame.self, bufferingPolicy: .bufferingNewest(2)) {
            cont = $0
        }
        self.continuation = cont
        super.init()
    }

    // MARK: - CameraSourcing

    public func start(device: AVCaptureDevice, config: RecordingConfig) async throws {
        // Scoped locking: NSLock.lock()/unlock() are unavailable from async
        // contexts (they cannot survive a suspension point safely).
        let alreadyRunning = lock.withLock { isRunning }
        if alreadyRunning {
            throw HaloError.invalidState("CameraSource.start called while already running")
        }

        // AVCaptureDevice / AVCaptureSession are not Sendable; box them to hop
        // onto the session queue under Swift 6 strict concurrency.
        let boxedDevice = UnsafeSendableBox(device)
        let boxedSelf = UnsafeSendableBox(self)

        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, any Error>) in
            sessionQueue.async {
                do {
                    try boxedSelf.value.configureAndStart(
                        device: boxedDevice.value,
                        config: config
                    )
                    resume.resume()
                } catch {
                    resume.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        let boxedSelf = UnsafeSendableBox(self)
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                boxedSelf.value.teardown()
                resume.resume()
            }
        }
        continuation.finish()
    }

    // MARK: - Latch access

    /// Most recent camera frame, or nil if none has arrived yet (the camera
    /// takes a few hundred ms to warm up after `start`).
    public func latestFrame() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    // MARK: - Session setup (session queue only)

    private func configureAndStart(device: AVCaptureDevice, config: RecordingConfig) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()

        // .high rather than .photo: we only ever draw this into a bubble a few
        // hundred pixels across, so a 4K Continuity Camera feed would be pure
        // waste. `selectFormat` narrows it further where possible.
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw HaloError.deviceUnavailable(
                "Could not open camera '\(device.localizedName)': \(error.localizedDescription)"
            )
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw HaloError.deviceUnavailable(
                "Camera '\(device.localizedName)' cannot be added to the capture session"
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // 32BGRA keeps the buffer IOSurface-backed and directly consumable by
        // CoreImage/Metal in the Compositor with no CPU round-trip.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Never let camera frames pile up: a late webcam frame is useless to a
        // compositor that is already past that instant.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: bufferQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw HaloError.deviceUnavailable("Camera session refused a video data output")
        }
        session.addOutput(output)

        session.commitConfiguration()

        configureDeviceFormat(device, frameRate: config.frameRate)

        lock.lock()
        self.session = session
        self.output = output
        self.isRunning = true
        self.firstSampleTime = nil
        self.latest = nil
        lock.unlock()

        session.startRunning()
    }

    /// Pick a modest format and cap the frame rate at the recording rate.
    /// Best-effort: any failure leaves the device on its default format, which
    /// still works, just less efficiently.
    private func configureDeviceFormat(_ device: AVCaptureDevice, frameRate: Int) {
        let desiredDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if let format = Self.selectFormat(for: device, frameRate: frameRate) {
            device.activeFormat = format
        }

        // Cap capture rate at the output rate. activeVideoMinFrameDuration is
        // the *minimum time between frames*, i.e. the maximum frame rate.
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let supportsDesired = ranges.contains {
            CMTimeCompare(desiredDuration, $0.minFrameDuration) >= 0
                && CMTimeCompare(desiredDuration, $0.maxFrameDuration) <= 0
        }
        if supportsDesired {
            device.activeVideoMinFrameDuration = desiredDuration
        } else if let widest = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            device.activeVideoMinFrameDuration = widest.minFrameDuration
        }
    }

    /// Smallest format that is still at least 720p wide and can hit the target
    /// frame rate; nil if nothing qualifies (caller then keeps the default).
    private static func selectFormat(
        for device: AVCaptureDevice,
        frameRate: Int
    ) -> AVCaptureDevice.Format? {
        let target = Double(frameRate)
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 1280 else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate + 0.5 >= target }
        }
        return candidates.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
    }

    private func teardown() {
        lock.lock()
        let session = self.session
        let output = self.output
        self.session = nil
        self.output = nil
        self.isRunning = false
        self.latest = nil
        lock.unlock()

        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session, session.isRunning {
            session.stopRunning()
        }
    }
}

// MARK: - Sample delivery

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // On macOS, AVCaptureSession stamps sample buffers in the host-time
        // domain (mach_absolute_time), which is the same domain
        // ScreenCaptureKit uses. That shared domain is what makes the
        // engine's camera-offset pairing meaningful.
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard hostTime.isValid else { return }

        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        if firstSampleTime == nil {
            firstSampleTime = hostTime
        }
        // Project notes item 3: normalize so the stream starts at t=0.
        let normalized = CMTimeSubtract(hostTime, firstSampleTime ?? hostTime)
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: normalized,
            captureHostTime: hostTime
        )
        // Exactly one retained buffer. Replacing (not appending) is what
        // returns the previous buffer to AVCaptureVideoDataOutput's pool.
        latest = frame
        lock.unlock()

        continuation.yield(frame)
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Expected and harmless: alwaysDiscardsLateVideoFrames is on, and the
        // compositor only ever wants the freshest camera frame anyway.
    }
}

// MARK: - Helpers

/// Escape hatch for handing non-Sendable AVFoundation objects to a serial
/// dispatch queue. Safe here because every boxed value is confined to one
/// queue for the duration of the hop.
struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
