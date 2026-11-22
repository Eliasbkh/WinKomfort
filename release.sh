#!/bin/bash
# Neue Version veröffentlichen – alle installierten Apps holen sie sich automatisch.
# Nutzung: ./release.sh 1.0.1 "Was ist neu"
set -e
cd "$(dirname "$0")"
V="$1"; [ -n "$V" ] || { echo "Nutzung: ./release.sh 1.0.1 \"Was ist neu\""; exit 1; }
./build.sh "$V"
gh release create "v$V" "build/WinKomfort-$V.zip" --repo Eliasbkh/WinKomfort \
  --title "WinKomfort $V" --notes "${2:-Verbesserungen und Fehlerbehebungen}"
