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
    let title: String
    let hint: String
    let prefs: [Pref]
    var restart: [String] = []
    var notify: String? = nil
}

let trackpads = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
let yes = ["-bool", "true"], no = ["-bool", "false"]

let features: [Feature] = [
    Feature(id: "drag", title: "2× tippen und halten zum Ziehen",
            hint: "Ohne Drücken verschieben. Wirkt nach Ab- und Anmelden.",
            prefs: trackpads.flatMap { [
                Pref(domain: $0, key: "Dragging", on: yes),
                Pref(domain: $0, key: "DragLock", on: no),
                Pref(domain: $0, key: "Clicking", on: yes, keep: true),
            ] } + [
                Pref(domain: "NSGlobalDomain", key: "com.apple.mouse.tapBehavior", on: ["-int", "1"], keep: true),
                Pref(domain: "host:NSGlobalDomain", key: "com.apple.mouse.tapBehavior", on: ["-int", "1"], keep: true),
            ]),
    Feature(id: "menubar", title: "Menüleiste ausblenden",
            hint: "Erscheint nur, wenn die Maus nach oben geht – Fenster bekommen die volle Höhe.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "_HIHideMenuBar", on: yes),
                    Pref(domain: "NSGlobalDomain", key: "AppleMenuBarVisibleInFullscreen", on: no)],
            notify: "AppleInterfaceMenuBarHidingChangedNotification"),
    Feature(id: "snap", title: "Fenster-Snapping mit Vorschau",
            hint: "Fenster an Rand oder nach oben ziehen → Vorschau → einrasten, ohne Lücken.",
            prefs: [Pref(domain: "com.apple.WindowManager", key: "EnableTilingByEdgeDrag", on: yes),
                    Pref(domain: "com.apple.WindowManager", key: "EnableTopTilingByEdgeDrag", on: yes),
                    Pref(domain: "com.apple.WindowManager", key: "EnableTilingOptionAccelerator", on: yes),
                    Pref(domain: "com.apple.WindowManager", key: "EnableTiledWindowMargins", on: no)],
            restart: ["Dock"]),
    Feature(id: "shot", title: "Screenshots in die Zwischenablage",
            hint: "⇧⌘4 / ⇧⌘5 kopiert direkt – einfach mit ⌘V einfügen.",
            prefs: [Pref(domain: "com.apple.screencapture", key: "target", on: ["-string", "clipboard"])],
            restart: ["SystemUIServer"]),
    Feature(id: "finder", title: "Finder wie Explorer",
            hint: "Dateiendungen, Pfadleiste, Statusleiste, Ordner zuerst.",
            prefs: [Pref(domain: "NSGlobalDomain", key: "AppleShowAllExtensions", on: yes),
                    Pref(domain: "com.apple.finder", key: "ShowPathbar", on: yes),
                    Pref(domain: "com.apple.finder", key: "ShowStatusBar", on: yes),
                    Pref(domain: "com.apple.finder", key: "_FXSortFoldersFirst", on: yes),
                    Pref(domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", on: yes)],
            restart: ["Finder"]),
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
    var login: Binding<Bool> {
        Binding(get: { SMAppService.mainApp.status == .enabled }, set: { v in
            if v { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            self.objectWillChange.send()
        })
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
            let (data, resp) = try await URLSession.shared.data(from: url)
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
        Task { await Updater.shared.loop() }
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    var body: some View {
        ForEach(features) { f in Toggle(f.title, isOn: store.binding(f)) }
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
            Section("Funktionen") {
                ForEach(features) { f in
                    Toggle(isOn: store.binding(f)) { Text(f.title); Text(f.hint) }
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
        .frame(width: 480)
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
