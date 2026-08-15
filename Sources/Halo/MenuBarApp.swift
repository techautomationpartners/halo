// MenuBarApp.swift
// The menu-bar-only UI shell: NSStatusItem, its menu, settings persistence,
// permission preflight, a global start/stop hotkey, and the small
// orchestrator that pumps frames from ScreenSource/CameraSource through
// Compositor into Recorder. This file owns AppDelegate/MenuBarApp only —
// ScreenSource.swift, CameraSource.swift, Compositor.swift, Recorder.swift,
// and Permissions.swift belong to other agents and are not modified here.
// This file talks to their public types (ScreenSource, CameraSource,
// Compositor, Recorder, Permissions) only through the frozen protocols in
// Interfaces.swift plus Permissions' own public API — see
// `HaloComponentFactory` for the one seam where concrete types are named.

import AppKit
// AVCaptureDevice (unlike VideoFrame/AudioFrame) isn't marked Sendable by
// the SDK even though it's documented thread-safe, and Interfaces.swift's
// CameraSourcing.start(device: AVCaptureDevice, ...) requires passing one
// across the RecordingEngine actor boundary. @preconcurrency here (matching
// Interfaces.swift's own @preconcurrency import of ScreenCaptureKit for the
// same reason) tells the compiler to trust AVFoundation's pre-Swift-6
// concurrency contract instead of erroring on every crossing.
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import Carbon.HIToolbox

// MARK: - Component factory (swap point for real conformers)

/// ScreenSource / CameraSource / Compositor / Recorder are owned by other
/// agents; this is the single seam where MenuBarApp reaches for the real
/// conformers. RecordingEngine itself only ever talks to the
/// `ScreenSourcing` / `CameraSourcing` / `Compositing` / `Recording`
/// protocols, so if a concrete type's initializer ever changes shape, this
/// is the only place that needs to follow.
enum HaloComponentFactory {
    static let makeScreenSource: @Sendable () -> any ScreenSourcing = { ScreenSource() }
    static let makeCameraSource: @Sendable () -> any CameraSourcing = { CameraSource() }
    static let makeCompositor: @Sendable () -> any Compositing = { Compositor() }
    static let makeRecorder: @Sendable () -> any Recording = { Recorder() }

    /// The camera list the picker shows MUST be the list CameraSource can
    /// actually open, or the UI hides working hardware. CameraSource's
    /// discovery includes Continuity Camera and Desk View, which on a Mac
    /// mini / Studio / Pro (no built-in camera at all) may be the user's only
    /// camera — and without them the circular webcam bubble, the whole point
    /// of Halo, is unreachable. One enumeration policy, defined once, here.
    static func availableCameras() -> [AVCaptureDevice] {
        CameraSource.availableDevices()
    }
}

// MARK: - Camera device box

/// AVCaptureDevice is not Sendable in this SDK, even though Apple documents
/// it as thread-safe (CameraSourcing.start(device:) already implicitly
/// relies on that same contract). Wrapping it here breaks the compiler's
/// region-based tracing back to `AppDelegate.availableCameras` (a
/// MainActor-isolated array that keeps its own reference to the same
/// device), which a bare `sending AVCaptureDevice` parameter isn't enough
/// to satisfy. The box crosses actor boundaries as an opaque Sendable
/// value; only its contents are ever touched, and only after arriving.
fileprivate struct CameraDeviceBox: @unchecked Sendable {
    let device: AVCaptureDevice
}

// MARK: - Camera frame latch

/// The single newest camera frame, shared between the camera pump (writer)
/// and the screen pump (reader).
///
/// This is a plain lock-protected box rather than actor state on purpose: the
/// screen pump reads it once per composited frame, and routing that through
/// `await engine.currentLatestCameraFrame()` would add an actor hop — and a
/// scheduling dependency on the actor's serial executor — to every single
/// frame at up to 60 fps.
///
/// It retains exactly ONE camera buffer at a time. Holding a history here
/// would drain AVCaptureVideoDataOutput's small vending pool (see the
/// CameraSource file header).
private final class CameraFrameLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VideoFrame?

    func set(_ newValue: VideoFrame) {
        lock.lock()
        frame = newValue
        lock.unlock()
    }

    func get() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

