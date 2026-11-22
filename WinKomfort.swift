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
            hint: "Erscheint nur, wenn die Maus nach oben geht – Fenster bekommen die volle Höhe.",
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
            restart: ["Dock"]),
    Feature(id: "desktop", group: groups[1], title: "Klick auf Schreibtisch versteckt keine Fenster",
            hint: "Fenster bleiben stehen, wenn du aus Versehen auf den Hintergrund klickst.",
            prefs: [Pref(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", on: no)],
            restart: ["Dock"]),
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
    @Published var on: [String: Bool] = [:]
    init() { for f in features { on[f.id] = isOn(f) } }
    func binding(_ f: Feature) -> Binding<Bool> {
        Binding(get: { self.on[f.id] ?? false }, set: { v in
            apply(f, v)
            self.on[f.id] = v
            if f.id == "drag" { if v { TapDragFix.start() } else { TapDragFix.stop() } }
        })
    }
    var closeQuits: Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: "closeQuits") }, set: { v in
            UserDefaults.standard.set(v, forKey: "closeQuits")
            CloseWatcher.shared.setEnabled(v)
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
    private var waitTimer: Timer?
    private let skip: Set<String> = ["com.apple.finder", "de.winkomfort.app"]

    func setEnabled(_ on: Bool) {
        stop()
        guard on else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            // Nur solange die Freigabe fehlt: alle 2 s nachsehen, dann sofort starten
            waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                self?.setEnabled(true)
            }
            return
        }
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
        waitTimer?.invalidate()
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
func afterTrust(_ then: @escaping () -> Void) {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) { then(); return }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
        guard AXIsProcessTrusted() else { return }
        t.invalidate()
        then()
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

    static func start() {
        afterTrust {
            guard devices.isEmpty,
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
        var kids: [pid_t: [pid_t]] = [:], cpu: [pid_t: Double] = [:], rss: [pid_t: Double] = [:]
        for line in sh(["/bin/ps", "-axo", "pid=,ppid=,%cpu=,rss="]).split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 4, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            kids[ppid, default: []].append(pid)
            cpu[pid] = Double(f[2]) ?? 0
            rss[pid] = Double(f[3]) ?? 0
        }
        // shortcut: zählt Kindprozesse mit (z. B. Browser-Tabs), aber keine XPC-Dienste – ganz genau ist die Aktivitätsanzeige
        func total(_ p: pid_t, _ m: [pid_t: Double]) -> Double {
            (m[p] ?? 0) + (kids[p] ?? []).reduce(0) { $0 + total($1, m) }
        }
        rows = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { a in
            TaskRow(id: a.processIdentifier, name: a.localizedName ?? "?", icon: a.icon,
                    cpu: total(a.processIdentifier, cpu), mem: total(a.processIdentifier, rss) * 1024)
        }
        let alive = Set(rows.map(\.id))
        selection = selection.filter { alive.contains($0) }
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
            Table(m.sorted, selection: $m.selection, sortOrder: $m.sortOrder) {
                TableColumn("Name", value: \.name) { r in
                    HStack {
                        if let i = r.icon { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
                        Text(r.name)
                    }
                }
                TableColumn("CPU", value: \.cpu) { r in Text(String(format: "%.1f %%", r.cpu)).monospacedDigit() }
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
                Text("\(m.rows.count) Apps · aktualisiert alle 2 s").foregroundStyle(.secondary)
                Spacer()
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
    func applicationDidFinishLaunching(_ n: Notification) {
        let d = UserDefaults.standard
        d.register(defaults: ["autoUpdate": true])
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
        HotKey.register()
        Task { await Updater.shared.loop() }
    }
}

struct MenuContent: View {
    var body: some View {
        Button("Task-Manager …") { openTaskManager() }
            .keyboardShortcut(.escape, modifiers: [.control, .shift])
        Button("Mac aufräumen …") { openCleanup() }
        Divider()
        SettingsLink { Text("Einstellungen …") }.keyboardShortcut(",")
        Button("Nach Updates suchen …") { Task { await Updater.shared.check(manual: true) } }
        Divider()
        Button("WinKomfort beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    var body: some View {
        TabView {
            GeneralTab(store: store).tabItem { Label("Allgemein", systemImage: "gearshape") }
            ForEach(groups.indices, id: \.self) { i in
                FeatureTab(store: store, group: groups[i]).tabItem { Label(groups[i], systemImage: groupIcons[i]) }
            }
        }
        .frame(width: 560, height: 470)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct FeatureTab: View {
    @ObservedObject var store: Store
    let group: String
    var body: some View {
        Form {
            Section {
                if group == groups[1] {
                    Toggle(isOn: store.closeQuits) { Text("Schließen beendet die App"); Text(closeHint) }
                }
                ForEach(features.filter { $0.group == group }) { f in
                    Toggle(isOn: store.binding(f)) { Text(f.title); Text(f.hint) }
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
                    Text(AXIsProcessTrusted() ? "Freigegeben" : "Nicht freigegeben – nötig für Ziehen und „Schließen beendet die App“")
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
                Button("Mac aufräumen …") { openCleanup() }
            }
        }
        .formStyle(.grouped)
    }
}

@main struct WinKomfortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store()
    var body: some Scene {
        MenuBarExtra("WinKomfort", systemImage: "macwindow.on.rectangle") { MenuContent() }
        Settings { SettingsView(store: store) }
    }
}
