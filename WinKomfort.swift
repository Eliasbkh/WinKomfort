// WinKomfort – Windows-Komfort für macOS als Menüleisten-App.
// Setzt nur eingebaute macOS-Einstellungen; im Leerlauf schläft die App (kein Polling außer 1 Update-Check alle 6 h).
import SwiftUI
import AppKit
import ServiceManagement
import CryptoKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ScreenCaptureKit

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
    init() { reload() }
    func reload() { for f in features { on[f.id] = isOn(f) } } // nach Umstellungen beim Start erneut lesen
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
    private static var logic = TapDragLogic()   // nur im Trackpad-Thread benutzt
    private static var dragging = false         // vom Bewegungs-Zuhörer gelesen; ein Bool, kurzes Nachhinken ist harmlos
    private static var moveTap: CFMachPort?

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
        case .press: TapDragFix.dragging = true; TapDragFix.click(.leftMouseDown)
        case .release: TapDragFix.dragging = false; TapDragFix.click(.leftMouseUp)
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
                    if let t = TapDragFix.moveTap { CGEvent.tapEnable(tap: t, enable: true) }
                } else if type == .mouseMoved, TapDragFix.dragging {
                    event.type = .leftMouseDragged
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            if let moveTap {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, moveTap, 0), .commonModes)
                CGEvent.tapEnable(tap: moveTap, enable: true)
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

    var results: [AppEntry] { query.isEmpty ? pinned : match(query) }

    // Treffer, die mit dem Suchbegriff anfangen, zuerst
    func match(_ query: String) -> [AppEntry] {
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
                    .help("Schnellnotiz (⌃⌥N)").accessibilityLabel("Schnellnotiz")
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

    // MARK: Systemeinstellungen → Mitteilungen
    private nonisolated static func isOverview(_ e: [AXUIElement]) -> Bool {
        e.contains { UIAuto.role($0) == "AXHeading" && UIAuto.label($0) == "App-Mitteilungen" }
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
              let start = e.firstIndex(where: { UIAuto.role($0) == "AXHeading" && UIAuto.label($0) == "App-Mitteilungen" }) else { return nil }
        return e[start...].compactMap { el in
            let l = UIAuto.label(el)
            guard UIAuto.role(el) == "AXButton", let comma = l.range(of: ", ") else { return nil }
            let name = String(l[..<comma.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}"))
            // „Kritisch“ allein heißt: Mitteilungen aus, nur kritische Hinweise (Notfälle) kommen noch durch
            let summary = String(l[comma.upperBound...])
            return (el, NotifApp(name: name, on: summary != "Aus" && summary != "Kritisch"))
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
            return (apps, dnd, apps == nil ? "Mitteilungs-Einstellungen konnten nicht gelesen werden." : "")
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
            return (Self.overview()?.map(\.1), nil, now == on ? "" : "„\(name)“ ließ sich nicht umschalten.")
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
                DispatchQueue.main.async { MainActor.assumeIsolated { Notifs.shared.message = "Schalte \(i + 1)/\(targets.count): \(name) …" } }
                if Self.switchOne(name, on) != on { failed.append(name) }
            }
            if on && failed.isEmpty { DispatchQueue.main.async { UserDefaults.standard.removeObject(forKey: key) } }
            return (Self.overview()?.map(\.1), nil, failed.isEmpty ? "" : "Nicht umgeschaltet: \(failed.joined(separator: ", "))")
        }
    }

    func setDND(_ on: Bool) {
        run {
            guard let now = Self.focus(want: on) else { return (nil, nil, "Kontrollzentrum nicht erreichbar.") }
            return (nil, now, now == on ? "" : "„Nicht stören“ ließ sich nicht umschalten.")
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
                    if m.items.isEmpty { Text(m.busy ? "Lese Menüleiste …" : m.message).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(group)
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
                Text(n.message.isEmpty ? "WinKomfort stellt das im Hintergrund in den Systemeinstellungen um – Apple bietet dafür keinen direkten Weg. Ein Schalter dauert 2–3 Sekunden." : n.message)
                    .foregroundStyle(n.message.isEmpty || n.busy ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { if n.apps.isEmpty && !n.busy { n.load() } }
    }
}

// MARK: - Suche (wie Spotlight): Apps sofort, Dateien über den macOS-Suchindex, Rechner, Web
// Sparsam: kein eigenes Indizieren; die Dateisuche läuft nur, während das Fenster offen ist, und stoppt nach dem ersten Ergebnis-Schwung.

struct SearchHit: Identifiable {
    enum Kind { case calc, app, file, web }
    let kind: Kind
    let title: String
    let subtitle: String
    let path: String?
    var id: String { "\(kind)|\(path ?? title)" }
}

@MainActor final class SearchModel: ObservableObject {
    static let shared = SearchModel()
    @Published var query = "" { didSet { if query != oldValue { selected = 0; update() } } }
    @Published private(set) var hits: [SearchHit] = []
    @Published var selected = 0
    @Published var opened = 0
    private var files: [SearchHit] = []
    private let mdq = NSMetadataQuery()

    init() {
        mdq.searchScopes = [NSMetadataQueryUserHomeScope]
        mdq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mdq, queue: .main) { _ in
            MainActor.assumeIsolated { SearchModel.shared.collectFiles() }
        }
    }

    private func collectFiles() {
        files = (0..<min(mdq.resultCount, 60)).compactMap { i -> SearchHit? in
            guard let item = mdq.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.hasSuffix(".app"), !path.contains("/Library/"), !path.contains("/.") else { return nil }
            let dir = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return SearchHit(kind: .file, title: (path as NSString).lastPathComponent, subtitle: dir, path: path)
        }.prefix(8).map { $0 }
        mdq.stop() // fertig gesammelt – nichts läuft weiter im Hintergrund
        rebuild()
    }

    private func update() {
        mdq.stop()
        files = []
        rebuild()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return }
        mdq.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, q)
        mdq.start()
    }

    private func rebuild() {
        let q = query.trimmingCharacters(in: .whitespaces)
        var h: [SearchHit] = []
        if let v = Calc.evaluate(q) {
            h.append(SearchHit(kind: .calc, title: "= " + Calc.format(v), subtitle: "Enter kopiert das Ergebnis", path: nil))
        }
        if !q.isEmpty {
            h += StartModel.shared.match(q).prefix(6).map { SearchHit(kind: .app, title: $0.name, subtitle: "App", path: $0.path) }
            h += files
            h.append(SearchHit(kind: .web, title: "Im Web suchen: „\(q)“", subtitle: "Öffnet deinen Browser", path: nil))
        }
        hits = h
        selected = min(selected, max(h.count - 1, 0))
    }

    func move(_ d: Int) { if !hits.isEmpty { selected = (selected + d + hits.count) % hits.count } }

    func openSelected() {
        guard hits.indices.contains(selected) else { return }
        let hit = hits[selected]
        switch hit.kind {
        case .app, .file: NSWorkspace.shared.open(URL(fileURLWithPath: hit.path!))
        case .calc:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(hit.title.dropFirst(2)), forType: .string)
        case .web:
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            NSWorkspace.shared.open(c.url!)
        }
        SearchPanel.hide()
    }

    func reset() {
        mdq.stop()
        query = ""
        files = []
        hits = []
        opened += 1
    }

    func icon(_ hit: SearchHit) -> NSImage {
        switch hit.kind {
        case .app, .file: return StartModel.shared.icon(hit.path!)
        case .calc: return NSImage(systemSymbolName: "equal.circle.fill", accessibilityDescription: "Rechner")!
        case .web: return NSImage(systemSymbolName: "globe", accessibilityDescription: "Web")!
        }
    }
}

