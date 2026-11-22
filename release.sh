#!/bin/bash
# Neue Version veröffentlichen – alle installierten Apps holen sie sich automatisch.
# Nutzung: ./release.sh 1.0.1 "Was ist neu"
# Braucht den geheimen Schlüssel in ~/.winkomfort/signing-key (siehe sign.swift).
set -e
cd "$(dirname "$0")"
V="$1"; [ -n "$V" ] || { echo "Nutzung: ./release.sh 1.0.1 \"Was ist neu\""; exit 1; }
./build.sh "$V"
ZIP="build/WinKomfort-$V.zip"
swift sign.swift sign "$ZIP" > "$ZIP.sig"
gh release create "v$V" "$ZIP" "$ZIP.sig" --repo Eliasbkh/WinKomfort \
  --title "WinKomfort $V" --notes "${2:-Verbesserungen und Fehlerbehebungen}"
