#!/bin/bash
# make_app.sh — assemble Halo.app from the release build and ad-hoc code sign it.
#
# WHY THIS SCRIPT EXISTS (read before deleting it):
# macOS's TCC (privacy permission) database keys Screen Recording, Camera,
# and Microphone grants to a *signed bundle identity*, not to a raw file
# path. A bare `.build/release/Halo` executable run directly from the
# terminal is unsigned (or signed as "swift-build" ad hoc with no stable
# identifier) and can silently fail to appear in System Settings ->
# Privacy & Security -> Screen Recording, or appear and then stop working
# after a rebuild because its signature/identity changed. Packaging into a
# proper .app with a fixed CFBundleIdentifier and signing it (even ad-hoc,
# with `codesign --sign -`) gives TCC a stable identity to remember.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Halo"
BUNDLE_ID="com.techautomationpartners.halo"
APP_DIR="${ROOT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} (release)"
(cd "${ROOT_DIR}" && swift build -c release)

BIN_PATH="${ROOT_DIR}/.build/release/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "error: expected binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

# The icon is optional: the app is LSUIElement so it shows no Dock icon, but
# Finder, the Get Info panel and permission prompts still use it. Only emit
# the CFBundleIconFile key if the .icns actually exists, since a key pointing
# at a missing resource makes the bundle look broken to Launch Services.
ICON_SRC="${ROOT_DIR}/Branding/${APP_NAME}.icns"
ICON_KEY=""
if [[ -f "${ICON_SRC}" ]]; then
    cp "${ICON_SRC}" "${RESOURCES_DIR}/${APP_NAME}.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>${APP_NAME}</string>"
    echo "    bundled icon: Branding/${APP_NAME}.icns"
fi

# Keep in sync with HaloVersion.string in Sources/Halo/Config.swift.
VERSION="1.0.0"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    ${ICON_KEY}
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <!-- Menu-bar-only app: no Dock icon, no app switcher entry, no windows on launch. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Required strings shown in the macOS permission prompts. Without these
         the app crashes on first camera/mic access attempt instead of prompting. -->
    <key>NSCameraUsageDescription</key>
    <string>Halo uses your camera to composite a webcam bubble into your screen recordings.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Halo uses your microphone to record narration audio into your screen recordings.</string>
</dict>
</plist>
PLIST

# Signing identity decides whether your permissions survive a rebuild.
#
# Ad-hoc (`--sign -`) produces a designated requirement of `cdhash H"..."` — the
# literal hash of the binary. TCC stores the grant against that, so EVERY rebuild
# looks like a brand-new app and Screen Recording silently reverts to denied. The
# app then reports "access was denied" even though the System Settings toggle is on.
#
# A real identity produces an identity-based requirement instead:
#   identifier "com.techautomationpartners.halo" and anchor apple generic and
#   certificate leaf[subject.CN] = "Apple Development: ..."
# which is stable across rebuilds, so the grant sticks.
#
# Override with:  HALO_SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/make_app.sh
# Force ad-hoc with: HALO_SIGN_IDENTITY=-
if [ -z "${HALO_SIGN_IDENTITY:-}" ]; then
  # `|| true` is load-bearing: under `set -euo pipefail`, grep exiting 1 because
  # no Developer ID exists would abort the whole script BEFORE the signing step,
  # leaving a bundle carrying only Swift's linker-signed placeholder signature —
  # which macOS will not accept into the privacy lists at all.
  HALO_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Developer ID Application' \
    | grep -v CSSMERR \
    | head -1 \
    | sed -E 's/.*"(.*)".*/\1/' || true)
fi

# HARDENED RUNTIME IS ONLY SAFE WITH A DEVELOPER ID.
# An "Apple Development" certificate is a *development* identity: entitlements
# signed with it must be authorized by an embedded provisioning profile. Signing
# with hardened runtime + entitlements and NO profile yields a bundle macOS
# treats as invalid for privacy purposes — Halo then never appears in
# System Settings > Screen & System Audio Recording, the prompt degrades to the
# already-denied "Open System Settings / Deny" variant, and even adding the app
# by hand with the "+" button silently fails. Observed directly on macOS 26.5.1.
# Ad-hoc, or a Developer ID, both work.
if [ -n "${HALO_SIGN_IDENTITY}" ] && [[ "${HALO_SIGN_IDENTITY}" == "Developer ID Application"* ]]; then
  echo "==> Code signing ${APP_NAME}.app as: ${HALO_SIGN_IDENTITY}"
  ENTITLEMENTS="${ROOT_DIR}/Scripts/Halo.entitlements"
  codesign --force --deep --options runtime --entitlements "${ENTITLEMENTS}" \
    --sign "${HALO_SIGN_IDENTITY}" "${APP_DIR}"
elif [ -n "${HALO_SIGN_IDENTITY}" ] && [ "${HALO_SIGN_IDENTITY}" != "-" ]; then
  # A development identity: sign WITHOUT hardened runtime and WITHOUT
  # entitlements, per the note above.
  echo "==> Code signing ${APP_NAME}.app as: ${HALO_SIGN_IDENTITY} (no hardened runtime)"
  codesign --force --deep --sign "${HALO_SIGN_IDENTITY}" "${APP_DIR}"
else
  echo "==> Ad-hoc code signing ${APP_NAME}.app"
  echo "    WARNING: ad-hoc signatures change on every rebuild, so macOS will forget"
  echo "    your Screen Recording / Camera grants each time. If you have an Apple"
  echo "    Development or Developer ID certificate, this script picks it up"
  echo "    automatically. Otherwise, after each rebuild run:"
  echo "      tccutil reset ScreenCapture com.techautomationpartners.halo"
  codesign --force --deep --sign - "${APP_DIR}"
fi

echo "==> Done: ${APP_DIR}"
echo "    Move it to /Applications, then launch it once to trigger the"
echo "    Screen Recording / Camera / Microphone permission prompts."