@MainActor enum SearchPanel {
    private static var panel: KeyPanel?
    private static let width: CGFloat = 640

    static func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    static func hide() { panel?.orderOut(nil); SearchModel.shared.reset() }
    // Beim Start einmal unsichtbar bauen – dann ist das Suchfeld beim ersten Öffnen sofort da
    static func prepare() { _ = panel ?? make(); panel?.contentView?.layoutSubtreeIfNeeded() }

    static func show() {
        StartModel.shared.reload() // App-Liste frisch (dauert nur Millisekunden)
        SearchModel.shared.reset()
        let p = panel ?? make()
        resize()
        p.orderFrontRegardless()
        p.makeKey()
        focusField()
    }

    // Textfeld aktivieren (blinkender Cursor). Klappt es nicht sofort, gleich noch einmal versuchen
    static func focusField(retries: Int = 3) {
        guard let p = panel, p.isVisible else { return }
        if !(p.firstResponder is NSTextView), let f = SearchField.current {
            p.makeKey()
            p.makeFirstResponder(f)
            (f.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (f.stringValue as NSString).length, length: 0))
        }
        if !(p.firstResponder is NSTextView), retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { focusField(retries: retries - 1) } }
        }
    }

    // Fensterhöhe folgt der Trefferzahl, die Oberkante bleibt stehen
    static func resize() {
        guard let p = panel else { return }
        let rows = min(SearchModel.shared.hits.count, 9)
        let h: CGFloat = 60 + (rows > 0 ? CGFloat(rows) * 46 + 17 : 0)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let top = screen.visibleFrame.maxY - screen.visibleFrame.height * 0.22
        p.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: top - h, width: width, height: h), display: true)
    }

    private static func make() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fixedHost(SearchView())
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { hide() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard panel?.isKeyWindow == true else { return e }
            // ⌥ noch gedrückt vom Öffnen mit ⌥ Leertaste? Dann normale Buchstaben statt ®, ∑ & Co.
            if e.modifierFlags.contains(.option), !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
               let plain = e.charactersIgnoringModifiers, plain.count == 1, plain.first!.isLetter || plain.first!.isNumber {
                MainActor.assumeIsolated { SearchModel.shared.query += e.modifierFlags.contains(.shift) ? plain.uppercased() : plain }
                return nil
            }
            // Textfeld in den ersten Millisekunden noch nicht bereit? Dann selbst ins Suchfeld schreiben – kein Buchstabe geht verloren
            if !(panel?.firstResponder is NSTextView), !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
               let chars = e.characters, !chars.isEmpty, e.keyCode != 53, e.keyCode != 125, e.keyCode != 126, e.keyCode != 36 {
                MainActor.assumeIsolated {
                    if e.keyCode == 51 { _ = SearchModel.shared.query.popLast() } // Rückschritt
                    else if chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { SearchModel.shared.query += chars }
                    focusField(retries: 0)
                }
                return nil
            }
            switch e.keyCode {
            case 53: MainActor.assumeIsolated { hide() }; return nil                       // Esc
            case 125: MainActor.assumeIsolated { SearchModel.shared.move(1) }; return nil  // ↓
            case 126: MainActor.assumeIsolated { SearchModel.shared.move(-1) }; return nil // ↑
            default: return e
            }
        }
        panel = p
        return p
    }
}

