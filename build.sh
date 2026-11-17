#!/bin/bash
# Builds AgentNotch.app — a background (menu-bar only) app, ad-hoc signed so
# macOS lets it run and post notifications without a developer account.
set -euo pipefail
cd "$(dirname "$0")"

# APP_NAME / BUNDLE_ID let a side-by-side test build live next to the real one
# without sharing its preferences or its login item. Defaults are unchanged.
APP="${APP_NAME:-AgentNotch}.app"
BUNDLE_ID="${BUNDLE_ID:-local.agentnotch}"
CONTENTS="$APP/Contents"

echo "▸ compilazione…"
swift build -c release

echo "▸ assemblo il bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/AgentNotch "$CONTENTS/MacOS/AgentNotch"

# --- Icone -------------------------------------------------------------------
# Bundle: la versione a colori.  Barra dei menu: il disegno in outline, che va
# convertito in immagine template (nero + alpha) perché macOS possa ricolorarlo
# da solo per la barra chiara e per quella scura.

find_image() {
    for candidate in "$@"; do
        [ -f "$candidate" ] && echo "$candidate" && return
    done
}

ICON_SRC="$(find_image Icon.png Icon icon.png)"
OUTLINE_SRC="$(find_image outline.png outline StatusIcon.png status.png)"

if [ -n "$ICON_SRC" ]; then
    echo "▸ icona del bundle da $ICON_SRC…"
    ICONSET="$(mktemp -d)/AgentNotch.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AgentNotch.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

if [ -n "$OUTLINE_SRC" ]; then
    # Il convertitore è compilato una volta sola e messo in cache: interpretato
    # con `swift file.swift` la stessa conversione impiega ~25s invece di ~1s.
    MAKER=.build/status-icon-maker
    if [ ! -x "$MAKER" ] || [ tools/make-status-icon.swift -nt "$MAKER" ]; then
        echo "▸ compilo il convertitore dell'icona…"
        mkdir -p .build
        swiftc -O tools/make-status-icon.swift -o "$MAKER"
    fi
    CACHED=.build/StatusIcon.png
    if [ ! -f "$CACHED" ] || [ "$OUTLINE_SRC" -nt "$CACHED" ]; then
        echo "▸ icona della barra dei menu da $OUTLINE_SRC…"
        "$MAKER" "$OUTLINE_SRC" "$CACHED" 38 0.18
    fi
    cp "$CACHED" "$CONTENTS/Resources/StatusIcon.png"
elif [ -n "$ICON_SRC" ]; then
    # Nessun outline: ripiega sulla versione a colori, ridotta.
    sips -z 36 36 "$ICON_SRC" --out "$CONTENTS/Resources/MenuIcon.png" >/dev/null
else
    echo "▸ nessuna icona trovata: uso il simbolo di sistema"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentNotch</string>
    <key>CFBundleDisplayName</key><string>AgentNotch</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>AgentNotch</string>
    <key>CFBundleIconFile</key><string>AgentNotch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
echo "▸ pronto: $(pwd)/$APP"
