#!/bin/bash
# Baut WinKomfort.app + Zip fürs Update.  Nutzung: ./build.sh 1.0.0
set -e
cd "$(dirname "$0")"
V="${1:-1.0.0}"
APP=build/WinKomfort.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/WinKomfort.icns Icon/Explorer.png "$APP/Contents/Resources/" # Quelle: Icon/icon.svg
python3 web/build.py "$APP/Contents/Resources/remote.html" # Handy-Oberfläche
cp -R de.lproj en.lproj "$APP/Contents/Resources/" # Übersetzungen (Schlüssel = deutscher Text)
# -target: sonst gilt die App nur für die macOS-Version dieses Macs (nicht für LSMinimumSystemVersion)
swiftc -O -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library WinKomfort.swift Explorer.swift ExplorerMouse.swift Search.swift SearchSlash.swift TaskManager.swift Tools.swift RenameLogic.swift AI.swift AIEngine.swift AIView.swift AIAct.swift ActLogic.swift AIPanel.swift AILogic.swift MTPLogic.swift Phone.swift MathExpr.swift SchoolLogic.swift Studio.swift Sketch.swift Fun3D.swift SlashLogic.swift Convert.swift Emoji.swift SearchRank.swift SearchActions.swift AppUsage.swift OneNoteCloud.swift OneNoteOrder.swift GameMode.swift Assistant.swift MouseScroll.swift SystemMonitor.swift Repair.swift DockSettings.swift Snippets.swift TimeParse.swift FolderSize.swift Launcher.swift LaunchLogic.swift LidScript.swift RemoteCrypto.swift Remote.swift BudsProtocol.swift Buds.swift FolderHandler.swift PhoneTab.swift TapDragLogic.swift Calc.swift Shortcut.swift SnapMath.swift -o "$APP/Contents/MacOS/WinKomfort"
# OneNote-Umwandler (Rust, Open Source aus Joplin – siehe onenote/LICENSE)
(cd onenote && PATH="$HOME/.cargo/bin:$PATH" cargo build --release -q -p onenote-html)
cp onenote/target/release/onenote-html "$APP/Contents/MacOS/"
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
  <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
  <key>CFBundleIconFile</key><string>WinKomfort</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>de.winkomfort.app</string>
    <key>CFBundleURLSchemes</key><array><string>winkomfort</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Ordner</string><key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict></array>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Damit der Assistent deine Termine zeigen und auf deinen Klick neue eintragen kann.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Damit der Assistent deine Erinnerungen zeigen und auf deinen Klick neue anlegen kann.</string>
  <key>NSContactsUsageDescription</key><string>Damit der Assistent Nummern und Geburtstage aus deinen Kontakten findet.</string>
  <key>NSMicrophoneUsageDescription</key><string>Damit du mit dem Assistenten sprechen kannst, nur während du das Mikrofon eingeschaltet hast.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Damit aus deiner Sprache Text wird. Das passiert nur auf diesem Mac.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>WinKomfort zeigt den Akku deiner Galaxy Buds und schaltet die Geräuschsteuerung um.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Damit dein Handy den Mac im selben WLAN fernbedienen kann.</string>
  <key>NSAppleEventsUsageDescription</key><string>WinKomfort bittet den Finder, Apps beim Aufräumen in den Papierkorb zu legen und wiederherzustellen.</string>
</dict></plist>
EOF
# Festes Zertifikat → macOS behält die Bedienungshilfen-Freigabe über Updates hinweg (sonst ad-hoc)
if security find-certificate -c "WinKomfort Signing" >/dev/null 2>&1; then
  codesign --force -s "WinKomfort Signing" "$APP/Contents/MacOS/onenote-html"
  codesign --force -s "WinKomfort Signing" "$APP"
else
  echo "⚠️  Kein Zertifikat „WinKomfort Signing“ – ad-hoc signiert, Freigaben gehen bei Updates verloren"
  codesign --force -s - "$APP/Contents/MacOS/onenote-html"
  codesign --force -s - "$APP"
fi
ditto -c -k --keepParent "$APP" "build/WinKomfort-$V.zip"
# DMG zum Herunterladen (App + Verknüpfung zu „Programme“); das Auto-Update nutzt weiter die signierte ZIP
DMG=$(mktemp -d); ditto "$APP" "$DMG/WinKomfort.app"; ln -s /Applications "$DMG/Applications"
hdiutil create -quiet -ov -volname WinKomfort -srcfolder "$DMG" -format UDZO build/WinKomfort.dmg; rm -rf "$DMG"
echo "✅ $APP (Version $V)"
