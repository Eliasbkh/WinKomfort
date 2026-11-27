// WinKomfort – Windows-Komfort für macOS als Menüleisten-App.
// Setzt nur eingebaute macOS-Einstellungen; im Leerlauf schläft die App (kein Polling außer 1 Update-Check alle 6 h).
import SwiftUI
import AppKit
import ServiceManagement
import CryptoKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ScreenCaptureKit
import PDFKit

let repo = "Eliasbkh/WinKomfort" // GitHub-Repo, aus dessen Releases Updates kommen
// Öffentlicher Ed25519-Schlüssel: nur Zips, die mit dem passenden geheimen Schlüssel (sign.swift) signiert sind, werden installiert
let updateKey = "U89i1hQZcm9gVR/pFcZDUc5fBi57hUyiM0laYznx0d0="

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

// Übersetzt Texte, die als String angezeigt werden (SwiftUI-Literale übersetzt SwiftUI selbst). Schlüssel = deutscher Text in en.lproj/Localizable.strings
func tr(_ s: String, _ args: CVarArg...) -> String {
    let t = Bundle.main.localizedString(forKey: s, value: nil, table: nil)
    return args.isEmpty ? t : String(format: t, arguments: args)
}

// MARK: - Shell & defaults

@discardableResult
func sh(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct Pref {
    let domain: String     // "host:" davor = -currentHost
    let key: String
    let on: [String]
    var off: [String]? = nil // nil = Eintrag löschen (macOS-Standard)
    var keep = false         // beim Ausschalten nicht anfassen
}

@discardableResult
func defaults(_ verb: String, _ p: Pref, _ value: [String] = []) -> String {
    var args = ["/usr/bin/defaults"]
    var domain = p.domain
    if domain.hasPrefix("host:") { args.append("-currentHost"); domain.removeFirst(5) }
    return sh(args + [verb, domain, p.key] + value)
}

struct Feature: Identifiable {
    let id: String
    let group: String
    let title: String
    let hint: String
    let prefs: [Pref]          // prefs[0] entscheidet, ob der Schalter als "an" gilt
    var restart: [String] = []
    var notify: String? = nil
    var activate = false       // Eingabe-Einstellungen sofort übernehmen, ohne Neuanmeldung
}

let trackpads = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
let yes = ["-bool", "true"], no = ["-bool", "false"]
let groups = ["Eingabe", "Fenster", "Finder", "Screenshots", "Schreibtisch"]
let groupIcons = ["hand.tap", "macwindow", "folder", "camera.viewfinder", "menubar.dock.rectangle"]

let features: [Feature] = [
    // Schreibtisch & Dock
    Feature(id: "showdesk", group: groups[4], title: "Ecke unten rechts zeigt den Schreibtisch",
            hint: "Wie der Knopf ganz rechts in der Windows-Taskleiste: Maus in die Ecke = alle Fenster beiseite.",
            prefs: [Pref(domain: "com.apple.dock", key: "wvous-br-corner", on: ["-int", "4"], off: ["-int", "1"]),
                    Pref(domain: "com.apple.dock", key: "wvous-br-modifier", on: ["-int", "0"], keep: true)], restart: ["Dock"]),
    Feature(id: "deskicons", group: groups[4], title: "Symbole auf dem Schreibtisch ausblenden",
            hint: "Aufgeräumter Schreibtisch – die Dateien bleiben im Ordner „Schreibtisch“ und im Explorer erreichbar.",
            prefs: [Pref(domain: "com.apple.finder", key: "CreateDesktop", on: no)], restart: ["Finder"]),
    Feature(id: "deskdrives", group: groups[4], title: "Laufwerke und USB-Sticks auf dem Schreibtisch",
            hint: "Wie „Dieser PC“: angeschlossene Festplatten, USB-Sticks und Netzlaufwerke direkt sichtbar.",
            prefs: [Pref(domain: "com.apple.finder", key: "ShowExternalHardDrivesOnDesktop", on: yes, off: no),
                    Pref(domain: "com.apple.finder", key: "ShowRemovableMediaOnDesktop", on: yes, off: no),
                    Pref(domain: "com.apple.finder", key: "ShowMountedServersOnDesktop", on: yes, off: no)], restart: ["Finder"]),
    Feature(id: "deskwidgets", group: groups[4], title: "Widgets auf dem Schreibtisch ausblenden",
            hint: "Die Widgets bleiben in der Mitteilungszentrale.",
            prefs: [Pref(domain: "com.apple.WindowManager", key: "StandardHideWidgets", on: yes)]),
    Feature(id: "dockrecents", group: groups[4], title: "Keine „Zuletzt benutzt“-Apps im Dock",
            hint: "Das Dock zeigt nur deine angehefteten und laufenden Apps – wie die Windows-Taskleiste.",
            prefs: [Pref(domain: "com.apple.dock", key: "show-recents", on: no)], restart: ["Dock"]),
    Feature(id: "dockhidden", group: groups[4], title: "Ausgeblendete Apps im Dock blass zeigen",
            hint: "Mit ⌘H versteckte Apps erkennt man sofort.",
            prefs: [Pref(domain: "com.apple.dock", key: "showhidden", on: yes)], restart: ["Dock"]),
    Feature(id: "dockbounce", group: groups[4], title: "Dock-Symbole hüpfen nicht",
            hint: "Kein Springen beim Start und bei Hinweisen.",
            prefs: [Pref(domain: "com.apple.dock", key: "no-bouncing", on: yes)], restart: ["Dock"]),
    // Trackpad & Tastatur
    Feature(id: "drag", group: groups[0], title: "2× tippen und halten zum Ziehen",
            hint: "Wie bei Windows: Finger heben lässt sofort los.",
            // WinKomfort zieht selbst (TapDragLogic) – das Ziehen von macOS ist dafür aus, sonst hält es nach dem Abheben fest
            prefs: [Pref(domain: "de.winkomfort.app", key: "tapDrag", on: yes)] + trackpads.flatMap { [
                Pref(domain: $0, key: "Dragging", on: no),
                Pref(domain: $0, key: "DragLock", on: no),
                Pref(domain: $0, key: "Clicking", on: yes, keep: true),
            ] } + [
                Pref(domain: "NSGlobalDomain", key: "com.apple.mouse.tapBehavior", on: ["-int", "1"], keep: true),
                Pref(domain: "host:NSGlobalDomain", key: "com.apple.mouse.tapBehavior", on: ["-int", "1"], keep: true),
            ],
            activate: true),
    Feature(id: "scroll", group: groups[0], title: "Scrollrichtung wie bei Windows",
            hint: "Finger nach unten = Seite nach unten.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "com.apple.swipescrolldirection", on: no)],
            activate: true),
    Feature(id: "keys", group: groups[0], title: "Tasten wiederholen beim Halten",
            hint: "Schnelle Wiederholung statt Akzent-Menü. Offene Apps nach ihrem Neustart.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "ApplePressAndHoldEnabled", on: no),
                    Pref(domain: "NSGlobalDomain", key: "KeyRepeat", on: ["-int", "2"]),
                    Pref(domain: "NSGlobalDomain", key: "InitialKeyRepeat", on: ["-int", "15"])],
            activate: true),
    Feature(id: "fnkeys", group: groups[0], title: "F1–F12 als echte F-Tasten",
            hint: "F5, F2 & Co. wie bei Windows. Helligkeit/Lautstärke dann mit fn.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "com.apple.keyboard.fnState", on: yes)],
            activate: true),
    Feature(id: "tabkeys", group: groups[0], title: "Tab springt durch alle Bedienelemente",
            hint: "Auch Knöpfe in Dialogen per Tab und Leertaste bedienen.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "AppleKeyboardUIMode", on: ["-int", "2"])],
            activate: true),

    // Fenster & Bildschirm
    Feature(id: "minimize", group: groups[1], title: "Minimieren ins App-Symbol",
            hint: "Wie die Taskleiste: Fenster verschwinden im Dock-Symbol der App statt rechts im Dock.",
            prefs: [Pref(domain: "com.apple.dock", key: "minimize-to-application", on: yes)],
            restart: ["Dock"]),
    Feature(id: "menubar", group: groups[1], title: "Menüleiste ausblenden",
            hint: "Erscheint nur, wenn die Maus nach oben geht. Den Streifen neben der Notch gibt macOS für Fenster nicht frei.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "_HIHideMenuBar", on: yes),
                    Pref(domain: "NSGlobalDomain", key: "AppleMenuBarVisibleInFullscreen", on: no)],
            notify: "AppleInterfaceMenuBarHidingChangedNotification"),
    Feature(id: "dock", group: groups[1], title: "Dock ausblenden – ohne Verzögerung",
            hint: "Mehr Platz; das Dock kommt sofort, auch über Vollbild-Apps, sobald die Maus unten ankommt.",
            prefs: [Pref(domain: "com.apple.dock", key: "autohide", on: yes),
                    Pref(domain: "com.apple.dock", key: "autohide-delay", on: ["-float", "0"]),
                    Pref(domain: "com.apple.dock", key: "autohide-time-modifier", on: ["-float", "0.12"])],
            restart: ["Dock"]),
    Feature(id: "dragany", group: groups[1], title: "Fenster überall anfassen (⌃⌘ ziehen)",
            hint: "⌃⌘ halten und irgendwo im Fenster ziehen. Offene Apps erst nach einem Neustart.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "NSWindowShouldDragOnGesture", on: yes)]),
    Feature(id: "snap", group: groups[1], title: "Fenster-Snapping mit Vorschau",
            hint: "An Rand oder nach oben ziehen → Vorschau → einrasten. Per Tastatur: fn ⌃ + Pfeiltasten.",
            prefs: [Pref(domain: "com.apple.WindowManager", key: "EnableTilingByEdgeDrag", on: yes),
                    Pref(domain: "com.apple.WindowManager", key: "EnableTopTilingByEdgeDrag", on: yes),
                    Pref(domain: "com.apple.WindowManager", key: "EnableTilingOptionAccelerator", on: yes),
                    Pref(domain: "com.apple.WindowManager", key: "EnableTiledWindowMargins", on: no)],
            restart: ["WindowManager"]),
    Feature(id: "desktop", group: groups[1], title: "Klick auf Schreibtisch versteckt keine Fenster",
            hint: "Fenster bleiben stehen, wenn du aus Versehen auf den Hintergrund klickst.",
            prefs: [Pref(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", on: no)],
            restart: ["WindowManager"]), // eigener Prozess, liest die Einstellung nur beim Start
    Feature(id: "spaces", group: groups[1], title: "Schreibtische nicht umsortieren",
            hint: "Deine Spaces bleiben in fester Reihenfolge.",
            prefs: [Pref(domain: "com.apple.dock", key: "mru-spaces", on: no)],
            restart: ["Dock"]),

    // Finder & Dateien
    Feature(id: "finder", group: groups[2], title: "Finder wie Explorer",
            hint: "Dateiendungen, Pfadleiste, Statusleiste, Ordner zuerst, Pfad im Titel.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "AppleShowAllExtensions", on: yes),
                    Pref(domain: "com.apple.finder", key: "ShowPathbar", on: yes),
                    Pref(domain: "com.apple.finder", key: "ShowStatusBar", on: yes),
                    Pref(domain: "com.apple.finder", key: "_FXSortFoldersFirst", on: yes),
                    Pref(domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", on: yes)],
            restart: ["Finder"]),
    Feature(id: "cut", group: groups[2], title: "⌘X schneidet Dateien aus",
            hint: "Wie im Explorer: ⌘X und dann ⌘V verschiebt die Dateien. Neue Textdatei im offenen Ordner: ⌃⌥⌘N.",
            prefs: [Pref(domain: "de.winkomfort.app", key: "finderCut", on: yes)]),
    Feature(id: "finderquit", group: groups[2], title: "Finder beenden erlauben",
            hint: "Wie jede andere App: ⌘Q beendet den Finder. Ein Klick aufs Finder-Symbol im Dock öffnet ihn wieder.",
            prefs: [Pref(domain: "com.apple.finder", key: "QuitMenuItem", on: yes)],
            restart: ["Finder"]),
    Feature(id: "search", group: groups[2], title: "Suche im aktuellen Ordner + Listenansicht",
            hint: "Wie im Explorer: Suche startet im offenen Ordner, Dateien als Liste.",
            prefs: [Pref(domain: "com.apple.finder", key: "FXDefaultSearchScope", on: ["-string", "SCcf"]),
                    Pref(domain: "com.apple.finder", key: "FXPreferredViewStyle", on: ["-string", "Nlsv"])],
            restart: ["Finder"]),
    Feature(id: "hidden", group: groups[2], title: "Versteckte Dateien anzeigen",
            hint: "Schnell umschalten geht auch mit ⇧⌘. im Finder.",
            prefs: [Pref(domain: "com.apple.finder", key: "AppleShowAllFiles", on: yes)],
            restart: ["Finder"]),
    Feature(id: "dsstore", group: groups[2], title: "Kein .DS_Store-Müll auf USB & Netzwerk",
            hint: "Keine versteckten Mac-Dateien auf USB-Sticks für Windows-PCs.",
            prefs: [Pref(domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", on: yes),
                    Pref(domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", on: yes)]),
    Feature(id: "save", group: groups[2], title: "Speichern- und Drucken-Dialog immer groß",
            hint: "Gleich mit Ordnerauswahl statt Mini-Dialog.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", on: yes),
                    Pref(domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode2", on: yes),
                    Pref(domain: "NSGlobalDomain", key: "PMPrintingExpandedStateForPrint", on: yes),
                    Pref(domain: "NSGlobalDomain", key: "PMPrintingExpandedStateForPrint2", on: yes)]),


    // Screenshots
    Feature(id: "shot", group: groups[3], title: "Screenshots in die Zwischenablage",
            hint: "⇧⌘3, ⇧⌘4 und ⇧⌘5 kopieren direkt – einfach mit ⌘V einfügen.",
            prefs: [Pref(domain: "com.apple.screencapture", key: "target", on: ["-string", "clipboard"]),
                    Pref(domain: "com.apple.screencapture", key: "target-screenshot", on: ["-string", "clipboard"])], // eigener Eintrag der ⇧⌘5-Leiste
            restart: ["SystemUIServer"]),
    Feature(id: "shadow", group: groups[3], title: "Fenster-Screenshots ohne Schatten",
            hint: "⇧⌘4, dann Leertaste: nur das Fenster, ohne breiten Rand.",
            prefs: [Pref(domain: "com.apple.screencapture", key: "disable-shadow", on: yes)],
            restart: ["SystemUIServer"]),
]

func isOn(_ f: Feature) -> Bool {
    let p = f.prefs[0]
    let want = p.on[1] == "true" ? "1" : p.on[1] == "false" ? "0" : p.on[1]
    return defaults("read", p) == want
}

func apply(_ f: Feature, _ on: Bool) {
    for p in f.prefs {
        if on { defaults("write", p, p.on) }
        else if p.keep { continue }
        else if let off = p.off { defaults("write", p, off) }
        else { defaults("delete", p) }
    }
    if f.activate { sh(["/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u"]) }
    for app in f.restart { sh(["/usr/bin/killall", app]) }
    if let n = f.notify {
        DistributedNotificationCenter.default().postNotificationName(.init(n), object: nil, deliverImmediately: true)
    }
}

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published var on: [String: Bool] = [:]
    init() { reload() }
    func reload() { for f in features { on[f.id] = isOn(f) } } // nach Umstellungen beim Start erneut lesen
    func binding(_ f: Feature) -> Binding<Bool> {
        Binding(get: { self.on[f.id] ?? false }, set: { v in
            apply(f, v)
            self.on[f.id] = v
            if f.id == "drag" { if v { TapDragFix.start(prompt: true) } else { TapDragFix.stop() } }
            if f.id == "cut" { if v { FinderCut.start(prompt: true) } else { FinderCut.stop() } }
        })
    }
    var startMenu: Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: "startMenu") }, set: { v in
            UserDefaults.standard.set(v, forKey: "startMenu")
            if v { StartKey.start(prompt: true) } else { StartKey.stop() }
            self.objectWillChange.send()
        })
    }
    var closeQuits: Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: "closeQuits") }, set: { v in
            UserDefaults.standard.set(v, forKey: "closeQuits")
            CloseWatcher.shared.setEnabled(v, prompt: true)
            self.objectWillChange.send()
        })
    }
    var login: Binding<Bool> {
        Binding(get: { SMAppService.mainApp.status == .enabled }, set: { v in
            if v { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            self.objectWillChange.send()
        })
    }
}

// MARK: - Schließen beendet die App (wie Windows)
// Ereignisgesteuert über die Bedienungshilfen-API: kein Polling, nur Reaktion, wenn in einer App etwas geschlossen wird.

let closeHint = "Wie bei Windows: Letztes Fenster zu = App beendet. Den Finder nur, wenn „Finder beenden erlauben“ an ist."

final class CloseWatcher {
    static let shared = CloseWatcher()
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var pending: Set<pid_t> = []
    private let skip: Set<String> = ["de.winkomfort.app"]

    func setEnabled(_ on: Bool, prompt: Bool = false) {
        stop()
        guard on else { return }
        afterTrust(prompt: prompt) { [weak self] in
            guard UserDefaults.standard.bool(forKey: "closeQuits") else { return } // inzwischen wieder ausgeschaltet
            self?.begin()
        }
    }

