// WinKomfort – Windows-Komfort für macOS als Menüleisten-App.
// Setzt nur eingebaute macOS-Einstellungen; im Leerlauf schläft die App (kein Polling außer 1 Update-Check alle 6 h).
import SwiftUI
import AppKit
import ServiceManagement
import CryptoKit

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
let groups = ["Trackpad & Tastatur", "Fenster & Bildschirm", "Finder & Dateien", "Screenshots"]

let features: [Feature] = [
    // Trackpad & Tastatur
    Feature(id: "drag", group: groups[0], title: "2× tippen und halten zum Ziehen",
            hint: "Fenster und Dateien verschieben, ohne zu drücken.",
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
            hint: "⇧⌘4 / ⇧⌘5 kopiert direkt – einfach mit ⌘V einfügen.",
            prefs: [Pref(domain: "com.apple.screencapture", key: "target", on: ["-string", "clipboard"])],
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
        Binding(get: { self.on[f.id] ?? false }, set: { v in apply(f, v); self.on[f.id] = v })
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

let closeHint = "Letztes Fenster zu = App beendet (außer Finder). Braucht Zugriff unter Bedienungshilfen."

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
        Task { await Updater.shared.loop() }
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    var body: some View {
        ForEach(groups, id: \.self) { g in
            Section(g) {
                if g == groups[1] { Toggle("Schließen beendet die App", isOn: store.closeQuits) }
                ForEach(features.filter { $0.group == g }) { f in Toggle(f.title, isOn: store.binding(f)) }
            }
        }
        Divider()
        SettingsLink { Text("Einstellungen …") }.keyboardShortcut(",")
        Button("Nach Updates suchen") { Task { await Updater.shared.check(manual: true) } }
        Divider()
        Text("Version \(appVersion)")
        Button("WinKomfort beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var updater = Updater.shared
    @AppStorage("autoUpdate") var autoUpdate = true

    var body: some View {
        Form {
            ForEach(groups, id: \.self) { g in
                Section(g) {
                    if g == groups[1] {
                        Toggle(isOn: store.closeQuits) { Text("Schließen beendet die App"); Text(closeHint) }
                    }
                    ForEach(features.filter { $0.group == g }) { f in
                        Toggle(isOn: store.binding(f)) { Text(f.title); Text(f.hint) }
                    }
                }
            }
            Section("Allgemein") {
                Toggle("Beim Anmelden automatisch starten", isOn: store.login)
                Toggle("Updates automatisch installieren", isOn: $autoUpdate)
            }
            Section("Info") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Updates", value: updater.status)
                Button("Jetzt nach Updates suchen") { Task { await updater.check(manual: true) } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

@main struct WinKomfortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store()
    var body: some Scene {
        MenuBarExtra("WinKomfort", systemImage: "macwindow.on.rectangle") { MenuContent(store: store) }
        Settings { SettingsView(store: store) }
    }
}
