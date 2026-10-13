#!/bin/bash
# Wallpy installer.
#   curl -fsSL https://raw.githubusercontent.com/drarekx/Wallpy/main/install.sh | bash
# Options (pass after `bash -s --`):
#   --no-deps   don't install yt-dlp / ffmpeg with Homebrew
set -euo pipefail

REPO="drarekx/Wallpy"
URL="https://github.com/$REPO/releases/latest/download/Wallpy.zip"
INSTALL_DEPS=1
for arg in "$@"; do
    [[ "$arg" == "--no-deps" ]] && INSTALL_DEPS=0
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Wallpy solo funciona en macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Wallpy necesita macOS 14 (Sonoma) o posterior. Tienes $(sw_vers -productVersion)."

bold "Descargando Wallpy…"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar "$URL" -o "$tmp/Wallpy.zip" || fail "No se pudo descargar $URL"
ditto -x -k "$tmp/Wallpy.zip" "$tmp"
[[ -d "$tmp/Wallpy.app" ]] || fail "El archivo descargado no contiene Wallpy.app"

# Close a running copy so it can be replaced.
if pgrep -x Wallpy >/dev/null; then
    bold "Cerrando Wallpy…"
    osascript -e 'quit app "Wallpy"' 2>/dev/null || true
    sleep 1
    pkill -x Wallpy 2>/dev/null || true
fi

dest="/Applications"
if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi
rm -rf "$dest/Wallpy.app"
mv "$tmp/Wallpy.app" "$dest/"
# The app is not notarized; skip the Gatekeeper prompt for this copy.
xattr -dr com.apple.quarantine "$dest/Wallpy.app" 2>/dev/null || true
bold "Instalado en $dest/Wallpy.app"

if (( INSTALL_DEPS )); then
    brew=""
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew "$(command -v brew 2>/dev/null || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] && { brew="$candidate"; break; }
    done
    if [[ -n "$brew" ]]; then
        missing=()
        for tool in yt-dlp ffmpeg; do
            "$brew" list --formula "$tool" >/dev/null 2>&1 || missing+=("$tool")
        done
        if (( ${#missing[@]} )); then
            bold "Instalando ${missing[*]} (para descargar de YouTube y crear bucles)…"
            "$brew" install "${missing[@]}"
        fi
    else
        echo
        echo "Para descargar de YouTube y usar el editor de bucles, Wallpy necesita yt-dlp y ffmpeg."
        echo "Instala Homebrew (https://brew.sh) y luego ejecuta:  brew install yt-dlp ffmpeg"
        echo "Los fondos de pantalla con tus propios vídeos funcionan sin ellos."
    fi
fi

open "$dest/Wallpy.app"
bold "¡Listo! Wallpy está en la barra de menú."
