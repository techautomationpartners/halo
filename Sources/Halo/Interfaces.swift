// Interfaces.swift
// Shared protocols and value types implemented by ScreenSource, CameraSource,
// Compositor, and Recorder. These are the fixed contract between modules —
// treat signatures here as frozen; changing them requires re-coordinating
// every conformer.

import CoreMedia
import CoreVideo
import Foundation
import AVFoundation
@preconcurrency import ScreenCaptureKit

// MARK: - Frame types

/// A single video frame: a pixel buffer plus timing info, produced by
/// ScreenSource or CameraSource and consumed by Compositor/Recorder.
///
/// TRAP (project notes item 3, PTS NORMALIZATION): every producer must
/// record the CMTime of its own first sample and subtract it from every
/// subsequent sample's presentation timestamp before wrapping it here, so
/// `presentationTime` always starts at .zero regardless of when capture
/// actually began or how the screen/camera clocks differ in origin.
public struct VideoFrame: @unchecked Sendable {
    /// The pixel buffer backing this frame.
    ///
    /// CVPixelBuffer is a Core Foundation type not marked `Sendable` by the
    /// SDK. It is safe to send across concurrency domains here because each
    /// `VideoFrame` wraps a reference freshly produced for this one sample
    /// by ScreenCaptureKit/AVFoundation (or freshly allocated by Compositor
    /// from its own CVPixelBufferPool), and nothing mutates a buffer's
    /// contents in place after it is wrapped — a reader either copies out
    /// of it or renders a brand-new buffer from it.
    public let pixelBuffer: CVPixelBuffer
    /// Presentation time, already normalized so recording start = .zero.
    public let presentationTime: CMTime
    /// Wall-clock capture time (CACurrentMediaTime / host-time domain, i.e.
    /// CMSampleBuffer's syncedHostTime), NOT normalized. Used by the
    /// camera-offset ring buffer (project notes item 5) to pair a screen
    /// frame with the camera frame that was actually in front of the
    /// camera at a matching real-world instant, independent of either
    /// stream's own PTS numbering.
    public let captureHostTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureHostTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.captureHostTime = captureHostTime
    }
}

/// Which physical/logical source an `AudioFrame` came from. Carried
/// explicitly (rather than inferred from which stream property it arrived
/// on) so Recorder can assert it is routing each frame to the correct,
/// separate AVAssetWriterInput.
public enum AudioSourceKind: Sendable, Codable {
    case systemAudio
    case microphone
}

/// A single audio sample buffer plus which physical source it came from.
///
/// TRAP (project notes item 4): a RAW .systemAudio frame and a RAW
/// .microphone frame must NEVER be appended to the same AVAssetWriterInput.
/// Apple DTS has confirmed that muxing ScreenCaptureKit's `.audio` and
/// `.microphone` sample buffers into one input produces a corrupt, unplayable
/// MP4 — they carry different CMFormatDescriptions, sample rates, and clocks,
/// and an AVAssetWriterInput assumes one format-stable, monotonic stream.
/// `Recording` exposes `appendSystemAudio` and `appendMicrophoneAudio` as two
/// distinct methods so the two raw streams cannot be merged by accident.
///
/// This is a constraint on the RAW buffers, not a ban on ever producing one
/// audio track. `RecordingConfig.audioTrackMode` has two legal answers:
///
///   .separate — the two raw streams go to two inputs and two tracks. The
///     trap is avoided by never letting them meet.
///
///   .mixed — `AudioMixer` (inside Recorder) converts BOTH sources to one
///     canonical PCM format (48 kHz stereo Float32), aligns them on the
///     normalized PTS timeline below, sums them, and emits brand-new
///     uniformly-formatted sample buffers. Only those emitted buffers reach
///     the single writer input; no raw capture buffer ever does. That is the
///     whole distinction — one input fed by a mixer is correct, one input fed
///     by two raw append paths is the corruption bug.
///
/// So "never merge these streams" means never merge them at the WRITER.
/// Mixing them into a new uniform stream first is the supported path.
public struct AudioFrame: @unchecked Sendable {
    /// See `VideoFrame.pixelBuffer` doc comment for why a non-Sendable Core
    /// Foundation type is safe to wrap here: each instance is a uniquely
    /// owned reference to one immutable sample, never mutated in place.
    public let sampleBuffer: CMSampleBuffer
    public let source: AudioSourceKind
    /// Presentation time, already normalized so recording start = .zero.
    public let presentationTime: CMTime

