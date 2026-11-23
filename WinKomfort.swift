// WinKomfort – Windows-Komfort für macOS als Menüleisten-App.
// Setzt nur eingebaute macOS-Einstellungen; im Leerlauf schläft die App (kein Polling außer 1 Update-Check alle 6 h).
import SwiftUI
import AppKit
import ServiceManagement
import CryptoKit
import Carbon.HIToolbox

let repo = "Eliasbkh/WinKomfort" // GitHub-Repo, aus dessen Releases Updates kommen
// Öffentlicher Ed25519-Schlüssel: nur Zips, die mit dem passenden geheimen Schlüssel (sign.swift) signiert sind, werden installiert
let updateKey = "U89i1hQZcm9gVR/pFcZDUc5fBi57hUyiM0laYznx0d0="

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

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
let groups = ["Eingabe", "Fenster", "Finder", "Screenshots"]
let groupIcons = ["hand.tap", "macwindow", "folder", "camera.viewfinder"]

let features: [Feature] = [
    // Trackpad & Tastatur
    Feature(id: "drag", group: groups[0], title: "2× tippen und halten zum Ziehen",
            hint: "Wie bei Windows: Loslassen lässt sofort los.",
            prefs: trackpads.flatMap { [
                Pref(domain: $0, key: "Dragging", on: yes),
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
            hint: "Mehr Platz; das Dock kommt sofort, wenn die Maus nach unten geht.",
            prefs: [Pref(domain: "com.apple.dock", key: "autohide", on: yes),
                    Pref(domain: "com.apple.dock", key: "autohide-delay", on: ["-float", "0"]),
                    Pref(domain: "com.apple.dock", key: "autohide-time-modifier", on: ["-float", "0.25"])],
            restart: ["Dock"]),
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

    Feature(id: "fast", group: groups[1], title: "Schnellere Animationen",
            hint: "Fenster öffnen sofort, Dock und Mission Control reagieren flotter.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", on: no),
                    Pref(domain: "NSGlobalDomain", key: "NSWindowResizeTime", on: ["-float", "0.001"]),
                    Pref(domain: "com.apple.dock", key: "launchanim", on: no),
                    Pref(domain: "com.apple.dock", key: "expose-animation-duration", on: ["-float", "0.12"])],
            restart: ["Dock"]),

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
    init() { for f in features { on[f.id] = isOn(f) } }
    func binding(_ f: Feature) -> Binding<Bool> {
        Binding(get: { self.on[f.id] ?? false }, set: { v in
            apply(f, v)
            self.on[f.id] = v
            if f.id == "drag" { if v { TapDragFix.start(prompt: true) } else { TapDragFix.stop() } }
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

let closeHint = "Wie bei Windows: Letztes Fenster zu = App beendet (außer Finder)."

final class CloseWatcher {
    static let shared = CloseWatcher()
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var pending: Set<pid_t> = []
    private let skip: Set<String> = ["com.apple.finder", "de.winkomfort.app"]

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

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !skip.contains(id),
              observers[pid] == nil else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, ctx in
            CloseWatcher.shared.schedule(pid_t(Int(bitPattern: ctx)))
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, AXUIElementCreateApplication(pid), kAXUIElementDestroyedNotification as CFString,
                                  UnsafeMutableRawPointer(bitPattern: Int(pid)))
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
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
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], windows.isEmpty,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            app.terminate()
        }
    }
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
    private static var lastCount: Int32 = 0

    private static let callback: Callback = { _, _, touches, _, _ in
        // shortcut: hält jemand gleichzeitig die Taste einer externen Maus, lässt das Abheben vom Trackpad auch sie los
        if touches == 0, TapDragFix.lastCount > 0, CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let pos = CGEvent(source: nil)?.location ?? .zero
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        TapDragFix.lastCount = touches
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
        }
    }

    static func stop() {
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
    private static func handle(_ flags: CGEventFlags) {
        let f = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
        if f == .maskControl { downAt = Date() }
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
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", "\(home)/Applications"]
        all = dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.map { entry("\(dir)/\($0)") }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Angeheftet = die Apps aus deinem Dock
        let dock = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        pinned = dock.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String, let url = URL(string: s), url.isFileURL else { return nil }
            return entry(url.path)
        }
        opened += 1
    }

    var results: [AppEntry] {
        guard !query.isEmpty else { return pinned }
        let q = query.lowercased()
        let hits = all.filter { $0.name.lowercased().contains(q) || $0.file.lowercased().contains(q) }
        return Array((hits.filter { $0.name.lowercased().hasPrefix(q) } + hits.filter { !$0.name.lowercased().hasPrefix(q) }).prefix(24))
    }

    func open(_ e: AppEntry) {
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
        let host = NSHostingView(rootView: StartView())
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

// MARK: - Fenster-Helfer

@MainActor var windows: [String: NSWindow] = [:]

@MainActor func showWindow<V: View>(_ id: String, _ title: String, onClose: (() -> Void)? = nil, _ view: () -> V) {
    let w: NSWindow
    if let existing = windows[id] { w = existing } else {
        w = NSWindow(contentViewController: NSHostingController(rootView: view()))
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()
        if let onClose {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in onClose() }
        }
        windows[id] = w
    }
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
}