    private func begin() {
        guard tokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.watch(app) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.unwatch(app.processIdentifier) }
        })
        NSWorkspace.shared.runningApplications.forEach(watch)
    }

    private func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        observers.keys.forEach(unwatch)
    }

    private func watch(_ app: NSRunningApplication) { watch(app, tries: 0) }

    private func watch(_ app: NSRunningApplication, tries: Int) {
        let pid = app.processIdentifier
        // Finder nur, wenn „Finder beenden erlauben“ an ist – sonst ließe er sich gar nicht beenden
        let finderQuittable = app.bundleIdentifier != "com.apple.finder"
            || defaults("read", Pref(domain: "com.apple.finder", key: "QuitMenuItem", on: [])) == "1"
        guard !tokens.isEmpty, !app.isTerminated, app.activationPolicy == .regular, let id = app.bundleIdentifier,
              !skip.contains(id), finderQuittable, observers[pid] == nil else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { obs, el, note, ctx in
            // Neues Fenster: auch dessen Schließen direkt beobachten (manche Apps melden es nicht an die App selbst)
            if note as String == kAXWindowCreatedNotification {
                AXObserverAddNotification(obs, el, kAXUIElementDestroyedNotification as CFString, ctx)
                return
            }
            CloseWatcher.shared.schedule(pid_t(Int(bitPattern: ctx)))
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(pid), ctx = UnsafeMutableRawPointer(bitPattern: Int(pid))
        // Frisch gestartete Apps sind oft noch nicht bereit – dann bis zu 10× im Sekundentakt erneut versuchen
        guard AXObserverAddNotification(obs, el, kAXUIElementDestroyedNotification as CFString, ctx) == .success else {
            if tries < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch(app, tries: tries + 1) }
            }
            return
        }
        AXObserverAddNotification(obs, el, kAXWindowCreatedNotification as CFString, ctx)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value) == .success {
            (value as? [AXUIElement])?.forEach { AXObserverAddNotification(obs, $0, kAXUIElementDestroyedNotification as CFString, ctx) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    // Bedienungshilfen sehen nur Fenster im aktuellen Space. Fenster in anderen Spaces oder im Vollbild
    // stehen nur in der Fensterliste – erkennbar am Titel (den liefert macOS nur mit Bildschirmaufnahme-Freigabe).
    // shortcut: ohne diese Freigabe wird so ein Fenster nicht erkannt; dann WinKomfort Bildschirmaufnahme erlauben
    private static func hasWindowInOtherSpace(_ pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0
                && (w[kCGWindowIsOnscreen as String] as? Bool) != true
                && !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }

    private func unwatch(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    // Viele Elemente werden zerstört (Knöpfe, Tabs …) – pro App nur einmal nach 0,5 s nachsehen.
    // shortcut: eine App, die ihr einziges Fenster schließt und >0,5 s später ein neues öffnet, wird beendet – dann App zu `skip` hinzufügen
    private func schedule(_ pid: pid_t) {
        guard pending.insert(pid).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pending.remove(pid)
            Self.queue.async { // eine hängende App darf WinKomfort nicht anhalten
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
                      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      // Der Schreibtisch zählt beim Finder als Fenster (ohne Fensterart) – ihn nicht mitzählen
                      let windows = (value as? [AXUIElement])?.filter({ app.bundleIdentifier != "com.apple.finder" || UIAuto.attr($0, kAXSubroleAttribute) != nil }),
                      windows.isEmpty, !Self.hasWindowInOtherSpace(pid) else { return }
                DispatchQueue.main.async { if UserDefaults.standard.bool(forKey: "closeQuits") { app.terminate() } }
            }
        }
    }
    private static let queue = DispatchQueue(label: "winkomfort.close", qos: .utility)
}

// MARK: - Ziehen endet sofort beim Loslassen (wie Windows)
// macOS hält ein Tipp-Ziehen nach dem Loslassen noch ~1 s fest. Wir lesen nur die Fingeranzahl vom Trackpad
// (privates MultitouchSupport – liefert nur bei Berührung Daten) und lassen los, sobald kein Finger mehr liegt.

// Bedienungshilfen-Freigabe anfragen; fehlt sie, alle 2 s nachsehen und danach `then` ausführen
// Nachgefragt wird nur, wenn du eine Funktion einschaltest – und höchstens einmal pro Start. Beim Start wird still gewartet.
private var trustWaiters: [() -> Void] = []
private var trustTimer: Timer?
private var trustPrompted = false

func afterTrust(prompt: Bool = false, _ then: @escaping () -> Void) {
    if AXIsProcessTrusted() { then(); return }
    if prompt, !trustPrompted {
        trustPrompted = true
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    trustWaiters.append(then)
    guard trustTimer == nil else { return }
    trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
        guard AXIsProcessTrusted() else { return }
        t.invalidate()
        trustTimer = nil
        let waiting = trustWaiters
        trustWaiters = []
        waiting.forEach { $0() }
    }
}

enum TapDragFix {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    typealias DevFn = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private static let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        guard let lib, let f = dlsym(lib, name) else { return nil }
        return unsafeBitCast(f, to: T.self)
    }
    private static var devices: [UnsafeMutableRawPointer] = []
    private static var logic = TapDragLogic()   // nur im Trackpad-Thread benutzt
    private static var dragging = false         // vom Bewegungs-Zuhörer gelesen; ein Bool, kurzes Nachhinken ist harmlos
    private static var moveTap: CFMachPort?

    // Der Maus-Filter läuft nur während des Ziehens – sonst gehen Mausbewegungen gar nicht durch WinKomfort
    private static func filter(_ on: Bool) { if let t = moveTap { CGEvent.tapEnable(tap: t, enable: on) } }

    private static func click(_ type: CGEventType) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // Jeder Trackpad-Frame: Positionen der aufliegenden Finger + Zeit → drücken / loslassen.
    // Rohdaten-Layout (MTTouch, 96 Byte): Zustand bei Byte 20, Position x/y (0…1) bei Byte 32/36 – auf macOS 27 geprüft.
    // Nur Zustand 3/4 (setzt auf / liegt auf) zählt; 5–7 heißt „hebt gerade ab“ – sonst käme das Loslassen zu spät.
    private static let callback: Callback = { _, data, count, time, _ in
        var touching: [TapDragLogic.Point] = []
        if let data {
            for i in 0..<Int(count) {
                let t = data + i * 96
                let state = t.load(fromByteOffset: 20, as: Int32.self)
                guard state == 3 || state == 4 else { continue }
                touching.append(.init(x: Double(t.load(fromByteOffset: 32, as: Float.self)), y: Double(t.load(fromByteOffset: 36, as: Float.self))))
            }
        }
        switch TapDragFix.logic.frame(touching: touching, time: time) {
        case .press: TapDragFix.dragging = true; TapDragFix.filter(true); TapDragFix.click(.leftMouseDown)
        case .release: TapDragFix.dragging = false; TapDragFix.click(.leftMouseUp); TapDragFix.filter(false)
        case .none: break
        }
        return 0
    }

    static func start(prompt: Bool = false) {
        afterTrust(prompt: prompt) {
            guard devices.isEmpty, features.first(where: { $0.id == "drag" }).map(isOn) == true,
                  let list = fn("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self)?()?.takeUnretainedValue(),
                  let register = fn("MTRegisterContactFrameCallback", DevFn.self),
                  let startDev = fn("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
            else { return }
            for i in 0..<CFArrayGetCount(list) {
                guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
                let dev = UnsafeMutableRawPointer(mutating: raw)
                register(dev, callback)
                startDev(dev, 0)
                devices.append(dev)
            }
            // Während des Ziehens werden Mausbewegungen zu Zieh-Bewegungen, damit Apps Fenster/Dateien mitnehmen
            moveTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue), callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = TapDragFix.moveTap, TapDragFix.dragging { CGEvent.tapEnable(tap: t, enable: true) }
                } else if type == .mouseMoved, TapDragFix.dragging {
                    event.type = .leftMouseDragged
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            if let moveTap {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, moveTap, 0), .commonModes)
                CGEvent.tapEnable(tap: moveTap, enable: false)
            }
        }
    }

    static func stop() {
        if dragging { dragging = false; click(.leftMouseUp) }
        if let t = moveTap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); moveTap = nil }
        guard let unregister = fn("MTUnregisterContactFrameCallback", DevFn.self),
              let stopDev = fn("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Void).self) else { return }
        for dev in devices { unregister(dev, callback); stopDev(dev) }
        devices = []
    }
}

// MARK: - Startmenü (Control kurz allein antippen = Windows-Taste)

enum StartKey {
    private static var downAt: Date?
    private static var tap: CFMachPort?

    // Reiner Zuhörer im System-Tastaturstrom (verändert nichts) – zuverlässig, auch wenn WinKomfort nie im Vordergrund war
    static func start(prompt: Bool = false) {
        afterTrust(prompt: prompt) {
            guard tap == nil, UserDefaults.standard.bool(forKey: "startMenu") else { return }
            // Scrollen zählt nicht als Abbruch: ein auf dem Trackpad liegender Finger erzeugt ständig Scroll-Ereignisse
            let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: mask, callback: { _, type, event, _ in
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let t = StartKey.tap { CGEvent.tapEnable(tap: t, enable: true) }
                case .flagsChanged: StartKey.handle(event.flags)
                default:
                    StartKey.downAt = nil // andere Taste oder Klick dazwischen → kein Startmenü
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            guard let tap else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    static func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
    }

    // Nur Control gedrückt und innerhalb 0,4 s wieder losgelassen – ohne andere Taste oder Klick dazwischen
    private static var lastFlags = CGEventFlags()
    private static var lastFlagsAt = Date.distantPast
    private static func handle(_ flags: CGEventFlags) {
        let f = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
        // Nur „Control aus dem Nichts“ zählt – nicht das übrig gebliebene Control beim Loslassen von ⌃⌘P & Co.
        // Ein älterer Zustand (> 1 s) gilt als veraltet, falls ein Loslassen-Ereignis verloren ging.
        let fresh = lastFlags.isEmpty || Date().timeIntervalSince(lastFlagsAt) > 1
        lastFlags = f
        lastFlagsAt = Date()
        if f == .maskControl && fresh { downAt = Date() }
        else if f.isEmpty, let d = downAt, Date().timeIntervalSince(d) < 0.4 {
            downAt = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { StartMenu.toggle() } }
        } else { downAt = nil }
    }
}

struct AppEntry: Identifiable {
    let name: String
    let path: String
    var file: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var id: String { path }
}

@MainActor final class StartModel: ObservableObject {
    static let shared = StartModel()
    @Published var query = ""
    @Published var all: [AppEntry] = []
    @Published var pinned: [AppEntry] = []
    @Published var opened = 0
    private var icons: [String: NSImage] = [:]

    func icon(_ path: String) -> NSImage {
        if let i = icons[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        icons[path] = i
        return i
    }

    func entry(_ path: String) -> AppEntry {
        AppEntry(name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""), path: path)
    }

    func reload() {
        query = ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices/Applications", "\(home)/Applications"] // auch Apples versteckte Apps (Desk View, Schlüsselbund …)
        all = dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.map { entry("\(dir)/\($0)") }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        all.append(entry("/System/Library/CoreServices/Finder.app"))
        // Angeheftet = die Apps aus deinem Dock
        let dock = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        pinned = dock.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String, let url = URL(string: s), url.isFileURL else { return nil }
            return entry(url.path)
        }
        opened += 1
    }

    var results: [AppEntry] { query.isEmpty ? pinned : match(query) }

    // Beste Namenstreffer zuerst, häufig benutzte Apps angehoben; was du bei diesem Wort zuletzt gewählt hast, ganz oben
    func match(_ query: String) -> [AppEntry] {
        let pick = AppUsage.shared.pick(query)
        let hits = all.compactMap { e -> (AppEntry, Double)? in
            guard let m = [e.name, e.file].compactMap({ SearchRank.match(query, $0) }).max() else { return nil }
            return (e, SearchRank.total(m, usage: AppUsage.shared.score(e.path)) + (e.path == pick ? 1 : 0))
        }
        return Array(hits.sorted { $0.1 > $1.1 }.prefix(24).map(\.0)) // sorted ist stabil: bei Gleichstand alphabetisch
    }

    func open(_ e: AppEntry) {
        AppUsage.shared.picked(query, e.path)
        NSWorkspace.shared.open(URL(fileURLWithPath: e.path))
        StartMenu.hide()
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor enum StartMenu {
    private static var panel: KeyPanel?

    static func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    static func hide() { panel?.orderOut(nil) }

    static func show() {
        StartModel.shared.reload()
        let p = panel ?? make()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame, size = p.frame.size
        p.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.minY + 16))
        // Nicht aktivierendes Panel (wie Spotlight): erscheint und nimmt Tastatur an, ohne WinKomfort nach vorne zu holen
        p.orderFrontRegardless()
        p.makeKey()
    }

    private static func make() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = fixedHost(StartView())
        host.wantsLayer = true
        p.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { hide() }
        }
        // Esc schließt – das Suchfeld würde die Taste sonst selbst verschlucken
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53, panel?.isKeyWindow == true else { return e }
            MainActor.assumeIsolated { hide() }
            return nil
        }
        panel = p
        return p
    }
}

final class HoverBox: ObservableObject { @Published var on = false }

struct AppCell: View {
    let app: AppEntry
    @ObservedObject var m = StartModel.shared
    @StateObject var hover = HoverBox()
    var body: some View {
        Button { m.open(app) } label: {
            VStack(spacing: 6) {
                Image(nsImage: m.icon(app.path)).resizable().frame(width: 44, height: 44)
                Text(app.name).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 84, height: 80)
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hover.on ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(app.name)
    }
}

struct StartView: View {
    @ObservedObject var m = StartModel.shared
    @FocusState var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Apps durchsuchen", text: $m.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searching)
                    .onSubmit { if let first = m.results.first { m.open(first) } }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))

            Text(m.query.isEmpty ? "Angeheftet" : "Ergebnisse").font(.headline)
            ScrollView {
                if m.results.isEmpty {
                    Text("Keine App gefunden.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 4), count: 6), spacing: 8) {
                    ForEach(m.results) { AppCell(app: $0) }
                }
            }
            Divider()
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                Text(NSFullUserName())
                Spacer()
                Button { StartMenu.hide(); QuickNote.shared.show() } label: { Image(systemName: "note.text") }
                    .help(tr("Schnellnotiz") + (HotAction.note.current.map { " (\($0.display))" } ?? "")).accessibilityLabel("Schnellnotiz")
                Button { StartMenu.hide(); openTaskManager() } label: { Image(systemName: "list.bullet.rectangle") }
                    .help("Task-Manager").accessibilityLabel("Task-Manager")
                Button { StartMenu.hide(); openSettingsWindow() } label: { Image(systemName: "macwindow.on.rectangle") }
                    .help("WinKomfort-Einstellungen").accessibilityLabel("WinKomfort-Einstellungen")
                Button { m.open(m.entry("/System/Applications/System Settings.app")) } label: {
                    Image(systemName: "gearshape")
                }
                .help("Systemeinstellungen")
                .accessibilityLabel("Systemeinstellungen")
                Menu {
                    Button("Ruhezustand") { StartMenu.hide(); sh(["/usr/bin/pmset", "sleepnow"]) }
                    Button("Neustart …") { power("aevtrrst") }
                    Button("Ausschalten …") { power("aevtrsdn") }
                    Divider()
                    Button("Abmelden …") { power("aevtlogo") }
                } label: { Image(systemName: "power") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Ein/Aus")
                .accessibilityLabel("Ein/Aus")
            }
            .buttonStyle(.borderless).font(.title3)
        }
        .padding(18)
        .frame(width: 600, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
        .onExitCommand { StartMenu.hide() }
        .onChange(of: m.opened) { _, _ in searching = true }
        .onAppear { searching = true }
    }

    // Zeigt den normalen macOS-Dialog zum Bestätigen
    private func power(_ code: String) {
        StartMenu.hide()
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"loginwindow\" to «event \(code)»")?.executeAndReturnError(&err)
    }
}

// MARK: - Mitteilungen
// Apple bietet Apps keinen Weg, Mitteilungen anderer Apps oder „Nicht stören“ zu schalten. WinKomfort bedient deshalb
// im Hintergrund dieselben Schalter wie du: Systemeinstellungen → Mitteilungen und Kontrollzentrum → Fokus.
// shortcut: hängt an Apples interner Bedienstruktur (Kennungen wie „allow-notifications“) – nach großen macOS-Updates nachtesten

enum UIAuto {
    static func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
    }
    static func id(_ e: AXUIElement) -> String? { attr(e, kAXIdentifierAttribute) as? String }
    static func role(_ e: AXUIElement) -> String? { attr(e, kAXRoleAttribute) as? String }
    static func label(_ e: AXUIElement) -> String {
        (attr(e, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (attr(e, kAXTitleAttribute) as? String) ?? ""
    }
    static func press(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }
    static func app(_ bundle: String) -> AXUIElement? {
        guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        return ax
    }
    // Alle Elemente der Fenster einer App in Baum-Reihenfolge
    static func elements(_ ax: AXUIElement, windowsOnly: Bool = true) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ d: Int) {
            // Eigene Elemente (z. B. unser Menüleisten-Symbol) nie abfragen: das wartet auf den Hauptthread und hängt WinKomfort auf
            var pid: pid_t = 0
            if AXUIElementGetPid(e, &pid) == .success, pid == getpid() { return }
            out.append(e)
            if d < 14 { for k in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(k, d + 1) } }
        }
        if windowsOnly { for w in attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(w, 0) } } else { walk(ax, 0) }
        return out
    }
    // Wartet bis zu 12 s, bis die Bedingung erfüllt ist (Kaltstart der Systemeinstellungen braucht ~5 s)
    static func wait(_ bundle: String, windowsOnly: Bool = true, seconds: Double = 12, _ ok: ([AXUIElement]) -> Bool) -> [AXUIElement]? {
        for _ in 0..<Int(seconds / 0.15) {
            if let ax = app(bundle) { let e = elements(ax, windowsOnly: windowsOnly); if ok(e) { return e } }
            usleep(150_000)
        }
        return nil
    }
}

struct NotifApp: Identifiable {
    let name: String
    var on: Bool
    var id: String { name }
}

@MainActor final class Notifs: ObservableObject {
    static let shared = Notifs()
    @Published var apps: [NotifApp] = []
    @Published var dnd: Bool?
    @Published var busy = false
    @Published var message = ""
    private let queue = DispatchQueue(label: "winkomfort.notifs") // nacheinander, nie gleichzeitig

    private nonisolated static let settings = "com.apple.systempreferences"
    // Die Systemeinstellungen sprechen die Systemsprache – Texte daher auf Deutsch und Englisch erkennen
    private nonisolated static let appHeadings: Set<String> = ["App-Mitteilungen", "Application Notifications"]
    private nonisolated static let offSummaries: Set<String> = ["Aus", "Kritisch", "Off", "Critical"]

    // MARK: Systemeinstellungen → Mitteilungen
    private nonisolated static func isOverview(_ e: [AXUIElement]) -> Bool {
        e.contains { UIAuto.id($0) == "summarize-previews" || (UIAuto.role($0) == "AXHeading" && appHeadings.contains(UIAuto.label($0))) }
    }
    private nonisolated static func isDetail(_ e: [AXUIElement]) -> Bool {
        e.contains { UIAuto.id($0) == "allow-notifications" }
    }

    // Öffnet die Mitteilungs-Übersicht im Hintergrund und liefert die App-Zeilen
    private nonisolated static func overview() -> [(AXUIElement, NotifApp)]? {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true // unsichtbar öffnen – du siehst die Systemeinstellungen gar nicht
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!, configuration: cfg)
        if let e = UIAuto.wait(settings, { isOverview($0) || isDetail($0) }), !isOverview(e),
           let back = e.first(where: { UIAuto.id($0) == "chevron.backward" }) { UIAuto.press(back) }
        guard let e = UIAuto.wait(settings, isOverview),
              let start = e.lastIndex(where: { UIAuto.role($0) == "AXHeading" }) else { return nil } // App-Liste kommt nach der letzten Überschrift
        return e[start...].compactMap { el in
            let l = UIAuto.label(el)
            guard UIAuto.role(el) == "AXButton", let comma = l.range(of: ", ") else { return nil }
            let name = String(l[..<comma.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}"))
            // „Kritisch“ allein heißt: Mitteilungen aus, nur kritische Hinweise (Notfälle) kommen noch durch
            let summary = String(l[comma.upperBound...])
            return (el, NotifApp(name: name, on: !offSummaries.contains(summary)))
        }
    }

    private nonisolated static func closeSettings(_ wasRunning: Bool) {
        // Hattest du die Systemeinstellungen selbst offen, bleiben sie offen
        if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: settings).first?.terminate() }
    }

    // MARK: Kontrollzentrum → Fokus
    // Ein Durchgang: Kontrollzentrum öffnen, Fokus lesen, bei Bedarf schalten, schließen. `want == nil` = nur lesen
    private nonisolated static func focus(want: Bool?) -> Bool? {
        guard let bar = UIAuto.app("com.apple.MenuBarAgent"),
              let item = UIAuto.elements(bar, windowsOnly: false).first(where: { UIAuto.id($0) == "com.apple.menuextra.controlcenter" })
        else { return nil }
        let isFocus = { (e: AXUIElement) in UIAuto.id(e)?.hasPrefix("controlcenter-focus-modes") == true }
        // Direkt nach dem Schließen ignoriert macOS ein erneutes Öffnen kurz → bis zu 3 Versuche
        var found: AXUIElement?
        for _ in 0..<3 {
            UIAuto.press(item)
            if let e = UIAuto.wait("com.apple.controlcenter", seconds: 2, { $0.contains(where: isFocus) }) { found = e.first(where: isFocus); break }
            usleep(700_000)
        }
        guard let sw = found else { return nil }
        defer { UIAuto.press(item) } // Kontrollzentrum wieder schließen
        let isOn = { (UIAuto.attr(sw, kAXValueAttribute) as? Int) == 1 }
        if let want, isOn() != want {
            UIAuto.press(sw)
            for _ in 0..<20 where isOn() != want { usleep(100_000) } // Kontrollzentrum aktualisiert den Wert verzögert
        }
        return isOn()
    }

    // MARK: Aktionen (im Hintergrund, Ergebnis auf dem Hauptthread)
    private func run(_ work: @escaping () -> (apps: [NotifApp]?, dnd: Bool?, message: String)) {
        busy = true
        message = ""
        queue.async {
            let r = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let a = r.apps { self.apps = a }
                    if let d = r.dnd { self.dnd = d }
                    self.message = r.message
                    self.busy = false
                }
            }
        }
    }

    func load() {
        run {
            let was = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settings).isEmpty
            let apps = Self.overview()?.map(\.1)
            Self.closeSettings(was)
            let dnd = Self.focus(want: nil)
            return (apps, dnd, apps == nil ? tr("Mitteilungs-Einstellungen konnten nicht gelesen werden.") : "")
        }
    }

    // Eine App umschalten, während die Mitteilungs-Seite offen ist. nil = App/Seite nicht gefunden
    private nonisolated static func switchOne(_ name: String, _ on: Bool) -> Bool? {
        guard let row = overview()?.first(where: { $0.1.name == name }) else { return nil }
        UIAuto.press(row.0)
        guard let d = UIAuto.wait(settings, isDetail),
              let sw = d.first(where: { UIAuto.id($0) == "allow-notifications" }) else { return nil }
        if UIAuto.value(sw) != on {
            UIAuto.press(sw)
            for _ in 0..<20 where UIAuto.value(sw) != on { usleep(100_000) }
        }
        let now = UIAuto.value(sw)
        if let back = d.first(where: { UIAuto.id($0) == "chevron.backward" }) { UIAuto.press(back) }
        return now
    }

    func set(_ name: String, _ on: Bool) {
        run {
            let was = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settings).isEmpty
            defer { Self.closeSettings(was) }
            let now = Self.switchOne(name, on)
            return (Self.overview()?.map(\.1), nil, now == on ? "" : tr("„%@“ ließ sich nicht umschalten.", name))
        }
    }

    // Hauptschalter. Aus: merkt sich, welche Apps an waren. An: stellt genau diese wieder her (ohne Merkliste: alle)
    func setAll(_ on: Bool) {
        let key = "notifsOnBeforeAllOff"
        let remembered = UserDefaults.standard.stringArray(forKey: key) ?? []
        let targets = on ? apps.filter { !$0.on && (remembered.isEmpty || remembered.contains($0.name)) }.map(\.name)
                         : apps.filter(\.on).map(\.name)
        if !on { UserDefaults.standard.set(targets, forKey: key) }
        run {
            let was = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settings).isEmpty
            defer { Self.closeSettings(was) }
            var failed: [String] = []
            for (i, name) in targets.enumerated() {
                DispatchQueue.main.async { MainActor.assumeIsolated { Notifs.shared.message = tr("Schalte %lld/%lld: %@ …", i + 1, targets.count, name) } }
                if Self.switchOne(name, on) != on { failed.append(name) }
            }
            if on && failed.isEmpty { DispatchQueue.main.async { UserDefaults.standard.removeObject(forKey: key) } }
            return (Self.overview()?.map(\.1), nil, failed.isEmpty ? "" : tr("Nicht umgeschaltet: %@", failed.joined(separator: ", ")))
        }
    }

    func setDND(_ on: Bool) {
        run {
            guard let now = Self.focus(want: on) else { return (nil, nil, tr("Kontrollzentrum nicht erreichbar.")) }
            return (nil, now, now == on ? "" : tr("„Nicht stören“ ließ sich nicht umschalten."))
        }
    }
}

