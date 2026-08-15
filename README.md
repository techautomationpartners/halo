# Halo

A small, local-only macOS screen recorder with a circular webcam bubble
overlay. Outputs MP4 at 1080p or 4K.

Halo runs entirely on your Mac. There is no cloud, no accounts, no AI
features, no telemetry, and no analytics — and no network code at all. The
only thing it writes outside the recording file is your menu selections, in
`UserDefaults`.

## Status

Halo builds cleanly and the app bundle launches, but **no recording has been
verified end to end yet** — that needs a human to grant the Screen Recording,
Camera, and Microphone permissions that macOS will not grant to an automated
process. Treat everything below as "implemented and compiled", not "measured".
See [Known limitations](#known-limitations).

## Requirements

- macOS 15 (Sequoia) or later. The floor comes from
  `SCStreamConfiguration.captureMicrophone`, which Halo uses for the mic track.
- Apple Silicon or Intel. Built and tested on Apple Silicon (M4).
- Xcode 26 / Swift 6 toolchain to build from source.
- Screen Recording permission, plus Camera and Microphone if you enable those.
  All three are requested by macOS at first use and managed entirely by macOS.

## Building

```sh
swift build -c release
```

This produces a bare executable at `.build/release/Halo`. To get a proper
menu-bar `.app` bundle that macOS will let you grant Screen Recording
permission to, run:

```sh
Scripts/make_app.sh
```

This assembles `Halo.app` (with the correct `Info.plist` and an ad-hoc code
signature) at the repository root. Signing matters here: TCC (macOS's privacy
permission database) ties Screen Recording / Camera / Microphone grants to a
signed bundle identity, so an unsigned loose binary may never show up in
System Settings' permission lists.

## Usage

Launch `Halo.app`. It lives in the menu bar (no Dock icon, no windows). Click
the icon to pick a display, a camera, an output resolution and frame rate, and
where the bubble sits. `Cmd-Shift-R` starts and stops recording from anywhere,
when the hotkey registration succeeds.

Recordings are written to `~/Movies/Halo/` as `.mp4`.

## What it does

- Captures one display through ScreenCaptureKit at the display's true backing
  resolution (points are multiplied by the content filter's `pointPixelScale`,
  so a scaled 1710x1107pt display is captured at 3420x2214px, not 1710x1107).
- Emits video at a fixed cadence. ScreenCaptureKit only delivers a frame when
  something on screen changes, so Halo re-submits the last frame on a timer;
  the file's duration tracks the wall clock even if you record a static slide.
- Composites the camera into a circular bubble on the GPU, via Core Image on a
  persistent Metal-backed `CIContext` (one context and one buffer pool per
  recording, never per frame).
- Never stretches. The display's aspect ratio (1.545:1 on the development Mac)
  is reconciled with the 16:9 output by letterboxing (the default) or by a
  centered crop. The bubble is positioned against the visible picture, so it
  does not sit on a letterbox bar.
- Writes system audio and microphone as **two separate tracks**. Muxing
  ScreenCaptureKit's `.audio` and `.microphone` buffers into a single
  `AVAssetWriterInput` produces a corrupt MP4; they are never merged here.
- Tags color explicitly on the capture config, the video track, and every
  pixel buffer, so output is not washed out or oversaturated on a P3 display.
- Delays screen frames by a configurable offset (90 ms by default) before
  pairing them with a camera frame, to compensate for the webcam pipeline's
  latency.
- Flushes a movie fragment every 2 seconds and finalizes on SIGINT/SIGTERM and
  Quit, so an abrupt exit costs at most the last fragment rather than the whole
  file.

## Known limitations

- **Nothing has been verified at runtime.** The package compiles under Swift 6
  strict concurrency and `Halo.app` launches, but no `.mp4` has been produced
  and inspected. Frame timing, A/V sync, the camera-offset default, color
  fidelity, and 4K60 throughput are all reasoned-about, not measured.
- **The camera offset is a guess.** `cameraOffsetMilliseconds` defaults to 90.
  That is a plausible value for AVCaptureSession on Apple Silicon, not a
  measurement on your hardware. There is no UI for it yet — it is persisted in
  the config, so it can only be changed by editing the stored defaults.
- **One display per recording.** No multi-display, window, or region capture.
- **No preview.** You cannot see the bubble's placement before you record.
- **Only 1080p and 4K.** No 1440p, no custom sizes.
- **Aspect policy is not exposed in the menu.** `letterbox` vs `crop` lives in
  `RecordingConfig` only; the menu always uses the persisted value
  (`letterbox` by default).
- **No editing of any kind.** No trimming, no timeline, no annotation. Halo
  writes a file and stops.
- **System audio is off by default** and is a separate track from the
  microphone. Some players show only the first audio track; use an editor, or
  remux, if you need them mixed.
- **A recording that fails mid-way is deleted, not salvaged.** If the writer
  errors (a full disk, for example), Halo cancels it, removes the partial
  file, and reports the original cause. It does not attempt to keep the good
  prefix.
- **Ad-hoc signed, not notarized.** Gatekeeper will warn on a bundle copied
  from another machine. Build it yourself.

## Layout

```
Sources/Halo/
  Config.swift        presets, bubble geometry, encoder settings
  Interfaces.swift    the protocols the four capture/write modules share
  Permissions.swift   TCC: screen recording, camera, microphone
  ScreenSource.swift  SCStream capture, fixed cadence, PTS normalization
  CameraSource.swift  AVCaptureSession camera capture
  Compositor.swift    GPU composite: screen + circular-masked camera bubble
  Recorder.swift      AVAssetWriter muxing, two audio tracks
  MenuBarApp.swift    menu bar UI and the recording engine that pumps frames
  main.swift          entry point
Scripts/make_app.sh   assembles Halo.app + Info.plist + ad-hoc codesign
```

No third-party dependencies — system frameworks only.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Aman Meghrajani.
</content>
</invoke>