// MARK: - Task-Manager (⌃⇧⎋ wie bei Windows)

struct TaskRow: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let cpu: Double
    let mem: Double
}

@MainActor final class TaskModel: ObservableObject {
    static let shared = TaskModel()
    @Published var rows: [TaskRow] = []
    @Published var selection: Set<pid_t> = []
    @Published var sortOrder = [KeyPathComparator(\TaskRow.cpu, order: .reverse)]
    @Published var background = false { didSet { selection = []; refresh() } }
    private var timer: Timer?

    var sorted: [TaskRow] { rows.sorted(using: sortOrder) }

    // Läuft nur, solange das Fenster offen ist
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { TaskModel.shared.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        var kids: [pid_t: [pid_t]] = [:], parent: [pid_t: pid_t] = [:], cpu: [pid_t: Double] = [:], rss: [pid_t: Double] = [:]
        for line in sh(["/bin/ps", "-axo", "pid=,ppid=,%cpu=,rss="]).split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 4, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            kids[ppid, default: []].append(pid)
            parent[pid] = ppid
            cpu[pid] = Double(f[2]) ?? 0
            rss[pid] = Double(f[3]) ?? 0
        }
        // shortcut: zählt Kindprozesse mit (z. B. Browser-Tabs), aber keine XPC-Dienste – ganz genau ist die Aktivitätsanzeige
        func total(_ p: pid_t, _ m: [pid_t: Double]) -> Double {
            (m[p] ?? 0) + (kids[p] ?? []).reduce(0) { $0 + total($1, m) }
        }
        let apps = NSWorkspace.shared.runningApplications
        let regular = Set(apps.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        // Helfer offener Apps (Browser-Tabs …) zählen zu ihrer App – beenden würde sie abstürzen lassen
        func belongsToApp(_ p: pid_t) -> Bool {
            var cur = parent[p]
            while let c = cur, c > 1 { if regular.contains(c) { return true }; cur = parent[c] }
            return false
        }
        let shown = apps.filter { a in
            if !background { return a.activationPolicy == .regular }
            let id = a.bundleIdentifier ?? ""
            let path = (a.bundleURL ?? a.executableURL)?.path ?? "/System"
            let system = ["/System/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"].contains { path.hasPrefix($0) }
            return a.activationPolicy != .regular && !system && !id.hasPrefix("com.apple.") && id != Bundle.main.bundleIdentifier
                && !belongsToApp(a.processIdentifier)
        }
        rows = shown.map { a in
            TaskRow(id: a.processIdentifier, name: a.localizedName ?? "?", icon: a.icon,
                    cpu: total(a.processIdentifier, cpu), mem: total(a.processIdentifier, rss) * 1024)
        }
        let alive = Set(rows.map(\.id))
        selection = selection.filter { alive.contains($0) }
    }

    // Fremde Hintergrund-Apps, die gerade spürbar Strom ziehen
    func endHogs() {
        let hogs = rows.filter { $0.cpu >= 3 }
        guard !hogs.isEmpty else {
            alert("Keine Stromfresser gefunden", "Gerade braucht keine Hintergrund-App mehr als 3 % CPU.")
            return
        }
        guard alert("\(hogs.count) Stromfresser beenden?",
                    hogs.map { "• \($0.name) – \($0.cpu.formatted(.number.precision(.fractionLength(0)))) % CPU" }.joined(separator: "\n")
                    + "\n\nSie werden normal beendet und starten beim nächsten Mal wieder, falls sie Autostart haben.",
                    ["Beenden", "Abbrechen"]) else { return }
        end(Set(hogs.map(\.id)), force: false)
    }

