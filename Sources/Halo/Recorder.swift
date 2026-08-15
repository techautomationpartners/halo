// Recorder.swift
// AVAssetWriter-based MP4 muxer: one hardware-encoded video track fed from
// the compositor through an AVAssetWriterInputPixelBufferAdaptor, plus up to
// two SEPARATE audio tracks (system audio and microphone).
//
// This file owns project traps #2 (fixed-cadence submission), #3 (PTS
// normalization contract), #4 (separate audio inputs), and the writer half of
// #6 (color tags). See the inline TRAP comments below.

import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox
import os

// MARK: - Recorder

public final class Recorder: Recording, @unchecked Sendable {

    /// Coarse lifecycle state, observable from the UI.
    public enum State: String, Sendable, Equatable {
        case idle
        case recording
        case finishing
        case finished
        case failed
    }

    /// Everything created by `start` and torn down by `stop`. Bundled into one
    /// value so the whole session can be swapped in/out under a single lock.
    private struct Session {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
        /// TRAP #4: two distinct inputs, never one shared input. See
        /// `makeAudioInput` for the full reasoning.
        let systemAudioInput: AVAssetWriterInput?
        let microphoneInput: AVAssetWriterInput?
        let config: RecordingConfig
        let outputURL: URL
    }

    /// Statistics useful for a HUD / debugging; all counters are cumulative
    /// for the current session.
    public struct Stats: Sendable, Equatable {
        public var videoFramesAppended: Int = 0
        public var videoFramesRepeated: Int = 0
        public var videoFramesDropped: Int = 0
        public var systemAudioAppended: Int = 0
        public var microphoneAppended: Int = 0
        public var audioDropped: Int = 0
        /// Duration of the written video track so far, derived from the last
        /// accepted presentation timestamp.
        public var lastVideoPresentationSeconds: Double = 0
    }

    private static let log = Logger(subsystem: "com.halo.recorder", category: "Recorder")

    /// Interval at which a self-contained movie fragment is flushed to disk.
    /// See `start` for why this is set instead of `shouldOptimizeForNetworkUse`.
    private let movieFragmentInterval: CMTime

    private let lock = NSLock()

    // --- state below is guarded by `lock` ---
    private var session: Session?
    private var _state: State = .idle
    private var _stats = Stats()
    /// Most recently appended screen/composited pixel buffer, retained so the
    /// fixed-cadence driver can re-submit it while the screen is idle (TRAP #2).
    private var lastPixelBuffer: CVPixelBuffer?
    /// Last presentation timestamp actually handed to the video input.
    /// AVAssetWriter requires strictly increasing PTS per track; anything at or
    /// before this is dropped rather than allowed to corrupt the track.
    private var lastVideoPTS: CMTime = .invalid
    private var lastSystemAudioPTS: CMTime = .invalid
    private var lastMicrophonePTS: CMTime = .invalid
    /// The FIRST error that pushed this recorder into `.failed`. Kept so
    /// `stop()` can report the real cause (a full disk, a revoked permission)
    /// instead of a useless "called in state failed".
    private var failureError: (any Error)?
    // --- end guarded state ---

    /// - Parameter movieFragmentIntervalSeconds: how often to flush a movie
    ///   fragment. 0 or negative disables fragmentation.
    public init(movieFragmentIntervalSeconds: Double = 2.0) {
        self.movieFragmentInterval = movieFragmentIntervalSeconds > 0
            ? CMTime(seconds: movieFragmentIntervalSeconds, preferredTimescale: 600)
            : .invalid
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    /// URL currently being written, if any.
    public var outputURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return session?.outputURL
    }

    // MARK: - Output location

    /// `~/Movies/Halo/Halo-YYYY-MM-DD-HHmmss.mp4`, creating the directory if
    /// needed. Fully local, no sandbox container, no cloud anything.
    public static func makeDefaultOutputURL(date: Date = Date()) throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies", isDirectory: true)
        let folder = movies.appendingPathComponent("Halo", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw HaloError.writeFailed("Could not create \(folder.path): \(error.localizedDescription)")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return folder.appendingPathComponent("Halo-\(formatter.string(from: date)).mp4", isDirectory: false)
    }

