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
BUNDLE_ID="com.amanmeghrajani.halo"
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

echo "==> Ad-hoc code signing ${APP_NAME}.app"
codesign --force --deep --sign - "${APP_DIR}"

echo "==> Done: ${APP_DIR}"
echo "    Move it to /Applications, then launch it once to trigger the"
echo "    Screen Recording / Camera / Microphone permission prompts."
