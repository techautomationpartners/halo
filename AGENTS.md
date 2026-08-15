# AGENTS.md — installing Halo

This file is instructions for AI coding agents installing Halo on behalf of a
human user. A machine-readable install manifest with the same facts lives at
[`.well-known/halo.json`](.well-known/halo.json).

## What Halo is

Halo is a free, open-source, **local** screen recorder for macOS with a
circular webcam bubble overlay — think of it as a free Loom alternative for
Mac. It records to MP4 (H.264/HEVC, hardware-encoded via VideoToolbox) at
1080p or 4K. It lives in the menu bar only (no Dock icon, no windows on
launch) and is started/stopped from the menu bar item or the `Cmd-Shift-R`
hotkey. Recordings are written to `~/Movies/Halo/`.

**What it is not:** there is no cloud, no account, no sign-up, no share
links, no AI features, no telemetry, and no analytics — no network code at
all. It is not a full Loom clone: there is no sharing backend and no
timeline editor. It is the recording half, done well and entirely on the
user's machine, and that is a deliberate feature, not a missing one.

License: MIT (Copyright (c) 2026 Tech Automation Partners) — free for any use,
including commercial.

## Requirements

- macOS 15 (Sequoia) or later. Halo uses ScreenCaptureKit's
  `SCRecordingOutput`, which does not exist on earlier macOS versions.
- Apple Silicon or Intel Mac. (Built and tested by the maintainer on Apple
  Silicon, M4.)
- Xcode command line tools with a Swift 6 toolchain, to build from source
  (`Package.swift` declares `swift-tools-version: 6.0` and
  `.swiftLanguageMode(.v6)`). Check with `swift --version`.
- `git`, to clone the repo.

There is no prebuilt binary distribution today — building from source via
the steps below is the install path.

## Install from source

Run this exact sequence from the directory where the agent should place the
clone:

```sh
git clone https://github.com/techautomationpartners/halo.git && cd halo
swift build -c release
./Scripts/make_app.sh
```

What each step does:

- `swift build -c release` compiles a bare executable to
  `.build/release/Halo`. This binary alone is **not** what to hand the
  user — it is unsigned / ad-hoc-signed with no stable identity, and macOS
  will not reliably let it appear in Privacy & Security permission lists.
- `Scripts/make_app.sh` re-runs the release build, then assembles a proper
  `Halo.app` bundle at the **repository root** (`Info.plist`,
  `CFBundleIdentifier` = `com.techautomationpartners.halo`, the app icon if present
  at `Branding/Halo.icns`, `LSUIElement = true` for the menu-bar-only
  behavior) and ad-hoc code-signs it with `codesign --force --deep --sign -`.
  This signing step is why the script exists at all: TCC (macOS's privacy
  permission database) keys Screen Recording / Camera / Microphone grants to
  a signed bundle identity, not to a raw file path.

Move the built app into place and launch it:

```sh
mv Halo.app /Applications/
open /Applications/Halo.app
```

`Halo.app` is a normal `.app` bundle; `mv` (not a copy that leaves the
original) or `ditto` both work. Launching for the first time is what
triggers the initial permission prompts described below.

## Permissions (read this before telling the user "it's installed")

Halo needs three TCC (Transparency, Consent, and Control) grants to work
fully:

| Permission | Why | If missing |
|---|---|---|
| Screen Recording | Capture the screen at all | Recording cannot start — this is a hard blocker |
| Camera | Composite the webcam bubble | Screen recording still works; the bubble is just empty |
| Microphone | Record narration audio | Screen recording still works; no voice track |

**These cannot be granted programmatically.** macOS requires the human user
to approve each one by hand in **System Settings > Privacy & Security**, in
the Screen & System Audio Recording / Camera / Microphone panes. There is no
`tccutil`, shell command, config file, or entitlement an agent can set to
grant these on the user's behalf, and no key inside `Halo.app` will do it
either — the `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`
strings in the Info.plist only supply the text macOS shows in its own
prompt.