// Echtes macOS-Textfeld statt SwiftUI-TextField: lässt sich im schwebenden Panel zuverlässig aktivieren (mit Cursor)
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    static weak var current: NSTextField?

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 22)
        f.placeholderString = "Suchen – Apps, Dateien, Rechnen …"
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.delegate = context.coordinator
        f.setAccessibilityLabel("Suche")
        SearchField.current = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard f.stringValue != text else { return }
        f.stringValue = text
        (f.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) // Cursor ans Ende
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ n: Notification) { parent.text = (n.object as? NSTextField)?.stringValue ?? "" }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

struct SearchView: View {
    @ObservedObject var m = SearchModel.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                SearchField(text: $m.query) { m.openSelected() }
            }
            .padding(.horizontal, 18).frame(height: 60)
            if !m.hits.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(m.hits.enumerated()), id: \.element.id) { i, hit in
                                HStack(spacing: 10) {
                                    Image(nsImage: m.icon(hit)).resizable().scaledToFit().frame(width: 28, height: 28)
                                        .foregroundStyle(i == m.selected ? .white : .accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.title).lineLimit(1)
                                        Text(hit.subtitle).font(.caption).lineLimit(1).truncationMode(.middle)
                                            .foregroundStyle(i == m.selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 44)
                                .foregroundStyle(i == m.selected ? .white : .primary)
                                .background(RoundedRectangle(cornerRadius: 8).fill(i == m.selected ? Color.accentColor : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { m.selected = i; m.openSelected() }
                                .id(i)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(i == m.selected ? .isSelected : [])
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: m.selected) { _, i in proxy.scrollTo(i) }
                }
            }
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
        .onChange(of: m.hits.count) { _, _ in SearchPanel.resize() }
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
    static func show(_ text: String, symbol: String) {
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        let view = fixedHost(Label(text, systemImage: symbol).font(.headline).padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule()))
        let size = view.fittingSize
        p.contentView = view
        let screen = NSScreen.main!.visibleFrame
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.18, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        hideTask?.cancel()
        let t = DispatchWorkItem { panel?.orderOut(nil) }
        hideTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: t)
        NSAccessibility.post(element: p, notification: .announcementRequested, userInfo: [.announcement: text])
    }
}

// MARK: - Schnellnotiz (oben links, immer im Vordergrund, speichert automatisch)

