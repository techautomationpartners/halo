// Permissions.swift
// TCC (Transparency, Consent, and Control) handling for the three
// privacy-gated capabilities Halo needs: Screen Recording, Camera, and
// Microphone.
//
// Everything here is local and read-only with respect to the user's data —
// we only ask the system what it has already decided, and (optionally) ask
// it to show the standard system prompt.

import AVFoundation
import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Kinds

/// One privacy-gated capability. `rawValue` is stable and safe to persist.
public enum PermissionKind: String, Sendable, Codable, Hashable, CaseIterable {
    case screenRecording
    case camera
    case microphone

    /// Name as it appears in System Settings, for user-facing strings.
    public var displayName: String {
        switch self {
        case .screenRecording: return "Screen & System Audio Recording"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        }
    }

    /// Deep link into the matching System Settings > Privacy & Security pane.
    ///
    /// The legacy `com.apple.preference.security` host is the one every tutorial
    /// still cites, but on macOS 26 it no longer honours the anchor — it just
    /// reopens whatever pane System Settings last showed. Verified on macOS
    /// 26.5.1: asking for `Privacy_ScreenCapture` through the legacy host landed
    /// on the Camera pane, sending users somewhere they cannot fix the problem
    /// (Camera has no "+" button, so the app they are looking for is not even
    /// addable there). `com.apple.settings.PrivacySecurity.extension` resolves
    /// the anchor correctly.
    public var settingsURL: URL? {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")
    }

    /// Human-readable instructions for granting this permission by hand,
    /// used when the system will no longer show a prompt (see
    /// `Permissions.requestScreenRecording` for why that happens).
    public var manualGuidance: String {
        switch self {
        case .screenRecording:
            return """
            Open System Settings > Privacy & Security > Screen & System Audio \
            Recording and switch Halo on. macOS only ever shows the Screen \
            Recording prompt once per app; after that the toggle is the only \
            way in. macOS also requires Halo to be relaunched after the \
            toggle is flipped before capture will actually work.
            """
        case .camera:
            return """
            Open System Settings > Privacy & Security > Camera and switch \
            Halo on. Without it the webcam bubble stays empty; screen \
            recording itself still works.
            """
        case .microphone:
            return """
            Open System Settings > Privacy & Security > Microphone and switch \
            Halo on. Without it the recording has no voice track; screen \
            recording itself still works.
            """
        }
    }
}

/// Current TCC decision for one `PermissionKind`.
public enum PermissionStatus: String, Sendable, Codable, Hashable {
    /// Granted — the capability is usable right now.
    case authorized
    /// The user has never been asked; requesting will show a system prompt.
    case notDetermined
    /// The user (or a previous prompt) said no. Only System Settings can undo it.
    case denied
    /// Blocked by policy (MDM / parental controls). The user cannot change it.
    case restricted

    public var isUsable: Bool { self == .authorized }
}

// MARK: - Report

/// The result of a preflight: what Halo needs, what it has, and what to tell
/// the user about the gap.
public struct PermissionReport: Sendable, Equatable {
    /// Status of every permission that was *checked* (i.e. every one this
    /// recording configuration actually needs).
    public let statuses: [PermissionKind: PermissionStatus]
    /// Permissions that were required but are not `.authorized`, in a stable
    /// order (screen recording first — it is the only hard blocker).
    public let missing: [PermissionKind]
    /// Permissions that are missing but that Halo can degrade around
    /// (camera, microphone). Screen recording is never in here.
    public let missingButOptional: [PermissionKind]

    /// True when nothing required is missing.
    public var isSatisfied: Bool { missing.isEmpty }

    /// True when recording can proceed at all — i.e. screen recording is
    /// granted, even if camera/mic are not.
    public var canRecord: Bool {
        statuses[.screenRecording, default: .denied].isUsable
    }

    public func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }

    /// A ready-to-display multi-line explanation of everything that is
    /// missing, with System Settings directions. Empty string when nothing
    /// is missing.
    public var guidanceText: String {
        guard !missing.isEmpty else { return "" }
        return missing.map { kind in
            let state = status(of: kind)
            let head: String
            switch state {
            case .restricted:
                head = "\(kind.displayName) is blocked by a device policy and cannot be enabled here."
            case .denied:
                head = "\(kind.displayName) access was denied."
            case .notDetermined:
                head = "\(kind.displayName) access has not been granted yet."
            case .authorized:
                head = "\(kind.displayName) access is granted."
            }
            return "\(head)\n\(kind.manualGuidance)"
        }
        .joined(separator: "\n\n")
    }

    public init(statuses: [PermissionKind: PermissionStatus]) {
        self.statuses = statuses
        // Stable ordering: screen recording is the hard blocker, so it leads.
        let order: [PermissionKind] = [.screenRecording, .camera, .microphone]
        let notGranted = order.filter { statuses[$0].map { !$0.isUsable } ?? false }
        self.missing = notGranted
        self.missingButOptional = notGranted.filter { $0 != .screenRecording }
    }
}

// MARK: - Permissions

/// Namespace for TCC checks and requests. Stateless — every call asks the
/// system fresh (subject to the caveats documented on each method).
public enum Permissions {

