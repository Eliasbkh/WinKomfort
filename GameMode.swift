// Game Mode: mehr Leistung und Ruhe beim Spielen – nur mit offiziellen Mitteln, alles beim Beenden rückgängig.
// • Hintergrund-Apps laufen gedrosselt (macOS-Priorität „Hintergrund“: weniger CPU und Festplatte, nichts wird beendet)
// • Nicht stören an, Bildschirm bleibt an, Dock blendet sich aus
// • Startet automatisch, wenn ein Spiel nach vorne kommt (App-Kategorie „Spiele“ oder deine eigene Liste)
import AppKit
import SwiftUI
import IOKit.pwr_mgt

@MainActor final class GameMode: ObservableObject {
    static let shared = GameMode()
    @Published private(set) var active = false
    @Published private(set) var game: String?
    private var throttled: Set<pid_t> = []
    private var assertion: IOPMAssertionID = 0
    private var tokens: [NSObjectProtocol] = []
    private var gamePID: pid_t?
    private var dndBefore: Bool?
    private var dockWasHidden: Bool?
    private var manual = false

    private let d = UserDefaults.standard
    var auto: Bool { d.object(forKey: "gameAuto") as? Bool ?? true }
    var throttle: Bool { d.object(forKey: "gameThrottle") as? Bool ?? true }
    var dnd: Bool { d.object(forKey: "gameDND") as? Bool ?? true }
    var hideDock: Bool { d.object(forKey: "gameDock") as? Bool ?? false }
    var extraGames: [String] { d.stringArray(forKey: "gameApps") ?? [] }

    // Diese Prozesse nie drosseln (System, Eingabe, Audio, das Spiel selbst)
    private static let keep: Set<String> = [
        "de.winkomfort.app", "com.apple.finder", "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.systemuiserver", "com.apple.loginwindow", "com.apple.Spotlight", "com.apple.TextInputMenuAgent",
        "com.apple.coreaudiod", "com.discord.Discord", "com.hnc.Discord", "com.spotify.client", "com.apple.Music",
        "com.valvesoftware.steam", "com.apple.gamecenter", "com.apple.GameOverlayUI",
    ]