struct MenuBarTab: View {
    @ObservedObject var m = menuBarSwitches
    var body: some View {
        Form {
            Section {
                Text("Rechts neben der Notch ist wenig Platz – was nicht mehr passt, blendet macOS einfach aus. Schalte hier Symbole ab, die du nicht brauchst.")
                    .foregroundStyle(.secondary)
            }
            ForEach(["Symbole von macOS", "Symbole von Apps"], id: \.self) { group in
                Section {
                    ForEach(m.items.filter { $0.group == group }) { item in
                        Toggle(item.name, isOn: Binding(get: { item.on }, set: { m.set(item.id, $0) }))
                            .accessibilityLabel(item.name)
                            .disabled(m.busy)
                    }
                    if m.items.isEmpty { Text(m.busy ? tr("Lese Menüleiste …") : m.message).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(tr(group))
                        Spacer()
                        if m.busy && group == "Symbole von macOS" { ProgressView().controlSize(.small) }
                    }
                }
            }
            if !m.message.isEmpty && !m.items.isEmpty { Section { Text(m.message).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .onAppear { if m.items.isEmpty && !m.busy { m.load() } }
    }
}

struct NotificationsTab: View {
    @ObservedObject var n = Notifs.shared
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { n.dnd ?? false }, set: { n.setDND($0) })) {
                    Text("Nicht stören")
                    Text("Schaltet alle Mitteilungen stumm – wie im Kontrollzentrum.")
                }
                .accessibilityLabel("Nicht stören")
                .disabled(n.busy || n.dnd == nil)
            }
            Section {
                Toggle(isOn: Binding(get: { n.apps.contains(where: \.on) }, set: { n.setAll($0) })) {
                    Text("Alle Mitteilungen")
                    Text("Aus schaltet alle Apps stumm und merkt sich, welche an waren – An stellt genau diese wieder her.")
                }
                .accessibilityLabel("Alle Mitteilungen")
                .disabled(n.busy || n.apps.isEmpty)
            }
            Section {
                if n.apps.isEmpty {
                    Text(n.busy ? "Lese Mitteilungs-Einstellungen …" : "Keine Apps gefunden.").foregroundStyle(.secondary)
                }
                ForEach(n.apps) { app in
                    Toggle(app.name, isOn: Binding(get: { app.on }, set: { n.set(app.name, $0) }))
                        .accessibilityLabel(app.name)
                        .disabled(n.busy)
                }
            } header: {
                HStack {
                    Text("Mitteilungen pro App")
                    Spacer()
                    if n.busy { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text(n.message.isEmpty ? tr("WinKomfort stellt das im Hintergrund in den Systemeinstellungen um – Apple bietet dafür keinen direkten Weg. Ein Schalter dauert 2–3 Sekunden.") : n.message)
                    .foregroundStyle(n.message.isEmpty || n.busy ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { if n.apps.isEmpty && !n.busy { n.load() } }
    }
}

// SwiftUI-Inhalt für Fenster, deren Größe der Code selbst setzt. Ohne `sizingOptions = []` zwingt die Ansicht dem
// Fenster eigene Größen-Regeln auf – zusammen mit setFrame endet das in einer Layout-Endlosschleife (Absturz).
func fixedHost<V: View>(_ view: V) -> NSHostingView<V> {
    let h = NSHostingView(rootView: view)
    h.sizingOptions = []
    return h
}

// MARK: - Kurze Hinweise (Toast) in der Bildschirmmitte

@MainActor enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: DispatchWorkItem?
    static func show(_ text: String, symbol: String, seconds: Double = 1.4) {
        let text = tr(text)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        let view = fixedHost(HStack(spacing: 8) { Image(systemName: symbol); Text(text).lineLimit(1) }.font(.headline).fixedSize().padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule()))
        view.sizingOptions = [.intrinsicContentSize] // ohne das meldet SwiftUI nur die Mindestgröße (Symbol ohne Text)
        let size = view.fittingSize
        view.sizingOptions = []
        p.contentView = view
        let screen = NSScreen.main!.visibleFrame
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.18, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        hideTask?.cancel()
        let t = DispatchWorkItem { panel?.orderOut(nil) }
        hideTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: t)
        NSAccessibility.post(element: p, notification: .announcementRequested, userInfo: [.announcement: text])
    }
}

// MARK: - Schnellnotiz (oben links, immer im Vordergrund, speichert automatisch)

@MainActor final class QuickNote: ObservableObject {
    static let shared = QuickNote()
    func append(_ t: String) { text = text.isEmpty ? t : text + "\n" + t }
    // Mehrere Notizen als Tabs; die alte Einzelnotiz („quickNote“) wird zum ersten Tab
    @Published var notes: [String] = UserDefaults.standard.stringArray(forKey: "quickNotes")
        ?? [UserDefaults.standard.string(forKey: "quickNote") ?? ""] {
        didSet { UserDefaults.standard.set(notes, forKey: "quickNotes") }
    }
    @Published var current = min(UserDefaults.standard.integer(forKey: "quickNoteTab"), (UserDefaults.standard.stringArray(forKey: "quickNotes")?.count ?? 1) - 1) {
        didSet { UserDefaults.standard.set(current, forKey: "quickNoteTab") }
    }
    var text: String {
        get { notes[current] }
        set { notes[current] = newValue }
    }
    func newTab() { notes.append(""); current = notes.count - 1; focusEditor() }
    func closeTab(_ i: Int) {
        guard notes.indices.contains(i) else { return }
        if notes.count == 1 { notes[0] = ""; return }
        notes.remove(at: i)
        if current >= i, current > 0 { current -= 1 }
    }
    // Tab-Titel: erste Zeile mit Text, sonst „Neue Notiz“
    func title(_ i: Int) -> String {
        let line = notes[i].split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? L("Neue Notiz", "New note") : String(line.prefix(18))
    }
    private var panel: KeyPanel?

    func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    func hide() { panel?.orderOut(nil) }

    func show() {
        let p = panel ?? make()
        if !p.isVisible {
            let v = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!).visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: v.minX + 12, y: v.maxY - 12))
        }
        p.orderFrontRegardless()
        p.makeKey()
        if !p.isKeyWindow { // manche Panels nehmen den Fokus nur, wenn WinKomfort kurz vorne ist – du hast sie ja selbst aufgerufen
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        }
        focusEditor()
    }

    // Fokus ins Textfeld, damit man direkt lostippen kann
    func focusEditor() {
        guard let p = panel else { return }
        DispatchQueue.main.async {
            p.contentView?.layoutSubtreeIfNeeded()
            func editor(_ v: NSView) -> NSTextView? {
                if let t = v as? NSTextView, t.isEditable { return t }
                for s in v.subviews { if let e = editor(s) { return e } }
                return nil
            }
            if let content = p.contentView, let e = editor(content) { p.makeFirstResponder(e) }
        }
    }

    private func make() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                         styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating // immer über normalen Fenstern
        p.hidesOnDeactivate = false // bleibt sichtbar, wenn du in eine andere App klickst
        p.isMovableByWindowBackground = true
        p.minSize = NSSize(width: 200, height: 120)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fixedHost(QuickNoteView())
        panel = p
        return p
    }
}

struct QuickNoteView: View {
    @ObservedObject var n = QuickNote.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Tabs oben; ⌘T neuer Tab, ⌘W Tab schließen
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(n.notes.indices, id: \.self) { i in
                                NoteTab(title: n.title(i), selected: i == n.current, closable: n.notes.count > 1,
                                        select: { n.current = i; n.focusEditor() }, close: { askClose(i) })
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: n.current) { _, i in withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(i) } }
                }
                Button { n.newTab() } label: { Image(systemName: "plus") }
                    .keyboardShortcut("t", modifiers: .command)
                    .help(L("Neuer Tab (⌘T)", "New tab (⌘T)")).accessibilityLabel(L("Neuer Tab", "New tab"))
                Button { askClose(n.current) } label: { EmptyView() }
                    .keyboardShortcut("w", modifiers: .command).frame(width: 0).opacity(0).accessibilityHidden(true)
                Button { n.text = "" } label: { Image(systemName: "trash") }
                    .help("Notiz leeren").accessibilityLabel("Notiz leeren").disabled(n.text.isEmpty)
                Button { n.hide() } label: { Image(systemName: "xmark") }
                    .help(tr("Ausblenden") + (HotAction.note.current.map { " (\($0.display))" } ?? "")).accessibilityLabel("Notiz ausblenden")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            TextEditor(text: $n.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityLabel("Notiztext")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
    }

    // Leere Tabs gehen sofort zu, Tabs mit Text erst nach Rückfrage (sonst wäre die Notiz weg)
    private func askClose(_ i: Int) {
        guard n.notes.indices.contains(i) else { return }
        if n.notes[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n.closeTab(i); return }
        let a = NSAlert()
        a.messageText = L("„\(n.title(i))“ schließen?", "Close “\(n.title(i))”?")
        a.informativeText = L("Der Text dieser Notiz wird gelöscht.", "The text of this note will be deleted.")
        a.addButton(withTitle: L("Schließen", "Close"))
        a.addButton(withTitle: L("Abbrechen", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn { n.closeTab(i) }
    }
}

struct NoteTab: View {
    let title: String, selected: Bool, closable: Bool
    let select: () -> Void, close: () -> Void
    @StateObject private var hover = TextBox<Bool>()
    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).font(.callout.weight(selected ? .semibold : .regular))
            if closable && (selected || hover.value == true) {
                Button(action: close) { Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("Tab schließen", "Close tab"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selected ? AnyShapeStyle(.primary.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .onHover { hover.value = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: L("Öffnen", "Open"), select)
    }
}

// MARK: - Fenster anheften (immer im Vordergrund)
// macOS lässt keine App die Ebene fremder Fenster ändern. WinKomfort legt deshalb eine Live-Kopie des Fensters
// (ScreenCaptureKit, nur dieses eine Fenster, höchstens 15 Bilder/s und nur bei Änderungen) in ein eigenes, schwebendes Fenster an dieselbe Stelle.
// Klick darauf → das echte Fenster kommt nach vorne. Wechselst du weg, liegt die Kopie wieder obenauf.

// Nicht öffentlich: erst zur Laufzeit suchen. Fehlt sie in einem künftigen macOS, fällt nur diese Funktion weg – fest eingebunden startete die App nicht mehr
private let axWindowID: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? =
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self) }
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError { axWindowID?(element, id) ?? .failure }
// Antworten fremder Apps nie blind umdeuten
func axPoint(_ v: CFTypeRef) -> CGPoint? { var p = CGPoint.zero; return CFGetTypeID(v) == AXValueGetTypeID() && AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil }
func axSize(_ v: CFTypeRef) -> CGSize? { var s = CGSize.zero; return CFGetTypeID(v) == AXValueGetTypeID() && AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil }

final class PinnedWindow: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let pid: pid_t
    let ax: AXUIElement
    let name: String
    let overlay: NSPanel
    private let surface = CALayer()
    private var stream: SCStream?
    private var size = CGSize.zero
    private var closeObserver: AXObserver?

    init(windowID: CGWindowID, pid: pid_t, ax: AXUIElement, name: String) {
        self.windowID = windowID; self.pid = pid; self.ax = ax; self.name = name
        overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = true
        overlay.level = .floating
        overlay.hidesOnDeactivate = false // sonst verschwindet die Kopie beim App-Wechsel
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ClickView()
        view.wantsLayer = true
        view.layer?.addSublayer(surface)
        surface.contentsGravity = .resize
        // Keine weichen Übergänge: sonst flackert jedes neue Bild und die Kopie „schwimmt“ beim Verschieben
        surface.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // Doppelklick statt Klick: ein versehentlicher Klick soll nicht in einen anderen Space springen
        view.onDoubleClick = { [weak self] in self?.focusReal() }
        view.onRightClick = { [weak self] in MainActor.assumeIsolated { if let self { Pins.shared.remove(self) } } }
        view.toolTip = L("Doppelklick: Original nach vorne · Rechtsklick: lösen", "Double-click: bring original forward · Right-click: unpin")
        overlay.contentView = view
    }

    // Rahmen des echten Fensters in Bildschirmkoordinaten (AppKit: Ursprung unten links)
    func frame() -> NSRect? {
        guard let p = UIAuto.attr(ax, kAXPositionAttribute).flatMap(axPoint), let s = UIAuto.attr(ax, kAXSizeAttribute).flatMap(axSize) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
    }

    // Schließen, Verschieben, Größe, Minimieren und Fensterwechsel innerhalb der App verfolgen
    private func watchWindow() {
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, _, note, ctx in
            guard let ctx else { return }
            let pin = Unmanaged<PinnedWindow>.fromOpaque(ctx).takeUnretainedValue()
            let closed = note as String == kAXUIElementDestroyedNotification
            DispatchQueue.main.async { MainActor.assumeIsolated { closed ? Pins.shared.remove(pin) : pin.update() } }
        }, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowNotes { AXObserverAddNotification(obs, ax, n as CFString, me) }
        for n in Self.appNotes { AXObserverAddNotification(obs, axApp, n as CFString, me) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        closeObserver = obs
    }
    private static let windowNotes = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    private static let appNotes = [kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification]
    private lazy var axApp = AXUIElementCreateApplication(pid)

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw CocoaError(.featureUnsupported) }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: config(for: w.frame.size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try await stream.startCapture()
        self.stream = stream
        size = w.frame.size
        watchWindow()
    }

    private func config(for s: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        c.width = Int(s.width * scale)
        c.height = Int(s.height * scale)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15 Bilder/s reichen und sparen Strom
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true // sonst ist der Schatten mit im Bild und alles verschoben
        c.backgroundColor = .clear
        c.queueDepth = 3
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Nur echte neue Bilder zeichnen – „nichts hat sich geändert“-Frames überspringen (spart Strom)
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = buffer.imageBuffer, let io = CVPixelBufferGetIOSurface(px)?.takeUnretainedValue() else { return }
        surface.contents = io
        if !hasImage { hasImage = true; update(); overlay.invalidateShadow() } // erst mit dem ersten Bild zeigen
    }
    private var hasImage = false

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { Pins.shared.remove(self) } } // Fenster geschlossen o. ä.
    }

    // Kopie an die Stelle des echten Fensters legen und zeigen (wenn dessen App nicht vorne ist)
    func update() {
        guard let f = frame() else { // Fenster gibt es nicht mehr
            DispatchQueue.main.async { MainActor.assumeIsolated { Pins.shared.remove(self) } }
            return
        }
        overlay.setFrame(f, display: true)
        surface.frame = CGRect(origin: .zero, size: f.size)
        if f.size != size, let stream {
            size = f.size
            stream.updateConfiguration(config(for: f.size)) { _ in }
        }
        // Nur verstecken, wenn genau dieses Fenster vorne ist (nicht irgendein anderes derselben App) oder es weggelegt wurde
        var front: CGWindowID = 0
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let w = UIAuto.attr(axApp, kAXFocusedWindowAttribute) {
            _ = _AXUIElementGetWindow(w as! AXUIElement, &front)
        }
        let away = UIAuto.attr(ax, kAXMinimizedAttribute) as? Bool == true || UIAuto.attr(axApp, kAXHiddenAttribute) as? Bool == true
        if front == windowID || away || !hasImage { overlay.orderOut(nil) } else if !overlay.isVisible { overlay.orderFrontRegardless(); overlay.invalidateShadow() }
    }

    func focusReal() {
        // Über die Bedienungshilfen nach vorne holen – macOS lehnt normales Aktivieren aus dem Hintergrund oft ab
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        overlay.orderOut(nil)
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        if let o = closeObserver {
            for n in Self.windowNotes { AXObserverRemoveNotification(o, ax, n as CFString) }
            for n in Self.appNotes { AXObserverRemoveNotification(o, axApp, n as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            closeObserver = nil
        }
        overlay.orderOut(nil)
    }
}

final class ClickView: NSView {
    var onDoubleClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onDoubleClick?() } }
    override func rightMouseUp(with event: NSEvent) { onRightClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class Pins: ObservableObject {
    static let shared = Pins()
    @Published private(set) var pinned: [PinnedWindow] = []
    private var starting: Set<CGWindowID> = []
    private var token: NSObjectProtocol?
    private var quitToken: NSObjectProtocol?

    // ⌃⌘P: vorderstes Fenster anheften bzw. wieder lösen
    func toggleFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let axApp = UIAuto.app(app.bundleIdentifier ?? ""),
              let win = UIAuto.attr(axApp, kAXFocusedWindowAttribute) else {
            Toast.show("Kein Fenster zum Anheften", symbol: "pin.slash"); return
        }
        let ax = win as! AXUIElement
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(ax, &id) == .success, id != 0 else { Toast.show("Fenster nicht erkannt", symbol: "pin.slash"); return }
        if let p = pinned.first(where: { $0.windowID == id }) {
            remove(p)
            Toast.show(tr("%@ gelöst", p.name), symbol: "pin.slash")
            return
        }
        guard !starting.contains(id) else { return } // zweimal schnell gedrückt
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess() // fragt einmal nach „Bildschirmaufnahme“
            Toast.show("Bitte „Bildschirmaufnahme“ für WinKomfort erlauben", symbol: "lock")
            return
        }
        let title = (UIAuto.attr(ax, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Fenster"
        let p = PinnedWindow(windowID: id, pid: app.processIdentifier, ax: ax, name: title)
        starting.insert(id)
        Task { @MainActor in
            defer { starting.remove(id) }
            do {
                try await p.start()
                pinned.append(p)
                observe()
                p.update()
                Toast.show(tr("%@ angeheftet", title), symbol: "pin.fill")
            } catch {
                p.stop()
                Toast.show("Anheften nicht möglich", symbol: "pin.slash")
            }
        }
    }

    func remove(_ p: PinnedWindow) {
        guard pinned.contains(where: { $0 === p }) else { return }
        p.stop()
        pinned.removeAll { $0 === p }
        if pinned.isEmpty {
            for t in [token, quitToken].compactMap({ $0 }) { NSWorkspace.shared.notificationCenter.removeObserver(t) }
            token = nil
            quitToken = nil
        }
    }

    func unpinAll() { pinned.forEach(remove) }

    // Nur bei App-Wechsel reagieren – kein Dauer-Abfragen
    private func observe() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Pins.shared.pinned.forEach { $0.update() } }
        }
        quitToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { Pins.shared.pinned.filter { $0.pid == pid }.forEach { Pins.shared.remove($0) } }
        }
    }
}

// MARK: - Dock zuverlässig einblenden – auch über Vollbild-Apps
// macOS zeigt das Dock erst, wenn man mit der Maus gegen den unteren Rand „drückt“. Bleibt der Zeiger einfach am Rand
// stehen (typisch auf dem Trackpad, vor allem im Vollbild), passiert oft nichts. WinKomfort erkennt das und drückt kurz
// selbst nach – macOS zeigt und versteckt das Dock dann ganz normal. Keine Einstellung wird verändert.

enum DockReveal {
    private static var tap: CFMachPort?
    private static var pushed = false          // schon nachgedrückt, bis die Maus den Rand wieder verlässt
    private static let marker: Int64 = 0x574B  // kennzeichnet eigene Ereignisse, damit sie nicht erneut auslösen
    // Bildschirmränder (Ursprung oben links), neu nur wenn sich Bildschirme ändern
    private struct Edge { let minX, maxX, top, bottom: CGFloat }
    nonisolated(unsafe) private static var edges: [Edge] = []
    private static var screenToken: NSObjectProtocol?
    private static func measureEdges() {
        guard let primary = NSScreen.screens.first else { edges = []; return }
        edges = NSScreen.screens.map { s in let top = primary.frame.maxY - s.frame.maxY; return Edge(minX: s.frame.minX, maxX: s.frame.maxX, top: top, bottom: top + s.frame.height) }
    }