// MARK: - Recording engine

/// Owns the lifecycle of one recording: starts the four components, pumps
/// their AsyncStreams into each other, and tears everything down on stop.
actor RecordingEngine {
    enum State: Equatable { case idle, starting, recording, stopping }

    private(set) var state: State = .idle

    private var screenSource: (any ScreenSourcing)?
    private var cameraSource: (any CameraSourcing)?
    private var compositorInstance: (any Compositing)?
    private var recorderInstance: (any Recording)?

    private var screenPumpTask: Task<Void, Never>?
    private var cameraPumpTask: Task<Void, Never>?
    private var systemAudioPumpTask: Task<Void, Never>?
    private var microphonePumpTask: Task<Void, Never>?

    /// Fresh per recording so a previous recording's last frame can never leak
    /// into the next one's first composite.
    private var cameraLatch = CameraFrameLatch()

    fileprivate func start(display: SCDisplay, cameraDevice: CameraDeviceBox?, config: RecordingConfig, outputURL: URL) async throws {
        guard state == .idle else {
            throw HaloError.invalidState("A recording is already in progress.")
        }
        state = .starting

        let screen = HaloComponentFactory.makeScreenSource()
        let compositor = HaloComponentFactory.makeCompositor()
        let recorder = HaloComponentFactory.makeRecorder()
        var camera: (any CameraSourcing)?

        // Track what actually came up, so a failure half-way through can be
        // unwound. Without this, a camera that fails to open leaves an SCStream
        // capturing forever and an AVAssetWriter holding an open zero-frame
        // file on disk — and because `state` goes back to .idle, nothing else
        // ever holds a reference to either one to clean them up.
        var screenStarted = false
        var recorderStarted = false
        do {
            try compositor.prepare(config: config)
            try recorder.start(outputURL: outputURL, config: config)
            recorderStarted = true
            try await screen.start(display: display, config: config)
            screenStarted = true
            if let cameraDevice {
                let cameraInstance = HaloComponentFactory.makeCameraSource()
                try await cameraInstance.start(device: cameraDevice.device, config: config)
                camera = cameraInstance
            }
        } catch {
            if screenStarted { await screen.stop() }
            if recorderStarted {
                // Recorder.stop() throws writeFailed on a zero-frame
                // recording and deletes the file, which is exactly the
                // cleanup we want here. Swallow it: the caller gets the
                // original start failure, which is the useful one.
                try? await recorder.stop()
            }
            state = .idle
            throw error
        }

        screenSource = screen
        cameraSource = camera
        compositorInstance = compositor
        recorderInstance = recorder
        cameraLatch = CameraFrameLatch()

        if let camera {
            startCameraPump(camera)
        }
        startAudioPumps(screen: screen, recorder: recorder, config: config)
        startScreenPump(screen: screen, compositor: compositor, recorder: recorder, config: config, hasCamera: camera != nil)

        state = .recording
    }

    func stop() async throws {
        guard state == .recording else { return }
        state = .stopping

        // Order matters here, and getting it wrong loses the end of every
        // recording.
        //
        // Stop the SOURCES first: ScreenSource.stop()/CameraSource.stop()
        // finish their AsyncStreams, which is what ends the `for await`
        // pump loops naturally and lets the screen pump flush its
        // camera-offset delay queue. Cancelling the pump tasks instead
        // would abort that flush part-way through.
        await screenSource?.stop()
        await cameraSource?.stop()

        // Then DRAIN: every frame the pumps still hold has to reach the
        // recorder before finishWriting runs. Without this the pump tasks
        // would still be appending while AVAssetWriter finalizes, and those
        // frames land in a closed writer (or trip an "append after
        // finishWriting" exception). Awaiting is deadlock-free: the pumps are
        // detached, so they never need this actor to make progress.
        await screenPumpTask?.value
        await cameraPumpTask?.value
        await systemAudioPumpTask?.value
        await microphonePumpTask?.value

        do {
            try await recorderInstance?.stop()
        } catch {
            resetComponents()
            state = .idle
            throw error
        }

        resetComponents()
        state = .idle
    }

    private func resetComponents() {
        screenSource = nil
        cameraSource = nil
        compositorInstance = nil
        recorderInstance = nil
        cameraLatch = CameraFrameLatch()
        screenPumpTask = nil
        cameraPumpTask = nil
        systemAudioPumpTask = nil
        microphonePumpTask = nil
    }

    // Every pump below is `Task.detached`, never `Task { }`.
    //
    // `Task.init` is `@_inheritActorContext`, so a task created inside an
    // actor-isolated method runs its body ON THAT ACTOR'S SERIAL EXECUTOR.
    // That is fatal here: the screen pump makes two blocking synchronous calls
    // per frame (`compositor.composite`, which waits on the GPU, and
    // `recorder.appendVideo`, which holds Recorder's lock across the encoder
    // submit). On the engine's executor those would serialize the audio and
    // camera pumps behind every video frame, so audio would reach the writer
    // in bursts and get discarded whenever a burst outran
    // `isReadyForMoreMediaData` — real holes in the AAC tracks. Detached, each
    // media path gets its own execution context and the engine keeps the actor
    // for lifecycle state only.
    private func startCameraPump(_ camera: any CameraSourcing) {
        let latch = cameraLatch
        cameraPumpTask = Task.detached(priority: .userInitiated) {
            for await frame in camera.videoFrames {
                latch.set(frame)
            }
        }
    }

    private func startAudioPumps(screen: any ScreenSourcing, recorder: any Recording, config: RecordingConfig) {
        // config.captureSystemAudio / captureMicrophone gate whether
        // ScreenSource emits anything on these streams at all (see
        // Interfaces.swift), but we also only bother pumping the ones the
        // config asked for.
        if config.captureSystemAudio {
            systemAudioPumpTask = Task.detached(priority: .userInitiated) {
                for await frame in screen.systemAudioFrames {
                    try? recorder.appendSystemAudio(frame)
                }
            }
        }
        if config.captureMicrophone {
            microphonePumpTask = Task.detached(priority: .userInitiated) {
                for await frame in screen.microphoneAudioFrames {
                    try? recorder.appendMicrophoneAudio(frame)
                }
            }
        }
    }

    // TRAP #5 (camera latency, see project notes): webcam frames lag screen
    // frames by ~50-150ms because AVCaptureSession's sensor -> ISP ->
    // delivery pipeline is slower than ScreenCaptureKit's. Pairing "latest
    // screen frame" with "latest camera frame" at arrival time bakes that
    // lag visibly into the bubble. Instead we hold each screen frame in a
    // small FIFO delay queue and only release it once its capture host time
    // is at least `config.cameraOffsetMilliseconds` in the past, then
    // composite it against whatever camera frame is latest AT RELEASE TIME.
    // Compositor itself stays a pure function of the pair it's handed (per
    // its protocol doc) — this pairing decision is the caller's job, and
    // this engine is the caller.
    private func startScreenPump(screen: any ScreenSourcing, compositor: any Compositing, recorder: any Recording, config: RecordingConfig, hasCamera: Bool) {
        // The delay only buys anything when there is a camera to sync
        // against. With no bubble, holding screen frames back would add
        // pure latency and cost us the tail of the recording for nothing,
        // so the queue degenerates to pass-through.
        let offsetSeconds = hasCamera ? max(0, config.cameraOffsetMilliseconds) / 1000.0 : 0

        // BUFFER LIFETIME: every frame parked in `delayQueue` pins one of
        // ScreenCaptureKit's `queueDepth` IOSurfaces (these are the raw
        // capture buffers, not composited output). If the client holds the
        // whole ring, SCK has nowhere to render the next frame and drops it —
        // precisely during scrolling and video playback, the moments where
        // dropped frames are visible. So the cap is derived from the offset
        // that is actually being compensated for (4 frames at the 90 ms / 30
        // fps default) rather than a flat 30, keeping total retention here
        // plus ScreenSource's stream buffer inside `queueDepth`.
        let maxDelayFrames = max(1, Int((offsetSeconds * Double(max(1, config.frameRate))).rounded(.up)) + 1)
        let latch = cameraLatch

        screenPumpTask = Task.detached(priority: .userInitiated) {
            var delayQueue: [VideoFrame] = []

            // Composite + write one screen frame against whatever camera
            // frame is current. Returns false only on an unrecoverable
            // write error, which we treat as "stop pumping" rather than
            // spinning on a dead writer for the rest of the recording.
            func emit(_ frame: VideoFrame) -> Bool {
                do {
                    let composited = try compositor.composite(
                        screenFrame: frame,
                        cameraFrame: latch.get(),
                        config: config
                    )
                    try recorder.appendVideo(composited)
                    return true
                } catch HaloError.compositingFailed {
                    // Transient (e.g. the output pool is momentarily
                    // exhausted). Dropping one frame keeps the recording
                    // alive, which is the better failure mode of the two.
                    return true
                } catch {
                    // Write/state failure: the writer is dead. Stop pumping so
                    // `stop()` can cancel it and report the real cause instead
                    // of this loop spinning on a corpse for the rest of the
                    // recording.
                    return false
                }
            }

            for await screenFrame in screen.videoFrames {
                delayQueue.append(screenFrame)
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                var alive = true
                while let oldest = delayQueue.first {
                    let age = CMTimeGetSeconds(CMTimeSubtract(now, oldest.captureHostTime))
                    guard age >= offsetSeconds || delayQueue.count > maxDelayFrames else { break }
                    delayQueue.removeFirst()
                    if !emit(oldest) { alive = false; break }
                }
                if !alive {
                    delayQueue.removeAll()
                    break
                }
            }

            // The stream has finished (stop() was called). Whatever is still
            // held back by the camera-offset delay is real recorded content
            // — flush it instead of silently truncating the last
            // cameraOffsetMilliseconds of every recording.
            for frame in delayQueue {
                if !emit(frame) { break }
            }
        }
    }
}