    func setup() {
        guard tokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { GameMode.shared.frontChanged(app) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if app?.processIdentifier == GameMode.shared.gamePID, !GameMode.shared.manual { GameMode.shared.stop() } }
        })
        // Nach einem Absturz von WinKomfort nichts gedrosselt lassen (Selbstreparatur)
        restoreAfterCrash()
    }

    static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, !keep.contains(id) else { return false }
        if GameMode.shared.extraGames.contains(id) { return true }
        guard let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
        let cat = (info["LSApplicationCategoryType"] as? String ?? "").lowercased()
        return cat.contains("games")
    }

    private func frontChanged(_ app: NSRunningApplication?) {
        guard auto, let app, !active, Self.isGame(app) else { return }
        start(game: app)
    }

    func toggle() {
        if active { stop() } else {
            manual = true
            start(game: NSWorkspace.shared.frontmostApplication)
        }
    }

    func start(game app: NSRunningApplication?) {
        guard !active else { return }
        active = true
        game = app?.localizedName
        gamePID = app?.processIdentifier
        if throttle {
            for a in NSWorkspace.shared.runningApplications where a.processIdentifier != gamePID && a.processIdentifier != getpid() {
                guard let id = a.bundleIdentifier, !Self.keep.contains(id), !id.hasPrefix("com.apple.") || a.activationPolicy == .regular else { continue }
                // Hintergrund-Priorität: weniger CPU, Festplatte und Netz – die App läuft weiter
                if setpriority(PRIO_DARWIN_PROCESS, id_t(a.processIdentifier), PRIO_DARWIN_BG) == 0 { throttled.insert(a.processIdentifier) }
            }
            d.set(throttled.map(Int.init), forKey: "gameThrottledPIDs")
        }
        let reason = "WinKomfort Game Mode" as CFString
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
        if dnd {
            dndBefore = Notifs.shared.dnd
            if Notifs.shared.dnd != true { Notifs.shared.setDND(true) }
        }
        if hideDock {
            let hidden = defaults("read", Pref(domain: "com.apple.dock", key: "autohide", on: [])) == "1"
            dockWasHidden = hidden
            if !hidden { sh(["/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "true"]); sh(["/usr/bin/killall", "Dock"]) }
        }
        Toast.show(L("Game Mode an", "Game Mode on") + (game.map { " – \($0)" } ?? ""), symbol: "gamecontroller.fill")
    }

    func stop() {
        guard active else { return }
        active = false
        manual = false
        for p in throttled { setpriority(PRIO_DARWIN_PROCESS, id_t(p), 0) }
        throttled = []
        d.removeObject(forKey: "gameThrottledPIDs")
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        if dnd, dndBefore != true { Notifs.shared.setDND(false) }
        dndBefore = nil
        if let was = dockWasHidden, !was { sh(["/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "false"]); sh(["/usr/bin/killall", "Dock"]) }
        dockWasHidden = nil
        Toast.show(L("Game Mode aus", "Game Mode off"), symbol: "gamecontroller")
        game = nil
        gamePID = nil
    }

    private func restoreAfterCrash() {
        for p in d.array(forKey: "gameThrottledPIDs") as? [Int] ?? [] { setpriority(PRIO_DARWIN_PROCESS, id_t(p), 0) }
        d.removeObject(forKey: "gameThrottledPIDs")
    }
}

struct GameModeTab: View {
    @ObservedObject var gm = GameMode.shared
    @AppStorage("gameAuto") private var auto = true
    @AppStorage("gameThrottle") private var throttle = true
    @AppStorage("gameDND") private var dnd = true
    @AppStorage("gameDock") private var hideDock = false
    @AppStorage("gameAppsText") private var gameAppsRaw = ""

    private var status: some View {
        HStack {
            Image(systemName: gm.active ? "gamecontroller.fill" : "gamecontroller")
                .font(.title2).foregroundStyle(gm.active ? Color.accentColor : Color.secondary).accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(gm.active ? L("Game Mode ist an", "Game Mode is on") : L("Game Mode ist aus", "Game Mode is off")).font(.headline)
                if let g = gm.game { Text(g).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(gm.active ? L("Ausschalten", "Turn off") : L("Jetzt einschalten", "Turn on now")) { gm.toggle() }
        }
    }
    private var shortcutText: String {
        let k = HotAction.gameMode.current?.display ?? "–"
        return L("Tastenkürzel: \(k)", "Shortcut: \(k)")
    }

    var body: some View {
        Form {
            Section { status } footer: { Text(shortcutText) }
            Section {
                Toggle(isOn: $auto) {
                    Text(L("Automatisch bei Spielen", "Automatically for games"))
                    Text(L("Startet, sobald ein Spiel nach vorne kommt, und endet, wenn es beendet wird.", "Starts when a game comes to the front and ends when it quits."))
                }
                Toggle(isOn: $throttle) {
                    Text(L("Hintergrund-Apps drosseln", "Throttle background apps"))
                    Text(L("Andere Apps bekommen weniger CPU und Festplatte – sie laufen weiter, nichts wird beendet.", "Other apps get less CPU and disk – they keep running, nothing quits."))
                }
                Toggle(isOn: $dnd) {
                    Text(L("Nicht stören", "Do Not Disturb"))
                    Text(L("Keine Mitteilungen während des Spielens.", "No notifications while playing."))
                }
                Toggle(isOn: $hideDock) {
                    Text(L("Dock ausblenden", "Hide the Dock"))
                    Text(L("Wird danach wieder wie vorher eingestellt.", "Restored to your setting afterwards."))
                }
            } footer: {
                Text(L("Der Bildschirm bleibt an, solange Game Mode läuft. macOS’ eigener Spielmodus (mehr Leistung für das Spiel, Bluetooth-Latenz) läuft zusätzlich weiter.",
                       "The display stays on while Game Mode runs. macOS’ own Game Mode (more performance for the game, Bluetooth latency) keeps working too."))
            }
            Section {
                let apps = gameAppsRaw.split(separator: "\n").map(String.init)
                if apps.isEmpty {
                    Text(L("Spiele ohne Kategorie „Spiele“ (z. B. aus Steam oder Browser-Spiele) hier hinzufügen.", "Add games without the “Games” category (e.g. from Steam) here."))
                        .foregroundStyle(.secondary)
                }
                ForEach(apps, id: \.self) { id in
                    HStack {
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                        Spacer()
                        Button(L("Entfernen", "Remove")) { gameAppsRaw = apps.filter { $0 != id }.joined(separator: "\n") }
                    }
                }
                Button(L("App hinzufügen …", "Add app…")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.application]
                    p.directoryURL = URL(fileURLWithPath: "/Applications")
                    if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier, !apps.contains(id) {
                        gameAppsRaw = (apps + [id]).joined(separator: "\n")
                    }
                }
            } header: { Text(L("Weitere Spiele", "More games")) }
        }
        .formStyle(.grouped)
        .onChange(of: gameAppsRaw) { _, v in UserDefaults.standard.set(v.split(separator: "\n").map(String.init), forKey: "gameApps") }
    }
}
