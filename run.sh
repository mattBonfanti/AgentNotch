#!/bin/bash
# Ricompila, sostituisce l'istanza in esecuzione e riavvia.
# Usa questo dopo ogni modifica al codice o alle preferenze via `defaults write`.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
pkill -f "AgentNotch.app/Contents/MacOS/AgentNotch" 2>/dev/null || true
sleep 0.5
open AgentNotch.app
sleep 1

if pgrep -f "AgentNotch.app/Contents/MacOS/AgentNotch" >/dev/null; then
    echo "▸ in esecuzione — cerca l'icona nella barra dei menu"
else
    echo "▸ non è partita. Prova ad aprirla dal Finder per vedere l'errore:"
    echo "  open -a Finder $(pwd)"
    exit 1
fi