// MARK: - Settings persistence

/// Persists the user's picks in UserDefaults. Local-only, no network, no
/// telemetry — this is the whole persistence story for Halo.
@MainActor
final class HaloSettingsStore {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let config = "halo.recordingConfig.v1"
        static let displayID = "halo.selectedDisplayID.v1"
        static let cameraUniqueID = "halo.selectedCameraUniqueID.v1"
        /// Sentinel written when the user explicitly picks "None", so that an absent
        /// key can still mean "never chosen".
        static let noCamera = "halo.camera.none"
    }

    var config: RecordingConfig {
        get {
            guard let data = defaults.data(forKey: Key.config),
                  let decoded = try? JSONDecoder().decode(RecordingConfig.self, from: data)
            else {
                return .default
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.config)
        }
    }

    /// nil means "use whatever display is first available".
    var selectedDisplayID: CGDirectDisplayID? {
        get {
            let raw = defaults.integer(forKey: Key.displayID)
            return raw == 0 ? nil : CGDirectDisplayID(raw)
        }
        set { defaults.set(Int(newValue ?? 0), forKey: Key.displayID) }
    }

    /// Stored as a device uniqueID, or `Key.noCamera` when the user has explicitly
    /// chosen "None". The key being ABSENT is a third, distinct state: the user has
    /// never chosen, and first run defaults to the built-in camera (see
    /// `AppDelegate.selectedCamera()`). Returning nil for "absent" and "None" alike
    /// is what shipped the headline feature switched off.
    var selectedCameraUniqueID: String? {
        get {
            guard let raw = defaults.string(forKey: Key.cameraUniqueID) else { return nil }
            return raw == Key.noCamera ? nil : raw
        }
        set { defaults.set(newValue ?? Key.noCamera, forKey: Key.cameraUniqueID) }
    }

    /// False until the user picks something in the Camera menu — including "None".
    var hasChosenCamera: Bool { defaults.object(forKey: Key.cameraUniqueID) != nil }
}

