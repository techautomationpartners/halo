// ScreenSource.swift
// ScreenCaptureKit capture: display enumeration, SCStream setup, and the
// fixed-cadence video / system-audio / microphone fan-out that the rest of
// the pipeline consumes.
//
// Four of the project's documented traps live in this file:
//   #1 POINTS vs PIXELS  (see `CaptureGeometry`)
//   #2 VARIABLE FRAME RATE (see the cadence timer / `emitCadenceFrame`)
//   #3 PTS NORMALIZATION (see `firstHostTime`)
//   #6 COLOR (see `SCStreamConfiguration.colorSpaceName`)

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

private let log = Logger(subsystem: "com.halo.recorder", category: "ScreenSource")

// MARK: - Discovery

/// Display enumeration. Separated from `ScreenSource` so the UI can populate
/// a display picker without constructing (or starting) a capture object.
public enum ScreenSourceDiscovery {

    /// Fetches the current shareable content, mapping ScreenCaptureKit's
    /// TCC refusal onto `HaloError.permissionDenied`.
    ///
    /// NOTE: this is the call that actually trips the Screen Recording TCC
    /// gate. `CGPreflightScreenCaptureAccess` (see Permissions.swift) can
    /// disagree with it right after a settings change, so treat a throw from
    /// here as authoritative.
    public static func shareableContent(
        excludingDesktopWindows: Bool = false,
        onScreenWindowsOnly: Bool = true
    ) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
        } catch {
            throw Self.mapped(error, context: "enumerating shareable content")
        }
    }

    /// All displays currently attached, in ScreenCaptureKit's order.
    public static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await shareableContent()
        let displays = content.displays
        guard !displays.isEmpty else {
            throw HaloError.deviceUnavailable("No displays are available for capture.")
        }
        return displays
    }

    /// The display containing the menu bar (`CGMainDisplayID`), falling back
    /// to the first enumerated display.
    public static func mainDisplay() async throws -> SCDisplay {
        let displays = try await availableDisplays()
        let mainID = CGMainDisplayID()
        return displays.first { $0.displayID == mainID } ?? displays[0]
    }

    /// Resolves the display whose `displayID` matches, or nil.
    public static func display(withID id: CGDirectDisplayID) async throws -> SCDisplay? {
        try await availableDisplays().first { $0.displayID == id }
    }

    /// Maps ScreenCaptureKit's `SCStreamErrorDomain` codes onto `HaloError`,
    /// with messages a user can act on.
    static func mapped(_ error: any Error, context: String) -> HaloError {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain else {
            return .captureFailed("Screen capture failed while \(context): \(ns.localizedDescription)")
        }
        switch ns.code {
        case -3801: // SCStreamErrorUserDeclined
            return .permissionDenied(
                """
                macOS denied Screen Recording access to Halo. \
                \(PermissionKind.screenRecording.manualGuidance)
                """
            )
        case -3803: // SCStreamErrorMissingEntitlements
            return .permissionDenied(
                """
                Halo is missing the entitlements ScreenCaptureKit requires. \
                If you built this yourself, re-run Scripts/make_app.sh so the \
                bundle is assembled and code-signed correctly, then launch \
                Halo.app (not the bare executable).
                """
            )
        case -3817, -3821: // UserStopped, SystemStoppedStream
            return .captureFailed("Screen capture was stopped by the system or the user.")
        case -3818, -3819: // Failed to start/stop audio capture
            return .captureFailed("System audio capture could not be started. Try recording without system audio.")
        case -3820: // FailedToStartMicrophoneCapture
            return .permissionDenied(
                """
                The microphone could not be started. \
                \(PermissionKind.microphone.manualGuidance)
                """
            )
        case -3814, -3815: // NoDisplayList, NoCaptureSource
            return .deviceUnavailable("No capturable display was found.")
        default:
            return .captureFailed("Screen capture failed while \(context) (SCStreamError \(ns.code)): \(ns.localizedDescription)")
        }
    }
}

// MARK: - Capture geometry (TRAP #1)

