#!/usr/bin/env bash
#
# notarize.sh — sign, notarize and staple grably.app (Phase N, not Phase 0).
#
# grably bundles third-party helpers (yt-dlp, ffmpeg, ffprobe). They must be
# signed INSIDE-OUT: every nested executable first, then the app bundle, then
# submitted to Apple's notary service, then stapled.
#
# Prerequisites:
#   - "Developer ID Application: <NAME> (<TEAMID>)" cert in the keychain
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials grably-notary \
#           --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#   - Hardened Runtime enabled (see grably.entitlements)
#
set -euo pipefail

APP_PATH="${1:-build/grably.app}"
ENTITLEMENTS="grably.entitlements"
SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"   # TODO: fill in
NOTARY_PROFILE="grably-notary"                                  # TODO: match store-credentials
BIN_DIR="${APP_PATH}/Contents/Resources/bin"

# --- 1. Sign nested helper executables (inside-out) ------------------------
# Each bundled binary needs its own signature + hardened runtime. The
# entitlements above allow unsigned executable memory / JIT that these tools use.
echo "==> Signing bundled helpers ..."
for bin in yt-dlp ffmpeg ffprobe; do
    if [[ -f "${BIN_DIR}/${bin}" ]]; then
        codesign --force --timestamp --options runtime \
            --entitlements "${ENTITLEMENTS}" \
            --sign "${SIGN_IDENTITY}" \
            "${BIN_DIR}/${bin}"
    fi
done

# --- 2. Sign the app bundle (outermost) ------------------------------------
echo "==> Signing app bundle ..."
codesign --force --deep --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" \
    "${APP_PATH}"

echo "==> Verifying signature ..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

# --- 3. Notarize -----------------------------------------------------------
echo "==> Zipping for notarization ..."
ZIP_PATH="build/grably.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Submitting to Apple notary service ..."
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# --- 4. Staple -------------------------------------------------------------
echo "==> Stapling ticket ..."
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "==> Notarization complete: ${APP_PATH}"
