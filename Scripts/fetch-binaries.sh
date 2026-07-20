#!/usr/bin/env bash
#
# fetch-binaries.sh — download the helper executables grably ships with.
#
#   - yt-dlp        : official universal macOS build (yt-dlp_macos)
#   - ffmpeg/ffprobe: builds from https://evermeet.cx/ffmpeg
#
# Binaries land in Resources/bin and are NOT committed to git
# (see .gitignore). Run via `make fetch-binaries`.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_DIR="${ROOT_DIR}/Resources/bin"

mkdir -p "${BIN_DIR}"

# --- yt-dlp ----------------------------------------------------------------
# yt-dlp_macos is a self-contained universal (arm64 + x86_64) executable.
# Pinned to the latest release channel; yt-dlp self-updates at runtime.
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

echo "==> Downloading yt-dlp ..."
curl -L --fail --progress-bar -o "${BIN_DIR}/yt-dlp" "${YTDLP_URL}"
chmod +x "${BIN_DIR}/yt-dlp"

# Stamp the bundled yt-dlp version. BinaryProvisioner reads this `.yt-dlp.version`
# side-file to decide whether the support copy (which the app may have self-updated
# to a newer build) should be overwritten with the bundled one: it only does so when
# the bundled version is strictly newer. Without this stamp the provisioner falls
# back to content hashing, which would revert a user's self-update on every launch.
echo "==> Stamping yt-dlp version ..."
"${BIN_DIR}/yt-dlp" --version | head -n1 | tr -d '[:space:]' > "${BIN_DIR}/.yt-dlp.version"
echo "    yt-dlp $(cat "${BIN_DIR}/.yt-dlp.version")"

# --- ffmpeg / ffprobe ------------------------------------------------------
# evermeet.cx publishes signed macOS builds. These are arm64-only or x86_64
# depending on the endpoint.
#
# TODO(universal): evermeet ships single-arch binaries. For a truly universal
# app, download both arm64 and x86_64 builds and merge them with:
#     lipo -create ffmpeg_arm64 ffmpeg_x86_64 -output ffmpeg
# For now we pull the default (host-arch) zip archives.
FFMPEG_ZIP_URL="https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
FFPROBE_ZIP_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Downloading ffmpeg ..."
curl -L --fail --progress-bar -o "${TMP_DIR}/ffmpeg.zip" "${FFMPEG_ZIP_URL}"
unzip -o -q "${TMP_DIR}/ffmpeg.zip" -d "${BIN_DIR}"
chmod +x "${BIN_DIR}/ffmpeg"

echo "==> Downloading ffprobe ..."
curl -L --fail --progress-bar -o "${TMP_DIR}/ffprobe.zip" "${FFPROBE_ZIP_URL}"
unzip -o -q "${TMP_DIR}/ffprobe.zip" -d "${BIN_DIR}"
chmod +x "${BIN_DIR}/ffprobe"

echo "==> Done. Binaries in ${BIN_DIR}:"
ls -lh "${BIN_DIR}"
