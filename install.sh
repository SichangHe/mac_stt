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
# `uname -m` says x86_64 when the shell runs under Rosetta, so ask the hardware instead.
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || { echo "mac-stt needs an Apple Silicon Mac (uname -m: $(uname -m))" >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
# 🧑 "Support my version. I'm not upgrading" (macOS 14.4) ... "Also need to be accelerated"
# Core ML's stateful decoder needs macOS 15 and did not compile in 7 minutes on a hosted macOS 15.8 runner,
# so macOS 14 and 15 use MLX on the GPU; macOS 26 uses Core ML. `mac-stt` picks the same way at run time.
if [ "$major" -lt 14 ] && [ "${MAC_STT_FORCE:-}" != 1 ]; then
    echo "mac-stt needs macOS 14 or newer (found $(sw_vers -productVersion)); set MAC_STT_FORCE=1 to try anyway" >&2
    exit 1
fi
if [ "$major" -ge 26 ]; then engine=coreml; else engine=mlx; fi
echo "macOS $(sw_vers -productVersion): using the $engine engine"

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
install -m 644 "$work/mlx.metallib" "$prefix/bin/mlx.metallib"
echo "installed $prefix/bin/mac-stt"
# Build ~/Applications/mac-stt.app (the app macOS lists under Accessibility and Input Monitoring). Not fatal.
"$prefix/bin/mac-stt" app setup || echo "warning: app setup failed; run 'mac-stt app setup' later" >&2

if [ "${MAC_STT_SKIP_SETUP:-}" != 1 ]; then
    MAC_STT_BACKEND=$engine "$prefix/bin/mac-stt" setup
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