// MARK: - Recordings folder

enum RecordingsFolder {
    static var url: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let folder = base.appendingPathComponent("Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return url.appendingPathComponent("Halo Recording \(formatter.string(from: Date())).mp4")
    }
}

// MARK: - Global hotkey (Cmd-Shift-R)

/// Registers a system-wide hotkey via the Carbon Event Manager
/// (RegisterEventHotKey), NOT NSEvent.addGlobalMonitorForEvents. This is
/// deliberate: Carbon hotkeys need no Accessibility/Input Monitoring TCC
/// grant at all, whereas a global NSEvent monitor for key events does. If
/// registration fails for any reason we return nil and the caller degrades
/// gracefully — the menu item still starts/stops recording, it's just not
/// bound to a system-wide key combo.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_R), modifiers: UInt32 = UInt32(cmdKey | shiftKey), action: @escaping () -> Void) {
        self.action = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x48414C4F), id: 1) // 'HALO'
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))

        var handlerRef: EventHandlerRef?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventParameterNotFoundErr) }
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return status }
                if pressedID.id == 1 {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else { return nil }
        eventHandlerRef = handlerRef

        var registeredRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &registeredRef)
        guard registerStatus == noErr, let registeredRef else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            return nil
        }
        hotKeyRef = registeredRef
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

