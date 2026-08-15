// Config.swift
// Central configuration types shared by every module: capture presets,
// webcam-bubble geometry, encoder settings, and the aspect-ratio policy.
// These are pure value types (structs/enums) so they can cross actor and
// concurrency-domain boundaries freely — hence `Sendable` throughout.

import Foundation
import CoreGraphics
import AVFoundation

/// Output resolution presets. Values are the PIXEL dimensions of the final
/// encoded video, after any letterbox/crop policy has been applied — NOT
/// the raw display capture size.
///
/// TRAP (see project notes, item 1): SCDisplay.width/height are reported in
/// POINTS. To get capture pixel dimensions you must multiply by
/// SCContentFilter.pointPixelScale (2.0 on this machine's scaled display
/// mode: 1710x1107 pt -> 3420x2214 px). ScreenSource is responsible for
/// doing that conversion; Config only describes the desired OUTPUT.
public enum OutputResolution: String, Sendable, Codable, CaseIterable {
    case hd1080p
    case uhd4K

    /// Target pixel dimensions in landscape orientation (width, height).
    public var pixelSize: CGSize {
        switch self {
        case .hd1080p: return CGSize(width: 1920, height: 1080)
        case .uhd4K: return CGSize(width: 3840, height: 2160)
        }
    }
}

/// How to reconcile the display's native aspect ratio (1.545:1 on this
/// machine's panel) with the fixed output aspect ratio (1.778:1 / 16:9 for
/// both 1080p and 4K presets).
///
/// TRAP (project notes item 7): naively stretching the captured frame to
/// fill the output frame distorts everything on screen (circles become
/// ovals, text becomes squashed). Compositor must implement one of these
/// two policies explicitly — it must never scale width and height by
/// different factors.
public enum AspectPolicy: String, Sendable, Codable, CaseIterable {
    /// Fit the whole captured display inside the output frame, adding
    /// letterbox bars (top/bottom or left/right, whichever is needed) filled
    /// with `letterboxColor`. Nothing is cropped; some output pixels are bars.
    case letterbox
    /// Fill the entire output frame with the captured display, cropping
    /// whatever doesn't fit (centered crop). No bars; some source content
    /// outside the output aspect is discarded.
    case crop
}

/// Which corner of the screen the circular camera bubble is anchored to.
public enum BubbleCorner: String, Sendable, Codable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// Geometry for the circular webcam bubble overlay, expressed in fractions
/// of the OUTPUT frame so it scales consistently between 1080p and 4K.
public struct BubbleGeometry: Sendable, Codable, Equatable {
    /// Which corner the bubble is anchored to.
    public var corner: BubbleCorner
    /// Diameter of the bubble as a fraction of the output frame's shorter
    /// side (e.g. 0.22 => bubble diameter is 22% of min(width, height)).
    public var diameterFraction: CGFloat
    /// Inset from the two edges of `corner`, as a fraction of the output
    /// frame's shorter side.
    public var marginFraction: CGFloat
    /// Width of the solid border stroke drawn around the bubble, as a
    /// fraction of the bubble diameter. 0 disables the border.
    public var borderWidthFraction: CGFloat
    /// Border stroke color (sRGB). Ignored if borderWidthFraction is 0.
    public var borderColor: CodableColor

    public init(
        corner: BubbleCorner = .bottomLeft,
        diameterFraction: CGFloat = 0.22,
        marginFraction: CGFloat = 0.04,
        borderWidthFraction: CGFloat = 0.012,
        borderColor: CodableColor = CodableColor(red: 1, green: 1, blue: 1, alpha: 0.9)
    ) {
        self.corner = corner
        self.diameterFraction = diameterFraction
        self.marginFraction = marginFraction
        self.borderWidthFraction = borderWidthFraction
        self.borderColor = borderColor
    }

    public static let `default` = BubbleGeometry()
}