    func end(_ ids: Set<pid_t>, force: Bool) {
        for id in ids {
            guard let a = NSRunningApplication(processIdentifier: id) else { continue }
            if force { a.forceTerminate() } else { a.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { TaskModel.shared.refresh() } }
    }
}

struct TaskView: View {
    @ObservedObject var m = TaskModel.shared
    var body: some View {
        VStack(spacing: 0) {
            Picker("Anzeige", selection: $m.background) {
                Text("Apps").tag(false)
                Text("Hintergrund").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(10)
            Table(m.sorted, selection: $m.selection, sortOrder: $m.sortOrder) {
                TableColumn("Name", value: \.name) { r in
                    HStack {
                        if let i = r.icon { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
                        Text(r.name)
                    }
                }
                TableColumn("CPU", value: \.cpu) { r in Text(r.cpu.formatted(.number.precision(.fractionLength(1))) + " %").monospacedDigit() }
                    .width(70)
                TableColumn("Arbeitsspeicher", value: \.mem) { r in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(r.mem), countStyle: .memory)).monospacedDigit()
                }
                .width(120)
            }
            .contextMenu(forSelectionType: pid_t.self) { ids in
                Button("Task beenden") { m.end(ids, force: false) }
                Button("Sofort beenden (erzwingen)") { m.end(ids, force: true) }
            }
            HStack {
                Text(m.rows.isEmpty && m.background ? "Keine fremden Hintergrund-Apps aktiv"
                     : "\(m.rows.count) \(m.background ? "Hintergrund-Apps" : "Apps") · alle 2 s aktualisiert")
                    .foregroundStyle(.secondary)
                Spacer()
                if m.background { Button("Stromfresser beenden …") { m.endHogs() } }
                Button("Aktivitätsanzeige") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Button("Sofort beenden") { m.end(m.selection, force: true) }.disabled(m.selection.isEmpty)
                Button("Task beenden") { m.end(m.selection, force: false) }
                    .keyboardShortcut(.defaultAction).disabled(m.selection.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 540, minHeight: 420)
    }
}

@MainActor func openTaskManager() {
    showWindow("tasks", "Task-Manager", onClose: { MainActor.assumeIsolated { TaskModel.shared.stop() } }) { TaskView() }
    TaskModel.shared.start()
}

enum HotKey {
    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { openTaskManager() } }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | shiftKey),
                            EventHotKeyID(signature: OSType(0x574B4654), id: 1), GetApplicationEventTarget(), 0, &ref)
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
            if err != nil { message = "Abgebrochen – \(item.label) wurde nicht geändert."; scan(); return }
        } else {
            cmds.forEach { sh(["/bin/sh", "-c", $0 + " 2>/dev/null"]) }
        }
        message = on ? "\(item.label) startet wieder automatisch." : "\(item.label) startet nicht mehr automatisch."
        scan()
    }
}

