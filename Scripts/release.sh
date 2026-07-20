#!/usr/bin/env bash
#
# release.sh — bump the version, build a Release grably.app, sign it and drop
# the artifact in build/.
#
# Mirrors the stereo-hysteria release flow (versioned local Release build), but
# grably bundles third-party helpers (yt-dlp, ffmpeg, ffprobe) that must be
# signed INSIDE-OUT: every nested executable first, then the .app.
#
# Signing:
#   - Default (like stereo-hysteria): keep Xcode's ad-hoc "Sign to Run Locally"
#     signature. This launches on the build machine with no further work.
#   - Set GRABLY_SIGN_IDENTITY to a "Developer ID Application" identity (name or
#     SHA-1 hash) to re-sign inside-out with Hardened Runtime + entitlements for
#     distribution (then run Scripts/notarize.sh to notarize + staple).
#
# NOTE: do NOT re-sign with an "Apple Development" cert for a macOS app — on
# macOS that requires an embedded provisioning profile, and without one the app
# fails to launch (RunningBoard "Launchd job spawn failed", POSIX 163). Apple
# Development signing is an iOS-device/TestFlight flow, not a macOS local-run one.
#
# Usage:
#   Scripts/release.sh [patch|minor|major]     (default: patch)
#
set -euo pipefail

BUMP="${1:-patch}"
case "$BUMP" in
    patch|minor|major) ;;
    *) echo "usage: $(basename "$0") [patch|minor|major]" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$ROOT/project.yml"
ENTITLEMENTS="$ROOT/grably.entitlements"
BIN_DIR="$ROOT/Resources/bin"

SIGN_IDENTITY="${GRABLY_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Will re-sign for distribution with: $SIGN_IDENTITY"
else
    echo "==> Keeping Xcode ad-hoc signature (local run; set GRABLY_SIGN_IDENTITY to re-sign)"
fi

# --- ensure bundled binaries are present -------------------------------------
if [[ ! -x "$BIN_DIR/yt-dlp" || ! -x "$BIN_DIR/ffmpeg" || ! -x "$BIN_DIR/ffprobe" ]]; then
    echo "==> Bundled binaries missing — running fetch-binaries.sh"
    bash "$ROOT/Scripts/fetch-binaries.sh"
fi

# --- read + bump versions ----------------------------------------------------
cur_ver=$(grep -E '^[[:space:]]*MARKETING_VERSION:' "$PROJECT_YML" | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/')
cur_build=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 \
    | sed -E 's/.*"([0-9]+)".*/\1/')

if [[ ! "$cur_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: MARKETING_VERSION '$cur_ver' is not X.Y.Z semver" >&2
    exit 1
fi

IFS='.' read -r major minor patch <<< "$cur_ver"
case "$BUMP" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac
new_ver="$major.$minor.$patch"
new_build=$((cur_build + 1))

echo "==> $cur_ver (build $cur_build)  ->  $new_ver (build $new_build)   [$BUMP]"
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*/\1\"$new_ver\"/" "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*).*/\1\"$new_build\"/" "$PROJECT_YML"

# --- regenerate + build (unsigned; we sign manually inside-out) --------------
cd "$ROOT"
xcodegen generate
xcodebuild -project grably.xcodeproj -scheme grably \
    -configuration Release -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO clean build

app=$(find "$HOME/Library/Developer/Xcode/DerivedData/grably-"*/Build/Products/Release \
    -maxdepth 1 -name "grably.app" 2>/dev/null | head -1)
if [[ -z "$app" ]]; then echo "error: built grably.app not found" >&2; exit 1; fi

dest="$ROOT/build/grably.app"
mkdir -p "$ROOT/build"
rm -rf "$dest"
# ditto preserves the code signature cleanly (cp -R can disturb xattrs).
ditto "$app" "$dest"

# --- re-sign inside-out ------------------------------------------------------
# Building with CODE_SIGNING_ALLOWED=NO leaves only the linker's ad-hoc
# signature on the main executable (no sealed resources), so `codesign --verify
# --strict` fails. We always re-sign the bundle inside-out: with the Developer
# ID identity when GRABLY_SIGN_IDENTITY is set (distribution), otherwise ad-hoc
# so the local artifact is properly sealed and launches cleanly.
#
# Kill any running instance first — a live process holds the executables open
# and codesign then fails with EPERM.
pkill -9 -f "grably.app/Contents/MacOS/grably" 2>/dev/null || true
sleep 1
xattr -cr "$dest"

if [[ -n "$SIGN_IDENTITY" ]]; then
    # Helpers first (inside-out). yt-dlp is a PyInstaller binary; it is signed
    # with Hardened Runtime + the app entitlements so its unsigned executable
    # memory / JIT is allowed under notarization.
    echo "==> Re-signing bundled helpers (Developer ID) ..."
    for bin in yt-dlp ffmpeg ffprobe; do
        [[ -f "$dest/Contents/Resources/bin/$bin" ]] && \
            codesign --force --timestamp --options runtime \
                --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" \
                "$dest/Contents/Resources/bin/$bin"
    done
    echo "==> Re-signing app bundle (Hardened Runtime + entitlements) ..."
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$dest"
else
    echo "==> Ad-hoc re-signing inside-out (local run) ..."
    for bin in yt-dlp ffmpeg ffprobe; do
        [[ -f "$dest/Contents/Resources/bin/$bin" ]] && \
            codesign --force --sign - "$dest/Contents/Resources/bin/$bin"
    done
    codesign --force --sign - "$dest"
fi

echo "==> Verifying signature ..."
codesign --verify --strict "$dest"
echo "    signature valid"

echo
echo "==> Built $new_ver (build $new_build)"
echo "    $dest"
echo "    Signing: ${SIGN_IDENTITY:-ad-hoc (local run)}"
echo "    Remember to commit the version bump: git add project.yml"