// MARK: - Bubble size presets (menu-friendly buckets over diameterFraction)

private enum BubbleSizePreset: CaseIterable {
    case small, medium, large

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var diameterFraction: CGFloat {
        switch self {
        case .small: return 0.16
        case .medium: return 0.22
        case .large: return 0.30
        }
    }

    /// Nearest preset to an arbitrary stored fraction, for drawing the menu
    /// checkmark against whatever is actually in RecordingConfig.
    static func nearest(to fraction: CGFloat) -> BubbleSizePreset {
        allCases.min(by: { abs($0.diameterFraction - fraction) < abs($1.diameterFraction - fraction) }) ?? .medium
    }
}

private extension BubbleCorner {
    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

private extension OutputResolution {
    var label: String {
        switch self {
        case .hd1080p: return "1080p"
        case .uhd4K: return "4K"
        }
    }
}

// MARK: - App delegate / status item controller

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let settings = HaloSettingsStore()
    private let engine = RecordingEngine()
    private var hotKey: GlobalHotKey?

    private var availableDisplays: [SCDisplay] = []
    private var availableCameras: [AVCaptureDevice] = []
    /// Why the display list is empty, when it is. On first launch this is
    /// almost always the Screen Recording TCC refusal, and saying so is the
    /// difference between an actionable message and "No displays found".
    private var displayDiscoveryError: (any Error)?
    private var isRecording = false
    /// Rebuilding a menu's items while it is on screen is disruptive, so a
    /// refresh that lands mid-open defers until it closes.
    private var isMenuOpen = false
    private var needsMenuRebuild = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders alongside the LSUIElement key Scripts/make_app.sh
        // writes into Info.plist: keeps this menu-bar-only even when run via
        // `swift run` (no bundled Info.plist) during development.
        NSApp.setActivationPolicy(.accessory)

        // Recorder's crash/kill safety net is opt-in by design (it changes
        // process-wide SIGINT/SIGTERM disposition, which a library has no
        // business doing behind the caller's back). Launch is the one place
        // that owns that decision, so install it here: without it, a `kill`
        // or Ctrl-C mid-recording leaves the MP4 unfinalized and the moov
        // atom unwritten. AppKit's own applicationShouldTerminate path
        // (below) covers the ordinary Quit case.
        Recorder.installTerminationHandlers()

        buildStatusItem()
        installHotKey()
        installDeviceObservers()