@MainActor final class QuickNote: ObservableObject {
    static let shared = QuickNote()
    @Published var text = UserDefaults.standard.string(forKey: "quickNote") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "quickNote") }
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
        // Fokus sofort ins Textfeld, damit man direkt lostippen kann
        p.contentView?.layoutSubtreeIfNeeded()
        func editor(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView, t.isEditable { return t }
            for s in v.subviews { if let e = editor(s) { return e } }
            return nil
        }
        if let content = p.contentView, let e = editor(content) { p.makeFirstResponder(e) }
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
            HStack {
                Label("Notiz", systemImage: "note.text").font(.headline)
                Spacer()
                Button { n.text = "" } label: { Image(systemName: "trash") }
                    .help("Notiz leeren").accessibilityLabel("Notiz leeren").disabled(n.text.isEmpty)
                Button { n.hide() } label: { Image(systemName: "xmark") }
                    .help("Ausblenden (⌃⌥N)").accessibilityLabel("Notiz ausblenden")
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
}

// MARK: - Fenster anheften (immer im Vordergrund)
// macOS lässt keine App die Ebene fremder Fenster ändern. WinKomfort legt deshalb eine Live-Kopie des Fensters
// (ScreenCaptureKit, nur dieses eine Fenster, höchstens 15 Bilder/s und nur bei Änderungen) in ein eigenes, schwebendes Fenster an dieselbe Stelle.
// Klick darauf → das echte Fenster kommt nach vorne. Wechselst du weg, liegt die Kopie wieder obenauf.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

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
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ClickView()
        view.wantsLayer = true
        view.layer?.addSublayer(surface)
        surface.contentsGravity = .resize
        view.onClick = { [weak self] in self?.focusReal() }
        overlay.contentView = view
    }

    // Rahmen des echten Fensters in Bildschirmkoordinaten (AppKit: Ursprung unten links)
    func frame() -> NSRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = UIAuto.attr(ax, kAXPositionAttribute), let sv = UIAuto.attr(ax, kAXSizeAttribute) else { return nil }
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
    }

    // Sobald das echte Fenster zugeht: Kopie und Aufnahme sofort beenden
    private func watchClose() {
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, ctx in
            guard let ctx else { return }
            let pin = Unmanaged<PinnedWindow>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { Pins.shared.remove(pin) } }
        }, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, ax, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        closeObserver = obs
    }

    func start() async throws {
        watchClose()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw CocoaError(.featureUnsupported) }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: config(for: w.frame.size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try await stream.startCapture()
        self.stream = stream
        size = w.frame.size
    }

    private func config(for s: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        c.width = Int(s.width * scale)
        c.height = Int(s.height * scale)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15 Bilder/s reichen und sparen Strom
        c.showsCursor = false
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
    }

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
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { overlay.orderOut(nil) } else { overlay.orderFrontRegardless() }
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
            AXObserverRemoveNotification(o, ax, kAXUIElementDestroyedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            closeObserver = nil
        }
        overlay.orderOut(nil)
    }
}

