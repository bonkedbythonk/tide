#!/bin/bash
set -e

# Tide installer. Downloads the latest release into /Applications, clears the
# quarantine flag the ad-hoc signature would trip over, and installs yt-dlp.
#
#   curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/tide/main/Scripts/install.sh | bash
#
# Run it again to update.

REPO="bonkedbythonk/tide"
INSTALL_PATH="/Applications/Tide.app"

if [ "$(uname -m)" != "arm64" ]; then
    echo "Tide is built for Apple silicon only; this Mac reports $(uname -m)."
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
    echo "Tide needs macOS 15 or later; this Mac runs $(sw_vers -productVersion)."
    exit 1
fi
# A standard account can't write /Applications; ~/Applications works the same.
if [ ! -w /Applications ]; then
    INSTALL_PATH="$HOME/Applications/Tide.app"
    mkdir -p "$HOME/Applications"
    echo "/Applications is not writable by this account; installing to $INSTALL_PATH."
fi

echo "Step 1: Finding the latest version..."
# No python3 or jq: a stock Mac has neither.
TAG="$(curl -fsSI "https://github.com/$REPO/releases/latest" | grep -i '^location:' \
    | grep -o '/releases/tag/v[^[:space:]]*' | sed 's|/releases/tag/||' | head -n 1)"
if [ -z "$TAG" ]; then
    echo "Couldn't find a release. Download it by hand from https://github.com/$REPO/releases"
    exit 1
fi
ZIP_NAME="Tide-${TAG#v}.zip"
BASE="https://github.com/$REPO/releases/download/$TAG"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Step 2: Downloading Tide ${TAG#v}..."
if [ -t 2 ]; then curl -fL --progress-bar -o "$TMP_DIR/$ZIP_NAME" "$BASE/$ZIP_NAME"
else curl -fL -sS -o "$TMP_DIR/$ZIP_NAME" "$BASE/$ZIP_NAME"; fi
# The bytes about to be unpacked and launched must be the ones the release was cut with.
curl -fL -sS -o "$TMP_DIR/SHA256SUMS" "$BASE/SHA256SUMS"
EXPECTED="$(grep " $ZIP_NAME\$" "$TMP_DIR/SHA256SUMS" | cut -d' ' -f1)"
ACTUAL="$(shasum -a 256 "$TMP_DIR/$ZIP_NAME" | cut -d' ' -f1)"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "The download doesn't match the release's checksum. Nothing was installed." >&2
    exit 1
fi

echo "Step 3: Installing..."
# A running copy has to quit before its bundle is replaced. `curl | bash` keeps
# stdin as the pipe, so ask on the terminal itself.
if pgrep -x MusicSample >/dev/null 2>&1; then
    if { : < /dev/tty; } 2>/dev/null; then
        printf 'Tide is running and has to quit to be replaced. Quit it now? [Y/n] ' > /dev/tty
        read -r answer < /dev/tty || answer=""
        case "$answer" in [Nn]*) echo "Nothing was installed."; exit 0 ;; esac
    fi
    osascript -e 'quit app id "local.music-sample"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MusicSample >/dev/null || break; sleep 0.5; done
fi
ditto -x -k "$TMP_DIR/$ZIP_NAME" "$TMP_DIR/unzipped"
rm -rf "$INSTALL_PATH"
mv "$TMP_DIR/unzipped/Tide.app" "$INSTALL_PATH"
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

echo "Step 4: Checking yt-dlp, which Tide plays through..."
if command -v brew >/dev/null 2>&1; then
    brew install yt-dlp deno >/dev/null 2>&1 || brew upgrade yt-dlp >/dev/null 2>&1 || true
    echo "yt-dlp is installed and up to date."
else
    echo "Homebrew isn't installed. Install it from https://brew.sh, then run: brew install yt-dlp deno"
fi

echo "Done. Opening Tide."
open "$INSTALL_PATH"
