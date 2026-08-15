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

This assembles `Halo.app` (with the correct `Info.plist` and a code signature)
at the repository root. Signing matters here: TCC (macOS's privacy permission
database) ties Screen Recording / Camera / Microphone grants to a signed bundle
identity, so an unsigned loose binary may never show up in System Settings'
permission lists.

The script signs with the first Apple Development or Developer ID certificate
in your keychain, and falls back to ad-hoc (`codesign --sign -`) if you have
none. Prefer a real certificate: an ad-hoc signature's designated requirement
is the literal hash of the binary, so **every rebuild looks to macOS like a
different app** and your Screen Recording grant silently reverts to denied —
the app then reports "access was denied" with the System Settings toggle still
switched on. After each ad-hoc rebuild, run:

```sh
tccutil reset ScreenCapture com.techautomationpartners.halo
```

Override the choice with `HALO_SIGN_IDENTITY="Developer ID Application: ..."`,
or force ad-hoc with `HALO_SIGN_IDENTITY=-`.

## Usage

Launch `Halo.app`. It lives in the menu bar (no Dock icon, no windows). Click
the icon to pick a display, a camera, an output resolution and frame rate, and
where the bubble sits. `Cmd-Shift-R` starts and stops recording from anywhere,
when the hotkey registration succeeds.

Recordings are written to `~/Movies/Halo/` as `.mp4`.

### Audio menu items

| Item | What it does |
| --- | --- |
| **Include System Audio** | Records everything your Mac plays. **On by default.** |
| **Include Microphone** | Records your narration. On by default. |
| **Microphone ▸** | Which input device to record. **System Default** or any connected input. Dimmed while *Include Microphone* is off. |
| **Audio Track ▸** | **Mixed (one track)** — the default — or **Separate (two tracks)**. |

The **Microphone** submenu lists every connected input (built-in, USB and
Bluetooth headsets, and audio interfaces that enumerate as external devices),
and re-enumerates whenever the menu opens or a device is plugged in or removed.
The choice is stored as the device's `uniqueID`. If that device is not
connected when you record, Halo falls back to the system default input and the
submenu says so — the stored choice is kept, so reconnecting the device
restores it without re-picking. This matters because ScreenCaptureKit does not
fall back on its own: handed a `uniqueID` that no longer exists it starts
happily and simply produces no microphone audio, which you would not discover
until playback.

**Audio Track** decides how the two sources are laid out in the file:

- **Mixed (one track)** — one track containing both, summed. Choose this if the
  recording is going anywhere other than an editor. Many players and upload
  pipelines (YouTube among them) read only the *first* audio track, so a
  two-track file can arrive with the narration silently missing.
- **Separate (two tracks)** — microphone and system audio as two independent
  tracks, so you can balance or mute them in post. This is the pre-1.0
  behaviour, unchanged.

Every setting is read once, when the recording starts. The menu therefore
disables all of them while recording, rather than letting you change a
checkmark that the file being written cannot reflect.

### Defaults, and what happens to an existing install

New installs record **system audio + microphone into one mixed track**.

If you have run an earlier version, its saved settings live in `UserDefaults`
and would otherwise keep the old mic-only, two-track behaviour forever —
changing a default in the source does nothing to a config that has already been
written. So the stored blob carries a schema version, and a config saved before
this change is upgraded once, in place: system audio is switched on and the
track mode is set to mixed. Everything else you had chosen (resolution, frame
rate, codec, bubble position and size, camera offset, color space) is kept —
the alternative, starting from a fresh storage key, would have reset all of it.
`captureMicrophone` is deliberately *not* forced on, because it already
defaulted to true: a stored `false` there is a real decision to record silently,
and overriding it would start recording a room somebody chose not to record.

Both settings remain yours to change afterwards; the upgrade runs once and does
not reassert itself.

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
- Records **system audio and microphone by default**, with a choice of track
  layout. **Mixed** (the default) writes one track containing both, because
  many players and upload pipelines read only the first audio track and would
  otherwise silently drop the narration. **Separate** writes two tracks, which
  is what an editor wants.
- Mixed mode **mixes, it does not merge**. Appending ScreenCaptureKit's
  `.audio` and `.microphone` buffers to a single `AVAssetWriterInput` produces
  a corrupt MP4 — they carry different formats and independent clocks. So the
  mixed track is fed by an upstream mixer that resamples both to one canonical
  format (48 kHz stereo Float32), aligns them by timestamp, sums them with
  soft-clipped headroom, and emits fresh uniform buffers. Raw capture buffers
  never reach that input. A source that is absent or gappy becomes silence of
  exactly the right duration, so the track cannot drift against the video. A
  source that is merely running *behind* is waited for rather than written off:
  the two capture pumps are independent and their buffers routinely arrive
  hundreds of milliseconds apart, and treating that skew as "this source has
  stopped" is how a narration track quietly ends up empty.
- Lets you **pick the input device** for the microphone, not just the system
  default. If the chosen device is unplugged, it falls back to the system
  default rather than recording a silent track.
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
- **The audio path in particular has never been heard.** Mixed mode's summing,
  alignment, and silence-padding are covered by an offline harness (exact frame
  counts, contiguous timestamps, correct sums, bounded work under multi-second
  arrival skew and 10-minute gaps), but that harness feeds it synthetic
  buffers. Nobody has yet played back a real recording and confirmed that mic
  and system audio are both audible, at sane relative levels, and in sync with
  the picture.
- **A source that goes silent for more than a second costs a second.** If a
  capture stream stops delivering without ending — hardware disappearing
  mid-recording, say — the mixed track waits that long before continuing
  without it, and that span is silence for that source. A stream that ends
  cleanly is handled immediately, with no gap.
- **Mixed mode sums at unity with a soft knee, and has no level control.** Loud
  system audio can sit over quiet narration; there is no ducking, no per-source
  gain, and no meters. If levels matter, record **Separate** and balance in an
  editor.
- **A recording that fails mid-way is deleted, not salvaged.** If the writer
  errors (a full disk, for example), Halo cancels it, removes the partial
  file, and reports the original cause. It does not attempt to keep the good
  prefix.
- **Not notarized.** `make_app.sh` signs with a local development certificate
  when it finds one, and ad-hoc otherwise; neither is notarized, so Gatekeeper
  will warn on a bundle copied from another machine. Build it yourself.

## Layout

```
Sources/Halo/
  Config.swift        presets, bubble geometry, encoder settings
  Interfaces.swift    the protocols the four capture/write modules share
  Permissions.swift   TCC: screen recording, camera, microphone
  ScreenSource.swift  SCStream capture, fixed cadence, PTS normalization
  CameraSource.swift  AVCaptureSession camera capture
  Compositor.swift    GPU composite: screen + circular-masked camera bubble
  AudioMixer.swift    mic + system audio -> one canonical PCM stream
  Recorder.swift      AVAssetWriter muxing, mixed or separate audio tracks
  MenuBarApp.swift    menu bar UI and the recording engine that pumps frames
  main.swift          entry point
Scripts/make_app.sh   assembles Halo.app + Info.plist + codesign
```

No third-party dependencies — system frameworks only.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Tech Automation Partners.