    static func start() {
        afterTrust {
            // nur nötig, wenn das Dock unten sitzt und sich automatisch ausblendet – sonst lauscht WinKomfort gar nicht auf die Maus
            let dock = UserDefaults(suiteName: "com.apple.dock")
            guard tap == nil, (dock?.string(forKey: "orientation") ?? "bottom") == "bottom", dock?.bool(forKey: "autohide") == true else { return }
            measureEdges()
            if screenToken == nil { screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in measureEdges() } }
            let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue) | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                    eventsOfInterest: mask, callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = DockReveal.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else if event.getIntegerValueField(.eventSourceUserData) != DockReveal.marker {
                    DockReveal.check(event.location)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            guard let tap else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    static func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
    }

    // p in Bildschirmkoordinaten mit Ursprung oben links (wie Mausereignisse)
    private static func check(_ p: CGPoint) {
        // nur Zahlen vergleichen: läuft bei jeder Mausbewegung, Bildschirme kommen aus dem Zwischenspeicher
        guard let bottom = edges.first(where: { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.top && p.y <= $0.bottom })?.bottom else { return }
        if p.y < bottom - 30 { pushed = false; return }       // Rand verlassen → nächstes Mal wieder helfen
        guard !pushed, p.y >= bottom - 1, !dockVisible() else { return }
        pushed = true
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<15 { // ~¼ s sanft weiterdrücken, Zeiger bleibt am Rand
                // Immer an der aktuellen Stelle drücken; verlässt der Zeiger den Rand, sofort aufhören (sonst springt er zurück)
                guard let now = CGEvent(source: nil)?.location, now.y >= bottom - 2,
                      let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: now.x, y: bottom - 1), mouseButton: .left) else { return }
                e.setIntegerValueField(.mouseEventDeltaY, value: 6)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
                usleep(16_000)
            }
        }
    }

    // Sichtbares Dock = Dock-Fenster auf Ebene 20 (nur am Rand abgefragt, nicht bei jeder Bewegung)
    private static func dockVisible() -> Bool {
        let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return l.contains { ($0["kCGWindowOwnerName"] as? String) == "Dock" && ($0["kCGWindowLayer"] as? Int) == 20 }
    }
}

// MARK: - Animationen (Tempo der macOS-Animationen, Minimieren-Effekt)

struct AnimSpeed: Identifiable {
    let id: String
    let title: String
    let hint: String
    let domain: String
    let key: String
    let standard: Double      // macOS-Standard in Sekunden
    let range: ClosedRange<Double>
    let restartDock: Bool
}

let animSpeeds = [
    AnimSpeed(id: "dock", title: "Dock ein- und ausblenden", hint: "Wie schnell das Dock hereinfährt.",
              domain: "com.apple.dock", key: "autohide-time-modifier", standard: 0.5, range: 0...1, restartDock: true),
    AnimSpeed(id: "mission", title: "Mission Control", hint: "Öffnen und Schließen der Fensterübersicht.",
              domain: "com.apple.dock", key: "expose-animation-duration", standard: 0.2, range: 0...1, restartDock: true),
    AnimSpeed(id: "resize", title: "Fenster und Dialoge", hint: "Größe ändern, Speichern-Dialoge einblenden. Gilt nach dem Neustart einer App.",
              domain: "NSGlobalDomain", key: "NSWindowResizeTime", standard: 0.2, range: 0.001...0.6, restartDock: false),
    AnimSpeed(id: "quicklook", title: "Übersicht (Leertaste im Finder)", hint: "Aufzoomen der Dateivorschau.",
              domain: "NSGlobalDomain", key: "QLPanelAnimationDuration", standard: 0.2, range: 0...1, restartDock: false),
]

@MainActor final class Animations: ObservableObject {
    static let shared = Animations()
    @Published var speeds: [String: Double] = [:]
    @Published var effect = "genie"
    @Published var windowAnim = true
    @Published var launchBounce = true

    init() { load() }

    func load() {
        for a in animSpeeds {
            speeds[a.id] = Double(defaults("read", Pref(domain: a.domain, key: a.key, on: []))) ?? a.standard
        }
        let e = defaults("read", Pref(domain: "com.apple.dock", key: "mineffect", on: []))
        effect = e.isEmpty ? "genie" : e
        windowAnim = defaults("read", Pref(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", on: [])) != "0"
        launchBounce = defaults("read", Pref(domain: "com.apple.dock", key: "launchanim", on: [])) != "0"
    }

    // Kurz nach der letzten Änderung speichern (Maus, Pfeiltasten oder VoiceOver) – nicht bei jeder Bewegung,
    // sonst würde das Dock dauernd neu starten
    private var pending: [String: DispatchWorkItem] = [:]
    func change(_ a: AnimSpeed, _ v: Double) {
        speeds[a.id] = v
        pending[a.id]?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { Animations.shared.commit(a) } }
        pending[a.id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func commit(_ a: AnimSpeed) {
        guard let v = speeds[a.id] else { return }
        defaults("write", Pref(domain: a.domain, key: a.key, on: []), ["-float", String(format: "%.3f", v)])
        if a.restartDock { sh(["/usr/bin/killall", "Dock"]) }
    }

    func setEffect(_ e: String) {
        effect = e
        defaults("write", Pref(domain: "com.apple.dock", key: "mineffect", on: []), ["-string", e])
        sh(["/usr/bin/killall", "Dock"])
    }

    func setWindowAnim(_ on: Bool) {
        windowAnim = on
        let p = Pref(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", on: [])
        if on { defaults("delete", p) } else { defaults("write", p, ["-bool", "false"]) }
    }

    func setLaunchBounce(_ on: Bool) {
        launchBounce = on
        let p = Pref(domain: "com.apple.dock", key: "launchanim", on: [])
        if on { defaults("delete", p) } else { defaults("write", p, ["-bool", "false"]) }
        sh(["/usr/bin/killall", "Dock"])
    }

    // Alles auf den macOS-Standard zurück
    func reset() {
        for a in animSpeeds { defaults("delete", Pref(domain: a.domain, key: a.key, on: [])) }
        for (d, k) in [("com.apple.dock", "mineffect"), ("com.apple.dock", "launchanim"), ("NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled")] {
            defaults("delete", Pref(domain: d, key: k, on: []))
        }
        sh(["/usr/bin/killall", "Dock"])
        load()
    }
}

struct AnimationTab: View {
    @ObservedObject var m = Animations.shared
    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { m.effect }, set: { m.setEffect($0) })) {
                    Text("Trichter").tag("genie")
                    Text("Skalieren (schnell)").tag("scale")
                    Text("Einsaugen").tag("suck")
                } label: {
                    Text("Minimieren-Effekt")
                    Text("Für den Trichter gibt es keine Tempo-Einstellung – „Skalieren“ ist deutlich schneller.")
                }
                .accessibilityLabel("Minimieren-Effekt")
            }
            Section("Tempo") {
                ForEach(animSpeeds) { a in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { m.speeds[a.id] ?? a.standard }, set: { m.change(a, $0) }), in: a.range)
                                .frame(width: 170)
                                .accessibilityLabel(tr(a.title))
                                .accessibilityValue("\((m.speeds[a.id] ?? a.standard).formatted(.number.precision(.fractionLength(2)))) Sekunden")
                            Text("\((m.speeds[a.id] ?? a.standard).formatted(.number.precision(.fractionLength(2)))) s")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                        }
                    } label: {
                        Text(tr(a.title))
                        Text(tr(a.hint))
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { m.windowAnim }, set: { m.setWindowAnim($0) })) {
                    Text("Fenster mit Animation öffnen")
                    Text("Aus: Fenster erscheinen sofort. Gilt nach dem Neustart einer App.")
                }
                .accessibilityLabel("Fenster mit Animation öffnen")
                Toggle(isOn: Binding(get: { m.launchBounce }, set: { m.setLaunchBounce($0) })) {
                    Text("Apps hüpfen beim Start im Dock")
                }
                .accessibilityLabel("Apps hüpfen beim Start im Dock")
            }
            Section {
                Button("Alles auf macOS-Standard zurücksetzen") { m.reset() }
            }
        }
        .formStyle(.grouped)
        .onAppear { m.load() }
    }
}

// MARK: - Willkommen (einmal beim ersten Start, wie bei Apple-Apps)

struct WelcomeView: View {
    var close: () -> Void
    private let highlights: [(String, Color, String, String)] = [
        ("square.grid.2x2.fill", .blue, "Startmenü", "Control kurz antippen – Apps suchen, Ein/Aus."),
        ("magnifyingglass", .gray, "Suche", tr("Apps, Dateien und Rechnen – mit %@.", HotAction.search.current?.display ?? tr("eigenem Kürzel"))),
        ("macwindow", .indigo, "Fenster wie bei Windows", "Einrasten, anheften, Schließen beendet die App."),
        ("dock.rectangle", .teal, "Dock wie die Taskleiste", "Kommt zuverlässig – auch über Vollbild-Apps."),
        ("folder.fill", .cyan, "Explorer", "Dateimanager im Stil von GNOME, Dolphin oder Windows 11 – mit ⌃⌥E."),
        ("sparkles", .purple, "KI-Assistent", "Fragen, sprechen, Bilder und Dateien verstehen – mit ⌃⌥K. Bleibt auf dem Mac."),
        ("graduationcap.fill", .indigo, "Schule", "Stundenplan, Hausaufgaben, Noten und Lernkarten – mit ⌃⌥S."),
    ]
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88).accessibilityHidden(true)
                .padding(.top, 28)
            Text("Willkommen bei WinKomfort").font(.largeTitle.bold()).padding(.top, 10)
            Text("Windows-Komfort für deinen Mac – sparsam und direkt eingebaut.")
                .foregroundStyle(.secondary).padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(highlights, id: \.2) { h in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: h.0).font(.title2).foregroundStyle(h.1).frame(width: 30).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr(h.2)).font(.headline)
                            Text(tr(h.3)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 24).padding(.horizontal, 44)
            Form {
                Section("Freigaben") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(spacing: 10) {
                            permission("Bedienungshilfen", "Für Startmenü, Ziehen und Fenster-Funktionen.", AXIsProcessTrusted()) {
                                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Divider()
                            permission("Bildschirmaufnahme", "Nur zum Anheften von Fenstern – kann auch später.", CGPreflightScreenCaptureAccess()) {
                                CGRequestScreenCaptureAccess()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 190).padding(.horizontal, 24)
            Button("Los geht’s") { close() }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .padding(.bottom, 24)
        }
        .frame(width: 560)
    }

    private func permission(_ title: String, _ hint: String, _ granted: Bool, _ action: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("Erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Erlauben …", action: action)
            }
        } label: {
            Text(tr(title))
            Text(tr(hint))
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor func openWelcome() {
    if windows["welcome"] == nil {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: WelcomeView { windows["welcome"]?.close() })
        w.center(); stayHere(w)
        windows["welcome"] = w
    }
    UserDefaults.standard.set(true, forKey: "welcomeShown")
    NSApp.activate(ignoringOtherApps: true)
    windows["welcome"]?.makeKeyAndOrderFront(nil)
}

// MARK: - Fenster-Helfer

@MainActor var windows: [String: NSWindow] = [:]

@MainActor func showWindow<V: View>(_ id: String, _ title: String, onClose: (() -> Void)? = nil, _ view: () -> V) {
    let w: NSWindow
    if let existing = windows[id] { w = existing } else {
        w = NSWindow(contentViewController: NSHostingController(rootView: view()))
        w.title = tr(title)
        w.isReleasedWhenClosed = false
        w.center()
        if let onClose {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in onClose() }
        }
        windows[id] = w
    }
    stayHere(w)
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
}

// Globale Tastenkürzel – selbst festlegbar unter Einstellungen → Tastenkürzel
enum HotAction: String, CaseIterable, Identifiable {
    case search, switcher, note, clipboard, pin, snapLeft, snapRight, snapMax, snapRestore, newFile, tasks, onenote, explorer, gameMode, ask, remote, aiText, shelf, school, scan
    var id: UInt32 {
        switch self {
        case .tasks: 1; case .search: 2; case .note: 3; case .pin: 4; case .clipboard: 5
        case .snapLeft: 6; case .snapRight: 7; case .snapMax: 8; case .snapRestore: 9; case .switcher: 10; case .newFile: 12; case .onenote: 13; case .explorer: 14; case .gameMode: 15; case .ask: 16; case .remote: 17; case .aiText: 18; case .shelf: 19; case .school: 20; case .scan: 21
        }
    }
    var title: String {
        switch self {
        case .search: "Suche öffnen"
        case .note: "Schnellnotiz ein-/ausblenden"
        case .pin: "Fenster anheften / lösen"
        case .tasks: "Task-Manager"
        case .clipboard: "Zwischenablage-Verlauf"
        case .switcher: "Fenster wechseln (⇧ dazu: rückwärts)"
        case .newFile: "Neue Textdatei im Finder"
        case .onenote: "OneNote: Seite, Abschnitt oder Notizbuch als PDF"
        case .explorer: "Explorer öffnen"
        case .gameMode: "Game Mode ein/aus"
        case .remote: "Handy-Fernbedienung"
        case .aiText: "KI für markierten Text"
        case .ask: "KI fragen"
        case .shelf: "Ablage ein-/ausblenden"
        case .school: "Schule öffnen"
        case .scan: "Blatt scannen (Desk View)"
        case .snapLeft: "Fenster: linke Hälfte"
        case .snapRight: "Fenster: rechte Hälfte"
        case .snapMax: "Fenster: maximieren"
        case .snapRestore: "Fenster: vorherige Größe / minimieren"
        }
    }
    var standard: Shortcut {
        switch self {
        case .search: Shortcut(code: kVK_Space, mods: optionKey)
        case .note: Shortcut(code: kVK_ANSI_N, mods: controlKey | optionKey, key: "N")
        case .pin: Shortcut(code: kVK_ANSI_P, mods: controlKey | cmdKey, key: "P")
        case .tasks: Shortcut(code: kVK_Escape, mods: controlKey | shiftKey)
        case .switcher: Shortcut(code: kVK_Tab, mods: optionKey)
        case .newFile: Shortcut(code: kVK_ANSI_N, mods: controlKey | optionKey | cmdKey, key: "N")
        case .clipboard: Shortcut(code: kVK_ANSI_V, mods: controlKey | optionKey, key: "V")
        case .onenote: Shortcut(code: kVK_ANSI_P, mods: controlKey | optionKey, key: "P")
        case .explorer: Shortcut(code: kVK_ANSI_E, mods: controlKey | optionKey, key: "E")
        case .gameMode: Shortcut(code: kVK_ANSI_G, mods: controlKey | optionKey, key: "G")
        case .aiText: Shortcut(code: kVK_ANSI_A, mods: controlKey | optionKey, key: "A")
        case .shelf: Shortcut(code: kVK_ANSI_D, mods: controlKey | optionKey, key: "D")
        case .school: Shortcut(code: kVK_ANSI_S, mods: controlKey | optionKey, key: "S")
        case .scan: Shortcut(code: kVK_ANSI_B, mods: controlKey | optionKey, key: "B")
        case .remote: Shortcut(code: kVK_ANSI_R, mods: controlKey | optionKey, key: "R")
        case .ask: Shortcut(code: kVK_ANSI_K, mods: controlKey | optionKey, key: "K")
        case .snapLeft: Shortcut(code: kVK_LeftArrow, mods: controlKey | optionKey)
        case .snapRight: Shortcut(code: kVK_RightArrow, mods: controlKey | optionKey)
        case .snapMax: Shortcut(code: kVK_UpArrow, mods: controlKey | optionKey)
        case .snapRestore: Shortcut(code: kVK_DownArrow, mods: controlKey | optionKey)
        }
    }
    private var storeKey: String { "shortcut.\(rawValue)" }
    // nil = ausgeschaltet
    var current: Shortcut? {
        get {
            guard let d = UserDefaults.standard.data(forKey: storeKey) else { return standard }
            return (try? JSONDecoder().decode(Shortcut?.self, from: d)) ?? standard
        }
        nonmutating set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storeKey) }
    }
    func reset() { UserDefaults.standard.removeObject(forKey: storeKey) }
    @MainActor func perform() {
        switch self {
        case .search: SearchPanel.toggle()
        case .note: QuickNote.shared.toggle()
        case .pin: Pins.shared.toggleFrontmost()
        case .tasks: openTaskManager()
        case .clipboard: ClipPanel.toggle()
        case .switcher: WindowSwitcher.shared.step(1)
        case .newFile: newTextFile()
        case .onenote: OneNotePDF.showMenu()
        case .explorer:
            // Finder vorne → Explorer im selben Ordner öffnen
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
               let dir = NSAppleScript(source: "tell application \"Finder\" to return POSIX path of (insertion location as alias)")?.executeAndReturnError(nil).stringValue {
                openExplorer(URL(fileURLWithPath: dir))
            } else { openExplorer() }
        case .gameMode: GameMode.shared.toggle()
        case .remote: openRemote()
        case .aiText:
            SearchPanel.show()
            SearchModel.shared.query = "/"
        case .ask: AIPanel.toggle()
        case .shelf: Shelf.shared.toggle()
        case .school: School.open()
        case .scan: Scanner.open()
        case .snapLeft: Snap.run(.left)
        case .snapRight: Snap.run(.right)
        case .snapMax: Snap.run(.max)
        case .snapRestore: Snap.run(nil)
        }
    }
}

enum HotKey {
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private(set) static var failed: Set<HotAction> = []
    private(set) static var failedLaunch: Set<UUID> = []
    static let launchBase: UInt32 = 1000 // eigene Kürzel
    static var launchKeys: [UInt32: LaunchKey] {
        MainActor.assumeIsolated { Dictionary(uniqueKeysWithValues: Launcher.shared.keys.enumerated().map { (launchBase + UInt32($0.offset), $0.element) }) }
    }
    static let switchBack: UInt32 = 11 // dasselbe Kürzel mit ⇧: rückwärts blättern

    static func register() {
        // Umstellung von ≤ 1.6: altes Such-Kürzel (⌥/⌘/⌃ + Leertaste) übernehmen
        if let old = UserDefaults.standard.string(forKey: "searchHotkey") {
            let mods = ["opt": optionKey, "cmd": cmdKey, "ctrl": controlKey][old]
            HotAction.search.current = mods.map { Shortcut(code: kVK_Space, mods: $0) }
            UserDefaults.standard.removeObject(forKey: "searchHotkey")
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated {
                if id == HotKey.switchBack { WindowSwitcher.shared.step(-1) } else if id >= HotKey.launchBase { HotKey.launchKeys[id].map { Launcher.shared.perform($0) } }
                else { HotAction.allCases.first { $0.id == id }?.perform() }
            } }
            return noErr
        }, 1, &spec, nil, nil)
        registerAll()
    }

    static func registerAll() {
        unregisterAll()
        for a in HotAction.allCases where Tool.allows(a) {
            guard let s = a.current else { continue }
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(s.code), UInt32(s.mods), EventHotKeyID(signature: OSType(0x574B4654), id: a.id),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs[a.id] = ref } else { failed.insert(a) }
        }
        for (id, k) in launchKeys {
            guard let s = k.shortcut else { continue }
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(s.code), UInt32(s.mods), EventHotKeyID(signature: OSType(0x574B4654), id: id),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs[id] = ref } else { failedLaunch.insert(k.id) }
        }
        if let s = HotAction.switcher.current, s.mods & shiftKey == 0 {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(s.code), UInt32(s.mods | shiftKey), EventHotKeyID(signature: OSType(0x574B4654), id: switchBack),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs[switchBack] = ref }
        }
    }

    // Während der Aufnahme aus – sonst würde das alte Kürzel die Taste wegschnappen
    static func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        failed = []
        failedLaunch = []
    }
}

