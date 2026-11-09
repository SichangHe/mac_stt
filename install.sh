#!/bin/sh
# Installs mac-stt from the latest public release, then downloads and warms the models.
#   curl -fsSL https://raw.githubusercontent.com/SichangHe/mac_stt/main/install.sh | sh
# Environment: MAC_STT_VERSION (tag, default latest), MAC_STT_PREFIX (default ~/.local),
#              MAC_STT_SKIP_SETUP=1 to skip the model download, MAC_STT_FORCE=1 to skip the macOS check.
set -eu

repo=SichangHe/mac_stt
prefix=${MAC_STT_PREFIX:-$HOME/.local}
asset=mac-stt-macos-arm64.tar.gz

[ "$(uname -s)" = Darwin ] || { echo "mac-stt runs on macOS only" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "mac-stt needs an Apple Silicon Mac" >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
# On a hosted macOS 15.8 runner the Core ML decoder compile did not finish in 7 minutes; macOS 26 loads in seconds.
if [ "$major" -lt 26 ] && [ "${MAC_STT_FORCE:-}" != 1 ]; then
    echo "mac-stt needs macOS 26 or newer (found $(sw_vers -productVersion)); set MAC_STT_FORCE=1 to try anyway" >&2
    exit 1
fi

if [ -n "${MAC_STT_VERSION:-}" ]; then
    base=https://github.com/$repo/releases/download/$MAC_STT_VERSION
else
    base=https://github.com/$repo/releases/latest/download
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mac-stt-install.XXXXXX")
trap 'rm -rf "$work"' EXIT
echo "downloading $base/$asset"
curl -fSL --retry 3 -o "$work/$asset" "$base/$asset"
curl -fsSL --retry 3 -o "$work/$asset.sha256" "$base/$asset.sha256"
(cd "$work" && shasum -a 256 -c "$asset.sha256")
tar -xzf "$work/$asset" -C "$work"

mkdir -p "$prefix/bin"
install -m 755 "$work/mac-stt" "$prefix/bin/mac-stt"
echo "installed $prefix/bin/mac-stt"

if [ "${MAC_STT_SKIP_SETUP:-}" != 1 ]; then
    "$prefix/bin/mac-stt" setup
fi

case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "add to your shell profile: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
cat <<MSG

done. Bind this command to a key with any hotkey tool (Shortcuts, skhd, Raycast, Hammerspoon,
BetterTouchTool):

    $prefix/bin/mac-stt toggle

First press starts recording; the second stops, transcribes, and copies the text to the clipboard.
The first press launches the background server. macOS asks for microphone access the first time.
Add --no-clipboard or --diarize by starting the server yourself: mac-stt serve --diarize
MSG