/// A `Sendable`, `Codable` stand-in for `CGColor` (which is neither),
/// carrying straight sRGB components in [0, 1].
public struct CodableColor: Sendable, Codable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Video codec choice for the encoded output.
public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case h264
    case hevc

    public var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Encoder tuning knobs handed to AVAssetWriter / VideoToolbox.
public struct EncoderSettings: Sendable, Codable, Equatable {
    public var codec: VideoCodec
    /// Average bitrate in bits per second. nil lets the codec pick a
    /// quality-based rate (VBR).
    public var averageBitRate: Int?
    /// Keyframe interval in seconds.
    public var keyframeIntervalSeconds: Double
    /// Whether to request hardware encoding explicitly (AppleAVE is present
    /// on the target machine; this should stay true).
    public var preferHardwareEncoder: Bool

    public init(
        codec: VideoCodec = .hevc,
        averageBitRate: Int? = nil,
        keyframeIntervalSeconds: Double = 2.0,
        preferHardwareEncoder: Bool = true
    ) {
        self.codec = codec
        self.averageBitRate = averageBitRate
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.preferHardwareEncoder = preferHardwareEncoder
    }

    public static let `default` = EncoderSettings()
}

/// Top-level recording configuration assembled by the UI and consumed by
/// ScreenSource, CameraSource, Compositor, and Recorder.
public struct RecordingConfig: Sendable, Codable, Equatable {
    public var outputResolution: OutputResolution
    public var aspectPolicy: AspectPolicy
    public var frameRate: Int
    public var bubble: BubbleGeometry
    public var encoder: EncoderSettings
    /// Fixed compensation delay applied to the SCREEN stream so it lines up
    /// with the (slower) camera stream.
    ///
    /// TRAP (project notes item 5): webcam frames arrive 50-150ms behind
    /// screen frames because AVCaptureSession's pipeline (sensor -> ISP ->
    /// delivery) is slower than ScreenCaptureKit's. If the compositor pairs
    /// "latest screen frame" with "latest camera frame" naively, the bubble
    /// visibly lags the screen content (e.g. mouse clicks are seen before
    /// the presenter's reaction to them). Compositor delays the screen
    /// frame it composites against by this many milliseconds (via a small
    /// ring buffer) to resynchronize. 90ms is a reasonable measured default
    /// for AVCaptureSession on Apple Silicon; expose it so it's tunable
    /// without a rebuild once real measurements come in.
    public var cameraOffsetMilliseconds: Double
    /// Whether to capture the microphone.
    ///
    /// TRAP (project notes item 4): system audio (.audio) and microphone
    /// (.microphone) sample buffers MUST NEVER be appended to the same
    /// AVAssetWriterInput. They carry different CMFormatDescriptions,
    /// sample rates, and clocks; muxing them into one input produces a
    /// corrupt, unplayable MP4 (confirmed by Apple DTS). In
    /// `.separate` mode Recorder therefore uses two audio input handles,
    /// never one; in `.mixed` mode the single input is fed by the mixer,
    /// which has already resampled both sources into one uniform format —
    /// see `audioTrackMode`.
    public var captureMicrophone: Bool
    /// Whether to capture system audio output.
    public var captureSystemAudio: Bool
    /// Whether the two audio sources land on two tracks or are summed into
    /// one. See `AudioTrackMode` — `.mixed` is NOT "both inputs share one
    /// AVAssetWriterInput", it requires the upstream mixer.
    public var audioTrackMode: AudioTrackMode
    /// `AVCaptureDevice.uniqueID` of the microphone to record, or nil for
    /// "system default input".
    ///
    /// Fed to `SCStreamConfiguration.microphoneCaptureDeviceID` (which is
    /// itself `String?` with the same nil = default semantics), so nil
    /// passes straight through. If the chosen device has been unplugged by
    /// the time recording starts, callers must fall back to nil rather than
    /// failing — a stale uniqueID handed to ScreenCaptureKit yields no mic
    /// audio at all.
    public var microphoneDeviceID: String?
    /// Explicit color space tag applied to both SCStreamConfiguration and
    /// the written video track.
    ///
    /// TRAP (project notes item 6): if this is left unset, captured frames
    /// and/or the encoded file end up with mismatched or absent color
    /// tagging and playback looks washed out or oversaturated on wide-gamut
    /// displays. ScreenSource sets SCStreamConfiguration.colorSpaceName
    /// from this value; Recorder writes matching color primaries /
    /// transfer function / YCbCr matrix tags to the video track.
    public var colorSpace: ColorSpacePolicy
    /// Version of the persisted representation this value was decoded from
    /// (or `Self.currentSchemaVersion` for a freshly constructed one). See
    /// the migration note on `init(from:)`.
    public private(set) var schemaVersion: Int