// Aufnahme eines Kürzels wie in den macOS-Systemeinstellungen
@MainActor final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()
    @Published private(set) var recording: HotAction?
    @Published private(set) var recordingLaunch: UUID?
    @Published private(set) var output = false // true: aufgenommen wird, was gedrückt werden SOLL
    var active: Bool { recording != nil || recordingLaunch != nil }
    @Published var message = ""
    private var monitor: Any?

    func start(_ a: HotAction) { stop(); recording = a; listen() }
    func start(launch id: UUID, output: Bool = false) { stop(); recordingLaunch = id; self.output = output; listen() }

    private func listen() {
        message = ""
        HotKey.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { ShortcutRecorder.shared.handle(e) }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = nil
        recordingLaunch = nil
        output = false
        HotKey.registerAll()
    }

    private func handle(_ e: NSEvent) {
        guard active else { return }
        let a = recording, launch = recordingLaunch
        let set = { (s: Shortcut?) in if let a { a.current = s } else if let launch { Launcher.shared.setShortcut(launch, s, output: ShortcutRecorder.shared.output) } }
        let f = e.modifierFlags
        if f.intersection([.command, .control, .option]).isEmpty {
            if e.keyCode == 53 { stop(); return }                                   // Esc: abbrechen
            if e.keyCode == 51 || e.keyCode == 117 { set(nil); stop(); return } // ⌫: Kürzel aus
        }
        var mods = 0
        if f.contains(.command) { mods |= cmdKey }
        if f.contains(.control) { mods |= controlKey }
        if f.contains(.option) { mods |= optionKey }
        if f.contains(.shift) { mods |= shiftKey }
        let s = Shortcut(code: Int(e.keyCode), mods: mods, key: e.charactersIgnoringModifiers)
        if output { // beim Ziel ist jede Taste erlaubt, nur kein eigenes Kürzel (sonst dreht es sich im Kreis)
            if Launcher.shared.keys.contains(where: { $0.shortcut.map { $0.code == s.code && $0.mods == s.mods } == true }) { NSSound.beep(); message = L("Das ist selbst ein eigenes Kürzel.", "That is a custom shortcut itself."); return }
            set(s); stop(); return
        }
        guard s.isValid else { NSSound.beep(); message = tr("Bitte mit ⌘, ⌃ oder ⌥ kombinieren."); return }
        if let other = HotAction.allCases.first(where: { $0 != a && $0.current?.code == s.code && $0.current?.mods == s.mods }) {
            NSSound.beep(); message = tr("Schon vergeben an „%@“.", tr(other.title)); return
        }
        if Launcher.shared.keys.contains(where: { $0.output.map { $0.code == s.code && $0.mods == s.mods } == true }) {
            NSSound.beep(); message = L("Das ist schon das Ziel eines umgelegten Kürzels.", "That is already the target of a remapped shortcut."); return
        }
        if let other = Launcher.shared.keys.first(where: { $0.id != launch && $0.shortcut?.code == s.code && $0.shortcut?.mods == s.mods }) {
            NSSound.beep(); message = tr("Schon vergeben an „%@“.", Launcher.shared.title(other)); return
        }
        set(s)
        stop()
        if a.map(HotKey.failed.contains) == true || launch.map(HotKey.failedLaunch.contains) == true { message = tr("%@ ist schon von macOS oder einer anderen App belegt.", s.display) }
    }
}

struct ShortcutsTab: View {
    @ObservedObject var r = ShortcutRecorder.shared
    var body: some View {
        Form {
            LauncherSection()
            Section {
                ForEach(HotAction.allCases) { a in
                    LabeledContent(tr(a.title)) {
                        HStack(spacing: 8) {
                            Button {
                                if r.recording == a { r.stop() } else { r.start(a) }
                            } label: {
                                Text(r.recording == a ? tr("Kürzel drücken …") : (a.current?.display ?? tr("Aus")))
                                    .frame(minWidth: 120)
                                    .foregroundStyle(r.recording == a ? Color.accentColor : (a.current == nil ? .secondary : .primary))
                            }
                            .accessibilityLabel("\(tr(a.title)): \(a.current?.display ?? tr("aus"))")
                            .accessibilityHint("Klicken und neue Tastenkombination drücken")
                            Button { a.reset(); HotKey.registerAll(); r.message = "" } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.borderless)
                                .help("Auf Standard (\(a.standard.display)) zurücksetzen")
                                .accessibilityLabel("\(tr(a.title)) auf Standard zurücksetzen")
                                .disabled(a.current == a.standard)
                        }
                    }
                }
            } footer: {
                Text(r.message.isEmpty ? tr("Klicken, dann die neue Kombination drücken. Esc bricht ab, ⌫ schaltet das Kürzel aus.") : r.message)
                    .foregroundStyle(r.message.isEmpty ? Color.secondary : Color.red)
            }
            Section {
                LabeledContent("Startmenü") { Text("Control kurz antippen").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onDisappear { if r.active { r.stop() } }
    }
}

// MARK: - Finder wie der Explorer: ⌘X schneidet Dateien aus, ⌘V verschiebt sie

enum FinderCut {
    private static var tap: CFMachPort?
    private static var cutChange: Int?   // Zwischenablage-Stand direkt nach ⌘X

    static func start(prompt: Bool = false) {
        afterTrust(prompt: prompt) {
            guard tap == nil, isOn(features.first { $0.id == "cut" }!) else { return }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = FinderCut.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else if type == .keyDown { FinderCut.handle(event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            guard let tap else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    static func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
        cutChange = nil
    }

    // Nur ⌘X / ⌘V im Finder, und nicht beim Umbenennen oder in der Suche (dort bleibt es Text ausschneiden/einfügen)
    private static func handle(_ e: CGEvent) {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        guard code == 7 || code == 9,
              e.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder", !editingText() else { return }
        if code == 7 { // ⌘X → Finder kopiert (⌘C), WinKomfort merkt sich: das war Ausschneiden
            e.setIntegerValueField(.keyboardEventKeycode, value: 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                cutChange = NSPasteboard.general.changeCount
                MainActor.assumeIsolated { Toast.show("Ausgeschnitten – mit ⌘V verschieben", symbol: "scissors") }
            }
        } else if let c = cutChange, c == NSPasteboard.general.changeCount { // ⌘V nach ⌘X → verschieben (⌥⌘V)
            e.flags.insert(.maskAlternate)
            cutChange = nil
        }
    }

    private static func editingText() -> Bool {
        guard let f = UIAuto.attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox"].contains(UIAuto.role(f as! AXUIElement) ?? "")
    }
}

// Neue Textdatei im offenen Finder-Ordner (wie „Neu › Textdokument“ im Explorer), direkt zum Umbenennen
@MainActor func newTextFile() {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
        Toast.show("Im Finder benutzen", symbol: "doc.badge.plus"); return
    }
    var err: NSDictionary?
    guard let dir = NSAppleScript(source: "tell application \"Finder\" to return POSIX path of (insertion location as alias)")?
            .executeAndReturnError(&err).stringValue else {
        Toast.show("Bitte erlauben, dass WinKomfort den Finder steuert", symbol: "lock"); return
    }
    var url = URL(fileURLWithPath: dir).appendingPathComponent(tr("Neue Textdatei") + ".txt")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = URL(fileURLWithPath: dir).appendingPathComponent(tr("Neue Textdatei") + " \(n).txt")
        n += 1
    }
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        Toast.show("Hier darf keine Datei angelegt werden", symbol: "exclamationmark.triangle"); return
    }
    let p = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    NSAppleScript(source: "tell application \"Finder\" to select (POSIX file \"\(p)\" as alias)")?.executeAndReturnError(&err)
    // ↩ startet im Finder das Umbenennen – nur, wenn der Finder noch vorne ist
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) }
    }
}

// MARK: - OneNote: Seite, Abschnitt oder Notizbuch als eine PDF
// OneNote für Mac kann nur die aktuelle Seite als PDF sichern. WinKomfort klickt deshalb jede Seite an, nutzt
// „Save As PDF“, tippt einen eindeutigen Dateinamen ein und fügt am Ende alles zu einer PDF in „Downloads“ zusammen.
// shortcut: hängt an OneNotes Bedienstruktur („List of Pages“, Menü „Save As PDF“) – nach OneNote-Updates nachtesten

enum OneNotePDF {
    enum Scope { case page, section, notebook }
    static let bundle = "com.microsoft.onenote.mac"
    private static var running = false
    private static let saveTitles: Set<String> = ["Save As PDF", "Als PDF speichern"]
    private static let saveButtons: Set<String> = ["Save", "Sichern", "Speichern"]