        // First-run / every-launch preflight: check everything up front
        // (includeCamera: true) so the user sees the full picture
        // immediately rather than discovering a missing grant mid-recording.
        Task { _ = await runPermissionsPreflight(includeCamera: true) }
        Task { await refreshDisplaysAndCameras() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        Task {
            try? await engine.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Status item / menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusItemAppearance()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    /// Displays and cameras are hot-pluggable, and this app has no window to
    /// reopen — a stale list would mean quitting and relaunching a menu-bar
    /// app to see a monitor or webcam that was plugged in a minute ago.
    private func installDeviceObservers() {
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in await self?.refreshDisplaysAndCameras() }
        }
        for name in [
            NSApplication.didChangeScreenParametersNotification,
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main, using: refresh)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        // Camera discovery is synchronous, so the camera list can always be
        // current at the moment the menu opens.
        availableCameras = HaloComponentFactory.availableCameras()
        // Displays need an async ScreenCaptureKit round-trip, so this refresh
        // lands for the *next* open; the observers above cover live hot-plug,
        // and `handleToggleRecording` re-checks immediately before recording.
        // The case this specifically fixes is first launch, where the display
        // list is empty until Screen Recording is granted.
        if availableDisplays.isEmpty || displayDiscoveryError != nil {
            Task { await refreshDisplaysAndCameras() }
        }
        menu.removeAllItems()
        populate(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        isMenuOpen = false
        if needsMenuRebuild {
            needsMenuRebuild = false
            rebuildMenu()
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        if isRecording {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Start Recording")
            button.contentTintColor = nil
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        if isMenuOpen {
            needsMenuRebuild = true
            return
        }
        menu.removeAllItems()
        populate(menu)
    }

    /// Fills `menu` in place rather than handing back a fresh NSMenu, so the
    /// status item keeps one menu object (and therefore its delegate) for the
    /// life of the app.
    private func populate(_ menu: NSMenu) {
        let config = settings.config
        let editingEnabled = !isRecording

        let startStopItem = NSMenuItem(
            title: isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        startStopItem.keyEquivalentModifierMask = [.command, .shift]
        startStopItem.target = self
        menu.addItem(startStopItem)
        menu.addItem(.separator())

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayItem.submenu = buildDisplayMenu()
        displayItem.isEnabled = editingEnabled
        menu.addItem(displayItem)

        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraItem.submenu = buildCameraMenu()
        cameraItem.isEnabled = editingEnabled
        menu.addItem(cameraItem)

        let resolutionItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        resolutionItem.submenu = buildResolutionMenu(config: config)
        resolutionItem.isEnabled = editingEnabled
        menu.addItem(resolutionItem)

        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        fpsItem.submenu = buildFrameRateMenu(config: config)
        fpsItem.isEnabled = editingEnabled
        menu.addItem(fpsItem)

        let bubbleItem = NSMenuItem(title: "Bubble", action: nil, keyEquivalent: "")
        bubbleItem.submenu = buildBubbleMenu(config: config)
        bubbleItem.isEnabled = editingEnabled
        menu.addItem(bubbleItem)

        menu.addItem(.separator())

        let systemAudioItem = NSMenuItem(title: "Include System Audio", action: #selector(toggleSystemAudio), keyEquivalent: "")
        systemAudioItem.target = self
        systemAudioItem.state = config.captureSystemAudio ? .on : .off
        systemAudioItem.isEnabled = editingEnabled
        menu.addItem(systemAudioItem)

        let microphoneItem = NSMenuItem(title: "Include Microphone", action: #selector(toggleMicrophone), keyEquivalent: "")
        microphoneItem.target = self
        microphoneItem.state = config.captureMicrophone ? .on : .off
        microphoneItem.isEnabled = editingEnabled
        menu.addItem(microphoneItem)

        menu.addItem(.separator())

        let openFolderItem = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Halo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func buildDisplayMenu() -> NSMenu {
        let menu = NSMenu()
        if availableDisplays.isEmpty {
            let title: String
            if case .permissionDenied? = displayDiscoveryError as? HaloError {
                title = "Screen Recording permission needed"
            } else if displayDiscoveryError != nil {
                title = "Displays unavailable"
            } else {
                title = "No displays found"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        let selectedID = settings.selectedDisplayID ?? availableDisplays.first?.displayID
        for display in availableDisplays {
            let item = NSMenuItem(title: displayLabel(for: display), action: #selector(selectDisplay), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: display.displayID)
            item.state = (display.displayID == selectedID) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func buildCameraMenu() -> NSMenu {
        let menu = NSMenu()
        // Reflect what will ACTUALLY be used, so the checkmark matches reality on first
        // run rather than sitting on "None" while a camera is in fact selected.
        let selectedID = settings.hasChosenCamera
            ? settings.selectedCameraUniqueID
            : selectedCamera()?.uniqueID

        let noneItem = NSMenuItem(title: "None", action: #selector(selectCamera), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = nil as String?
        noneItem.state = (selectedID == nil) ? .on : .off
        menu.addItem(noneItem)

        if !availableCameras.isEmpty {
            menu.addItem(.separator())
            for device in availableCameras {
                let item = NSMenuItem(title: device.localizedName, action: #selector(selectCamera), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uniqueID
                item.state = (device.uniqueID == selectedID) ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    private func buildResolutionMenu(config: RecordingConfig) -> NSMenu {
        let menu = NSMenu()
        for resolution in OutputResolution.allCases {
            let item = NSMenuItem(title: resolution.label, action: #selector(selectResolution), keyEquivalent: "")
            item.target = self
            item.representedObject = resolution.rawValue
            item.state = (resolution == config.outputResolution) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func buildFrameRateMenu(config: RecordingConfig) -> NSMenu {
        let menu = NSMenu()
        for fps in [30, 60] {
            let item = NSMenuItem(title: "\(fps) fps", action: #selector(selectFrameRate), keyEquivalent: "")
            item.target = self
            item.representedObject = fps
            item.state = (fps == config.frameRate) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func buildBubbleMenu(config: RecordingConfig) -> NSMenu {
        let menu = NSMenu()

        let cornerItem = NSMenuItem(title: "Corner", action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu()
        for corner in BubbleCorner.allCases {
            let item = NSMenuItem(title: corner.label, action: #selector(selectBubbleCorner), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = (corner == config.bubble.corner) ? .on : .off
            cornerMenu.addItem(item)
        }
        cornerItem.submenu = cornerMenu
        menu.addItem(cornerItem)

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        let currentPreset = BubbleSizePreset.nearest(to: config.bubble.diameterFraction)
        for preset in BubbleSizePreset.allCases {
            let item = NSMenuItem(title: preset.label, action: #selector(selectBubbleSize), keyEquivalent: "")
            item.target = self
            item.representedObject = Double(preset.diameterFraction)
            item.state = (preset == currentPreset) ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        return menu
    }

    private func displayLabel(for display: SCDisplay) -> String {
        if let screen = NSScreen.screens.first(where: { screenNumber(for: $0) == display.displayID }) {
            return screen.localizedName
        }
        return "Display \(display.displayID)"
    }

    private func screenNumber(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(truncating: number)
    }

    // MARK: Data refresh

    private func refreshDisplaysAndCameras() async {
        // ScreenSourceDiscovery, not `try? await SCShareableContent.current`:
        // it maps ScreenCaptureKit's -3801 onto an actionable "grant Screen
        // Recording and relaunch" message. Swallowing the throw into an empty
        // array turns a permission problem into the false diagnosis "Halo
        // could not find a display to record".
        do {
            let content = try await ScreenSourceDiscovery.shareableContent()
            availableDisplays = content.displays
            displayDiscoveryError = content.displays.isEmpty
                ? HaloError.deviceUnavailable("No displays are available for capture.")
                : nil
        } catch {
            availableDisplays = []
            displayDiscoveryError = error
        }

        availableCameras = HaloComponentFactory.availableCameras()

        rebuildMenu()
    }

    private func selectedDisplay() -> SCDisplay? {
        if let id = settings.selectedDisplayID, let match = availableDisplays.first(where: { $0.displayID == id }) {
            return match
        }
        return availableDisplays.first
    }

    private func selectedCamera() -> AVCaptureDevice? {
        // First run: default to the built-in camera. The circular webcam bubble is the
        // entire point of Halo, and defaulting to "None" meant a new user's first
        // recording came out as a plain screen capture and looked broken.
        guard settings.hasChosenCamera else {
            return availableCameras.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? availableCameras.first
        }
        guard let id = settings.selectedCameraUniqueID else { return nil }
        return availableCameras.first(where: { $0.uniqueID == id })
    }

    // MARK: Actions

    @objc private func toggleRecording() {
        Task { await handleToggleRecording() }
    }

    private func handleToggleRecording() async {
        if isRecording {
            do {
                try await engine.stop()
            } catch {
                presentError(error)
            }
            isRecording = false
            updateStatusItemAppearance()
            rebuildMenu()
            return
        }

        // Re-enumerate right before recording: the saved display or camera may
        // have been unplugged since the menu was last built, and on first run
        // the display list is empty until Screen Recording has been granted.
        await refreshDisplaysAndCameras()

        let camera = selectedCamera()
        let wantsCamera = camera != nil
        let report = await runPermissionsPreflight(includeCamera: wantsCamera)
        guard report.canRecord else { return }

        guard let display = selectedDisplay() else {
            presentSimpleAlert(
                title: "No display available",
                message: displayDiscoveryError.map(Self.message(for:))
                    ?? "Halo could not find a display to record."
            )
            return
        }

        // A camera that was chosen but is no longer attached would otherwise
        // produce a bubble-less recording with no explanation at all.
        if wantsCamera, camera == nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Selected camera is not available"
            alert.informativeText =
                "The camera you picked is no longer connected. Halo can record the "
                + "screen without the webcam bubble."
            alert.addButton(withTitle: "Record Without Camera")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            try await engine.start(
                display: display,
                cameraDevice: camera.map(CameraDeviceBox.init),
                config: settings.config,
                outputURL: RecordingsFolder.newRecordingURL()
            )
            isRecording = true
            updateStatusItemAppearance()
            rebuildMenu()
        } catch {
            presentError(error)
        }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        settings.selectedDisplayID = CGDirectDisplayID(truncating: number)
        rebuildMenu()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        settings.selectedCameraUniqueID = sender.representedObject as? String
        rebuildMenu()
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let resolution = OutputResolution(rawValue: raw) else { return }
        var config = settings.config
        config.outputResolution = resolution
        settings.config = config
        rebuildMenu()
    }

    @objc private func selectFrameRate(_ sender: NSMenuItem) {
        guard let fps = sender.representedObject as? Int else { return }
        var config = settings.config
        config.frameRate = fps
        settings.config = config
        rebuildMenu()
    }

    @objc private func selectBubbleCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = BubbleCorner(rawValue: raw) else { return }
        var config = settings.config
        config.bubble.corner = corner
        settings.config = config
        rebuildMenu()
    }

    @objc private func selectBubbleSize(_ sender: NSMenuItem) {
        guard let fraction = sender.representedObject as? Double else { return }
        var config = settings.config
        config.bubble.diameterFraction = CGFloat(fraction)
        settings.config = config
        rebuildMenu()
    }

    @objc private func toggleSystemAudio() {
        var config = settings.config
        config.captureSystemAudio.toggle()
        settings.config = config
        rebuildMenu()
    }

    @objc private func toggleMicrophone() {
        var config = settings.config
        config.captureMicrophone.toggle()
        settings.config = config
        rebuildMenu()
    }

    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(RecordingsFolder.url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Hotkey

    private func installHotKey() {
        hotKey = GlobalHotKey { [weak self] in
            // Carbon's callback may not statically prove it's on the main
            // thread to the compiler; hop explicitly rather than assume.
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
        // Registration failing (e.g. combo already claimed system-wide) is
        // not fatal: hotKey stays nil and the menu item remains the only
        // way to start/stop. No Accessibility/Input Monitoring permission
        // is required either way (see GlobalHotKey's doc comment).
    }

    // MARK: Permissions

    /// Delegates to `Permissions.preflight` (Permissions.swift) — the single
    /// canonical TCC entry point for the whole app — then, if anything
    /// required is still missing, shows one alert with `report.guidanceText`
    /// (which already names exactly which permission and where to grant it)
    /// and a button that opens System Settings to the first missing pane.
    @discardableResult
    private func runPermissionsPreflight(includeCamera: Bool) async -> PermissionReport {
        let report = await Permissions.preflight(config: settings.config, includeCamera: includeCamera)
        if !report.isSatisfied {
            presentPermissionAlert(report)
        }
        return report
    }

    private func presentPermissionAlert(_ report: PermissionReport) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Halo needs permission"
        alert.informativeText = report.guidanceText
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let firstMissing = report.missing.first {
            Permissions.openSettings(for: firstMissing)
        }
    }

    // MARK: Alerts

    /// HaloError's payload is already a user-facing sentence; `String(describing:)`
    /// would wrap it in enum-case noise instead.
    static func message(for error: any Error) -> String {
        switch error as? HaloError {
        case .permissionDenied(let text), .deviceUnavailable(let text),
            .captureFailed(let text), .compositingFailed(let text),
            .writeFailed(let text), .invalidState(let text):
            return text
        case .underlying(let inner):
            return inner.localizedDescription
        case nil:
            return error.localizedDescription
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Halo encountered an error"
        alert.informativeText = Self.message(for: error)
        alert.runModal()
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Entry point

public enum MenuBarApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