    // MARK: - Recording conformance

    public func start(outputURL: URL, config: RecordingConfig) throws {
        lock.lock()
        defer { lock.unlock() }

        guard session == nil else {
            throw HaloError.invalidState("Recorder.start called while a session is already running")
        }

        // A stale file at the destination makes AVAssetWriter fail outright.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw HaloError.writeFailed("AVAssetWriter init failed: \(error.localizedDescription)")
        }

        // Crash safety. `shouldOptimizeForNetworkUse` would relocate the moov
        // atom to the front, but it only does so during finishWriting — so a
        // process that dies mid-recording leaves a file with no moov at all,
        // i.e. completely unplayable. A movie fragment interval instead flushes
        // self-describing fragments every N seconds, so an abrupt kill costs at
        // most the last fragment and the rest still plays. The two options are
        // mutually exclusive; crash resilience wins for a screen recorder.
        if movieFragmentInterval.isValid {
            writer.movieFragmentInterval = movieFragmentInterval
        } else {
            writer.shouldOptimizeForNetworkUse = true
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Recorder.videoOutputSettings(config: config)
        )
        // Frames arrive live from the capture pipeline; without this the writer
        // assumes it can back-pressure an offline source and will stall.
        videoInput.expectsMediaDataInRealTime = true

        // No sourcePixelBufferAttributes: we never pull buffers from the
        // adaptor's own pool — the compositor owns a Metal-backed pool
        // (project trap #8) and hands us buffers from it. Passing nil lets the
        // adaptor accept those buffers directly with no extra copy.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )

        guard writer.canAdd(videoInput) else {
            throw HaloError.writeFailed("AVAssetWriter rejected the video input for codec \(config.encoder.codec.rawValue)")
        }
        writer.add(videoInput)

        // ── TRAP #4 ────────────────────────────────────────────────────────
        // System audio and microphone MUST be two separate AVAssetWriterInputs
        // and therefore two separate tracks. Apple DTS has confirmed that
        // feeding ScreenCaptureKit's `.audio` and `.microphone` sample buffers
        // into a single input produces a corrupt, unplayable MP4: the two
        // streams carry different CMFormatDescriptions (channel count and
        // layout), run off different clocks, and interleave non-monotonically.
        // AVAssetWriterInput assumes one continuous, format-stable stream per
        // input, so the muxed result gets nonsense sample tables. There is no
        // "mix them first" shortcut here — mixing would need a real
        // sample-rate-converting mixer; two tracks is the supported answer, and
        // editors handle multi-track audio natively anyway.
        // ───────────────────────────────────────────────────────────────────
        var systemAudioInput: AVAssetWriterInput?
        if config.captureSystemAudio {
            let input = Recorder.makeAudioInput()
            guard writer.canAdd(input) else {
                throw HaloError.writeFailed("AVAssetWriter rejected the system-audio input")
            }
            writer.add(input)
            systemAudioInput = input
        }