    // MARK: Status

    /// Current status of one permission, without prompting.
    public static func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return screenRecordingStatus()
        case .camera:
            return captureStatus(for: .video)
        case .microphone:
            return captureStatus(for: .audio)
        }
    }

    /// Screen Recording status.
    ///
    /// CAVEAT: CoreGraphics exposes only a boolean preflight, so there is no
    /// way to distinguish "never asked" from "explicitly denied" — both come
    /// back false. We report `.denied` for false, because the user-facing
    /// remedy (`manualGuidance`) is identical in both cases and is the safe
    /// thing to show. `CGPreflightScreenCaptureAccess` also caches its answer
    /// for the lifetime of the process, so a permission granted in System
    /// Settings while Halo is running will not be reflected until relaunch —
    /// which matches macOS's own requirement that the app be restarted.
    public static func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    private static func captureStatus(for mediaType: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    // MARK: Requests

    /// Triggers the system Screen Recording prompt if it has never been shown
    /// for this app, and returns whether access is granted.
    ///
    /// CAVEAT: macOS shows this prompt AT MOST ONCE per app (keyed by bundle
    /// identifier + code signature). Once the user dismisses or denies it,
    /// this call silently returns false forever and the only path forward is
    /// System Settings — hence `PermissionKind.manualGuidance`. Granting also
    /// requires an app relaunch before ScreenCaptureKit will actually hand
    /// over frames.
    ///
    /// This is a synchronous CoreGraphics call that can block briefly while
    /// the system UI appears; call it off the main thread when possible.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Shows the system Camera prompt if the status is `.notDetermined`.
    /// Returns the resulting grant state. Never prompts twice.
    @discardableResult
    public static func requestCamera() async -> Bool {
        await requestCaptureAccess(for: .video)
    }

    /// Shows the system Microphone prompt if the status is `.notDetermined`.
    ///
    /// NOTE: Halo captures the mic through
    /// `SCStreamConfiguration.captureMicrophone` rather than its own
    /// AVCaptureSession, but the TCC gate is the same one AVFoundation uses,
    /// so requesting it via AVCaptureDevice is correct and is what makes the
    /// ScreenCaptureKit mic path work.
    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await requestCaptureAccess(for: .audio)
    }

    private static func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted:
            // Requesting again is a no-op that returns false immediately;
            // skip it so callers don't mistake it for a fresh refusal.
            return false
        @unknown default:
            return false
        }
    }

    // MARK: Preflight

    /// The single entry point the UI should call before starting a recording.
    ///
    /// Checks exactly the permissions `config` implies (screen recording
    /// always; microphone only if `config.captureMicrophone`; camera only if
    /// `includeCamera`), optionally showing the system prompts for any that
    /// are still `.notDetermined`, and returns a report describing what is
    /// still missing plus human-readable guidance.
    ///
    /// - Parameters:
    ///   - config: the recording configuration about to be used.
    ///   - includeCamera: whether the webcam bubble is enabled. Camera access
    ///     is not implied by `RecordingConfig`, so the caller states it.
    ///   - requestIfNeeded: when true (default), shows system prompts for
    ///     `.notDetermined` permissions before reporting. When false this is
    ///     a pure, non-interactive query.
    public static func preflight(
        config: RecordingConfig,
        includeCamera: Bool,
        requestIfNeeded: Bool = true
    ) async -> PermissionReport {
        var required: [PermissionKind] = [.screenRecording]
        if includeCamera { required.append(.camera) }
        if config.captureMicrophone { required.append(.microphone) }
        return await preflight(required, requestIfNeeded: requestIfNeeded)
    }

    /// Preflight an explicit set of permissions.
    public static func preflight(
        _ required: [PermissionKind],
        requestIfNeeded: Bool = true
    ) async -> PermissionReport {
        var statuses: [PermissionKind: PermissionStatus] = [:]

        for kind in required {
            var current = status(of: kind)

            if requestIfNeeded && !current.isUsable && current != .restricted {
                switch kind {
                case .screenRecording:
                    // CGRequestScreenCaptureAccess MUST run on the main thread.
                    // Dispatching it to a detached task made it return false
                    // WITHOUT ever showing the prompt or registering the app in
                    // System Settings > Screen & System Audio Recording, so the
                    // user was told access was denied with no way to grant it —
                    // the app never appeared in the list to toggle on.
                    let granted = await MainActor.run { requestScreenRecording() }
                    current = granted ? .authorized : .denied
                case .camera:
                    current = await requestCamera() ? .authorized : captureStatus(for: .video)
                case .microphone:
                    current = await requestMicrophone() ? .authorized : captureStatus(for: .audio)
                }
            }

            statuses[kind] = current
        }

        return PermissionReport(statuses: statuses)
    }

    // MARK: Settings

    /// Opens System Settings at the pane for `kind`. Returns false if the
    /// URL could not be opened.
    @MainActor
    @discardableResult
    public static func openSettings(for kind: PermissionKind) -> Bool {
        #if canImport(AppKit)
        guard let url = kind.settingsURL else { return false }
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }
}