    @MainActor static func showMenu() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else {
            Toast.show("In OneNote benutzen", symbol: "doc.richtext"); return
        }
        guard !running else { Toast.show("PDF wird schon erstellt …", symbol: "hourglass"); return }
        guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; return }
        let menu = NSMenu()
        for (title, scope) in [("Diese Seite als PDF", Scope.page), ("Ganzen Abschnitt als PDF", .section), ("Ganzes Notizbuch als PDF", .notebook)] {
            let item = NSMenuItem(title: tr(title), action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
            item.target = MenuTarget.shared
            item.representedObject = scope
            menu.addItem(item)
        }
        let onenote = NSWorkspace.shared.frontmostApplication
        NSApp.activate() // sonst zeigt macOS das Menü einer Hintergrund-App nicht
        if !menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) { onenote?.activate() } // abgebrochen: zurück zu OneNote
    }

    private final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @MainActor @objc func run(_ sender: NSMenuItem) {
            guard let scope = sender.representedObject as? Scope else { return }
            OneNotePDF.start(scope)
        }
    }

    // Auch für KI-Befehle und Links: erst Cloud (Hintergrund), sonst Notbehelf über OneNote selbst
    @MainActor static func start(_ scope: Scope) {
        guard !running else { Toast.show(L("PDF wird schon erstellt …", "Already creating a PDF…"), symbol: "hourglass"); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first != nil else {
            Toast.show(L("OneNote ist nicht geöffnet", "OneNote isn't open"), symbol: "doc.richtext"); return
        }
        do {
            OneNotePDF.running = true
            DispatchQueue.global(qos: .userInitiated).async {
                // Bevorzugt: Original-Dateien aus der Cloud – schnell, im Hintergrund, ohne OneNote zu bedienen
                if let target = OneNoteCloud.target(scope) {
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        Toast.show(L("OneNote-PDF wird im Hintergrund erstellt", "Creating OneNote PDF in the background"), symbol: "doc.richtext")
                        Task { @MainActor in
                            let r = await OneNoteCloud.export(scope, target)
                            OneNotePDF.running = false
                            switch r {
                            case .success(let url):
                                Toast.show(L("PDF gespeichert: \(url.lastPathComponent)", "PDF saved: \(url.lastPathComponent)"), symbol: "checkmark.circle")
                                FolderHandler.revealInFinder([url])
                            case .failure(let e): Toast.show(e.text, symbol: "exclamationmark.triangle")
                            }
                        }
                    } }
                    return
                }
                // Notbehelf (z. B. Notizbuch nur auf dem Mac): Seiten in OneNote einzeln sichern
                DispatchQueue.main.async { MainActor.assumeIsolated { Toast.show(L("PDF wird erstellt – bitte OneNote nicht bedienen", "Creating PDF – please don't use OneNote"), symbol: "doc.richtext") } }
                let result = OneNotePDF.export(scope)
                DispatchQueue.main.async {
                    OneNotePDF.running = false
                    switch result {
                    case .success(let url):
                        Toast.show(L("PDF gespeichert: \(url.lastPathComponent)", "PDF saved: \(url.lastPathComponent)"), symbol: "checkmark.circle")
                        FolderHandler.revealInFinder([url])
                    case .failure(let e): Toast.show(e.text, symbol: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    struct Failure: Error { let text: String; var retry = false }

    // Selbstreparatur beim Start: Zwischendateien eines abgebrochenen Exports (z. B. bei einem Update) entfernen
    static func cleanLeftovers() {
        let fm = FileManager.default
        for d in [FileManager.SearchPathDirectory.documentDirectory, .desktopDirectory, .downloadsDirectory] {
            guard let dir = fm.urls(for: d, in: .userDomainMask).first,
                  let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for f in files where f.hasPrefix("WinKomfort-") && f.hasSuffix(".pdf") && f.range(of: #"^WinKomfort-[0-9A-F]{8}-\d{4}b?\.pdf$"#, options: .regularExpression) != nil {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        // Zwischenordner von OneNote-Umwandlungen (nach einem Absturz oder Update liegen gebliebene)
        let tmp = fm.temporaryDirectory
        for f in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where f.hasPrefix("WinKomfort-OneNote-") {
            try? fm.removeItem(at: tmp.appendingPathComponent(f))
        }
        // OneNote-Zwischenspeicher: Abschnitte, die 30 Tage nicht exportiert wurden, wieder freigeben
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("de.winkomfort.app/OneNote")
        let old = Date().addingTimeInterval(-30 * 86400)
        for case let f as URL in fm.enumerator(at: cache, includingPropertiesForKeys: [.contentAccessDateKey, .isRegularFileKey]) ?? FileManager.DirectoryEnumerator() {
            guard let v = try? f.resourceValues(forKeys: [.contentAccessDateKey, .isRegularFileKey]), v.isRegularFile == true,
                  (v.contentAccessDate ?? .distantPast) < old else { continue }
            try? fm.removeItem(at: f)
        }
    }

    private static func outline(_ win: AXUIElement, _ name: String) -> AXUIElement? {
        UIAuto.elements(win, windowsOnly: false).first { UIAuto.role($0) == "AXOutline" && UIAuto.label($0) == name }
    }
    private static func rows(_ o: AXUIElement) -> [AXUIElement] { UIAuto.attr(o, kAXRowsAttribute) as? [AXUIElement] ?? [] }
    private static func selected(_ o: AXUIElement) -> AXUIElement? { rows(o).first { UIAuto.attr($0, kAXSelectedAttribute) as? Bool == true } }
    private static func select(_ o: AXUIElement, _ row: AXUIElement) {
        AXUIElementSetAttributeValue(o, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
    }
    private static func isFront(_ pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    static func export(_ scope: Scope) -> Result<URL, Failure> {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              let ax = UIAuto.app(bundle),
              let win = UIAuto.attr(ax, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              let pages = outline(win, "List of Pages"), let sections = outline(win, "List of Sections") else {
            return .failure(Failure(text: L("OneNote-Seitenliste nicht gefunden – Seitenliste einblenden", "OneNote page list not found – show the page list")))
        }
        let pid = app.processIdentifier
        app.activate() // das Menü von WinKomfort kann den Fokus kurz genommen haben
        usleep(300_000)
        let origSection = selected(sections), origPage = selected(pages)
        defer { // Auswahl wiederherstellen
            if let origSection, scope == .notebook { select(sections, origSection); usleep(800_000) }
            if let origPage { select(pages, origPage) }
        }
        // Welche Abschnitte: beim Notizbuch erst alle Abschnittsgruppen aufklappen; Gruppen-Zeilen selbst haben keine Seiten
        if scope == .notebook {
            for _ in 0..<3 { // verschachtelte Gruppen: mehrmals, bis nichts Neues mehr aufgeht
                let closed = rows(sections).filter { UIAuto.attr($0, kAXDisclosingAttribute) as? Bool == false }
                closed.forEach { AXUIElementSetAttributeValue($0, kAXDisclosingAttribute as CFString, kCFBooleanTrue) }
                usleep(300_000)
                if rows(sections).filter({ UIAuto.attr($0, kAXDisclosingAttribute) as? Bool == false }).count == closed.count { break }
            }
        }
        let sectionRows: [AXUIElement?] = scope == .notebook
            ? rows(sections).filter { ((UIAuto.attr($0, kAXDisclosedRowsAttribute) as? [AXUIElement]) ?? []).isEmpty }
            : [nil]
        let token = UUID().uuidString.prefix(8)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("WinKomfort-OneNote-\(token)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        guard let bar = UIAuto.attr(ax, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
              let menuItem = UIAuto.elements(bar, windowsOnly: false).first(where: { saveTitles.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }) else {
            return .failure(Failure(text: L("OneNote-Menü „Save As PDF“ nicht gefunden", "OneNote menu “Save As PDF” not found")))
        }
        var parts: [URL] = []
        for (si, sec) in sectionRows.enumerated() {
            if let sec {
                // Warten, bis OneNote die Seiten des neuen Abschnitts zeigt (statt fester Pause)
                let before = pageSignature(pages)
                select(sections, sec)
                for _ in 0..<50 { usleep(40_000); if pageSignature(pages) != before { break } }
                usleep(100_000)
            }
            let list = scope == .page ? [origPage].compactMap { $0 } : rows(pages)
            for (pi, row) in list.enumerated() {
                if scope != .page {
                    select(pages, row)
                    for _ in 0..<25 where UIAuto.attr(row, kAXSelectedAttribute) as? Bool != true { usleep(20_000) }
                    usleep(120_000)
                }
                let text = scope == .notebook
                    ? L("Abschnitt \(si + 1)/\(sectionRows.count) · Seite \(pi + 1)/\(list.count)", "Section \(si + 1)/\(sectionRows.count) · page \(pi + 1)/\(list.count)")
                    : L("Seite \(pi + 1) von \(list.count)", "Page \(pi + 1) of \(list.count)")
                DispatchQueue.main.async { Toast.show(text, symbol: "doc.richtext") }
                let dest = work.appendingPathComponent(String(format: "%05d.pdf", parts.count))
                let unique = "WinKomfort-\(token)-\(String(format: "%04d", parts.count))"
                var r = savePage(ax: ax, pid: pid, item: menuItem, main: win, to: dest, uniqueName: unique)
                if case .failure(let e) = r, e.retry { r = savePage(ax: ax, pid: pid, item: menuItem, main: win, to: dest, uniqueName: unique + "b") }
                switch r {
                case .success(let url): parts.append(url)
                case .failure(let e): return .failure(e)
                }
            }
        }
        guard !parts.isEmpty else { return .failure(Failure(text: L("Keine Seiten gefunden", "No pages found"))) }
        DispatchQueue.main.async { Toast.show(L("PDF wird zusammengefügt …", "Combining PDF…"), symbol: "doc.on.doc") }
        let out = PDFDocument()
        for p in parts { if let d = PDFDocument(url: p) { for i in 0..<d.pageCount { if let pg = d.page(at: i) { out.insert(pg, at: out.pageCount) } } } }
        let title = (UIAuto.attr(win, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "OneNote"
        let base = scope == .notebook ? title : (UIAuto.label(selected(sections).flatMap { UIAuto.elements($0, windowsOnly: false).first { !UIAuto.label($0).isEmpty } } ?? win))
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = downloads.appendingPathComponent("\(clean).pdf"), n = 2
        while fm.fileExists(atPath: url.path) { url = downloads.appendingPathComponent("\(clean) \(n).pdf"); n += 1 }
        guard out.write(to: url) else { return .failure(Failure(text: L("PDF konnte nicht gespeichert werden", "Couldn't save the PDF"))) }
        return .success(url)
    }

    private static func pageSignature(_ o: AXUIElement) -> String {
        let r = rows(o)
        let first = r.first.flatMap { UIAuto.elements($0, windowsOnly: false).lazy.compactMap { UIAuto.attr($0, kAXTitleAttribute) as? String }.first { !$0.isEmpty } } ?? ""
        return "\(r.count)|\(first)"
    }

    private static let dirs: [URL] = [FileManager.SearchPathDirectory.documentDirectory, .desktopDirectory, .downloadsDirectory]
        .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    private static func pdfs() -> [URL: Set<String>] {
        Dictionary(uniqueKeysWithValues: dirs.map { d in
            (d, Set(((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.lowercased().hasSuffix(".pdf") }))
        })
    }
    private static let replaceButtons: Set<String> = ["Replace", "Ersetzen"]
    private static let cancelButtons: Set<String> = ["Cancel", "Abbrechen"]

    // Eine Seite über „Save As PDF“ sichern. OneNote vergibt den Namen (Seitentitel); die neue Datei wird sofort
    // in den Arbeitsordner verschoben. Nur wenn es den Namen schon gibt, wird ein eindeutiger Name eingetippt – nie ersetzt.
    private static func savePage(ax: AXUIElement, pid: pid_t, item: AXUIElement, main: AXUIElement, to dest: URL, uniqueName: String) -> Result<URL, Failure> {
        let abort = Failure(text: L("Abgebrochen – OneNote war nicht mehr vorne", "Stopped – OneNote was no longer in front"))
        let fm = FileManager.default
        guard isFront(pid) else { return .failure(abort) }
        UIAuto.press(item)
        // Der Dialog ist das neue fokussierte Fenster – nur ihn durchsuchen (das Hauptfenster ist riesig)
        var dialog: AXUIElement?, save: AXUIElement?
        for _ in 0..<250 where save == nil {
            usleep(20_000)
            guard let w = UIAuto.attr(ax, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }), !CFEqual(w, main) else { continue }
            dialog = w
            save = UIAuto.elements(w, windowsOnly: false).first { UIAuto.role($0) == "AXButton" && saveButtons.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }
        }
        guard let save, let dialog else { return .failure(Failure(text: L("Speichern-Dialog von OneNote kam nicht", "OneNote's save dialog didn't appear"), retry: true)) }
        // Bei Fehlschlag den Dialog schließen, damit OneNote sauber bleibt
        func cancelDialog() {
            if let c = UIAuto.elements(dialog, windowsOnly: false).last(where: { UIAuto.role($0) == "AXButton" && cancelButtons.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }) { UIAuto.press(c) }
        }
        let before = pdfs()
        usleep(60_000) // der Dialog ignoriert „Sichern“, solange er noch aufgebaut wird
        guard isFront(pid) else { cancelDialog(); return .failure(abort) }
        UIAuto.press(save)
        var found: URL?, last = -1, typed = false
        for i in 0..<750 { // bis 15 s (große Seiten mit vielen Bildern)
            usleep(20_000)
            // „Sichern“ wurde verschluckt: Dialog noch offen, keine Datei, keine Rückfrage → erneut drücken
            if found == nil, i % 50 == 49, UIAuto.role(save) != nil, replaceCancel(dialog) == nil {
                guard isFront(pid) else { cancelDialog(); return .failure(abort) }
                UIAuto.press(save)
            }
            if found == nil {
                for (d, names) in pdfs() { if let n = names.subtracting(before[d] ?? []).first { found = d.appendingPathComponent(n) } }
            }
            if let f = found {
                let size = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? Int ?? 0
                if size > 0, size == last, UIAuto.role(save) == nil, PDFDocument(url: f) != nil {
                    do { try fm.moveItem(at: f, to: dest); return .success(dest) }
                    catch { return .failure(Failure(text: error.localizedDescription)) }
                }
                last = size
                continue
            }
            // Datei gibt es schon → Dialog fragt „Ersetzen?“: abbrechen und eindeutigen Namen tippen
            if !typed, i % 10 == 9, let cancel = replaceCancel(dialog) {
                UIAuto.press(cancel)
                usleep(150_000)
                guard isFront(pid) else { cancelDialog(); return .failure(abort) }
                typeText(uniqueName, selectAll: true)
                usleep(120_000)
                guard isFront(pid) else { cancelDialog(); return .failure(abort) }
                UIAuto.press(save)
                typed = true
            }
        }
        cancelDialog()
        return .failure(Failure(text: L("PDF nicht gefunden – im Speichern-Dialog einmal „Dokumente“ wählen", "PDF not found – pick “Documents” once in the save dialog")))
    }

    private static func replaceCancel(_ dialog: AXUIElement) -> AXUIElement? {
        let els = UIAuto.elements(dialog, windowsOnly: false)
        guard els.contains(where: { replaceButtons.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }) else { return nil }
        return els.last { UIAuto.role($0) == "AXButton" && cancelButtons.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }
    }

    private static func typeText(_ text: String, selectAll: Bool) {
        if selectAll {
            for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down); e?.flags = .maskCommand; e?.post(tap: .cghidEventTap) }
            usleep(50_000)
        }
        let chars = Array(text.utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            if down { e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars) }
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Fenster-Umschalter mit Vorschau (wie Alt-Tab unter Windows)

struct SwitchWin: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let icon: NSImage
    var thumb: CGImage?
}

@MainActor final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()
    @Published var wins: [SwitchWin] = []
    @Published var selected = 0
    private var panel: KeyPanel?
    private var timer: Timer?
    private var active = false
    private var shown = false
    private var hold: CGEventFlags = []
    private static let cols = 6, cardW: CGFloat = 216, cardH: CGFloat = 176

    // Erster Druck: Liste holen, das vorige Fenster wählen. Weitere Drücke (Taste gehalten): weiterblättern
    func step(_ d: Int) {
        if active {
            selected = (selected + d + wins.count) % wins.count
            if !shown { show() }
            return
        }
        guard AXIsProcessTrusted() else {
            afterTrust(prompt: true) {}
            Toast.show("Bitte „Bedienungshilfen“ für WinKomfort erlauben", symbol: "lock"); return
        }
        wins = Self.list()
        guard wins.count > 1 else { NSSound.beep(); return }
        active = true
        selected = d > 0 ? 1 : wins.count - 1
        let m = HotAction.switcher.current?.mods ?? 0
        hold = []
        if m & optionKey != 0 { hold.insert(.maskAlternate) }
        if m & cmdKey != 0 { hold.insert(.maskCommand) }
        if m & controlKey != 0 { hold.insert(.maskControl) }
        // Loslassen der Taste erkennen: nur solange der Umschalter offen ist, alle 30 ms eine Zahl lesen
        let t = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = WindowSwitcher.shared
                if !CGEventSource.flagsState(.combinedSessionState).isSuperset(of: s.hold) { s.commit() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Kurz getippt = sofort wechseln ohne Aufblitzen; erst beim Halten erscheint die Übersicht
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated { let s = WindowSwitcher.shared; if s.active && !s.shown { s.show() } }
        }
        loadThumbs()
    }

    func commit() {
        guard active, wins.indices.contains(selected) else { finish(); return }
        let w = wins[selected]
        finish()
        // Erst nachdem die Übersicht weg ist – sonst gibt macOS den Fokus beim Schließen ans alte Fenster zurück
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { Self.raise(w) }
    }

    private static func raise(_ w: SwitchWin) {
        let axApp = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(axApp, 1)
        let all = UIAuto.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let win = all.first(where: { var id: CGWindowID = 0; return _AXUIElementGetWindow($0, &id) == .success && id == w.id }) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        active = false
        shown = false
        panel?.orderOut(nil)
    }

    // Sichtbare Fenster normaler Apps, vorderstes zuerst (so liefert macOS die Liste)
    private static func list() -> [SwitchWin] {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [SwitchWin] = []
        for w in infos {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: bd),
                  b.width >= 120, b.height >= 80,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            let name = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Fenster"
            out.append(SwitchWin(id: id, pid: pid, title: name, icon: app.icon ?? NSImage(), thumb: nil))
            if out.count == 18 { break } // 3 Reihen à 6
        }
        return out
    }

    // Vorschaubilder nur, wenn „Bildschirmaufnahme“ schon erlaubt ist (sonst App-Symbole) – nie extra nachfragen
    private func loadThumbs() {
        guard CGPreflightScreenCaptureAccess() else { return }
        let ids = wins.map(\.id)
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for sw in content.windows where ids.contains(sw.windowID) {
                Task { @MainActor in
                    let cfg = SCStreamConfiguration()
                    let scale = min(400 / max(sw.frame.width, 1), 250 / max(sw.frame.height, 1))
                    cfg.width = max(Int(sw.frame.width * scale), 1)
                    cfg.height = max(Int(sw.frame.height * scale), 1)
                    cfg.showsCursor = false
                    guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw),
                                                                                configuration: cfg),
                          self.active, let i = self.wins.firstIndex(where: { $0.id == sw.windowID }) else { return }
                    self.wins[i].thumb = img
                }
            }
        }
    }

    private func show() {
        let p = panel ?? make()
        let cols = min(wins.count, Self.cols), rows = (wins.count + Self.cols - 1) / Self.cols
        let size = NSSize(width: CGFloat(cols) * Self.cardW + 24, height: CGFloat(rows) * Self.cardH + 24)
        let m = NSEvent.mouseLocation
        let v = (NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!).visibleFrame
        p.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        p.makeKey()
        shown = true
    }

    private func make() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fixedHost(SwitcherView())
        // ←/→ blättern, ↩ wechseln, Esc abbrechen
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard WindowSwitcher.shared.panel?.isKeyWindow == true else { return e }
            return MainActor.assumeIsolated {
                let s = WindowSwitcher.shared
                switch e.keyCode {
                case 53: s.finish()
                case 36, 76: s.commit()
                case 123: s.step(-1)
                case 124: s.step(1)
                default: return e
                }
                return nil
            }
        }
        panel = p
        return p
    }
}

struct SwitcherView: View {
    @ObservedObject var s = WindowSwitcher.shared
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 16), count: min(max(s.wins.count, 1), 6)), spacing: 12) {
            ForEach(Array(s.wins.enumerated()), id: \.element.id) { i, w in
                let on = i == s.selected
                Button { s.selected = i; s.commit() } label: {
                    VStack(spacing: 8) {
                        Group {
                            if let t = w.thumb { Image(decorative: t, scale: 2).resizable().scaledToFit() }
                            else { Image(nsImage: w.icon).resizable().frame(width: 64, height: 64) }
                        }
                        .frame(width: 184, height: 115)
                        HStack(spacing: 6) {
                            Image(nsImage: w.icon).resizable().frame(width: 16, height: 16)
                            Text(w.title).font(.callout).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(maxWidth: 184)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(on ? 0.12 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: on ? 2.5 : 0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(w.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Fenster per Tastatur einrasten (wie Windows-Taste + Pfeile)

@MainActor enum Snap {
    private static var saved: [CGWindowID: CGRect] = [:] // Größe vor dem ersten Einrasten, je Fenster

    // nil = zurück zur vorherigen Größe; war das Fenster nicht eingerastet, minimieren (wie Windows)
    static func run(_ d: SnapMath.Dir?) {
        guard AXIsProcessTrusted() else {
            afterTrust(prompt: true) {}
            Toast.show("Bitte „Bedienungshilfen“ für WinKomfort erlauben", symbol: "lock"); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        guard let w = UIAuto.attr(axApp, kAXFocusedWindowAttribute), let frame = frame(w as! AXUIElement) else { NSSound.beep(); return }
        let win = w as! AXUIElement
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(win, &id)
        guard let d else {
            if let old = saved.removeValue(forKey: id) { set(win, old) }
            else { AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            return
        }
        if saved[id] == nil { saved[id] = frame }
        let primaryH = NSScreen.screens[0].frame.height
        let center = CGPoint(x: frame.midX, y: primaryH - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main!
        set(win, SnapMath.target(d, in: SnapMath.toAX(screen.visibleFrame, primaryHeight: primaryH)))
    }

    // Fenster auf einen Bruchteil des Bildschirms legen (0…1, oben links = 0,0)
    static func place(_ f: CGRect) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let w = UIAuto.attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute), let old = frame(w as! AXUIElement) else { NSSound.beep(); return }
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(w as! AXUIElement, &id)
        if saved[id] == nil { saved[id] = old }
        let h = NSScreen.screens[0].frame.height, c = CGPoint(x: old.midX, y: h - old.midY)
        let v = SnapMath.toAX((NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main!).visibleFrame, primaryHeight: h)
        set(w as! AXUIElement, SnapMath.fraction(f, in: v))
    }

    private static func frame(_ w: AXUIElement) -> CGRect? {
        guard let pos = UIAuto.attr(w, kAXPositionAttribute).flatMap(axPoint), let size = UIAuto.attr(w, kAXSizeAttribute).flatMap(axSize) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // Größe, Position, Größe: manche Apps begrenzen die Größe je nach Position
    private static func set(_ w: AXUIElement, _ r: CGRect) {
        var pos = r.origin, size = r.size
        let s = AXValueCreate(.cgSize, &size)!, p = AXValueCreate(.cgPoint, &pos)!
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
    }
}

// MARK: - Zwischenablage-Verlauf (wie Windows + V) – nur im Arbeitsspeicher

struct ClipItem: Identifiable {
    let id = UUID()
    let text: String?
    let image: NSImage?
}

@MainActor final class ClipHistory: ObservableObject {
    static let shared = ClipHistory()
    @Published private(set) var items: [ClipItem] = []
    @Published var selected = 0
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    // So markieren Passwort-Manager Geheimes (nspasteboard.org) – das wird nie gespeichert
    private static let secret: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                              "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    var enabled: Bool { UserDefaults.standard.object(forKey: "clipHistory") as? Bool ?? true }

    // macOS meldet neue Kopien nicht – nur eine Zahl abfragen kostet praktisch nichts
    func start() {
        timer?.invalidate()
        timer = nil
        guard enabled else { clear(); return }
        lastCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.7, repeats: true) { _ in MainActor.assumeIsolated { ClipHistory.shared.poll() } }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func clear() { items = []; selected = 0 }
    func skipCurrent() { lastCount = NSPasteboard.general.changeCount } // eigene, kurz kopierte Inhalte nicht merken

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard Set((pb.types ?? []).map(\.rawValue)).isDisjoint(with: Self.secret) else { return }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.removeAll { $0.text == s }
            items.insert(ClipItem(text: s, image: nil), at: 0)
        } else if pb.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]),
                  let img = NSImage(pasteboard: pb) {
            items.insert(ClipItem(text: nil, image: img), at: 0)
        } else { return }
        var texts = 0, images = 0
        items = items.filter { $0.image != nil ? { images += 1; return images <= 10 }() : { texts += 1; return texts <= 50 }() }
    }

    func remove(at i: Int) {
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        selected = min(selected, max(items.count - 1, 0))
    }

    // In die App einfügen, die vorne ist: Eintrag in die Zwischenablage legen, dann ⌘V schicken
    func paste(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items.remove(at: i)
        items.insert(item, at: 0)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = item.text { pb.setString(t, forType: .string) } else if let img = item.image { pb.writeObjects([img]) }
        lastCount = pb.changeCount
        ClipPanel.hide()
        Self.pressPaste()
    }
    static func pressPaste() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}

@MainActor enum ClipPanel {
    private static var panel: KeyPanel?
    private static let size = NSSize(width: 380, height: 440)

    static func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    static func hide() { panel?.orderOut(nil) }

    static func show() {
        let h = ClipHistory.shared
        guard h.enabled else { Toast.show("Zwischenablage-Verlauf ist aus (Einstellungen › Allgemein)", symbol: "clipboard"); return }
        h.selected = 0
        let p = panel ?? make()
        // Wie bei Windows nah am Geschehen: unter dem Mauszeiger, aber immer ganz auf dem Bildschirm
        let m = NSEvent.mouseLocation
        let v = (NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!).visibleFrame
        p.setFrameOrigin(NSPoint(x: min(max(m.x - size.width / 2, v.minX + 8), v.maxX - size.width - 8),
                                 y: min(max(m.y - size.height - 12, v.minY + 8), v.maxY - size.height - 8)))
        p.orderFrontRegardless()
        p.makeKey()
    }

    private static func make() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fixedHost(ClipView())
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { hide() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard panel?.isKeyWindow == true else { return e }
            return MainActor.assumeIsolated { key(e) } ? nil : e
        }
        panel = p
        return p
    }

    private static func key(_ e: NSEvent) -> Bool {
        let h = ClipHistory.shared
        switch e.keyCode {
        case 53: hide()
        case 125: h.selected = min(h.selected + 1, max(h.items.count - 1, 0))
        case 126: h.selected = max(h.selected - 1, 0)
        case 36, 76: h.paste(h.selected)
        case 51, 117: h.remove(at: h.selected)
        default:
            guard let n = Int(e.charactersIgnoringModifiers ?? ""), (1...9).contains(n) else { return false }
            h.paste(n - 1)
        }
        return true
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var h = ClipHistory.shared
    var body: some View {
        let selected = h.selected == index
        Button { h.paste(index) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(index < 9 ? "\(index + 1)" : "")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 12)
                if let t = item.text {
                    Text(t.trimmingCharacters(in: .whitespacesAndNewlines)).lineLimit(3).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let img = item.image {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 70)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Bild")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(selected ? 0.22 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { h.selected = index } }
        .accessibilityHint(index < 9 ? "Einfügen, Taste \(index + 1)" : "Einfügen")
    }
}

struct ClipView: View {
    @ObservedObject var h = ClipHistory.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Zwischenablage").font(.headline)
                Spacer()
                if !h.items.isEmpty { Button("Alle löschen") { h.clear() }.buttonStyle(.borderless) }
            }
            .padding(12)
            Divider()
            if h.items.isEmpty {
                ContentUnavailableView("Noch nichts kopiert", systemImage: "clipboard",
                                       description: Text("Kopierte Texte und Bilder erscheinen hier."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(h.items.enumerated()), id: \.element.id) { i, item in
                                ClipRow(item: item, index: i).id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: h.selected) { _, s in if h.items.indices.contains(s) { proxy.scrollTo(h.items[s].id) } }
                }
            }
            Divider()
            Text("↑↓ wählen · ↩ einfügen · 1–9 direkt · ⌫ löschen · esc schließt")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 380, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Autostarts (LaunchAgents/-Daemons fremder Apps, umkehrbar über launchctl enable/disable)

struct LaunchItem: Identifiable {
    let label: String
    let path: String
    let program: String
    let daemon: Bool   // systemweit, braucht Admin-Passwort
    var enabled: Bool
    var id: String { path }
}

@MainActor final class Autostarts: ObservableObject {
    static let shared = Autostarts()
    @Published var items: [LaunchItem] = []
    @Published var message = ""
    private let uid = getuid()

    private func disabledLabels(_ domain: String) -> Set<String> {
        Set(sh(["/bin/launchctl", "print-disabled", domain]).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\"")
            return parts.count >= 3 && (line.hasSuffix("disabled") || line.hasSuffix("true")) ? String(parts[1]) : nil
        })
    }

    func scan() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let off = disabledLabels("gui/\(uid)"), offSys = disabledLabels("system")
        var found: [LaunchItem] = []
        for (dir, daemon) in [("\(home)/Library/LaunchAgents", false), ("/Library/LaunchAgents", false), ("/Library/LaunchDaemons", true)] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                let path = "\(dir)/\(file)"
                guard let d = NSDictionary(contentsOfFile: path), let label = d["Label"] as? String,
                      !label.hasPrefix("com.apple.") else { continue }
                let args = d["ProgramArguments"] as? [String] ?? []
                var prog = (d["Program"] as? String) ?? (args.first ?? "")
                if (prog as NSString).lastPathComponent == "open", let target = args.last { prog = target } // „open X.app“ → X.app zeigen
                found.append(LaunchItem(label: label, path: path, program: (prog as NSString).lastPathComponent,
                                        daemon: daemon, enabled: !(daemon ? offSys : off).contains(label)))
            }
        }
        items = found.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    func set(_ item: LaunchItem, _ on: Bool) {
        let domain = item.daemon ? "system" : "gui/\(uid)"
        let cmds = on ? ["/bin/launchctl enable \(domain)/\(item.label)", "/bin/launchctl bootstrap \(domain) '\(item.path)'"]
                      : ["/bin/launchctl disable \(domain)/\(item.label)", "/bin/launchctl bootout \(domain)/\(item.label)"]
        if item.daemon {
            // macOS fragt selbst nach dem Admin-Passwort
            let script = "do shell script \"\(cmds.joined(separator: "; ")) 2>/dev/null; true\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if err != nil { message = tr("Abgebrochen – %@ wurde nicht geändert.", item.label); scan(); return }
        } else {
            cmds.forEach { sh(["/bin/sh", "-c", $0 + " 2>/dev/null"]) }
        }
        message = on ? tr("%@ startet wieder automatisch.", item.label) : tr("%@ startet nicht mehr automatisch.", item.label)
        scan()
    }
}

struct AutostartView: View {
    @ObservedObject var a = Autostarts.shared
    @ObservedObject var login = LoginItems.shared
    @ObservedObject var bg = backgroundSwitches
    var body: some View {
        Form {
            Section {
                if a.items.isEmpty { Text("Keine fremden Autostarts gefunden.").foregroundStyle(.secondary) }
                ForEach(a.items) { item in
                    Toggle(isOn: Binding(get: { item.enabled }, set: { a.set(item, $0) })) {
                        Text(item.label)
                        Text("\(item.program.isEmpty ? "–" : item.program)\(item.daemon ? tr(" · systemweit, fragt nach Passwort") : "")")
                    }
                    .accessibilityLabel(item.label)
                }
            } header: {
                Text("Hintergrund-Starter von Apps")
            } footer: {
                Text("Ausschalten verhindert den automatischen Start – nichts wird gelöscht, Einschalten macht es rückgängig. Apple-Dienste werden nicht angezeigt.")
            }
            Section("Apps beim Anmelden") {
                if login.items.isEmpty { Text(login.message.isEmpty ? tr("Keine.") : login.message).foregroundStyle(.secondary) }
                ForEach(login.items) { app in
                    Toggle(isOn: Binding(get: { app.on }, set: { login.set(app, $0) })) {
                        Text(app.name)
                        Text(app.path)
                    }
                    .accessibilityLabel(app.name)
                    .disabled(login.busy)
                }
            }
            Section {
                if bg.items.isEmpty { Text(bg.busy ? tr("Lese Hintergrundaktivitäten …") : bg.message).foregroundStyle(.secondary) }
                ForEach(bg.items) { item in
                    Toggle(isOn: Binding(get: { item.on }, set: { bg.set(item.id, $0) })) {
                        Text(item.name)
                        Text(item.detail)
                    }
                    .accessibilityLabel(item.name)
                    .disabled(bg.busy)
                }
            } header: {
                HStack {
                    Text("Hintergrundaktivitäten")
                    Spacer()
                    if bg.busy { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text(bg.message.isEmpty ? tr("Darf eine App im Hintergrund laufen (Updater, Sync …)?") : bg.message)
            }
            if !a.message.isEmpty { Section { Text(a.message) } }
        }
        .formStyle(.grouped)
        .onAppear {
            Autostarts.shared.scan()
            LoginItems.shared.load()
            if !backgroundSwitches.busy { backgroundSwitches.load() }
        }
    }
}

@MainActor func openAutostarts() {
    openSettingsWindow(.autostarts)
}

// MARK: - Schalter aus den Systemeinstellungen, direkt in WinKomfort
// Wie bei den Mitteilungen: Apple bietet keine Schnittstelle, also bedient WinKomfort die Seite unsichtbar im Hintergrund.

extension UIAuto {
    static let settings = "com.apple.systempreferences"

    // Öffnet eine Einstellungsseite unsichtbar, wartet bis sie bereit ist, arbeitet darauf und schließt sie wieder
    static func onSettingsPage<T>(_ url: String, ready: ([AXUIElement]) -> Bool, _ work: ([AXUIElement]) -> T?) -> T? {
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: settings).isEmpty
        defer { if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: settings).first?.terminate() } }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        NSWorkspace.shared.open(URL(string: url)!, configuration: cfg)
        guard let e = wait(settings, ready) else { return nil }
        return work(e)
    }

    static func value(_ e: AXUIElement) -> Bool { (attr(e, kAXValueAttribute) as? Int) == 1 }
}

struct SysSwitch: Identifiable {
    let id: String      // stabile Kennung zum Wiederfinden
    let name: String
    let group: String
    var on: Bool
    var detail = ""
}

// Eine Einstellungsseite mit vielen Schaltern: lesen und einzeln umschalten
@MainActor final class SettingsSwitches: ObservableObject {
    @Published var items: [SysSwitch] = []
    @Published var busy = false
    @Published var message = ""
    let url: String
    let ready: ([AXUIElement]) -> Bool
    let extract: ([AXUIElement]) -> [(SysSwitch, AXUIElement)]
    private let queue = DispatchQueue(label: "winkomfort.sysswitches")

    nonisolated init(url: String, ready: @escaping ([AXUIElement]) -> Bool, extract: @escaping ([AXUIElement]) -> [(SysSwitch, AXUIElement)]) {
        self.url = url; self.ready = ready; self.extract = extract
    }

    private func run(_ work: @escaping () -> ([SysSwitch]?, String)) {
        busy = true
        message = ""
        queue.async {
            let (items, msg) = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let items { self.items = items }
                    self.message = msg
                    self.busy = false
                }
            }
        }
    }

    func load() {
        let (url, ready, extract) = (url, ready, extract)
        run {
            let r = UIAuto.onSettingsPage(url, ready: ready) { extract($0).map(\.0) }
            return (r, r == nil ? tr("Konnte die Einstellungen nicht lesen.") : "")
        }
    }

    func set(_ id: String, _ on: Bool) {
        let (url, ready, extract) = (url, ready, extract)
        run {
            let r: [SysSwitch]? = UIAuto.onSettingsPage(url, ready: ready) { e in
                guard let (_, el) = extract(e).first(where: { $0.0.id == id }) else { return nil }
                if UIAuto.value(el) != on {
                    UIAuto.press(el)
                    for _ in 0..<20 where UIAuto.value(el) != on { usleep(100_000) }
                }
                return UIAuto.app(UIAuto.settings).map { extract(UIAuto.elements($0)).map(\.0) }
            }
            let ok = r?.first(where: { $0.id == id })?.on == on
            return (r, ok ? "" : tr("Konnte den Schalter nicht umstellen."))
        }
    }
}

// Systemeinstellungen → Allgemein → Anmeldeobjekte → App-Hintergrundaktivitäten
let backgroundSwitches = SettingsSwitches(
    url: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
    ready: { $0.contains { UIAuto.id($0)?.hasPrefix("background-switch-") == true } },
    extract: { e in
        var seen = Set<String>()
        return e.compactMap { el -> (SysSwitch, AXUIElement)? in
            guard UIAuto.role(el) == "AXCheckBox", let id = UIAuto.id(el), id.hasPrefix("background-switch-"),
                  !["Im Finder anzeigen", "Show in Finder"].contains(UIAuto.label(el)), seen.insert(id).inserted else { return nil }
            let name = String(id.dropFirst("background-switch-".count))
            guard name != "WinKomfort" else { return nil } // sich selbst nicht abschaltbar machen
            let detail = e.first { UIAuto.id($0) == "background-detail-for-\(name)-app-login-items" && UIAuto.role($0) == "AXStaticText" }
                .flatMap { UIAuto.attr($0, kAXValueAttribute) as? String } ?? ""
            return (SysSwitch(id: id, name: name, group: "Hintergrund", on: UIAuto.value(el), detail: detail), el)
        }
    })

// Systemeinstellungen → Menüleiste: Symbole von macOS und von Apps
let menuBarAppHeadings: Set<String> = ["In Menüleiste erlauben", "Allow in the Menu Bar"]
let menuBarSwitches = SettingsSwitches(
    url: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
    ready: { $0.contains { UIAuto.role($0) == "AXHeading" && menuBarAppHeadings.contains(UIAuto.label($0)) } },
    extract: { e in
        let names = ["controlcenter-battery-id": "Batterie", "controlcenter-userSwitcher-id": "Schneller Benutzerwechsel"]
        var out: [(SysSwitch, AXUIElement)] = []
        var lastText = "", inApps = false
        for el in e {
            let role = UIAuto.role(el)
            if role == "AXHeading" { inApps = menuBarAppHeadings.contains(UIAuto.label(el)) }
            if role == "AXStaticText" { lastText = (UIAuto.attr(el, kAXValueAttribute) as? String) ?? "" }
            guard role == "AXCheckBox" else { continue }
            if let id = UIAuto.id(el), id.hasPrefix("controlcenter-"), id.hasSuffix("-id") {
                let label = UIAuto.label(el)
                out.append((SysSwitch(id: id, name: label.isEmpty ? (names[id].map { tr($0) } ?? id) : label.replacingOccurrences(of: "\u{AD}", with: ""),
                                      group: "Symbole von macOS", on: UIAuto.value(el)), el))
            } else if inApps, !lastText.isEmpty, lastText != "WinKomfort" { // WinKomfort selbst bleibt immer sichtbar
                out.append((SysSwitch(id: "app:" + lastText, name: lastText, group: "Symbole von Apps", on: UIAuto.value(el)), el))
            }
        }
        return out
    })

// Apps beim Anmelden – über die offizielle Skript-Schnittstelle „System Events“ (umkehrbar: Pfad wird gemerkt)
struct LoginApp: Identifiable {
    let name: String
    let path: String
    var on: Bool
    var id: String { name }
}

@MainActor final class LoginItems: ObservableObject {
    static let shared = LoginItems()
    @Published var items: [LoginApp] = []
    @Published var message = ""
    @Published var busy = false
    private let queue = DispatchQueue(label: "winkomfort.loginitems")
    private var removed: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "removedLoginItems") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "removedLoginItems") }
    }

    // Läuft im Hintergrund über osascript – beim ersten Mal wartet macOS auf deine Erlaubnis, die App friert dabei nicht ein
    private nonisolated static func script(_ s: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\"\n\(s)\nend tell"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private nonisolated static func read() -> [LoginApp]? {
        // Name und Pfad je Zeile, damit Kommas in Namen nichts kaputt machen
        guard let out = script("set out to \"\"\nrepeat with i in every login item\nset out to out & name of i & tab & path of i & linefeed\nend repeat\nreturn out") else { return nil }
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return p.count == 2 ? LoginApp(name: p[0], path: p[1], on: true) : nil
        }
    }

    private func run(_ work: @escaping () -> (list: [LoginApp]?, change: (String, String?)?)) {
        busy = true
        message = items.isEmpty ? tr("Warte auf Erlaubnis für „System Events“ …") : ""
        queue.async {
            let r = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if let (name, path) = r.change { self.removed[name] = path }
                    guard let list = r.list else {
                        self.message = tr("Kein Zugriff auf „System Events“. Erlauben unter Datenschutz & Sicherheit → Automation.")
                        return
                    }
                    var all = list.filter { $0.name != "WinKomfort" } // WinKomfort selbst: Einstellungen → Allgemein
                    for (name, path) in self.removed where !all.contains(where: { $0.name == name }) { all.append(LoginApp(name: name, path: path, on: false)) }
                    self.items = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.message = ""
                }
            }
        }
    }

    func load() { run { (Self.read(), nil) } }

    func set(_ app: LoginApp, _ on: Bool) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        run {
            let ok = on ? Self.script("make login item at end with properties {path:\"\(esc(app.path))\", hidden:false}") != nil
                        : Self.script("delete login item \"\(esc(app.name))\"") != nil
            // Entfernt → Pfad merken (zum Wiederherstellen); wieder an → vergessen
            return (Self.read(), ok ? (app.name, on ? nil : app.path) : nil)
        }
    }
}

