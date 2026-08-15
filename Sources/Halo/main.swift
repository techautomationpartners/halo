// main.swift
// Halo's process entry point. All real behavior lives in MenuBarApp.swift
// (the NSStatusItem UI, settings, permissions preflight, hotkey, and the
// RecordingEngine that wires ScreenSource/CameraSource/Compositor/Recorder
// together) — this file just parses a couple of trivial flags and launches it.
//
// `MainActor.assumeIsolated` is safe here (rather than requiring an `async`
// entry point) because top-level code in a `main.swift` file runs on the
// process's initial thread, which is the main thread — the same thread
// AppKit requires `NSApplication` to be driven from.

import AppKit

// --help / --version deliberately run BEFORE any AppKit, ScreenCaptureKit,
// or AVFoundation object is touched, so they never trip a TCC permission
// prompt and never need a window server connection. That makes them usable
// for smoke-testing a freshly built bundle (and from CI) without granting
// Screen Recording first.
let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--version") || arguments.contains("-v") {
    print("Halo \(HaloVersion.string)")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Halo \(HaloVersion.string) — local macOS screen recorder with a circular webcam bubble.

    Usage: Halo [options]

    Halo is a menu-bar app. Launched with no options it installs its status
    item and waits; there is no command-line recording mode.

      -h, --help       Show this help and exit.
      -v, --version    Show the version and exit.

    Recordings are written to ~/Movies/Halo. Start/stop with the menu bar
    item or with Cmd-Shift-R.

    Halo runs entirely on this Mac: no network access, no accounts, and no
    telemetry of any kind.
    """)
    exit(0)
}

MainActor.assumeIsolated {
    MenuBarApp.run()
}
