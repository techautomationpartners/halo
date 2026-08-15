#!/bin/bash
# make_dmg.sh — package Halo.app into a drag-to-install DMG for release.
#
# Produces dist/Halo-<version>.dmg containing Halo.app next to an /Applications
# symlink, so the window shows the familiar "drag the app onto the folder" layout.
#
# GATEKEEPER, READ THIS BEFORE PUBLISHING:
# A DMG is only genuinely one-click if the app inside is signed with a
# "Developer ID Application" certificate AND notarized by Apple. Without that,
# macOS quarantines the download and refuses to open it — the message users see
# is "Halo is damaged and can't be opened", which reads as malware even though
# nothing is wrong. There is no way to suppress that from inside the DMG.
#
# The two honest options:
#   1. Ship unnotarized and tell users to right-click -> Open the first time
#      (or run: xattr -dr com.apple.quarantine /Applications/Halo.app)
#   2. Join the Apple Developer Program ($99/yr), get a Developer ID cert, and
#      notarize. Then it really is download-drag-run.
#
# Homebrew sidesteps this entirely: `brew install --cask` strips the quarantine
# attribute on install, so an unnotarized app runs without complaint. That is
# why the cask is the recommended path for anyone who has Homebrew.
#
# Signing for DISTRIBUTION differs from signing for local development:
# an "Apple Development" certificate authorizes the app on your own registered
# devices only, so it is the wrong choice for a public download. This script
# therefore defaults to an ad-hoc signature, which imposes no device
# restriction, unless you explicitly pass a Developer ID.
#
# Usage:
#   ./Scripts/make_dmg.sh                          # ad-hoc signed (default)
#   HALO_DIST_IDENTITY="Developer ID Application: You (TEAMID)" ./Scripts/make_dmg.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Halo"
APP_DIR="${ROOT_DIR}/${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${APP_DIR}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Building ${APP_NAME}.app"
"${ROOT_DIR}/Scripts/make_app.sh" >/dev/null

if [[ ! -d "${APP_DIR}" ]]; then
  echo "error: ${APP_DIR} not found" >&2
  exit 1
fi

# Re-sign for distribution. See the header: an Apple Development signature is
# device-restricted and must not ship.
DIST_IDENTITY="${HALO_DIST_IDENTITY:--}"
ENTITLEMENTS="${ROOT_DIR}/Scripts/Halo.entitlements"
echo "==> Signing for distribution as: ${DIST_IDENTITY}"
if [[ "${DIST_IDENTITY}" == "-" ]]; then
  # Ad-hoc: no hardened runtime, because a hardened runtime without a
  # provisioning profile blocks camera and microphone access outright.
  codesign --force --deep --sign - "${APP_DIR}"
  echo "    NOTE: ad-hoc. Users will need Homebrew (which strips quarantine)"
  echo "    or a one-time right-click -> Open."
else
  codesign --force --deep --options runtime --entitlements "${ENTITLEMENTS}" \
    --sign "${DIST_IDENTITY}" "${APP_DIR}"
  echo "    Signed with a real identity. Notarize before publishing:"
  echo "      xcrun notarytool submit '${DMG_PATH}' --keychain-profile <profile> --wait"
  echo "      xcrun stapler staple '${DMG_PATH}'"
fi

echo "==> Staging DMG contents"
mkdir -p "${DIST_DIR}"
cp -R "${APP_DIR}" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

# A short README inside the DMG, because the quarantine message is alarming and
# the fix is not discoverable.
cat > "${STAGE_DIR}/READ ME FIRST.txt" <<'TXT'
Installing Halo
===============

1. Drag Halo onto the Applications folder in this window.
2. Open your Applications folder.
3. RIGHT-CLICK (or Control-click) Halo and choose "Open".
   Then click "Open" again in the dialog that appears.

Step 3 matters. If you double-click Halo the normal way the first time,
macOS may say Halo "is damaged and can't be opened". It is not damaged.
That message appears for any app not notarized by Apple, which costs the
developer $99/year. Right-click -> Open tells macOS you trust it, and you
only ever have to do it once.

After it opens, Halo lives in your menu bar at the top of the screen -
look for the ring icon. It has no Dock icon and no window.

The first time you record, macOS will ask for permission to record your
screen. Approve it, then QUIT HALO AND OPEN IT AGAIN - macOS does not
apply that permission until the app restarts.

Recordings are saved to your Movies folder, inside a folder called Halo.
Nothing is ever uploaded anywhere.
TXT

rm -f "${DMG_PATH}"
echo "==> Creating ${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov -format UDZO \
  "${DMG_PATH}" >/dev/null

SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"

echo "==> Done: ${DMG_PATH} (${SIZE})"
echo "    sha256: ${SHA}"
echo
echo "    For the Homebrew cask:"
echo "      sha256 \"${SHA}\""