/// The POINTS -> PIXELS conversion, isolated so it can be reasoned about (and
/// eventually unit-tested) on its own.
///
/// TRAP (project notes item 1): `SCDisplay.width` / `.height` are POINTS.
/// `SCStreamConfiguration.width` / `.height` are PIXELS. On the target
/// machine the display reports 1710x1107 points with an
/// `SCContentFilter.pointPixelScale` of 2.0, so the correct capture size is
/// 3420x2214 pixels. Handing ScreenCaptureKit the raw point values captures
/// a quarter of the pixels and then the compositor upscales them — a
/// permanently blurry recorder, with no error message anywhere.
public struct CaptureGeometry: Sendable, Equatable {
    /// Content size in points, as reported by the content filter / display.
    public let pointSize: CGSize
    /// The filter's backing-store scale factor (2.0 on Retina, including
    /// non-integer "scaled" display modes).
    public let pointPixelScale: CGFloat
    /// Content size in PIXELS — what goes into SCStreamConfiguration.
    public let pixelSize: CGSize

    /// Derives capture geometry from a content filter, falling back to the
    /// display's own point dimensions when `contentRect` is degenerate.
    public init(filter: SCContentFilter, display: SCDisplay) {
        let scale = CGFloat(filter.pointPixelScale)
        // pointPixelScale is documented as >= 1 but defend against a 0 from a
        // display that is mid-reconfiguration; 1.0 is the safe identity.
        let safeScale = scale > 0 ? scale : 1.0

        let rect = filter.contentRect
        let points: CGSize
        if rect.width > 0, rect.height > 0 {
            points = rect.size
        } else {
            points = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        }

        self.pointSize = points
        self.pointPixelScale = safeScale
        // Round to even: H.264/HEVC chroma subsampling requires even
        // dimensions, and a non-integer scaled mode can land on an odd number.
        self.pixelSize = CGSize(
            width: CGFloat(Self.evenRounded(points.width * safeScale)),
            height: CGFloat(Self.evenRounded(points.height * safeScale))
        )
    }

    private static func evenRounded(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return rounded % 2 == 0 ? rounded : rounded + 1
    }

    public var pixelWidth: Int { Int(pixelSize.width) }
    public var pixelHeight: Int { Int(pixelSize.height) }
}

// MARK: - ScreenSource