final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class Pins: ObservableObject {
    static let shared = Pins()
    @Published private(set) var pinned: [PinnedWindow] = []
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
            Toast.show("\(p.name) gelöst", symbol: "pin.slash")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess() // fragt einmal nach „Bildschirmaufnahme“
            Toast.show("Bitte „Bildschirmaufnahme“ für WinKomfort erlauben", symbol: "lock")
            return
        }
        let title = (UIAuto.attr(ax, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Fenster"
        let p = PinnedWindow(windowID: id, pid: app.processIdentifier, ax: ax, name: title)
        Task { @MainActor in
            do {
                try await p.start()
                pinned.append(p)
                observe()
                Toast.show("\(title) angeheftet", symbol: "pin.fill")
            } catch {
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

    static func start() {
        afterTrust {
            guard tap == nil, (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == "bottom" else { return }
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
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: {
                  let top = primary.frame.maxY - $0.frame.maxY
                  return p.x >= $0.frame.minX && p.x < $0.frame.maxX && p.y >= top && p.y <= top + $0.frame.height
              }) else { return }
        let bottom = primary.frame.maxY - screen.frame.minY
        if p.y < bottom - 30 { pushed = false; return }       // Rand verlassen → nächstes Mal wieder helfen
        guard !pushed, p.y >= bottom - 1, !dockVisible() else { return }
        pushed = true
        let x = p.x
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<15 { // ~¼ s sanft weiterdrücken, Zeiger bleibt am Rand
                guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: bottom - 1), mouseButton: .left) else { return }
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
    private static var searchRef: EventHotKeyRef?
    static let searchKeys: [(id: String, title: String, mods: Int)] =
        [("opt", "⌥ Leertaste", optionKey), ("cmd", "⌘ Leertaste", cmdKey), ("ctrl", "⌃ Leertaste", controlKey), ("off", "Aus", 0)]

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch id {
                    case 2: SearchPanel.toggle()
                    case 3: QuickNote.shared.toggle()
                    case 4: Pins.shared.toggleFrontmost()
                    default: openTaskManager()
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        registerSearch()
        var note: EventHotKeyRef?, pin: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x574B4654), id: 3),
                            GetApplicationEventTarget(), 0, &note)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | cmdKey), EventHotKeyID(signature: OSType(0x574B4654), id: 4),
                            GetApplicationEventTarget(), 0, &pin)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | shiftKey),
                            EventHotKeyID(signature: OSType(0x574B4654), id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    // Suche: Kürzel aus den Einstellungen (Standard ⌥ Leertaste)
    static func registerSearch() {
        if let r = searchRef { UnregisterEventHotKey(r); searchRef = nil }
        let key = UserDefaults.standard.string(forKey: "searchHotkey") ?? "opt"
        guard let k = searchKeys.first(where: { $0.id == key }), k.mods != 0 else { return }
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(k.mods), EventHotKeyID(signature: OSType(0x574B4654), id: 2),
                            GetApplicationEventTarget(), 0, &searchRef)
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
    @ObservedObject var login = LoginItems.shared
    @ObservedObject var bg = backgroundSwitches
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
            Section("Apps beim Anmelden") {
                if login.items.isEmpty { Text(login.message.isEmpty ? "Keine." : login.message).foregroundStyle(.secondary) }
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
                if bg.items.isEmpty { Text(bg.busy ? "Lese Hintergrundaktivitäten …" : bg.message).foregroundStyle(.secondary) }
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
                Text(bg.message.isEmpty ? "Darf eine App im Hintergrund laufen (Updater, Sync …)?" : bg.message)
            }
            if !a.message.isEmpty { Section { Text(a.message) } }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }
}

@MainActor func openAutostarts() {
    Autostarts.shared.scan()
    LoginItems.shared.load()
    if !backgroundSwitches.busy { backgroundSwitches.load() }
    showWindow("autostarts", "Autostarts") { AutostartView() }
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
            return (r, r == nil ? "Konnte die Einstellungen nicht lesen." : "")
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
            return (r, ok ? "" : "Konnte den Schalter nicht umstellen.")
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
                  UIAuto.label(el) != "Im Finder anzeigen", seen.insert(id).inserted else { return nil }
            let name = String(id.dropFirst("background-switch-".count))
            guard name != "WinKomfort" else { return nil } // sich selbst nicht abschaltbar machen
            let detail = e.first { UIAuto.id($0) == "background-detail-for-\(name)-app-login-items" && UIAuto.role($0) == "AXStaticText" }
                .flatMap { UIAuto.attr($0, kAXValueAttribute) as? String } ?? ""
            return (SysSwitch(id: id, name: name, group: "Hintergrund", on: UIAuto.value(el), detail: detail), el)
        }
    })