    public init(sampleBuffer: CMSampleBuffer, source: AudioSourceKind, presentationTime: CMTime) {
        self.sampleBuffer = sampleBuffer
        self.source = source
        self.presentationTime = presentationTime
    }
}

// MARK: - Errors

/// Common error type surfaced by any module in this package. Individual
/// modules may wrap more specific underlying errors in `.underlying`.
public enum HaloError: Error, Sendable {
    case permissionDenied(String)
    case deviceUnavailable(String)
    case captureFailed(String)
    case compositingFailed(String)
    case writeFailed(String)
    case invalidState(String)
    case underlying(any Error & Sendable)
}

// MARK: - ScreenSourcing

/// Captures the screen via ScreenCaptureKit and produces a fixed-cadence
/// video stream plus (optionally) system-audio and microphone audio
/// streams. SCStreamConfiguration.captureMicrophone is used for the mic
/// path rather than a second AVCaptureSession, so both audio tracks share
/// ScreenCaptureKit's capture clock.
public protocol ScreenSourcing: Sendable {
    /// Begins capturing `display`. Implementations own the POINTS -> PIXELS
    /// conversion (project notes item 1): SCDisplay.width/height are in
    /// points, so the SCStreamConfiguration.width/height passed to
    /// ScreenCaptureKit must be `config.outputResolution`'s implied capture
    /// size scaled by the content filter's `pointPixelScale` (2.0 for this
    /// machine's scaled display mode), NOT the raw SCDisplay point values.
    func start(display: SCDisplay, config: RecordingConfig) async throws

    /// Stops capture and finishes all three AsyncStreams below.
    func stop() async

    /// Video frames delivered at a FIXED cadence of `config.frameRate`.
    ///
    /// TRAP (project notes item 2, VARIABLE FRAME RATE): ScreenCaptureKit
    /// only invokes its callback when on-screen content changes, so an
    /// idle screen can go seconds between native callbacks. Conformers
    /// must NOT pass that callback cadence straight through this stream —
    /// they must drive an internal fixed-rate timer and, whenever SCK has
    /// been idle, re-emit the most recently received pixel buffer with a
    /// freshly computed `presentationTime` so this stream always yields at
    /// `config.frameRate` regardless of on-screen activity.
    var videoFrames: AsyncStream<VideoFrame> { get }

    /// System audio frames (`.audio` from SCStream). Empty stream if
    /// `config.captureSystemAudio` was false at `start`.
    var systemAudioFrames: AsyncStream<AudioFrame> { get }

    /// Microphone frames (`.microphone` from SCStream). Empty stream if
    /// `config.captureMicrophone` was false at `start`.
    var microphoneAudioFrames: AsyncStream<AudioFrame> { get }
}

// MARK: - CameraSourcing

/// Captures raw (uncomposited, not yet circle-masked) webcam frames via
/// AVCaptureSession. Circular masking and bubble placement are Compositor's
/// job, not CameraSource's — this protocol only produces plain rectangular
/// frames plus timing.
public protocol CameraSourcing: Sendable {
    /// Begins capturing `device`.
    func start(device: AVCaptureDevice, config: RecordingConfig) async throws

    /// Stops capture and finishes `videoFrames`.
    func stop() async

    /// Raw camera frames as delivered by AVCaptureSession (variable
    /// cadence is fine here — Compositor/the camera-offset ring buffer
    /// consuming this stream is responsible for pairing frames against the
    /// fixed-cadence screen stream, not this protocol).
    ///
    /// NOTE (project notes item 5): frames on this stream lag real-world
    /// events by roughly 50-150ms relative to ScreenSource's `videoFrames`
    /// because of AVCaptureSession's sensor -> ISP -> delivery pipeline.
    /// `captureHostTime` on each frame is what downstream code uses to
    /// correct for that; CameraSource itself does no correction.
    var videoFrames: AsyncStream<VideoFrame> { get }
}

// MARK: - Compositing

/// Combines one screen frame and (optionally) one camera frame into a
/// single output frame at `config.outputResolution`: the screen frame
/// scaled per `config.aspectPolicy` (letterbox or crop — never stretched,
/// project notes item 7), with the camera frame circle-masked and drawn per
/// `config.bubble`.
public protocol Compositing: Sendable {
    /// Allocates persistent GPU resources (Metal device, CIContext,
    /// CVPixelBufferPool) sized for `config.outputResolution`. Must be
    /// called once before the first `composite` call, and again if
    /// `config` changes resolution.
    ///
    /// TRAP (project notes item 8): compositing at 4K60 must run on a
    /// persistent CIContext backed by Metal. Allocating a new CIContext
    /// per frame is a documented, severe performance cliff. Conformers
    /// must create and cache their CIContext/MTLDevice/pixel buffer pool
    /// here, not inside `composite`.
    func prepare(config: RecordingConfig) throws