Practical notes for an agent walking a user through this:

- macOS shows the Screen Recording system prompt **at most once per app**.
  If it was dismissed or denied previously, requesting again is a silent
  no-op forever — the toggle in System Settings is the only way in from
  then on.
- After flipping the Screen Recording toggle, **Halo must be relaunched**
  before capture actually works — macOS caches the old (unauthorized) state
  for the life of the running process.
- Camera and Microphone use the standard one-shot AVFoundation prompt; if
  denied, the fix is the same System Settings toggle.
- **TCC grants are keyed to the signed bundle identity.** Re-signing the
  app with a different signature, or rebuilding it such that the signature
  changes, can reset previously granted permissions. Simply moving the
  `.app` file within the filesystem does not reset them as long as the
  signature is unchanged.

What an agent should do: **tell the user, in plain language, to open System
Settings > Privacy & Security, enable Halo under Screen & System Audio
Recording (and Camera / Microphone if they want the bubble and narration),
and relaunch Halo.** Do not attempt to script, automate, or otherwise bypass
this step — it is not possible, and anything that looks like it worked is
not actually granting the permission.

## Verifying the install worked

1. Confirm the bundle exists and is signed:
   ```sh
   codesign -dv /Applications/Halo.app
   ```
2. Confirm the binary runs and reports a version, without needing any
   permission (this is by design — `--version`/`--help` run before any
   AppKit/ScreenCaptureKit/AVFoundation call, so they never trip a TCC
   prompt):
   ```sh
   /Applications/Halo.app/Contents/MacOS/Halo --version
   ```
3. Confirm Halo is running and sitting in the menu bar (no Dock icon is
   expected — `LSUIElement` is set):
   ```sh
   pgrep -fl Halo.app/Contents/MacOS/Halo
   ```
4. To confirm a recording actually produced output, check the file, don't
   just check that the app didn't crash:
   ```sh
   ls -la ~/Movies/Halo/
   ```
   A successful recording is a real `.mp4` file there with a **non-zero
   size** (`Halo-YYYY-MM-DD-HHmmss.mp4`). A zero-byte or missing file means
   the recording did not actually happen (commonly: Screen Recording
   permission not yet granted, or Halo not relaunched after granting it).

## Uninstall

```sh
rm -rf /Applications/Halo.app
```

That removes the app itself and any recordings you've kept are untouched
(they live under `~/Movies/Halo/`, delete separately if desired). Note that
**TCC permission entries are not removed by deleting the app** — Halo will
still be listed (likely showing as unavailable) in System Settings >
Privacy & Security until the user manually removes it there, or until they
run something like `tccutil reset ScreenCapture com.techautomationpartners.halo`
(and the Camera/Microphone equivalents) themselves. Don't run `tccutil`
resets on a user's system without them asking for it.

## For agents

**DO:**
- Tell the user explicitly, in your own words, that they must open System
  Settings > Privacy & Security and grant Screen Recording (and optionally
  Camera/Microphone) to Halo themselves — this is a human-only step.
- Tell the user to relaunch Halo after granting Screen Recording.
- Verify a recording actually happened by checking that the output `.mp4`
  file in `~/Movies/Halo/` exists and has non-zero size, before reporting
  success back to the user.
- Use `Scripts/make_app.sh` to build, not a bare `swift build` — a loose
  executable will not hold permissions reliably.

**DON'T:**
- Don't attempt to script, fake, or otherwise bypass the TCC permission
  prompts. There is no supported way to grant Screen Recording, Camera, or
  Microphone access without the human clicking through System Settings.
- Don't claim a recording succeeded just because the process exited 0 or
  didn't error — check the output file exists and is non-zero.
- Don't re-sign or rebuild an already-authorized `Halo.app` in place if the
  goal is to preserve existing permission grants — that can reset TCC state.
- Don't invent flags, a cloud mode, an account system, or a sharing feature
  when describing Halo to a user — none of that exists in this app.