    /// Bump whenever a DEFAULT changes in a way existing installs must pick
    /// up (not merely when a field is added — an added field with a sensible
    /// default needs no bump, `decodeIfPresent` handles it).
    ///
    /// v1 -> v2: audio on by default. `captureSystemAudio` false -> true and
    /// `audioTrackMode` introduced as `.mixed`.
    public static let currentSchemaVersion = 2

    public init(
        outputResolution: OutputResolution = .uhd4K,
        aspectPolicy: AspectPolicy = .letterbox,
        frameRate: Int = 30,
        bubble: BubbleGeometry = .default,
        encoder: EncoderSettings = .default,
        cameraOffsetMilliseconds: Double = 90,
        captureMicrophone: Bool = true,
        captureSystemAudio: Bool = true,
        audioTrackMode: AudioTrackMode = .mixed,
        microphoneDeviceID: String? = nil,
        colorSpace: ColorSpacePolicy = .displayP3
    ) {
        self.outputResolution = outputResolution
        self.aspectPolicy = aspectPolicy
        self.frameRate = frameRate
        self.bubble = bubble
        self.encoder = encoder
        self.cameraOffsetMilliseconds = cameraOffsetMilliseconds
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.audioTrackMode = audioTrackMode
        self.microphoneDeviceID = microphoneDeviceID
        self.colorSpace = colorSpace
        self.schemaVersion = Self.currentSchemaVersion
    }

    public static let `default` = RecordingConfig()

    // MARK: - Persistence & migration

    private enum CodingKeys: String, CodingKey {
        case outputResolution, aspectPolicy, frameRate, bubble, encoder
        case cameraOffsetMilliseconds, captureMicrophone, captureSystemAudio
        case audioTrackMode, microphoneDeviceID, colorSpace, schemaVersion
    }

    /// MIGRATION STRATEGY: versioned decode, NOT a bumped UserDefaults key.
    ///
    /// The problem: `HaloSettingsStore` persists this struct as a JSON blob
    /// under "halo.recordingConfig.v1". Every existing install decodes that
    /// old blob successfully, so flipping `captureSystemAudio`'s default in
    /// the memberwise init above changes NOTHING for them — the decoder
    /// reads the stored `false` and the user silently keeps a mic-only,
    /// two-track setup, which is exactly the outcome this change exists to
    /// fix.
    ///
    /// Why not just bump the key to ".v2": that throws away every unrelated
    /// preference the user has set (resolution, frame rate, codec, bubble
    /// corner/size/border color, camera offset, color space). Resetting a
    /// dozen deliberate choices to force one audio change is a bad trade,
    /// and it leaves a dead v1 blob in defaults forever.
    ///
    /// So: keep the key, carry an explicit `schemaVersion` INSIDE the blob,
    /// decode every field with `decodeIfPresent` so old blobs (which have
    /// none of the new keys, and no version at all) still load, and then
    /// apply a one-time upgrade for anything below the current version.
    /// Non-audio settings survive untouched.
    ///
    /// Idempotence note: the upgrade re-applies on each launch until the
    /// blob is rewritten with the new `schemaVersion`, because we only
    /// persist on save. That is harmless — it sets the same two values —
    /// and the very first settings write (the store does read-modify-write
    /// on every menu toggle, and a user disabling system audio necessarily
    /// performs one) stamps v2 and stops it, so a deliberate opt-out is not
    /// clobbered on the next launch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingConfig.default

