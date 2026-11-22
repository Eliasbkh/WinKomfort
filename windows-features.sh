#!/bin/bash
# Windows-Komfort für macOS – setzt nur eingebaute macOS-Einstellungen.
# Läuft einmal und beendet sich: keine Hintergrund-App, 0 % CPU, 0 MB RAM.
# Nutzung:  ./windows-features.sh an   |   ./windows-features.sh aus
set -e

TP=(com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad)

an() {
  # 1) Tippen zum Klicken + 2x tippen und halten = ziehen (ohne Ziehsperre)
  for d in "${TP[@]}"; do
    defaults write "$d" Clicking -bool true
    defaults write "$d" Dragging -bool true
    defaults write "$d" DragLock -bool false
  done
  defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
  defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

  # 2) Menüleiste immer automatisch ausblenden (auch im Vollbild)
  defaults write NSGlobalDomain _HIHideMenuBar -bool true
  defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool false

  # 3) Fenster-Snapping wie Windows (an Rand ziehen → Vorschau → einrasten), ohne Lücken
  defaults write com.apple.WindowManager EnableTilingByEdgeDrag -bool true
  defaults write com.apple.WindowManager EnableTopTilingByEdgeDrag -bool true
  defaults write com.apple.WindowManager EnableTilingOptionAccelerator -bool true
  defaults write com.apple.WindowManager EnableTiledWindowMargins -bool false

  # 4) Screenshots direkt in die Zwischenablage (wie Win+Shift+S)
  defaults write com.apple.screencapture target clipboard

  # 5) Finder wie Explorer: Dateiendungen, Pfadleiste, Statusleiste, Ordner zuerst
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder _FXSortFoldersFirst -bool true
  defaults write com.apple.finder _FXShowPosixPathInTitle -bool true

  neustart
  echo "✅ An. Bitte einmal ab- und wieder anmelden, damit das Trackpad-Ziehen greift."
}

aus() {
  for d in "${TP[@]}"; do
    defaults delete "$d" Dragging 2>/dev/null || true
    defaults delete "$d" DragLock 2>/dev/null || true
  done
  for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen AppleShowAllExtensions; do
    defaults delete NSGlobalDomain "$k" 2>/dev/null || true
  done
  for k in EnableTilingByEdgeDrag EnableTopTilingByEdgeDrag EnableTilingOptionAccelerator EnableTiledWindowMargins; do
    defaults delete com.apple.WindowManager "$k" 2>/dev/null || true
  done
  defaults delete com.apple.screencapture target 2>/dev/null || true
  for k in ShowPathbar ShowStatusBar _FXSortFoldersFirst _FXShowPosixPathInTitle; do
    defaults delete com.apple.finder "$k" 2>/dev/null || true
  done
  # "Tippen zum Klicken" bleibt an – das war evtl. schon vorher so eingestellt.
  neustart
  echo "↩️  Zurück auf macOS-Standard. Ab- und wieder anmelden für alle Änderungen."
}

neustart() {
  killall Finder Dock SystemUIServer 2>/dev/null || true
}

case "$1" in
  an)  an ;;
  aus) aus ;;
  *)   echo "Nutzung: $0 an | aus"; exit 1 ;;
esac