// MARK: - Mac aufräumen (mit Protokoll zum Rückgängigmachen)

struct Candidate: Identifiable {
    let name: String
    let path: String
    let store: String? // App-Store-ID zum Neuladen
    var id: String { path }
}

struct Removed: Codable, Identifiable {
    let name: String
    let original: String
    let trash: String
    let date: Date
    let store: String?
    var id: String { original + "\(date.timeIntervalSince1970)" }
}

// Nur Apple-Apps, die macOS löschen lässt. System-Apps in /System/Applications sind versiegelt (SIP) und bleiben.
let cleanupCandidates = [
    Candidate(name: "GarageBand", path: "/Applications/GarageBand.app", store: "682658836"),
    Candidate(name: "GarageBand-Soundbibliothek", path: "/Library/Application Support/GarageBand", store: nil),
    Candidate(name: "Apple Loops (GarageBand-Sounds)", path: "/Library/Audio/Apple Loops/Apple", store: nil),
    Candidate(name: "iMovie", path: "/Applications/iMovie.app", store: "408981434"),
    Candidate(name: "Keynote", path: "/Applications/Keynote.app", store: "409183694"),
    Candidate(name: "Pages", path: "/Applications/Pages.app", store: "409201541"),
    Candidate(name: "Numbers", path: "/Applications/Numbers.app", store: "409203825"),
]

@MainActor final class Cleaner: ObservableObject {
    static let shared = Cleaner()
    @Published var found: [Candidate] = []
    @Published var sizes: [String: String] = [:]
    @Published var chosen: Set<String> = []
    @Published var log: [Removed] = []
    @Published var message = ""

    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WinKomfort/entfernt.json")

    func scan() {
        if let d = try? Data(contentsOf: logURL), let l = try? JSONDecoder().decode([Removed].self, from: d) { log = l }
        found = cleanupCandidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        chosen = Set(found.map(\.id))
        for c in found where sizes[c.id] == nil {
            DispatchQueue.global(qos: .utility).async {
                let kb = Int64(sh(["/usr/bin/du", "-sk", c.path]).split(separator: "\t").first ?? "") ?? 0
                let s = ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file)
                DispatchQueue.main.async { MainActor.assumeIsolated { Cleaner.shared.sizes[c.id] = s } }
            }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(log).write(to: logURL)
    }

    // Finder legt in den Papierkorb und fragt selbst nach dem Admin-Passwort, wo nötig
    private func finder(_ script: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"Finder\"\n\(script)\nend tell")?.executeAndReturnError(&err)
        return err == nil ? (r?.stringValue ?? "") : nil
    }

    func removeChosen() {
        let items = found.filter { chosen.contains($0.id) }
        guard !items.isEmpty, alert(tr("%lld Objekt(e) in den Papierkorb legen?", items.count),
            items.map { "• \($0.name)" }.joined(separator: "\n")
            + "\n\n" + tr("Alles wird protokolliert. Wiederherstellen geht, solange der Papierkorb nicht geleert ist – Apple-Apps gibt es außerdem kostenlos im App Store."),
            ["In den Papierkorb", "Abbrechen"]) else { return }
        message = ""
        for c in items {
            if let trash = finder("POSIX path of ((delete (POSIX file \"\(c.path)\" as alias)) as alias)") {
                log.append(Removed(name: c.name, original: c.path, trash: trash, date: Date(), store: c.store))
                save()
            } else {
                message = tr("%@ konnte nicht entfernt werden.", c.name)
            }
        }
        scan()
    }

    func restore(_ r: Removed) {
        let parent = (r.original as NSString).deletingLastPathComponent
        let name = (r.original as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: r.trash),
           finder("set f to move (POSIX file \"\(r.trash)\" as alias) to (POSIX file \"\(parent)\" as alias)\nset name of f to \"\(name)\"") != nil {
            log.removeAll { $0.id == r.id }
            save()
            message = tr("%@ ist wieder da.", r.name)
        } else if let s = r.store {
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id\(s)")!)
            message = tr("%@ ist nicht mehr im Papierkorb – im App Store kostenlos neu laden.", r.name)
        } else {
            message = tr("%@ ist nicht mehr im Papierkorb. GarageBand lädt die Sounds beim nächsten Start selbst nach.", r.name)
        }
        scan()
    }
}

struct CleanupView: View {
    @ObservedObject var c = Cleaner.shared
    var body: some View {
        Form {
            Section("Entfernbare Standard-Apps") {
                if c.found.isEmpty { Text("Nichts mehr zum Aufräumen gefunden.").foregroundStyle(.secondary) }
                ForEach(c.found) { item in
                    Toggle(isOn: Binding(get: { c.chosen.contains(item.id) },
                                         set: { v in if v { c.chosen.insert(item.id) } else { c.chosen.remove(item.id) } })) {
                        Text("\(item.name) · \(c.sizes[item.id] ?? "…")")
                        Text(item.path)
                    }
                    .accessibilityLabel(item.name)
                }
                Button("Ausgewählte in den Papierkorb …") { c.removeChosen() }
                    .disabled(c.chosen.isEmpty)
            }
            Section("Entfernt – rückgängig machen") {
                if c.log.isEmpty { Text("Noch nichts entfernt.").foregroundStyle(.secondary) }
                ForEach(c.log) { r in
                    LabeledContent {
                        Button("Wiederherstellen") { c.restore(r) }
                    } label: {
                        Text(r.name)
                        Text("\(r.date.formatted(date: .abbreviated, time: .shortened)) · war in \(r.original)")
                    }
                }
            }
            if !c.message.isEmpty { Section { Text(c.message) } }
            Section {
                Text("System-Apps wie Schach, Aktien oder News liegen auf dem versiegelten Systemvolume. macOS lässt sie nur löschen, wenn man den Systemschutz (SIP) abschaltet – das macht WinKomfort bewusst nicht.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { Cleaner.shared.scan() }
    }
}

@MainActor func openCleanup() { openSettingsWindow(.cleanup) }

// MARK: - Popup

@MainActor @discardableResult
func alert(_ title: String, _ text: String, _ buttons: [String] = ["OK"]) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = tr(title)
    a.informativeText = tr(text)
    buttons.forEach { a.addButton(withTitle: tr($0)) }
    return a.runModal() == .alertFirstButtonReturn
}

// MARK: - Updates über GitHub Releases

struct Release: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    let tag_name: String
    let body: String?
    let assets: [Asset]
}

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var status = tr("Noch nicht geprüft")

    func loop() async {
        try? await Task.sleep(for: .seconds(10))
        while true {
            await check(manual: false)
            try? await Task.sleep(for: .seconds(6 * 3600))
        }
    }

    func check(manual: Bool) async {
        status = tr("Suche nach Updates …")
        do {
            let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard latest.compare(appVersion, options: .numeric) == .orderedDescending else {
                status = tr("Du hast die neueste Version.")
                if manual { alert("Kein Update nötig", tr("Version %@ ist aktuell.", appVersion)) }
                return
            }
            guard let zip = rel.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let sig = rel.assets.first(where: { $0.name == zip.name + ".sig" }) else {
                status = tr("Version %@ hat keine signierte Download-Datei.", latest)
                return
            }
            if !UserDefaults.standard.bool(forKey: "autoUpdate") {
                guard alert(tr("Neue Version %@ verfügbar", latest), rel.body ?? "", ["Jetzt installieren", "Später"]) else {
                    status = tr("Version %@ verfügbar", latest)
                    return
                }
            }
            status = tr("Installiere Version %@ …", latest)
            try await install(zip.browser_download_url, sig: sig.browser_download_url, expected: latest, notes: rel.body ?? "")
        } catch {
            status = tr("Update-Prüfung fehlgeschlagen")
            if manual { alert("Update fehlgeschlagen", error.localizedDescription) }
        }
    }

    func install(_ url: URL, sig sigURL: URL, expected: String, notes: String) async throws {
        let (zipData, _) = try await URLSession.shared.data(from: url)
        let (sigData, _) = try await URLSession.shared.data(from: sigURL)
        let sigText = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: sigText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: updateKey)!),
              key.isValidSignature(sig, for: zipData) else {
            throw UpdateError("Die Signatur des Updates stimmt nicht – es wurde nicht installiert.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("update.zip")
        try zipData.write(to: file)
        sh(["/usr/bin/ditto", "-x", "-k", file.path, dir.path])
        let new = dir.appendingPathComponent("WinKomfort.app")
        guard let b = Bundle(url: new), b.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("Das Update enthält keine gültige WinKomfort-App.")
        }
        // Version steckt im signierten Zip → schützt davor, dass ein altes signiertes Zip als "neu" untergeschoben wird
        let newVersion = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard newVersion == expected, newVersion.compare(appVersion, options: .numeric) == .orderedDescending else {
            throw UpdateError(tr("Das Update hat die falsche Version (%@) – es wurde nicht installiert.", newVersion))
        }
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: new)
        UserDefaults.standard.set(notes, forKey: "notes")
        try relaunch()
    }
}

// Startet WinKomfort neu: neue Instanz kurz nach dem Beenden öffnen
@MainActor func relaunch() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
    try p.run()
    NSApp.terminate(nil)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {

    // App erneut öffnen (Finder, Spotlight, Startmenü) → Einstellungen zeigen, auch wenn das Menüleisten-Symbol versteckt ist
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { DockIcon.reopen() }
        return false
    }

    // winkomfort://… aus Kurzbefehlen/Siri oder dem Browser
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            urls.filter { !$0.isFileURL }.forEach(Assistant.handle)
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { FolderHandler.open(files) }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Antwortet eine andere App nicht, höchstens 1 s warten (sonst 6 s – so lange stünde WinKomfort still)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        let d = UserDefaults.standard
        d.register(defaults: ["autoUpdate": true, "startMenu": true])
        // Dreimal hintereinander gleich nach dem Start abgestürzt → nur Menü und Updates, damit eine Reparatur ankommen kann
        let early = d.integer(forKey: "earlyCrashes")
        d.set(early + 1, forKey: "earlyCrashes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { UserDefaults.standard.set(0, forKey: "earlyCrashes") }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in UserDefaults.standard.set(0, forKey: "earlyCrashes") } // normal beendet ist kein Absturz
        if early >= 3 {
            d.set(0, forKey: "earlyCrashes") // der nächste Start versucht es wieder normal
            wkLog("Sicherer Modus nach \(early) Abstürzen beim Start")
            Toast.show(L("WinKomfort läuft im sicheren Modus und sucht nach einem Update. Beenden und neu öffnen versucht es wieder normal.", "WinKomfort is in safe mode and checking for an update. Quit and reopen to try normally again."), symbol: "lifepreserver", seconds: 8)
            DockIcon.setup()
            Task { await Updater.shared.loop() }
            return
        }
        if !d.bool(forKey: "didSetup") {
            try? SMAppService.mainApp.register() // beim ersten Start: automatisch bei Anmeldung starten
            d.set(true, forKey: "didSetup")
        }
        if let last = d.string(forKey: "lastVersion"), last != appVersion {
            Task { @MainActor in
                alert("WinKomfort wurde aktualisiert", "Version \(last) → \(appVersion)\n\n\(d.string(forKey: "notes") ?? "")")
            }
        }
        d.set(appVersion, forKey: "lastVersion")
        if d.bool(forKey: "closeQuits") { CloseWatcher.shared.setEnabled(true) }
        if let drag = features.first(where: { $0.id == "drag" }) {
            // Umstellung von ≤ 1.2: dort war das Ziehen von macOS an – jetzt übernimmt WinKomfort
            if d.object(forKey: "tapDrag") == nil,
               defaults("read", Pref(domain: trackpads[0], key: "Dragging", on: yes)) == "1" { apply(drag, true) }
            if isOn(drag) { TapDragFix.start() }
        }
        // Umstellung von ≤ 1.2: Dock-Animation von 0,25 s auf 0,12 s
        if let dock = features.first(where: { $0.id == "dock" }), isOn(dock),
           defaults("read", Pref(domain: "com.apple.dock", key: "autohide-time-modifier", on: [])) == "0.25" { apply(dock, true) }
        Store.shared.reload()
        if d.bool(forKey: "startMenu") { StartKey.start() }
        FinderCut.start()
        HotKey.register()
        ClipHistory.shared.start()
        DispatchQueue.global(qos: .utility).async { OneNotePDF.cleanLeftovers() }
        SearchPanel.prepare()
        if !d.bool(forKey: "welcomeShown"), d.object(forKey: "toolsLean") == nil { d.set(true, forKey: "toolsLean") } // neu installiert: schlank starten (Bibliothek)
        if !d.bool(forKey: "welcomeShown") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { openWelcome() } } }
        DockReveal.start()
        DockIcon.setup()
        AppUsage.shared.setup()
        AutoQuit.update()
        InputExtras.update()
        Awake.shared.lidCleanup()
        FolderHandler.setup()
        BudsMic.update()
        GameMode.shared.setup()
        Repair.setup()
        MouseScroll.update()
        Shelf.shared.setup(); Notch.shared.update(); if Tool.battery.on, !(UserDefaults.standard.stringArray(forKey: "batterySaving") ?? []).isEmpty { Battery.shared.setup() }
        Snippets.update()
        SystemMonitor.shared.update()
        Task { await Updater.shared.loop() }
    }
}

// MARK: - Wach bleiben (offizielle macOS-Energie-Schnittstelle, wie „caffeinate“)