        outputResolution = try c.decodeIfPresent(OutputResolution.self, forKey: .outputResolution) ?? d.outputResolution
        aspectPolicy = try c.decodeIfPresent(AspectPolicy.self, forKey: .aspectPolicy) ?? d.aspectPolicy
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        bubble = try c.decodeIfPresent(BubbleGeometry.self, forKey: .bubble) ?? d.bubble
        encoder = try c.decodeIfPresent(EncoderSettings.self, forKey: .encoder) ?? d.encoder
        cameraOffsetMilliseconds = try c.decodeIfPresent(Double.self, forKey: .cameraOffsetMilliseconds)
            ?? d.cameraOffsetMilliseconds
        captureMicrophone = try c.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? d.captureMicrophone
        captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? d.captureSystemAudio
        audioTrackMode = try c.decodeIfPresent(AudioTrackMode.self, forKey: .audioTrackMode) ?? d.audioTrackMode
        // Absent key and explicit null both mean "system default input".
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        colorSpace = try c.decodeIfPresent(ColorSpacePolicy.self, forKey: .colorSpace) ?? d.colorSpace

        // A blob written before versioning existed has no key here; treat it
        // as v1, which is what it is.
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = RecordingConfig.currentSchemaVersion
        if storedVersion < 2 {
            // v1 -> v2. Turn audio on for real, once. `captureMicrophone` is
            // intentionally NOT forced: its default was already true in v1,
            // so a stored `false` there is a deliberate user choice ("record
            // silently"), and overriding it would start recording a room the
            // user chose not to record. `captureSystemAudio == false`, by
            // contrast, is indistinguishable from the old default, so the
            // upgrade owns it.
            captureSystemAudio = true
            // `audioTrackMode` cannot have been stored by v1, so this is
            // just the new default made explicit — stated here rather than
            // left implicit so the intent of the migration is readable.
            audioTrackMode = .mixed
        }
    }
}

/// How the two audio sources (microphone + system audio) are laid out in
/// the written MP4.
///
/// TRAP (project notes item 4): the ONLY safe way to put both sources in one
/// file without mixing is `.separate` — two distinct AVAssetWriterInputs.
/// SCK's `.audio` and `.microphone` sample buffers carry different
/// CMFormatDescriptions, potentially different sample rates/channel counts,
/// and independent clocks, so appending both to a single AVAssetWriterInput
/// produces a corrupt, unplayable MP4 (confirmed by Apple DTS).
///
/// `.mixed` therefore does NOT mean "point both append paths at one input".
/// It means an upstream mixer converts both streams to one canonical PCM
/// format, aligns them on normalized PTS, sums them, and emits a single
/// uniformly-formatted stream — the writer still only ever sees one format
/// on that input. Anything less reintroduces the corruption bug.
public enum AudioTrackMode: String, Sendable, Codable, CaseIterable {
    /// Microphone and system audio each get their own audio track.
    /// Highest fidelity / post-production friendly, but many players and
    /// upload pipelines (YouTube among them) read only the FIRST audio
    /// track, silently dropping the other one.
    case separate
    /// One audio track containing mic + system audio summed together.
    /// Plays everywhere; the default for that reason.
    case mixed
}

/// Color space policy applied consistently to capture config and the
/// written file's video track tags. See `RecordingConfig.colorSpace`.
public enum ColorSpacePolicy: String, Sendable, Codable, CaseIterable {
    case sRGB
    case displayP3
}

/// Single source of truth for the version string. Scripts/make_app.sh writes
/// the same value into the bundle's CFBundleShortVersionString, so keep the
/// two in sync when bumping.
public enum HaloVersion {
    public static let string = "1.0.0"
}