// Systemeinstellungen → Menüleiste: Symbole von macOS und von Apps
let menuBarSwitches = SettingsSwitches(
    url: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
    ready: { $0.contains { UIAuto.role($0) == "AXHeading" && UIAuto.label($0) == "In Menüleiste erlauben" } },
    extract: { e in
        let names = ["controlcenter-battery-id": "Batterie", "controlcenter-userSwitcher-id": "Schneller Benutzerwechsel"]
        var out: [(SysSwitch, AXUIElement)] = []
        var lastText = "", inApps = false
        for el in e {
            let role = UIAuto.role(el)
            if role == "AXHeading" { inApps = UIAuto.label(el) == "In Menüleiste erlauben" }
            if role == "AXStaticText" { lastText = (UIAuto.attr(el, kAXValueAttribute) as? String) ?? "" }
            guard role == "AXCheckBox" else { continue }
            if let id = UIAuto.id(el), id.hasPrefix("controlcenter-"), id.hasSuffix("-id") {
                let label = UIAuto.label(el)
                out.append((SysSwitch(id: id, name: label.isEmpty ? (names[id] ?? id) : label.replacingOccurrences(of: "\u{AD}", with: ""),
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
        message = items.isEmpty ? "Warte auf Erlaubnis für „System Events“ …" : ""
        queue.async {
            let r = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if let (name, path) = r.change { self.removed[name] = path }
                    guard let list = r.list else {
                        self.message = "Kein Zugriff auf „System Events“. Erlauben unter Datenschutz & Sicherheit → Automation."
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
        HotKey.register()
        SearchPanel.prepare()
        DockReveal.start()
        Task { await Updater.shared.loop() }
    }
}

// MARK: - Wach bleiben (offizielle macOS-Energie-Schnittstelle, wie „caffeinate“)

@MainActor final class Awake: ObservableObject {
    static let shared = Awake()
    enum Mode: String { case display = "Bildschirm bleibt an", system = "Mac bleibt wach, Bildschirm darf aus" }
    @Published private(set) var mode: Mode?
    @Published private(set) var until: Date?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    static let durations: [(String, Int?)] = [("30 Minuten", 30), ("1 Stunde", 60), ("2 Stunden", 120), ("5 Stunden", 300), ("Unbegrenzt", nil)]

    func start(_ m: Mode, minutes: Int?) {
        stop()
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
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        timer?.invalidate()
        timer = nil
        mode = nil
        until = nil
    }

    var status: String {
        guard let mode else { return "Aus" }
        return mode.rawValue + (until.map { " – bis \($0.formatted(date: .omitted, time: .shortened))" } ?? " – unbegrenzt")
    }
}

struct MenuContent: View {
    @ObservedObject var awake = Awake.shared
    var body: some View {
        Menu("Wach bleiben") {
            Text(awake.status)
            Divider()
            ForEach([Awake.Mode.display, .system], id: \.self) { m in
                Section(m.rawValue) {
                    ForEach(Awake.durations, id: \.0) { d in
                        Button(d.0) { awake.start(m, minutes: d.1) }
                    }
                }
            }
            Divider()
            Button("Bildschirm jetzt aus – Mac arbeitet weiter") { sh(["/usr/bin/pmset", "displaysleepnow"]) }
            if awake.mode != nil { Button("Wach bleiben beenden") { awake.stop() } }
        }
        Divider()
        Button("Suche …") { SearchPanel.show() }
        Button("Schnellnotiz   ⌃⌥N") { QuickNote.shared.toggle() }
        if !Pins.shared.pinned.isEmpty { Button("Alle angehefteten Fenster lösen") { Pins.shared.unpinAll() } }
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
            vc.preferredContentSize = NSSize(width: 560, height: 440) // sonst bleibt das Fenster schmaler als der Inhalt
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("Allgemein", "gearshape", GeneralTab(store: Store.shared))
        for i in groups.indices { add(groups[i], groupIcons[i], FeatureTab(store: Store.shared, group: groups[i])) }
        add("Mitteilungen", "bell.badge", NotificationsTab())
        add("Menüleiste", "menubar.rectangle", MenuBarTab())
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
                    Picker(selection: Binding(get: { UserDefaults.standard.string(forKey: "searchHotkey") ?? "opt" },
                                              set: { UserDefaults.standard.set($0, forKey: "searchHotkey"); HotKey.registerSearch(); store.objectWillChange.send() })) {
                        ForEach(HotKey.searchKeys, id: \.id) { Text($0.title).tag($0.id) }
                    } label: {
                        Text("Suche öffnen mit")
                        Text("Apps, Dateien, Rechnen und Web – wie Spotlight, nur schneller.")
                    }
                    .accessibilityLabel("Suche öffnen mit")
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
    @ObservedObject var awake = Awake.shared
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
            Section("Wach bleiben") {
                LabeledContent("Status", value: awake.status)
                ForEach([Awake.Mode.display, .system], id: \.self) { m in
                    LabeledContent(m.rawValue) {
                        Menu("Starten") {
                            ForEach(Awake.durations, id: \.0) { d in Button(d.0) { awake.start(m, minutes: d.1) } }
                        }
                        .fixedSize()
                        .accessibilityLabel("\(m.rawValue) starten")
                    }
                }
                HStack {
                    Button("Bildschirm jetzt aus – Mac arbeitet weiter") { sh(["/usr/bin/pmset", "displaysleepnow"]) }
                    Spacer()
                    if awake.mode != nil { Button("Beenden") { awake.stop() } }
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
    @StateObject var awake = Awake.shared
    var body: some Scene {
        // Kaffeetasse, solange „Wach bleiben“ aktiv ist
        MenuBarExtra("WinKomfort", systemImage: awake.mode == nil ? "macwindow.on.rectangle" : "cup.and.saucer.fill") { MenuContent() }
    }
}