/// ScreenCaptureKit-backed `ScreenSourcing`.
///
/// Threading: ScreenCaptureKit delivers samples on plain dispatch queues, so
/// this is a lock-protected `@unchecked Sendable` class rather than an actor —
/// an actor cannot service an `@objc` delegate callback without hopping, and a
/// hop per frame at 4K60 is exactly the kind of per-frame overhead this
/// project is trying to avoid.
///
/// Lifecycle: one recording per instance. The three `AsyncStream`s are created
/// in `init` (the protocol exposes them as non-async properties, so they must
/// exist before `start`), and `stop` finishes them permanently. Create a fresh
/// `ScreenSource` for each recording.
public final class ScreenSource: NSObject, ScreenSourcing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    // MARK: Streams

    public let videoFrames: AsyncStream<VideoFrame>
    public let systemAudioFrames: AsyncStream<AudioFrame>
    public let microphoneAudioFrames: AsyncStream<AudioFrame>

    private let videoContinuation: AsyncStream<VideoFrame>.Continuation
    private let systemAudioContinuation: AsyncStream<AudioFrame>.Continuation
    private let microphoneContinuation: AsyncStream<AudioFrame>.Continuation

    // MARK: Queues

    // Separate queues per output type: a slow consumer on one path must not
    // stall the others, and Apple's guidance is one handler queue per
    // SCStreamOutputType.
    private let screenQueue = DispatchQueue(label: "com.halo.screensource.screen", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.halo.screensource.audio", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "com.halo.screensource.mic", qos: .userInitiated)
    private let cadenceQueue = DispatchQueue(label: "com.halo.screensource.cadence", qos: .userInitiated)

    // MARK: Guarded state

    private let lock = NSLock()
    private var stream: SCStream?
    private var cadenceTimer: DispatchSourceTimer?
    private var isRunning = false
    private var geometry: CaptureGeometry?

    /// Most recent COMPLETE screen pixel buffer. See `emitCadenceFrame` for
    /// why this is retained rather than forwarded directly (trap #2).
    private var latestPixelBuffer: CVPixelBuffer?
    /// Host time at which `latestPixelBuffer` was captured.
    private var latestPixelBufferHostTime: CMTime = .invalid

    /// TRAP (project notes item 3): host time of the FIRST sample of any kind
    /// (screen, system audio, or mic). Every timestamp this object publishes
    /// is `sampleHostTime - firstHostTime`, so the file starts at t=0 and all
    /// three tracks stay on one common origin. Deliberately shared across
    /// video and audio — normalizing each track against its own first sample
    /// would silently desynchronize them by however long the audio path took
    /// to warm up.
    private var firstHostTime: CMTime?

    private var lastEmittedVideoPTS: CMTime?

    /// Timescale for published video timestamps. 90 kHz is the conventional
    /// media timescale and divides cleanly by 30/60/24/25 fps.
    private static let mediaTimescale: CMTimeScale = 90_000

    /// Optional explicit microphone device (`AVCaptureDevice.uniqueID`).
    /// nil uses the system default input.
    private let microphoneDeviceID: String?
    /// Whether to hide Halo's own windows from the capture.
    private let excludeOwnWindows: Bool

    // MARK: Init

    /// - Parameters:
    ///   - microphoneDeviceID: `AVCaptureDevice.uniqueID` of the mic to record
    ///     through `SCStreamConfiguration.microphoneCaptureDeviceID`. nil (the
    ///     default) uses the system default input.
    ///   - excludeOwnWindows: when true, Halo's own windows are excluded from
    ///     the capture so the menu-bar UI does not appear in the recording.
    public init(microphoneDeviceID: String? = nil, excludeOwnWindows: Bool = true) {
        self.microphoneDeviceID = microphoneDeviceID
        self.excludeOwnWindows = excludeOwnWindows

        // Video: keep only the newest couple of frames. Every buffered frame
        // pins one of the SCStream's `queueDepth` IOSurfaces, and the consumer
        // (RecordingEngine) already parks a few more in its camera-offset
        // delay queue. Two here keeps the two together comfortably inside
        // queueDepth, so ScreenCaptureKit always has a free surface to render
        // the next frame into. A stalled consumer drops stale frames rather
        // than growing an unbounded queue of ~30 MB 4K buffers.
        let video = AsyncStream<VideoFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        // Audio: buffers are tiny, and dropping them punches audible holes in
        // the track, so allow a deep backlog before the safety valve trips.
        let systemAudio = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let mic = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(512))

        self.videoFrames = video.stream
        self.videoContinuation = video.continuation
        self.systemAudioFrames = systemAudio.stream
        self.systemAudioContinuation = systemAudio.continuation
        self.microphoneAudioFrames = mic.stream
        self.microphoneContinuation = mic.continuation

        super.init()
    }

    // MARK: Introspection

    /// True between a successful `start` and `stop` (or an unsolicited stream
    /// stop reported by ScreenCaptureKit).
    public var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    /// Resolved points/pixels geometry of the running capture, nil before
    /// `start`. Useful for the compositor and for surfacing "recording at
    /// 3420x2214" in the UI.
    public var captureGeometry: CaptureGeometry? {
        lock.lock(); defer { lock.unlock() }
        return geometry
    }

    /// How long ago ScreenCaptureKit last delivered a genuinely NEW frame,
    /// in seconds; nil before the first frame arrives.
    ///
    /// A large value here is normal, not a fault — it just means the screen
    /// has been static and the cadence timer (trap #2) has been re-emitting
    /// the retained frame. Exposed so the UI can distinguish "idle screen"
    /// from "capture wedged".
    public var secondsSinceLastScreenChange: Double? {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let last = lock.withLock { latestPixelBufferHostTime }
        guard last.isNumeric else { return nil }
        return CMTimeGetSeconds(CMTimeSubtract(now, last))
    }

    /// The most recently received screen frame, timestamped as if it were
    /// being emitted right now.
    ///
    /// TRAP (project notes item 2): ScreenCaptureKit only fires its callback
    /// when the screen CHANGES. `videoFrames` already handles this internally
    /// by re-emitting on a fixed cadence, so most callers do not need this.
    /// It is exposed for an external fixed-cadence driver (or a preview view)
    /// that wants to pull rather than be pushed.
    public var latestScreenFrame: VideoFrame? {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock(); defer { lock.unlock() }
        guard let buffer = latestPixelBuffer, let first = firstHostTime else { return nil }
        let pts = CMTimeConvertScale(
            CMTimeSubtract(now, first),
            timescale: Self.mediaTimescale,
            method: .roundHalfAwayFromZero
        )
        return VideoFrame(pixelBuffer: buffer, presentationTime: pts, captureHostTime: now)
    }

    // MARK: - ScreenSourcing

    public func start(display: SCDisplay, config: RecordingConfig) async throws {
        let alreadyRunning = lock.withLock { isRunning }
        if alreadyRunning {
            throw HaloError.invalidState("ScreenSource is already capturing.")
        }

        // Fail fast and legibly rather than letting SCStream throw -3801 from
        // somewhere deep inside startCapture.
        guard Permissions.screenRecordingStatus().isUsable else {
            throw HaloError.permissionDenied(
                """
                Halo does not have Screen Recording access. \
                \(PermissionKind.screenRecording.manualGuidance)
                """
            )
        }

        let filter = await makeContentFilter(display: display)
        let geometry = CaptureGeometry(filter: filter, display: display)

        guard geometry.pixelWidth > 0, geometry.pixelHeight > 0 else {
            throw HaloError.deviceUnavailable("Display \(display.displayID) reported an empty capture area.")
        }

        log.info("""
            Capture geometry: \(Int(geometry.pointSize.width))x\(Int(geometry.pointSize.height)) pt \
            * \(geometry.pointPixelScale, format: .fixed(precision: 2)) \
            = \(geometry.pixelWidth)x\(geometry.pixelHeight) px
            """)

        let streamConfig = makeStreamConfiguration(geometry: geometry, config: config)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
            if config.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if config.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
            }
        } catch {
            throw ScreenSourceDiscovery.mapped(error, context: "attaching stream outputs")
        }

        do {
            try await stream.startCapture()
        } catch {
            throw ScreenSourceDiscovery.mapped(error, context: "starting capture")
        }

        lock.withLock {
            self.stream = stream
            self.geometry = geometry
            self.isRunning = true
            self.firstHostTime = nil
            self.lastEmittedVideoPTS = nil
            self.latestPixelBuffer = nil
            self.latestPixelBufferHostTime = .invalid
        }

        // Close the streams the config says will stay silent, so consumers
        // that `for await` on them terminate immediately instead of hanging.
        if !config.captureSystemAudio { systemAudioContinuation.finish() }
        if !config.captureMicrophone { microphoneContinuation.finish() }

        startCadenceTimer(frameRate: config.frameRate)
        log.info("Screen capture started at \(config.frameRate) fps.")
    }

    public func stop() async {
        let (stream, timer) = lock.withLock { () -> (SCStream?, DispatchSourceTimer?) in
            let stream = self.stream
            let timer = self.cadenceTimer
            self.stream = nil
            self.cadenceTimer = nil
            self.isRunning = false
            self.latestPixelBuffer = nil
            self.latestPixelBufferHostTime = .invalid
            return (stream, timer)
        }

        timer?.cancel()

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // A stream that already stopped (e.g. the user revoked
                // permission, or the display was disconnected) throws here.
                // There is nothing to recover — the recording is over either
                // way — so log and continue finalizing.
                let ns = error as NSError
                log.notice("stopCapture returned \(ns.domain) \(ns.code): \(ns.localizedDescription)")
            }
        }

        finishAllStreams()
        log.info("Screen capture stopped.")
    }

    private func finishAllStreams() {
        videoContinuation.finish()
        systemAudioContinuation.finish()
        microphoneContinuation.finish()
    }

    // MARK: - Stream configuration

    /// Builds the capture filter for `display`, optionally hiding Halo's own
    /// windows so the menu-bar UI and any panels never appear in the
    /// recording. Window discovery is best-effort: if shareable content can't
    /// be re-read, we fall back to capturing the whole display rather than
    /// failing the recording over a cosmetic exclusion.
    private func makeContentFilter(display: SCDisplay) async -> SCContentFilter {
        guard excludeOwnWindows else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        do {
            let content = try await ScreenSourceDiscovery.shareableContent()
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            return SCContentFilter(display: display, excludingWindows: ownWindows)
        } catch {
            log.notice("Could not enumerate windows to exclude Halo's own UI; capturing full display.")
            return SCContentFilter(display: display, excludingWindows: [])
        }
    }

    private func makeStreamConfiguration(
        geometry: CaptureGeometry,
        config: RecordingConfig
    ) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()

        // TRAP #1: PIXELS here, never the display's point values.
        streamConfig.width = geometry.pixelWidth
        streamConfig.height = geometry.pixelHeight
        // .best forces the full backing-store resolution rather than letting
        // the system pick a cheaper nominal size on a scaled display mode.
        streamConfig.captureResolution = .best
        streamConfig.scalesToFit = false

        // BGRA keeps the compositor's Core Image path simple (no YCbCr
        // conversion before the circular mask composite) and is the format
        // SCK's cursor-click decoration requires.
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

        // TRAP #6 (COLOR): without an explicit color space the captured
        // surfaces carry no color tag, the encoder guesses, and playback comes
        // out washed out on sRGB or oversaturated on P3. Recorder writes the
        // matching primaries/transfer/matrix tags onto the video track.
        switch config.colorSpace {
        case .displayP3:
            streamConfig.colorSpaceName = CGColorSpace.displayP3
        case .sRGB:
            streamConfig.colorSpaceName = CGColorSpace.sRGB
        }

        // TRAP #2 (part one): this is a CEILING on ScreenCaptureKit's delivery
        // rate, not a floor. SCK still emits only on change, so an idle screen
        // produces nothing regardless of this value — the cadence timer below
        // is what actually guarantees `config.frameRate`.
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(config.frameRate, 1)))

        // Apple's guidance is 3-8. Deeper queues absorb compositor hiccups at
        // the cost of one full-resolution IOSurface each (~30 MB at 4K BGRA).
        // 8 (the top of the range) because the consumer legitimately holds a
        // few surfaces at once: the retained `latestPixelBuffer`, the video
        // AsyncStream's 2-frame buffer, and RecordingEngine's camera-offset
        // delay queue. Undersizing this makes SCK drop frames during motion.
        streamConfig.queueDepth = 8

        streamConfig.showsCursor = true

        streamConfig.capturesAudio = config.captureSystemAudio
        if config.captureSystemAudio {
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
            // Without this, Halo's own UI sounds (and any playback of a
            // previous recording) are re-recorded into the new file.
            streamConfig.excludesCurrentProcessAudio = true
        }

        // TRAP #4 support: the mic rides ScreenCaptureKit's clock here rather
        // than a second AVCaptureSession, but it is still delivered on its own
        // SCStreamOutputType with its own CMFormatDescription. Downstream it
        // must therefore either get its own AVAssetWriterInput (.separate) or
        // be converted and summed by AudioMixer first (.mixed) — what it must
        // never do is land raw on an input the system-audio stream also writes.
        streamConfig.captureMicrophone = config.captureMicrophone
        // nil means "system default input", which is exactly what leaving
        // microphoneCaptureDeviceID unset already does — so an unplugged
        // device (resolved to nil upstream in AppDelegate.effectiveConfig)
        // degrades to the built-in mic instead of recording silence.
        if config.captureMicrophone, let microphoneDeviceID {
            streamConfig.microphoneCaptureDeviceID = microphoneDeviceID
        }

        streamConfig.streamName = "Halo"
        return streamConfig
    }

    // MARK: - Fixed cadence (TRAP #2)

    /// TRAP (project notes item 2, VARIABLE FRAME RATE): ScreenCaptureKit is
    /// an on-change source. Point it at a static desktop and it delivers a
    /// handful of frames and then goes quiet for as long as nothing moves.
    /// Feeding that straight into AVAssetWriter yields a file whose duration
    /// is the sum of the moments something happened — the classic "5-minute
    /// recording produced a 3-second video" bug.
    ///
    /// The fix: retain the last COMPLETE pixel buffer, and run a timer at
    /// `config.frameRate` that publishes a frame on every tick — a fresh one
    /// when the screen changed, the retained one again when it did not, always
    /// with a newly computed timestamp. Re-emitting the same CVPixelBuffer is
    /// cheap (the encoder sees an identical frame and spends almost no bits on
    /// it) and costs no extra memory.
    private func startCadenceTimer(frameRate: Int) {
        let fps = max(frameRate, 1)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / Double(fps)))

        let timer = DispatchSource.makeTimerSource(queue: cadenceQueue)
        // Small leeway lets the system coalesce wakeups (battery) without
        // meaningfully perturbing timing, since each frame's PTS is computed
        // from the real clock rather than from a tick counter.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitCadenceFrame()
        }

        lock.lock()
        cadenceTimer = timer
        lock.unlock()

        timer.resume()
    }

    private func emitCadenceFrame() {
        // Read the clock outside the lock: it is the same host-time domain
        // ScreenCaptureKit stamps its sample buffers with, so screen video,
        // system audio, and mic audio all share one origin.
        let now = CMClockGetTime(CMClockGetHostTimeClock())

        var frame: VideoFrame?
        lock.lock()
        if isRunning, let buffer = latestPixelBuffer, let first = firstHostTime {
            // TRAP #3: normalize against the first sample so the file starts
            // at t=0.
            var pts = CMTimeConvertScale(
                CMTimeSubtract(now, first),
                timescale: Self.mediaTimescale,
                method: .roundHalfAwayFromZero
            )
            if pts < .zero { pts = .zero }
            // AVAssetWriter rejects non-increasing timestamps. A coalesced or
            // slightly early tick can otherwise land on the previous value.
            if let last = lastEmittedVideoPTS, pts <= last {
                pts = last + CMTime(value: 1, timescale: Self.mediaTimescale)
            }
            lastEmittedVideoPTS = pts
            // captureHostTime is the tick's instant, not the retained buffer's
            // original capture time. That is deliberate: it is the real-world
            // moment this output frame REPRESENTS, which is what the caller's
            // camera-offset ring buffer (trap #5) needs to pair against. Using
            // the stale original would make an idle screen pair with an
            // arbitrarily old camera frame.
            frame = VideoFrame(pixelBuffer: buffer, presentationTime: pts, captureHostTime: now)
        }
        lock.unlock()

        // Yield outside the lock — a consumer resumed by this call must never
        // be able to re-enter while we hold it.
        if let frame { videoContinuation.yield(frame) }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleScreenSample(sampleBuffer)
        case .audio:
            handleAudioSample(sampleBuffer, source: .systemAudio, into: systemAudioContinuation)
        case .microphone:
            handleAudioSample(sampleBuffer, source: .microphone, into: microphoneContinuation)
        @unknown default:
            break
        }
    }

    private func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        // SCK signals idle/blank/suspended frames through an attachment, and
        // those carry no IOSurface. Retaining one would blank the recording.
        guard let status = Self.frameStatus(of: sampleBuffer) else { return }
        switch status {
        case .complete, .started:
            break
        case .idle, .blank, .suspended, .stopped:
            // Nothing new to show. The cadence timer keeps re-emitting the
            // last complete frame, so the timeline stays continuous.
            return
        @unknown default:
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        guard isRunning else { lock.unlock(); return }
        if firstHostTime == nil, hostTime.isValid, hostTime.isNumeric {
            firstHostTime = hostTime
        }
        latestPixelBuffer = pixelBuffer
        latestPixelBufferHostTime = hostTime
        lock.unlock()
    }

    private func handleAudioSample(
        _ sampleBuffer: CMSampleBuffer,
        source: AudioSourceKind,
        into continuation: AsyncStream<AudioFrame>.Continuation
    ) {
        let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard hostTime.isValid, hostTime.isNumeric else { return }

        lock.lock()
        guard isRunning else { lock.unlock(); return }
        if firstHostTime == nil { firstHostTime = hostTime }
        let origin = firstHostTime ?? hostTime
        lock.unlock()

        let normalized = CMTimeSubtract(hostTime, origin)
        // Audio that predates the common origin belongs before the session
        // start; AVAssetWriter would reject a negative PTS, so drop it.
        guard normalized >= .zero else { return }

        // Rewrite the buffer's own timing too, not just AudioFrame's
        // presentationTime. Recorder appends the CMSampleBuffer directly, and
        // an un-normalized buffer PTS would place the audio minutes into the
        // timeline (trap #3) no matter what the wrapper says.
        guard let retimed = Self.sampleBuffer(sampleBuffer, offsetBy: origin) else { return }

        continuation.yield(AudioFrame(sampleBuffer: retimed, source: source, presentationTime: normalized))
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let mapped = ScreenSourceDiscovery.mapped(error, context: "capturing")
        log.error("Stream stopped unexpectedly: \(String(describing: mapped))")

        lock.lock()
        let timer = cadenceTimer
        self.cadenceTimer = nil
        self.stream = nil
        self.isRunning = false
        self.latestPixelBuffer = nil
        lock.unlock()

        timer?.cancel()
        // Finish the streams so `for await` consumers unblock and the caller's
        // recording task can finalize the file instead of hanging forever.
        finishAllStreams()
    }

    // MARK: - Sample helpers

    private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let raw = first[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// Copies `sampleBuffer` with every timestamp shifted back by `offset`.
    ///
    /// Copies the FULL timing array rather than synthesizing a single entry:
    /// an audio buffer holds many samples, and collapsing them onto one timing
    /// info with `CMSampleBufferGetDuration` (which is the TOTAL duration, not
    /// the per-sample duration) stretches the audio by the sample count.
    private static func sampleBuffer(_ sampleBuffer: CMSampleBuffer, offsetBy offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: Int(count)
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil
        ) == noErr else { return nil }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isNumeric {
                timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isNumeric {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &output
        ) == noErr else { return nil }

        return output
    }
}
