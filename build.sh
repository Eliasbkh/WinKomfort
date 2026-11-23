#!/bin/bash
# Baut WinKomfort.app + Zip fürs Update.  Nutzung: ./build.sh 1.0.0
set -e
cd "$(dirname "$0")"
V="${1:-1.0.0}"
APP=build/WinKomfort.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/WinKomfort.icns "$APP/Contents/Resources/" # Quelle: Icon/icon.svg
swiftc -O -swift-version 5 -parse-as-library WinKomfort.swift TapDragLogic.swift Calc.swift -o "$APP/Contents/MacOS/WinKomfort"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WinKomfort</string>
  <key>CFBundleIdentifier</key><string>de.winkomfort.app</string>
  <key>CFBundleExecutable</key><string>WinKomfort</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$V</string>
  <key>CFBundleVersion</key><string>$V</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleLocalizations</key><array><string>de</string></array>
  <key>CFBundleIconFile</key><string>WinKomfort</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>WinKomfort bittet den Finder, Apps beim Aufräumen in den Papierkorb zu legen und wiederherzustellen.</string>
</dict></plist>
EOF
# Festes Zertifikat → macOS behält die Bedienungshilfen-Freigabe über Updates hinweg (sonst ad-hoc)
if security find-certificate -c "WinKomfort Signing" >/dev/null 2>&1; then
  codesign --force -s "WinKomfort Signing" "$APP"
else
  echo "⚠️  Kein Zertifikat „WinKomfort Signing“ – ad-hoc signiert, Freigaben gehen bei Updates verloren"
  codesign --force -s - "$APP"
fi
ditto -c -k --keepParent "$APP" "build/WinKomfort-$V.zip"
echo "✅ $APP (Version $V)"
