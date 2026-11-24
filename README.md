# WinKomfort

Windows-Komfort für macOS als Menüleisten-App – jede Funktion einzeln schaltbar:

- **Trackpad & Tastatur:** 2× tippen und halten zum Ziehen (Finger heben lässt sofort los) · Scrollrichtung wie Windows · Tasten wiederholen beim Halten · F1–F12 als echte F-Tasten · Tab durch alle Bedienelemente
- **Fenster & Bildschirm:** Schließen beendet die App · Minimieren ins App-Symbol · Menüleiste ausblenden · Dock ohne Verzögerung · Snapping mit Vorschau · Klick auf Schreibtisch versteckt keine Fenster · Spaces nicht umsortieren · schnellere Animationen
- **Finder & Dateien:** Explorer-Ansicht (Endungen, Pfad, Statusleiste, Ordner zuerst) · Suche im aktuellen Ordner + Listenansicht · versteckte Dateien · kein .DS_Store auf USB/Netzwerk · große Speichern-Dialoge
- **Screenshots:** direkt in die Zwischenablage · ohne Fensterschatten
- **Startmenü:** Control kurz antippen wie die Windows-Taste – Apps suchen, angeheftete Apps, Ein/Aus
- **Task-Manager** mit ⌃⇧⎋: Apps und Hintergrund-Apps mit CPU und Arbeitsspeicher, Task beenden, Stromfresser beenden
- **Autostarts:** Apps beim Anmelden, Hintergrundaktivitäten und Hintergrund-Starter fremder Apps an- und ausschalten (umkehrbar)
- **Mitteilungen:** „Nicht stören“, Hauptschalter für alle und Mitteilungen pro App direkt in WinKomfort
- **Menüleiste:** Symbole von macOS und Apps ein-/ausblenden – Platz neben der Notch schaffen
- **Suche** (⌥ Leertaste): Apps, Dateien, Rechner, Web – mit Pfeiltasten und Enter
- **Schnellnotiz** (⌃⌥N): kleine Notiz oben links, immer im Vordergrund, speichert automatisch
- **Fenster wechseln wie Alt-Tab** (⌥⇥, ⌥⇧⇥ rückwärts): kurz tippen = letztes Fenster, halten = Übersicht mit Live-Vorschau
- **Finder wie Explorer**: ⌘X schneidet Dateien aus, ⌘V verschiebt sie; neue Textdatei im offenen Ordner (⌃⌥⌘N)
- **Zwischenablage-Verlauf** (⌃⌥V): letzte 50 Texte und 10 Bilder, nur im Arbeitsspeicher, Passwörter aus Passwort-Managern werden nie gespeichert
- **OneNote als PDF** (⌃⌥P in OneNote): Seite, Abschnitt oder ganzes Notizbuch als eine PDF in „Downloads“. Lädt die Original-Abschnitte mit deiner Microsoft-Anmeldung im Hintergrund (zwischengespeichert, nur Geändertes wird neu geladen), wandelt sie lokal um und baut eine kleine PDF – ganzes Notizbuch in ~9 s (beim ersten Mal mit Download ~20 s), eingefügte Arbeitsblätter vollständig. Größe wählbar (Sehr klein / Klein / Ausgewogen / Hoch). Notbehelf ohne Cloud: Seiten in OneNote einzeln sichern
- **Game Mode** (⌃⌥G, automatisch bei Spielen): Hintergrund-Apps gedrosselt, Nicht stören, Bildschirm bleibt an, Dock optional ausgeblendet – alles beim Beenden zurück
- **KI-Befehle** (⌃⌥K, Apple Intelligence auf dem Gerät): „halt den Mac eine Stunde wach“, „Game Mode an“, „zeig Downloads“ … Dieselben Befehle als Links für Kurzbefehle/Siri: `winkomfort://gamemode/on`, `winkomfort://awake/60`, `winkomfort://explorer/Downloads` (Links nur für harmlose Befehle – freie KI-Sätze und Apps öffnen gehen nur in WinKomfort selbst)
- **Maus wie unter Windows**: eigene Scrollrichtung und -geschwindigkeit für die Maus, Trackpad bleibt unverändert
- **Systemanzeige**: CPU und RAM in der Menüleiste (Klick = Task-Manager)
- **Schreibtisch & Dock**: Ecke unten rechts zeigt den Schreibtisch, Symbole/Widgets ausblenden, Laufwerke auf dem Schreibtisch, Dock ohne „Zuletzt benutzt“ und ohne Hüpfen
- **Englisch**: automatisch nach Systemsprache, umschaltbar unter Allgemein
- **Selbstreparatur**: nach dem Aufwachen startet WinKomfort Kürzel und Dienste still neu; Selbsttest mit „Reparieren“ unter Allgemein, Protokoll in ~/Library/Logs/WinKomfort.log
- **Text-Kürzel** (wie TextExpander): „;mail“ → deine E-Mail-Adresse – in jeder App, nie in Passwortfeldern (Allgemein › Text-Kürzel)
- **Siri & Kurzbefehle**: fertige Kurzbefehle mit einem Klick hinzufügen („Hey Siri, Game Mode an“)
- **Dock**: Position, Größe und Vergrößerung direkt unter Schreibtisch & Dock
- **Explorer** (⌃⌥E, im Finder: gleicher Ordner): eigener Dateimanager in drei Stilen – GNOME, KDE Dolphin, Windows 11 – mit Live-Vorschau in den Einstellungen, Quick Look (Leertaste), Tabs (⌘T), geteilter Ansicht (F3), Suche in allen Unterordnern, „Zuletzt benutzt“, Ordnergrößen, Laufwerke auswerfen, Pfeiltasten im Raster, Öffnen mit, ZIP, Pfad kopieren
- **Fenster einrasten per Tastatur** (⌃⌥←/→/↑/↓): linke/rechte Hälfte, maximieren, zurück bzw. minimieren
- **Fenster anheften** (⌃⌘P): Fenster bleibt immer im Vordergrund (Live-Kopie, braucht einmal „Bildschirmaufnahme“)
- **Wach bleiben:** Bildschirm an lassen oder nur den Mac wach halten, für 30 Min bis unbegrenzt
- **Mac aufräumen:** entfernbare Standard-Apps (GarageBand, iMovie, Keynote, Pages, Numbers + Sounds) in den Papierkorb – mit Protokoll und Wiederherstellen

Startet automatisch bei der Anmeldung und aktualisiert sich selbst über GitHub Releases.

## Installieren

`WinKomfort-x.y.z.zip` aus den [Releases](../../releases) laden, entpacken, nach **Programme** ziehen, öffnen.

## Bauen / testen / veröffentlichen

```bash
swiftc TapDragLogic.swift Calc.swift Shortcut.swift SnapMath.swift OneNoteOrder.swift TimeParse.swift ScaleLogic.swift LaunchLogic.swift Tests/main.swift -o /tmp/wktest && /tmp/wktest
./build.sh 1.0.0
./release.sh 1.0.1 "Was ist neu"
```

## Update-Sicherheit

Jedes Release-Zip wird mit Ed25519 signiert (`sign.swift`). Die App installiert ein Update nur, wenn die `.sig`-Datei zum eingebauten öffentlichen Schlüssel passt. Der geheime Schlüssel liegt nur lokal in `~/.winkomfort/signing-key` – nie ins Repo legen, aber sicher sichern.


OneNote-Umwandler in `onenote/`: aus [Joplin](https://github.com/laurent22/joplin) (`@joplin/onenote-converter`, basiert auf onenote.rs), Lizenz MPL-2.0 – siehe `onenote/LICENSE`.