    /// Produces one output `VideoFrame` at `config.outputResolution`.
    ///
    /// `cameraFrame` is nil when no camera is attached, or none is
    /// available yet (e.g. still warming up) — conformers must still
    /// return a valid screen-only frame in that case, not throw.
    ///
    /// The CALLER is responsible for camera-offset resynchronization
    /// (project notes item 5, `config.cameraOffsetMilliseconds`): by the
    /// time a `(screenFrame, cameraFrame)` pair reaches this method, the
    /// caller has already chosen the pairing that accounts for the offset.
    /// This method just draws whatever pair it is given.
    ///
    /// `presentationTime`/`captureHostTime` on the returned frame are
    /// copied from `screenFrame` (the screen stream owns the master
    /// cadence at `config.frameRate`).
    func composite(screenFrame: VideoFrame, cameraFrame: VideoFrame?, config: RecordingConfig) throws -> VideoFrame
}

// MARK: - Recording

/// Muxes composited video and one or two audio tracks into an MP4 via
/// AVAssetWriter + VideoToolbox. The audio track layout is chosen by
/// `RecordingConfig.audioTrackMode` — see `AudioFrame` for why the two
/// layouts are not interchangeable.
public protocol Recording: Sendable {
    /// Creates the AVAssetWriter, its single video input, and the audio
    /// inputs implied by `config.audioTrackMode`, then starts a writing
    /// session at source time `.zero`.
    ///
    /// - `.separate`: up to two audio inputs, one per enabled source. Raw
    ///   buffers go straight to their own input; the two never share one
    ///   (project notes item 4).
    /// - `.mixed`: exactly one audio input, fed only by the internal
    ///   `AudioMixer`'s canonical-format output. Raw capture buffers never
    ///   reach it.
    func start(outputURL: URL, config: RecordingConfig) throws

    /// Appends one composited video frame. `frame.presentationTime` must
    /// already be normalized to start-of-recording = 0 (project notes
    /// item 3); Recorder does not re-normalize.
    func appendVideo(_ frame: VideoFrame) throws

    /// Submits one system-audio sample buffer. In `.separate` mode it is
    /// appended to the dedicated system-audio track; in `.mixed` mode it is
    /// handed to the mixer and only its contribution to a summed block ever
    /// reaches a track. Throws `HaloError.invalidState` if `frame.source !=
    /// .systemAudio`.
    ///
    /// Kept as a separate method (rather than one `appendAudio` that
    /// switches on `frame.source`) in BOTH modes, so a caller can never
    /// route a raw buffer onto a track it does not belong on — see project
    /// notes item 4.
    func appendSystemAudio(_ frame: AudioFrame) throws

    /// Submits one microphone sample buffer. In `.separate` mode it goes to
    /// a microphone track on an AVAssetWriterInput distinct from
    /// `appendSystemAudio`'s (project notes item 4); in `.mixed` mode it
    /// goes to the mixer. Throws `HaloError.invalidState` if
    /// `frame.source != .microphone`.
    func appendMicrophoneAudio(_ frame: AudioFrame) throws

    /// Signals that one audio source's stream has FINISHED — no further
    /// `appendSystemAudio` / `appendMicrophoneAudio` call will ever be made for
    /// it in this session. Callers should invoke it as soon as their pump loop
    /// over that stream exits.
    ///
    /// It exists for `.mixed` mode: the mixer waits a bounded time for a source
    /// that is merely running behind, and without an explicit end-of-stream
    /// signal it cannot tell that case from a source that is simply over. That
    /// forces the wait to double as a dead-source timeout, and a short timeout
    /// silently DISCARDS late-but-valid buffers — losing exactly the narration
    /// that mixed mode exists to preserve. Defaulted to a no-op so `.separate`
    /// -only conformers (and test doubles) need not implement it.
    func audioSourceDidFinish(_ source: AudioSourceKind)

    /// Finishes writing, closes all tracks, and finalizes the MP4 at
    /// `outputURL`.
    func stop() async throws
}

public extension Recording {
    func audioSourceDidFinish(_ source: AudioSourceKind) {}
}