struct AutostartView: View {
    @ObservedObject var a = Autostarts.shared
    var body: some View {
        Form {
            Section {
                if a.items.isEmpty { Text("Keine fremden Autostarts gefunden.").foregroundStyle(.secondary) }
                ForEach(a.items) { item in
                    Toggle(isOn: Binding(get: { item.enabled }, set: { a.set(item, $0) })) {
                        Text(item.label)
                        Text("\(item.program.isEmpty ? "–" : item.program)\(item.daemon ? " · systemweit, fragt nach Passwort" : "")")
                    }
                    .accessibilityLabel(item.label)
                }
            } header: {
                Text("Hintergrund-Starter von Apps")
            } footer: {
                Text("Ausschalten verhindert den automatischen Start – nichts wird gelöscht, Einschalten macht es rückgängig. Apple-Dienste werden nicht angezeigt.")
            }
            Section {
                LabeledContent {
                    Button("Öffnen …") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                } label: {
                    Text("Apps beim Anmelden")
                    Text("Apps wie Spotify oder Steam stellst du in den Systemeinstellungen ein.")
                }
            }
            if !a.message.isEmpty { Section { Text(a.message) } }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
    }
}

@MainActor func openAutostarts() {
    Autostarts.shared.scan()
    showWindow("autostarts", "Autostarts") { AutostartView() }
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
        guard !items.isEmpty, alert("\(items.count) Objekt(e) in den Papierkorb legen?",
            items.map { "• \($0.name)" }.joined(separator: "\n")
            + "\n\nAlles wird protokolliert. Wiederherstellen geht, solange der Papierkorb nicht geleert ist – Apple-Apps gibt es außerdem kostenlos im App Store.",
            ["In den Papierkorb", "Abbrechen"]) else { return }
        message = ""
        for c in items {
            if let trash = finder("POSIX path of ((delete (POSIX file \"\(c.path)\" as alias)) as alias)") {
                log.append(Removed(name: c.name, original: c.path, trash: trash, date: Date(), store: c.store))
                save()
            } else {
                message = "\(c.name) konnte nicht entfernt werden."
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
            message = "\(r.name) ist wieder da."
        } else if let s = r.store {
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id\(s)")!)
            message = "\(r.name) ist nicht mehr im Papierkorb – im App Store kostenlos neu laden."
        } else {
            message = "\(r.name) ist nicht mehr im Papierkorb. GarageBand lädt die Sounds beim nächsten Start selbst nach."
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
        .frame(width: 500, height: 560)
    }
}

@MainActor func openCleanup() {
    Cleaner.shared.scan()
    showWindow("cleanup", "Mac aufräumen") { CleanupView() }
}

// MARK: - Popup

@MainActor @discardableResult
func alert(_ title: String, _ text: String, _ buttons: [String] = ["OK"]) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    buttons.forEach { a.addButton(withTitle: $0) }
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
    @Published var status = "Noch nicht geprüft"

    func loop() async {
        try? await Task.sleep(for: .seconds(10))
        while true {
            await check(manual: false)
            try? await Task.sleep(for: .seconds(6 * 3600))
        }
    }

    func check(manual: Bool) async {
        status = "Suche nach Updates …"
        do {
            let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard latest.compare(appVersion, options: .numeric) == .orderedDescending else {
                status = "Du hast die neueste Version."
                if manual { alert("Kein Update nötig", "Version \(appVersion) ist aktuell.") }
                return
            }
            guard let zip = rel.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let sig = rel.assets.first(where: { $0.name == zip.name + ".sig" }) else {
                status = "Version \(latest) hat keine signierte Download-Datei."
                return
            }
            if !UserDefaults.standard.bool(forKey: "autoUpdate") {
                guard alert("Neue Version \(latest) verfügbar", rel.body ?? "", ["Jetzt installieren", "Später"]) else {
                    status = "Version \(latest) verfügbar"
                    return
                }
            }
            status = "Installiere Version \(latest) …"
            try await install(zip.browser_download_url, sig: sig.browser_download_url, expected: latest, notes: rel.body ?? "")
        } catch {
            status = "Update-Prüfung fehlgeschlagen"
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
            throw UpdateError("Das Update hat die falsche Version (\(newVersion)) – es wurde nicht installiert.")
        }
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: new)
        UserDefaults.standard.set(notes, forKey: "notes")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    // App erneut öffnen (Finder, Spotlight, Startmenü) → Einstellungen zeigen, auch wenn das Menüleisten-Symbol versteckt ist
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { openSettingsWindow() }
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let d = UserDefaults.standard
        d.register(defaults: ["autoUpdate": true, "startMenu": true])
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
        if let drag = features.first(where: { $0.id == "drag" }), isOn(drag) { TapDragFix.start() }
        if d.bool(forKey: "startMenu") { StartKey.start() }
        HotKey.register()
        Task { await Updater.shared.loop() }
    }
}

struct MenuContent: View {
    var body: some View {
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
@MainActor func openSettingsWindow() {
    if windows["settings"] == nil {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add<V: View>(_ title: String, _ icon: String, _ view: V) {
            let vc = NSHostingController(rootView: view.frame(width: 560, height: 440))
            vc.title = title // wird zum Fenstertitel, wie bei Systemapps
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("Allgemein", "gearshape", GeneralTab(store: Store.shared))
        for i in groups.indices { add(groups[i], groupIcons[i], FeatureTab(store: Store.shared, group: groups[i])) }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.title = "Allgemein"
        w.isReleasedWhenClosed = false
        w.center()
        windows["settings"] = w
    }
    NSApp.activate(ignoringOtherApps: true)
    windows["settings"]?.makeKeyAndOrderFront(nil)
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
                if group == groups[1] {
                    Toggle(isOn: store.closeQuits) { Text("Schließen beendet die App"); Text(closeHint) }
                        .accessibilityLabel("Schließen beendet die App")
                }
                ForEach(features.filter { $0.group == group }) { f in
                    Toggle(isOn: store.binding(f)) { Text(f.title); Text(f.hint) }
                        .accessibilityLabel(f.title)
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
            Section("Updates") {
                Toggle("Updates automatisch installieren", isOn: $autoUpdate)
                LabeledContent("Version", value: appVersion)
                LabeledContent("Status", value: updater.status)
                Button("Jetzt nach Updates suchen") { Task { await updater.check(manual: true) } }
            }
            Section {
                LabeledContent("Task-Manager", value: "⌃⇧⎋")
                Button("Autostarts …") { openAutostarts() }
                Button("Mac aufräumen …") { openCleanup() }
            }
        }
        .formStyle(.grouped)
    }
}

@main struct WinKomfortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared
    var body: some Scene {
        MenuBarExtra("WinKomfort", systemImage: "macwindow.on.rectangle") { MenuContent() }
    }
}