        var microphoneInput: AVAssetWriterInput?
        if config.captureMicrophone {
            let input = Recorder.makeAudioInput()
            guard writer.canAdd(input) else {
                throw HaloError.writeFailed("AVAssetWriter rejected the microphone input")
            }
            writer.add(input)
            microphoneInput = input
        }

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown error"
            throw HaloError.writeFailed("AVAssetWriter.startWriting failed: \(reason)")
        }

        // TRAP #3: every producer normalizes its own first sample time away, so
        // by contract the frames arriving here already start at t=0. The
        // session therefore starts at source time .zero and Recorder does NOT
        // re-normalize — doing it twice would silently shift audio against
        // video whenever the two streams' first samples didn't coincide.
        writer.startSession(atSourceTime: .zero)

        session = Session(
            writer: writer,
            videoInput: videoInput,
            videoAdaptor: adaptor,
            systemAudioInput: systemAudioInput,
            microphoneInput: microphoneInput,
            config: config,
            outputURL: outputURL
        )
        _state = .recording
        _stats = Stats()
        lastPixelBuffer = nil
        lastVideoPTS = .invalid
        lastSystemAudioPTS = .invalid
        lastMicrophonePTS = .invalid
        failureError = nil

        RecorderRegistry.shared.register(self)

        Recorder.log.info("Recording started -> \(outputURL.path, privacy: .public)")
    }

    public func appendVideo(_ frame: VideoFrame) throws {
        try submitVideo(pixelBuffer: frame.pixelBuffer, presentationTime: frame.presentationTime, isRepeat: false)
    }

    /// Fixed-cadence entry point for the driver loop.
    ///
    /// TRAP #2 (VARIABLE FRAME RATE): ScreenCaptureKit only fires its callback
    /// when on-screen content changes, so a still screen emits almost no
    /// frames. Handing those straight to AVAssetWriter yields a file whose
    /// duration is the number of *changes*, not the elapsed wall clock — a
    /// five-minute recording of a static slide becomes a three-second movie.
    /// The driver therefore calls this once per tick at `config.frameRate`:
    /// with a fresh frame when one arrived, and with `nil` when the screen was
    /// idle, in which case the last accepted pixel buffer is re-encoded at the
    /// new timestamp. Repeated identical frames cost almost nothing (the
    /// encoder emits skip/P-frames of a few bytes) and the file's duration
    /// tracks the wall clock exactly.
    ///
    /// - Returns: true if a frame was written, false if the tick was skipped
    ///   (nothing to repeat yet, writer not ready, or non-monotonic timestamp).
    @discardableResult
    public func submitTick(frame: VideoFrame?, presentationTime: CMTime) throws -> Bool {
        if let frame {
            return try submitVideo(pixelBuffer: frame.pixelBuffer, presentationTime: presentationTime, isRepeat: false)
        }
        lock.lock()
        let buffer = lastPixelBuffer
        lock.unlock()
        guard let buffer else { return false }  // nothing captured yet; nothing to repeat
        return try submitVideo(pixelBuffer: buffer, presentationTime: presentationTime, isRepeat: true)
    }

    /// Convenience for drivers that count ticks rather than compute CMTimes:
    /// PTS is `tick / frameRate` on a `frameRate`-based timescale, which keeps
    /// every timestamp exact (no accumulating floating-point drift).
    @discardableResult
    public func submitTick(frame: VideoFrame?, tickIndex: Int, frameRate: Int) throws -> Bool {
        let fps = max(1, frameRate)
        let pts = CMTime(value: CMTimeValue(tickIndex), timescale: CMTimeScale(fps))
        return try submitTick(frame: frame, presentationTime: pts)
    }

    /// Records the FIRST failure, flips to `.failed`, and returns the error to
    /// throw. Caller must hold `lock`.
    ///
    /// The `Session` is deliberately NOT released here. `stop()` still needs
    /// it to cancel the writer and delete the half-written file; dropping it
    /// on the floor would leave an unfinalized MP4 on disk and the writer's
    /// file handle open until this object is deallocated.
    private func failLocked(_ message: String) -> any Error {
        if _state != .failed {
            _state = .failed
            failureError = HaloError.writeFailed(message)
        }
        return failureError ?? HaloError.writeFailed(message)
    }

    @discardableResult
    private func submitVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isRepeat: Bool) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let session, _state == .recording else {
            // Once failed, keep reporting the ORIGINAL cause rather than a
            // generic "no active session" that hides it.
            if let failureError { throw failureError }
            throw HaloError.invalidState("appendVideo called with no active recording session")
        }
        if let error = session.writer.error {
            throw failLocked("AVAssetWriter failed: \(error.localizedDescription)")
        }
        guard presentationTime.isValid, presentationTime.isNumeric else {
            throw HaloError.invalidState("Video frame has a non-numeric presentation time")
        }
        // Strictly increasing PTS is a hard AVAssetWriter requirement.
        if lastVideoPTS.isValid, presentationTime <= lastVideoPTS {
            _stats.videoFramesDropped += 1
            return false
        }
        guard session.videoInput.isReadyForMoreMediaData else {
            // The encoder is momentarily backed up. Dropping one frame keeps the
            // capture pipeline realtime; the previous frame simply displays for
            // an extra tick since the next accepted PTS jumps ahead.
            _stats.videoFramesDropped += 1
            return false
        }

        // TRAP #6 (writer half): the video *track* settings carry color tags,
        // but AVAssetWriter also reads per-buffer attachments and will emit a
        // mismatched (or untagged) track if a buffer disagrees. Stamping the
        // same primaries/transfer/matrix onto every buffer keeps the two in
        // agreement, so playback isn't washed out on a P3 display.
        Recorder.tagColor(pixelBuffer, policy: session.config.colorSpace)

        guard session.videoAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            let reason = session.writer.error?.localizedDescription ?? "unknown error"
            throw failLocked("Failed to append video frame at \(presentationTime.seconds)s: \(reason)")
        }

        lastVideoPTS = presentationTime
        lastPixelBuffer = pixelBuffer
        _stats.videoFramesAppended += 1
        if isRepeat { _stats.videoFramesRepeated += 1 }
        _stats.lastVideoPresentationSeconds = presentationTime.seconds
        return true
    }

    public func appendSystemAudio(_ frame: AudioFrame) throws {
        guard frame.source == .systemAudio else {
            // TRAP #4 guard rail: a mis-routed buffer here would be exactly the
            // "one input, two formats" mistake that corrupts the file.
            throw HaloError.invalidState("appendSystemAudio received a \(frame.source) frame")
        }
        try appendAudio(frame)
    }

    public func appendMicrophoneAudio(_ frame: AudioFrame) throws {
        guard frame.source == .microphone else {
            throw HaloError.invalidState("appendMicrophoneAudio received a \(frame.source) frame")
        }
        try appendAudio(frame)
    }

    /// Shared body for the two public audio entry points. The *input* is
    /// selected from `frame.source`, so the two sources can never land on the
    /// same AVAssetWriterInput (TRAP #4) — the only shared thing here is the
    /// bookkeeping, not the track.
    private func appendAudio(_ frame: AudioFrame) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let session, _state == .recording else {
            if let failureError { throw failureError }
            throw HaloError.invalidState("append audio called with no active recording session")
        }
        let input: AVAssetWriterInput?
        let previous: CMTime
        switch frame.source {
        case .systemAudio:
            input = session.systemAudioInput
            previous = lastSystemAudioPTS
        case .microphone:
            input = session.microphoneInput
            previous = lastMicrophonePTS
        }
        guard let input else {
            throw HaloError.invalidState("No writer input for \(frame.source); it was disabled in RecordingConfig")
        }
        if let error = session.writer.error {
            throw failLocked("AVAssetWriter failed: \(error.localizedDescription)")
        }

        if previous.isValid, frame.presentationTime <= previous {
            _stats.audioDropped += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            _stats.audioDropped += 1
            return
        }
        guard input.append(frame.sampleBuffer) else {
            let reason = session.writer.error?.localizedDescription ?? "unknown error"
            throw failLocked("Failed to append \(frame.source) sample: \(reason)")
        }
        switch frame.source {
        case .systemAudio:
            lastSystemAudioPTS = frame.presentationTime
            _stats.systemAudioAppended += 1
        case .microphone:
            lastMicrophonePTS = frame.presentationTime
            _stats.microphoneAppended += 1
        }
    }

    /// Atomically claims the running session and flips to `.finishing`, so two
    /// concurrent stops (e.g. the UI and a termination signal) can't both try
    /// to finalize the same writer.
    ///
    /// Split out of `stop()` because NSLock's lock/unlock are `noasync` under
    /// Swift 6 — holding a lock across a suspension point is exactly the bug
    /// that annotation exists to prevent, so all locking stays in small
    /// synchronous helpers like this one.
    ///
    /// `.failed` is accepted deliberately. A mid-recording write error (a full
    /// disk, a revoked permission) leaves a live AVAssetWriter holding an open
    /// file; if `stop()` refused to claim it, nothing would ever call
    /// `cancelWriting`, the partial MP4 would stay on disk unfinalized, and the
    /// file handle would survive until this object was deallocated. The
    /// returned `priorFailure` tells `stop()` to cancel rather than finish.
    private func claimSessionForFinishing() throws
        -> (session: Session, wroteAnyVideo: Bool, priorFailure: (any Error)?)
    {
        lock.lock()
        defer { lock.unlock() }
        guard let session, _state == .recording || _state == .finishing || _state == .failed else {
            throw HaloError.invalidState("Recorder.stop called in state \(_state.rawValue)")
        }
        let priorFailure = _state == .failed ? (failureError ?? HaloError.writeFailed("recording failed")) : nil
        _state = .finishing
        self.session = nil
        lastPixelBuffer = nil
        return (session, _stats.videoFramesAppended > 0, priorFailure)
    }

    private func setState(_ newValue: State) {
        lock.lock()
        _state = newValue
        lock.unlock()
    }

    public func stop() async throws {
        let (session, wroteAnyVideo, priorFailure) = try claimSessionForFinishing()

        RecorderRegistry.shared.unregister(self)

        // A writer that already failed cannot be finished — finishWriting on a
        // failed writer never completes cleanly. Cancel it so the file handle
        // is released and the unplayable partial file is removed, then report
        // the ORIGINAL cause.
        if let priorFailure {
            session.writer.cancelWriting()
            try? FileManager.default.removeItem(at: session.outputURL)
            setState(.failed)
            throw priorFailure
        }

        session.videoInput.markAsFinished()
        session.systemAudioInput?.markAsFinished()
        session.microphoneInput?.markAsFinished()

        guard wroteAnyVideo else {
            // finishWriting on an empty session produces a zero-sample, invalid
            // file. Cancel and clean up instead of shipping a broken MP4.
            session.writer.cancelWriting()
            try? FileManager.default.removeItem(at: session.outputURL)
            setState(.failed)
            throw HaloError.writeFailed("Recording contained no video frames; nothing was written")
        }

        let writer = session.writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        if writer.status == .completed {
            setState(.finished)
            Recorder.log.info("Recording finished -> \(session.outputURL.path, privacy: .public)")
        } else {
            setState(.failed)
            let reason = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
            throw HaloError.writeFailed("finishWriting did not complete: \(reason)")
        }
    }

    // MARK: - Guaranteed finalization

    /// Best-effort synchronous finalize used by the abrupt-exit paths
    /// (SIGINT/SIGTERM, `atexit`, app termination). Blocks the calling thread
    /// for at most `timeout` seconds; if the writer doesn't finish in time the
    /// file is left as-is — which is still playable up to the last flushed
    /// movie fragment, thanks to `movieFragmentInterval`.
    public func finalizeSynchronously(timeout: TimeInterval = 5.0) {
        lock.lock()
        guard let session, _state == .recording || _state == .failed else {
            lock.unlock()
            return
        }
        // Same reasoning as `stop()`: a writer already in `.failed` must be
        // cancelled here, not finished, or the process exits with the file
        // handle still open and an unfinalized MP4 on disk.
        let alreadyFailed = _state == .failed
        _state = .finishing
        self.session = nil
        let wroteAnyVideo = _stats.videoFramesAppended > 0
        lastPixelBuffer = nil
        lock.unlock()

        if alreadyFailed {
            session.writer.cancelWriting()
            try? FileManager.default.removeItem(at: session.outputURL)
            lock.lock(); _state = .failed; lock.unlock()
            return
        }

        session.videoInput.markAsFinished()
        session.systemAudioInput?.markAsFinished()
        session.microphoneInput?.markAsFinished()

        guard wroteAnyVideo else {
            session.writer.cancelWriting()
            try? FileManager.default.removeItem(at: session.outputURL)
            lock.lock(); _state = .failed; lock.unlock()
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        session.writer.finishWriting { semaphore.signal() }
        let result = semaphore.wait(timeout: .now() + timeout)

        lock.lock()
        _state = (result == .success && session.writer.status == .completed) ? .finished : .failed
        lock.unlock()
    }

    /// Installs SIGINT/SIGTERM handlers and an `atexit` hook that finalize any
    /// in-flight recording before the process goes away. Call once at launch.
    ///
    /// The signal side deliberately uses `DispatchSourceSignal` rather than a
    /// raw `signal()` handler: an actual POSIX handler runs on the interrupted
    /// thread and may call only async-signal-safe functions, which rules out
    /// every AVFoundation call. A dispatch source instead delivers the
    /// notification to a normal queue where finishing the writer is legal.
    public static func installTerminationHandlers() {
        RecorderRegistry.shared.installTerminationHandlers()
    }

    // MARK: - Writer settings

    /// Video track settings, including the bitrate ladder and the color tags
    /// that satisfy TRAP #6.
    static func videoOutputSettings(config: RecordingConfig) -> [String: any Sendable] {
        let size = config.outputResolution.pixelSize
        let bitRate = config.encoder.averageBitRate ?? defaultBitRate(for: config)
        let keyframeInterval = max(1, Int((Double(config.frameRate) * config.encoder.keyframeIntervalSeconds).rounded()))

        var compression: [String: any Sendable] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: config.frameRate,
            AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            AVVideoMaxKeyFrameIntervalDurationKey: config.encoder.keyframeIntervalSeconds,
            // Screen capture is a live pipeline: B-frame reordering buys a few
            // percent of bitrate at the cost of encoder latency and a
            // reordered DTS stream. Not worth it here.
            AVVideoAllowFrameReorderingKey: false,
        ]
        if config.encoder.codec == .h264 {
            // High profile with an auto level; 4K exceeds Main's limits, so
            // pinning a fixed level would fail at the larger preset.
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        var settings: [String: any Sendable] = [
            AVVideoCodecKey: config.encoder.codec.avVideoCodecType,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            // The compositor already applied letterbox/crop (TRAP #7), so the
            // incoming buffers match the output size exactly; resizeAspect is a
            // belt-and-braces guard that still never stretches if they don't.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorProperties(for: config.colorSpace),
        ]

        if config.encoder.preferHardwareEncoder {
            // M-series Macs have AppleAVE; this only *enables* hardware rather
            // than requiring it, so the recorder still works (slowly) if the
            // hardware encoder is busy or unavailable.
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ] as [String: any Sendable]
        }

        return settings
    }

    /// YouTube-oriented defaults: ~12 Mbps for 1080p60 and ~45 Mbps for 4K60,
    /// scaled by frame rate. The scale is sqrt(fps/60) rather than linear
    /// because halving the frame rate does not halve the bits needed — each
    /// remaining frame carries more motion between it and its predecessor.
    /// Anything here is overridable via `EncoderSettings.averageBitRate`.
    static func defaultBitRate(for config: RecordingConfig) -> Int {
        let base: Double
        switch config.outputResolution {
        case .hd1080p: base = 12_000_000
        case .uhd4K: base = 45_000_000
        }
        let ratio = Double(max(1, config.frameRate)) / 60.0
        let scale = min(1.5, max(0.5, ratio.squareRoot()))
        // HEVC reaches the same perceptual quality at roughly 75% of H.264's
        // bitrate; keep some headroom by using 0.8 rather than the full 0.75.
        let codecFactor = config.encoder.codec == .hevc ? 0.8 : 1.0
        return Int((base * scale * codecFactor).rounded())
    }

    /// TRAP #6: explicit color tags on the video track. ScreenSource sets the
    /// matching `SCStreamConfiguration.colorSpaceName`; if the two disagree —
    /// or if either is left untagged — QuickTime and every browser guess, and
    /// the result looks washed out (P3 content read as sRGB) or oversaturated
    /// (sRGB content read as P3).
    static func colorProperties(for policy: ColorSpacePolicy) -> [String: any Sendable] {
        switch policy {
        case .displayP3:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                // P3-D65 video uses the BT.709 transfer curve, not sRGB's
                // piecewise one — this is the correct pairing, not a typo.
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        case .sRGB:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
    }

    /// Stamps the same color tags onto a pixel buffer so per-buffer attachments
    /// agree with the track-level tags (TRAP #6).
    static func tagColor(_ pixelBuffer: CVPixelBuffer, policy: ColorSpacePolicy) {
        let primaries: CFString = policy == .displayP3
            ? kCVImageBufferColorPrimaries_P3_D65
            : kCVImageBufferColorPrimaries_ITU_R_709_2
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// One AAC audio input. Called once per audio source so system audio and
    /// microphone each get their own input and their own track (TRAP #4).
    ///
    /// The settings are fixed at 48 kHz stereo because AVAssetWriter needs all
    /// inputs added before `startWriting`, i.e. before any sample buffer (and
    /// therefore any real CMFormatDescription) has arrived. AVAssetWriterInput
    /// converts whatever it is fed — mono mic, 44.1 kHz system audio — into
    /// this format, and 48 kHz stereo is what ScreenCaptureKit produces
    /// natively on this hardware anyway.
    static func makeAudioInput(sampleRate: Double = 48_000, bitRate: Int = 192_000) -> AVAssetWriterInput {
        var stereo = AudioChannelLayout()
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = withUnsafeBytes(of: &stereo) { Data($0) }

        let settings: [String: any Sendable] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: bitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }
}

// MARK: - Registry for abrupt-exit finalization

/// Tracks live recorders so a termination signal or `atexit` can finalize them.
/// Holds weak references, so a recorder that is deallocated normally leaves no
/// trace here.
final class RecorderRegistry: @unchecked Sendable {

    static let shared = RecorderRegistry()

    private final class WeakRecorder {
        weak var value: Recorder?
        init(_ value: Recorder) { self.value = value }
    }

    private let lock = NSLock()
    private var recorders: [WeakRecorder] = []
    private var handlersInstalled = false
    private var atexitInstalled = false
    private var signalSources: [any DispatchSourceSignal] = []

    func register(_ recorder: Recorder) {
        lock.lock(); defer { lock.unlock() }
        recorders.removeAll { $0.value == nil || $0.value === recorder }
        recorders.append(WeakRecorder(recorder))
        installAtExitHookLocked()
    }

    func unregister(_ recorder: Recorder) {
        lock.lock(); defer { lock.unlock() }
        recorders.removeAll { $0.value == nil || $0.value === recorder }
    }

    /// Finalizes every live recording. Safe to call more than once; recorders
    /// not in `.recording` state return immediately.
    func finalizeAll(timeout: TimeInterval = 5.0) {
        lock.lock()
        let live = recorders.compactMap(\.value)
        lock.unlock()
        for recorder in live {
            recorder.finalizeSynchronously(timeout: timeout)
        }
    }

    /// Registers the `atexit` hook exactly once, lazily, on the first
    /// recording. Caller must hold `lock`.
    private func installAtExitHookLocked() {
        guard !atexitInstalled else { return }
        atexitInstalled = true
        // Non-capturing, so it converts to the @convention(c) function atexit
        // requires. It reaches the live recorders through the shared registry.
        atexit { RecorderRegistry.shared.finalizeAll() }
    }

    func installTerminationHandlers() {
        lock.lock()
        defer { lock.unlock() }
        guard !handlersInstalled else { return }
        handlersInstalled = true

        for sig in [SIGINT, SIGTERM] {
            // The default disposition must be disabled first, otherwise the
            // process dies before the dispatch source ever runs.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                RecorderRegistry.shared.finalizeAll()
                exit(sig == SIGINT ? 130 : 143)
            }
            source.resume()
            signalSources.append(source)
        }
        installAtExitHookLocked()
    }
}