@MainActor final class Awake: ObservableObject {
    static let shared = Awake()
    enum Mode: String { case display = "Bildschirm bleibt an", system = "Bildschirm aus, Mac arbeitet weiter" }
    @Published private(set) var mode: Mode?
    @Published private(set) var until: Date?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    static let durations: [(String, Int?)] = [("30 Minuten", 30), ("1 Stunde", 60), ("2 Stunden", 120), ("5 Stunden", 300), ("Unbegrenzt", nil)]

    private var lidStop: URL?
    private var lidWatch: Timer?
    private var lidRequest = 0 // verwirft eine alte Passwort-Abfrage, wenn inzwischen etwas anderes gewählt wurde

    // Hält macOS gerade wirklich auch zugeklappt wach?
    nonisolated static var sleepDisabled: Bool {
        let e = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard e != 0 else { return false }
        defer { IOObjectRelease(e) }
        return IORegistryEntryCreateCFProperty(e, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    // Darf WinKomfort das Zuklappen schon ohne Passwort schalten?
    private nonisolated static func allowed() -> Bool { run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]) }
    private nonisolated static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    private nonisolated static func admin(_ cmd: String, _ prompt: String) -> Bool {
        run("/usr/bin/osascript", ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges", "-e", "end run", cmd, prompt])
    }

    private func startLid(_ minutes: Int?) {
        lidRequest += 1
        let request = lidRequest
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wk-lid-\(UUID().uuidString)")
        let script = LidScript.make(pid: getpid(), seconds: minutes.map { $0 * 60 }, stopFile: file.path)
        Task.detached {
            var ok = Self.allowed()
            if !ok {
                _ = Self.admin(LidScript.install(uid: getuid()), L("WinKomfort möchte den Mac auch zugeklappt wach halten dürfen. Das fragt nur einmal.", "WinKomfort wants to be allowed to keep the Mac awake with the lid closed. It asks only once."))
                ok = Self.allowed()
            }
            if ok, await MainActor.run(body: { Awake.shared.lidRequest == request }) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", script]
                p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                ok = (try? p.run()) != nil
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else { ok = false }
            await MainActor.run { [ok] in Awake.shared.lidStarted(ok, request, file) }
        }
    }
    private func lidStarted(_ ok: Bool, _ request: Int, _ file: URL) {
        guard ok, request == lidRequest, Self.sleepDisabled else {
            FileManager.default.createFile(atPath: file.path, contents: nil) // falls es doch läuft: sofort zurücknehmen
            if request == lidRequest { Toast.show(L("Wach – aber nur aufgeklappt", "Awake – but only with the lid open"), symbol: "lock.open") }
            return
        }
        lidStop = file
        UserDefaults.standard.set(true, forKey: "lidOn")
        // Endet von selbst bei fast leerem Akku
        lidWatch = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { if !Awake.sleepDisabled { Awake.shared.lidEnded() } } }
        lidWatch?.tolerance = 10
        Toast.show(L("Du kannst zuklappen – der Mac arbeitet weiter", "You can close the lid – the Mac keeps working"), symbol: "laptopcomputer")
    }
    // Wurde alles hart beendet, blieb die Einstellung vielleicht stehen: beim Start zurücknehmen
    func lidCleanup() {
        guard UserDefaults.standard.bool(forKey: "lidOn") else { return }
        UserDefaults.standard.removeObject(forKey: "lidOn")
        Task.detached { if Self.sleepDisabled { _ = Self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]) } }
    }
    static var ruleInstalled: Bool { FileManager.default.fileExists(atPath: LidScript.rulePath) }
    func removeRule() {
        stop()
        // erst zurücknehmen lassen (das Skript schaut alle 5 s), dann die Erlaubnis löschen
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            let ok = Self.admin(LidScript.remove, L("WinKomfort entfernt die Erlaubnis fürs Zuklappen.", "WinKomfort removes the lid permission."))
            DispatchQueue.main.async { Toast.show(ok ? L("Erlaubnis entfernt", "Permission removed") : L("Nicht entfernt", "Not removed"), symbol: "lock") }
        }
    }

    private func lidEnded() {
        lidStop = nil
        lidWatch?.invalidate()
        lidWatch = nil
    }
    var lidActive: Bool { lidStop != nil }

    func start(_ m: Mode, minutes: Int?) {
        stop()
        begin(m, minutes)
        if m == .system { startLid(minutes) } // ohne Passwort bleibt er nur aufgeklappt wach
    }

    private func begin(_ m: Mode, _ minutes: Int?) {
        let type = m == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "WinKomfort: \(m.rawValue)" as CFString, &assertion) == kIOReturnSuccess else { return }
        mode = m
        if let minutes {
            until = Date().addingTimeInterval(Double(minutes) * 60)
            timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { _ in
                MainActor.assumeIsolated { Awake.shared.stop() }
            }
        }
    }

    func stop() {
        lidRequest += 1
        UserDefaults.standard.removeObject(forKey: "lidOn")
        if let f = lidStop { FileManager.default.createFile(atPath: f.path, contents: nil); lidStop = nil }
        lidWatch?.invalidate()
        lidWatch = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        timer?.invalidate()
        timer = nil
        mode = nil
        until = nil
    }

    var status: String {
        guard let mode else { return tr("Aus") }
        return tr(mode.rawValue) + (until.map { tr(" – bis %@", $0.formatted(date: .omitted, time: .shortened)) } ?? tr(" – unbegrenzt"))
    }
}

struct MenuContent: View {
    @ObservedObject var awake = Awake.shared
    var body: some View {
        Menu("Wach bleiben") {
            Text(awake.status)
            Divider()
            ForEach([Awake.Mode.display, .system], id: \.self) { m in
                Section(tr(m.rawValue)) {
                    ForEach(Awake.durations, id: \.0) { d in
                        Button(tr(d.0)) { awake.start(m, minutes: d.1) }
                    }
                }
            }
            Divider()
            Button("Bildschirm jetzt aus – Mac arbeitet weiter") { sh(["/usr/bin/pmset", "displaysleepnow"]) }
            if awake.mode != nil { Button("Wach bleiben beenden") { awake.stop() } }
        }
        Divider()
        if Tool.school.on, let l = School.shared.menuLine { Button(l) { School.open("heute") } }
        Button("Suche …") { SearchPanel.show() }
        Button(L("KI fragen …", "Ask AI…")) { AIPanel.show() }
        if Tool.school.on { Button(L("Schule …", "School…")) { School.open() } }
        if Tool.study.on { Button(L("Lernzettel …", "Study sheet…")) { Study.open() } }
        if Tool.scan.on { Button(L("Blatt scannen …", "Scan sheet…")) { Scanner.open() } }
        if Tool.battery.on { Button(L("Akku …", "Battery…")) { Battery.open() } }
        if Tool.hand.on { Button(L("Handschrift …", "Handwriting…")) { Hand.openWindow() } }
        if Tool.tidy.on { Button(L("Notizen schön machen …", "Tidy up notes…")) { Tidy.open() } }
        Button("Explorer …") { openExplorer() }
        Button("Schnellnotiz") { QuickNote.shared.toggle() }
        if !Pins.shared.pinned.isEmpty { Button("Alle angehefteten Fenster lösen") { Pins.shared.unpinAll() } }
        if Tool.remote.on { Button(L("Handy-Fernbedienung …", "Phone remote…")) { openRemote() } }
        if Buds.enabled { BudsMenu() }
        Button("Task-Manager …") { openTaskManager() }
            .keyboardShortcut(.escape, modifiers: [.control, .shift])
        Button("Autostarts …") { openAutostarts() }
        Button("Mac aufräumen …") { openCleanup() }
        Divider()
        Button("Einstellungen …") { openSettingsWindow() }.keyboardShortcut(",")
        Button("Nach Updates suchen …") { Task { await Updater.shared.check(manual: true) } }
        Divider()
        Button("WinKomfort beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// Einstellungsfenster wie bei Systemapps: AppKit-Tabs im Toolbar-Stil, Inhalt in SwiftUI
// Seiten wie in den Systemeinstellungen: farbige Symbolkachel, Titel, Suchbegriffe
enum Pane: String, CaseIterable, Identifiable {
    case general, library, ai, school, tools, shortcuts, input, windows, desktop, animations, menubar, notifications, finder, explorer, screenshots, phone, gamemode, autostarts, cleanup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Allgemein"
        case .library: L("Bibliothek", "Library")
        case .ai: L("KI-Assistent", "AI Assistant")
        case .school: L("Schule", "School")
        case .tools: L("Werkzeuge", "Tools")
        case .input: "Eingabe"
        case .shortcuts: "Tastenkürzel"
        case .windows: "Fenster"
        case .finder: "Finder"
        case .explorer: "Explorer"
        case .phone: "Handy & Buds"
        case .gamemode: "Game Mode"
        case .desktop: "Schreibtisch & Dock"
        case .screenshots: "Screenshots"
        case .notifications: "Mitteilungen"
        case .menubar: "Menüleiste"
        case .animations: "Animationen"
        case .autostarts: "Autostarts"
        case .cleanup: "Mac aufräumen"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .library: "square.grid.2x2.fill"
        case .ai: "sparkles"
        case .school: "graduationcap.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .input: "hand.tap.fill"
        case .shortcuts: "command"
        case .windows: "macwindow"
        case .finder: "folder.fill"
        case .explorer: "folder.badge.gearshape"
        case .phone: "iphone.gen3"
        case .gamemode: "gamecontroller.fill"
        case .desktop: "menubar.dock.rectangle"
        case .screenshots: "camera.viewfinder"
        case .notifications: "bell.badge.fill"
        case .menubar: "menubar.rectangle"
        case .animations: "wand.and.rays"
        case .autostarts: "power"
        case .cleanup: "trash.fill"
        }
    }
    // Systemfarben wie in den macOS-Systemeinstellungen
    var tint: Color {
        switch self {
        case .general: .gray
        case .library: .blue
        case .ai: .purple
        case .school: .indigo
        case .tools: .orange
        case .input: .blue
        case .shortcuts: .gray
        case .windows: .indigo
        case .finder: .cyan
        case .explorer: .teal
        case .phone: .green
        case .gamemode: .red
        case .desktop: .blue
        case .screenshots: .gray
        case .notifications: .red
        case .menubar: .secondary
        case .animations: .purple
        case .autostarts: .green
        case .cleanup: .orange
        }
    }
    var group: String? {
        switch self {
        case .input: groups[0]
        case .windows: groups[1]
        case .finder: groups[2]
        case .screenshots: groups[3]
        case .desktop: groups[4]
        default: nil
        }
    }
    // Wonach man suchen kann: Seitentitel, Schalter und Erklärungen darauf
    var searchText: String {
        var t = [title]
        if let g = group { t += features.filter { $0.group == g }.flatMap { [$0.title, $0.hint] } }
        switch self {
        case .general: t += ["Anmelden Start Updates Version Bedienungshilfen Wach bleiben Bildschirm Ruhezustand Zwischenablage Verlauf Kopieren Einfügen Text-Kürzel Snippets Textbausteine Siri Kurzbefehle Shortcuts KI Selbsttest Reparieren Protokoll Sprache Englisch Deutsch OneNote PDF Größe"]
        case .library: t += Tool.allCases.flatMap { [$0.title, $0.detail] } + ["Werkzeuge ausschalten deaktivieren Funktionen Module Tools Library Disable"]
        case .ai: t += ["KI AI Assistent Chat Siri Kurzbefehle Sprechen Mikrofon Kalender Erinnerungen Kontakte Wikipedia Wetter Gedächtnis Assistant Voice"]
        case .school: t += ["Stundenplan Hausaufgaben Noten Lernkarten Lernmodus Fokus Mathe Technik Timetable Homework Grades Study Focus"]
        case .tools: t += ["Wach bleiben Bildschirm Ruhezustand Zuklappen Zwischenablage Verlauf Ablage Text-Kürzel Snippets Textbaustein OneNote PDF Awake Clipboard Shelf"]
        case .shortcuts: t += HotAction.allCases.map(\.title) + ["Kürzel Tastatur Hotkey Startmenü"]
        case .desktop: t += ["Dock Position Größe Vergrößerung Taskleiste Ecke Schreibtisch Symbole Widgets Laufwerke"]
        case .input: t += ["Startmenü Control Suche Tastenkürzel Trackpad Ziehen Maus Scrollen Scrollrichtung Mausrad Tempo CPU RAM Speicher Auslastung Menüleiste"]
        case .windows: t += ["Schließen beendet die App"]
        case .phone: t += ["Samsung Galaxy Buds Handy Fernbedienung Bildschirm Mikrofon Phone Remote Display Microphone"]
        case .gamemode: t += ["Spiele Spielen Gaming Leistung Drosseln Nicht stören"]
        case .explorer: t += ["Dateimanager GNOME Nautilus Dolphin KDE Linux Windows 11 Quick Look Vorschau Stil"]
        case .notifications: t += ["Nicht stören Fokus Alle Mitteilungen"]
        case .menubar: t += ["Symbole Notch Platz"]
        case .animations: t += ["Trichter Minimieren Skalieren Tempo Dock Mission Control Übersicht"]
        case .autostarts: t += ["Anmeldeobjekte Hintergrund Login Starter"]
        case .cleanup: t += ["GarageBand iMovie Papierkorb löschen Speicher"]
        default: break
        }
        return (t + t.map { tr($0) }).joined(separator: " ")
    }
    // Überschriften der Seitenleiste
    static var sections: [(String, [Pane])] {
        [("", [.general, .library, .ai, .school, .tools]), (L("Bedienung", "Controls"), [.shortcuts, .input, .windows]), (L("Oberfläche", "Interface"), [.desktop, .animations, .menubar, .notifications]),
         (L("Dateien", "Files"), [.finder, .explorer, .screenshots]), (L("Geräte und Spiele", "Devices and games"), [.phone, .gamemode]), (L("Mac pflegen", "Maintenance"), [.autostarts, .cleanup])]
    }
}

@MainActor final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var pane: Pane? = .general
    @Published var query = ""
    var visible: [Pane] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Pane.allCases : Pane.allCases.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
    }
}

struct PaneIcon: View {
    let pane: Pane
    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pane.tint.gradient))
            .accessibilityHidden(true)
    }
}

struct SettingsRoot: View {
    @ObservedObject var nav = SettingsNav.shared
    var body: some View {
        NavigationSplitView {
            List(selection: $nav.pane) {
                ForEach(Pane.sections, id: \.0) { s in
                    let p = s.1.filter(nav.visible.contains)
                    if !p.isEmpty {
                        Section { ForEach(p) { pane in NavigationLink(value: pane) { Label { Text(tr(pane.title)) } icon: { PaneIcon(pane: pane) } } } } header: { if !s.0.isEmpty { Text(s.0) } }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
            .overlay { if nav.visible.isEmpty { ContentUnavailableView.search(text: nav.query) } }
        } detail: {
            Group {
                switch nav.pane ?? .general {
                case .general: GeneralTab(store: Store.shared)
                case .library: LibraryTab()
                case .ai: AITab()
                case .school: SchoolPane()
                case .tools: ToolsTab()
                case .notifications: NotificationsTab()
                case .menubar: MenuBarTab()
                case .animations: AnimationTab()
                case .shortcuts: ShortcutsTab()
                case .autostarts: AutostartView()
                case .cleanup: CleanupView()
                case .explorer: ExplorerTab()
                case .phone: PhoneTab()
                case .gamemode: GameModeTab()
                case let p: FeatureTab(store: Store.shared, group: p.group ?? groups[0])
                }
            }
            .navigationTitle(tr((nav.pane ?? .general).title))
            .onChange(of: nav.pane) { _, _ in if nav.query.isEmpty { calmFocus("settings") } }
        }
        .searchable(text: $nav.query, placement: .sidebar, prompt: "Suchen")
        .onChange(of: nav.query) { _, _ in
            // Bei der Suche automatisch die erste passende Seite zeigen
            if let p = nav.pane, nav.visible.contains(p) { return }
            nav.pane = nav.visible.first
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

// Auf dem Schreibtisch aufgehen, auf dem man gerade ist (auch über einer Vollbild-App), statt dorthin zu springen
@MainActor func stayHere(_ w: NSWindow) { w.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary]) }

// Einstellungsfenster wie die Systemeinstellungen: Seitenleiste, Suche, Inhalt rechts
@MainActor func openSettingsWindow(_ pane: Pane? = nil) {
    if let pane { SettingsNav.shared.query = ""; SettingsNav.shared.pane = pane }
    if windows["settings"] == nil {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: SettingsRoot())
        w.toolbar = NSToolbar() // Platz für Seitenleisten-Knopf und Titel, wie bei Systemapps
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.title = tr((SettingsNav.shared.pane ?? .general).title) // wie bei Apple: Name der Seite oben
        w.setContentSize(NSSize(width: 780, height: 560))
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("WinKomfortSettings") // Größe und Position merken
        if !w.setFrameUsingName("WinKomfortSettings") { w.center() }
        windows["settings"] = w
    }
    if let w = windows["settings"] { stayHere(w) }
    NSApp.activate(ignoringOtherApps: true)
    windows["settings"]?.makeKeyAndOrderFront(nil)
    calmFocus("settings")
}

// macOS markiert sonst beim Öffnen und Seitenwechsel das erste Textfeld
@MainActor func calmFocus(_ id: String) {
    DispatchQueue.main.async {
        guard let w = windows[id], (w.firstResponder as? NSTextView)?.isFieldEditor == true else { return }
        w.makeFirstResponder(nil)
    }
}

// Schalter für InputExtras
struct ExtraToggle: View {
    let key: String, title: String, hint: String
    @AppStorage private var on: Bool
    init(key: String, title: String, hint: String) { self.key = key; self.title = title; self.hint = hint; _on = AppStorage(wrappedValue: false, key) }
    var body: some View {
        Toggle(isOn: $on) { Text(title); Text(hint) }.onChange(of: on) { _, _ in InputExtras.update(prompt: true) }
    }
}

struct FeatureTab: View {
    @ObservedObject var store: Store
    let group: String
    var body: some View {
        Form {
            Section {
                if group == groups[0] {
                    Toggle(isOn: store.startMenu) {
                        Text("Control antippen öffnet das Startmenü")
                        Text("Wie die Windows-Taste: Control kurz allein drücken – Apps suchen, Ein/Aus.")
                    }
                    .accessibilityLabel("Control antippen öffnet das Startmenü")
                }
                if group == groups[0] { MouseSettings() }
                if group == groups[4] { DockSettings(); ExtraToggle(key: "dockMinimize", title: L("Klick aufs Dock-Symbol minimiert", "Click Dock icon to minimize"), hint: L("Wie die Windows-Taskleiste: Ist die App schon vorne, verschwinden ihre Fenster ins Dock.", "Like the Windows taskbar: if the app is already in front, its windows minimize.")) }
                if group == groups[1] {
                    Toggle(isOn: store.closeQuits) { Text("Schließen beendet die App"); Text(tr(closeHint)) }
                        .accessibilityLabel("Schließen beendet die App")
                }
                ForEach(features.filter { $0.group == group }) { f in
                    Toggle(isOn: store.binding(f)) { Text(tr(f.title)); Text(tr(f.hint)) }
                        .accessibilityLabel(tr(f.title))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @ObservedObject var store: Store
    @ObservedObject var updater = Updater.shared
    @AppStorage("autoUpdate") var autoUpdate = true
    @AppStorage("language") var language = "auto" // auch von L() in Explorer.swift gelesen
    var body: some View {
        Form {
            Section {
                Toggle("Beim Anmelden automatisch starten", isOn: store.login)
                LabeledContent {
                    Button("Öffnen …") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                } label: {
                    Text("Bedienungshilfen")
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        Text(AXIsProcessTrusted() ? "Freigegeben ✓" : "Nicht freigegeben – nötig für Startmenü, Ziehen und „Schließen beendet die App“")
                    }
                }
            }
            RepairSection()
            Section {
                Button("Einführung erneut zeigen …") { openWelcome() }
            }
            Section("Updates") {
                Toggle("Updates automatisch installieren", isOn: $autoUpdate)
                LabeledContent("Version", value: appVersion)
                LabeledContent("Status", value: updater.status)
                Button("Jetzt nach Updates suchen") { Task { await updater.check(manual: true) } }
            }
            Section {
                Picker("Sprache", selection: $language) {
                    Text("Automatisch (Systemsprache)").tag("auto")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: language) { _, v in
                    // AppleLanguages der App selbst: macOS wählt damit beim Start die Sprache aus de.lproj/en.lproj
                    if v == "auto" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
                }
                LabeledContent("Gilt nach dem Neustart von WinKomfort.") {
                    Button("Neu starten") { try? relaunch() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

@main struct WinKomfortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared
    @StateObject var awake = Awake.shared
    var body: some Scene {
        // Kaffeetasse, solange „Wach bleiben“ aktiv ist
        MenuBarExtra("WinKomfort", systemImage: awake.mode == nil ? "macwindow.on.rectangle" : "cup.and.saucer.fill") { MenuContent() }
    }
}

