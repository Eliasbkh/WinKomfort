// KI-Befehle: normale Sätze („halt den Mac eine Stunde wach“) werden mit Apples Sprachmodell auf dem Gerät
// (Apple Intelligence, offline, kostenlos) in genau einen WinKomfort-Befehl übersetzt und ausgeführt.
// Ausgewählte, harmlose Befehle gibt es auch als Links (winkomfort://gamemode/on …) – für Kurzbefehle und damit auch für Siri.
import AppKit
import FoundationModels
import SwiftUI

enum Assistant {
    // Befehlsliste für das Sprachmodell – kurz halten, damit es schnell und eindeutig bleibt
    private static let instructions = """
    Übersetze den Wunsch in GENAU EINEN Befehl und antworte nur mit dem Befehl, ohne Erklärung.
    Zahlen immer als Ziffern (zwei Stunden → 120, eine halbe Stunde → 30).
    Befehle:
    explorer(PFAD) – Ordner öffnen. PFAD z. B. ~/Downloads, ~/Documents, ~/Desktop, ~/Pictures, ~
    find(SUCHWORT) – Datei suchen, nur das wichtigste Wort, z. B. "finde meine bewerbung" → find(bewerbung)
    gamemode(on) | gamemode(off)
    awake(MINUTEN) – Mac wach halten, z. B. awake(60); awake(0) beendet
    onenote(page) | onenote(section) | onenote(notebook) – OneNote als PDF
    snap(left) | snap(right) | snap(max) | snap(restore) – aktuelles Fenster
    note(TEXT) – Schnellnotiz mit TEXT
    volume(0-100) – Lautstärke
    dark(on) | dark(off) – Dunkelmodus
    screenoff – Bildschirm aus
    open(APPNAME) – App öffnen
    tasks – Task-Manager
    clipboard – Zwischenablage-Verlauf
    settings – Einstellungen
    none – wenn nichts passt
    Beispiele: "spielmodus an" → gamemode(on) · "halt den mac 2 stunden wach" → awake(120) · "zeig downloads" → explorer(~/Downloads)
    · "fenster nach links" → snap(left) · "lauter" → volume(70) · "öffne safari" → open(Safari)
    """

    // Einmal pro Start prüfen – die Suche fragt bei jedem Tastendruck
    static let availableCached = available

    static var available: Bool {
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    // Satz → Befehl (nil, wenn kein Modell da ist)
    static func command(for text: String) async -> String? {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        guard let r = try? await session.respond(to: text) else { return nil }
        return r.content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first
    }

    // Befehl ausführen; gibt eine kurze Rückmeldung zurück
    @MainActor @discardableResult
    static func run(_ cmd: String) -> String {
        let c = cmd.trimmingCharacters(in: CharacterSet(charactersIn: " `\"'."))
        let name = c.prefix { $0 != "(" }.lowercased()
        var arg = ""
        if let a = c.firstIndex(of: "("), let b = c.lastIndex(of: ")"), a < b { arg = String(c[c.index(after: a)..<b]).trimmingCharacters(in: .whitespaces) }
        let on = !["off", "aus", "0", "false"].contains(arg.lowercased())
        switch name {
        case "explorer":
            let path = arg.isEmpty ? "~" : (arg as NSString).expandingTildeInPath
            openExplorer(URL(fileURLWithPath: path))
            return L("Explorer geöffnet", "Explorer opened")
        case "find":
            let word = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„ "))
            openExplorer(FileManager.default.homeDirectoryForCurrentUser, query: word)
            return L("Suche nach „\(word)“", "Searching for “\(word)”")
        case "gamemode":
            if on != GameMode.shared.active { GameMode.shared.toggle() }
            return on ? L("Game Mode an", "Game Mode on") : L("Game Mode aus", "Game Mode off")
        case "awake":
            let m = minutesOverride ?? Int(arg.filter(\.isNumber)) ?? 60
            if m == 0 { Awake.shared.stop(); return L("Wach bleiben beendet", "Stay awake ended") }
            Awake.shared.start(.display, minutes: m)
            return L("Mac bleibt \(m) Minuten wach", "Mac stays awake for \(m) minutes")
        case "onenote":
            let scope: OneNotePDF.Scope = arg.hasPrefix("page") || arg.hasPrefix("seite") ? .page : arg.hasPrefix("note") || arg.hasPrefix("notiz") ? .notebook : .section
            OneNotePDF.start(scope)
            return L("OneNote-PDF wird erstellt", "Creating OneNote PDF")
        case "snap":
            switch arg.lowercased() {
            case "left", "links": Snap.run(.left)
            case "right", "rechts": Snap.run(.right)
            case "max": Snap.run(.max)
            default: Snap.run(nil)
            }
            return L("Fenster angeordnet", "Window arranged")
        case "note":
            QuickNote.shared.append(arg)
            return L("Notiz gespeichert", "Note saved")
        case "volume":
            let v = max(0, min(100, Int(arg.filter(\.isNumber)) ?? 50))
            NSAppleScript(source: "set volume output volume \(v)")?.executeAndReturnError(nil)
            return L("Lautstärke \(v) %", "Volume \(v)%")
        case "dark":
            NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")?.executeAndReturnError(nil)
            return on ? L("Dunkelmodus an", "Dark mode on") : L("Dunkelmodus aus", "Dark mode off")
        case "screenoff":
            sh(["/usr/bin/pmset", "displaysleepnow"])
            return L("Bildschirm aus", "Display off")
        case "open":
            let ws = NSWorkspace.shared
            let dirs = ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            let target = arg.lowercased()
            for d in dirs {
                if let f = (try? FileManager.default.contentsOfDirectory(atPath: d))?.first(where: { $0.lowercased().hasSuffix(".app") && $0.lowercased().dropLast(4) == target[...] })
                    ?? (try? FileManager.default.contentsOfDirectory(atPath: d))?.first(where: { $0.lowercased().hasSuffix(".app") && $0.lowercased().contains(target) }) {
                    ws.open(URL(fileURLWithPath: d).appendingPathComponent(f))
                    return L("\(f.dropLast(4)) geöffnet", "Opened \(f.dropLast(4))")
                }
            }
            return L("App „\(arg)“ nicht gefunden", "App “\(arg)” not found")
        case "tasks": openTaskManager(); return L("Task-Manager", "Task Manager")
        case "clipboard": ClipPanel.toggle(); return L("Zwischenablage", "Clipboard")
        case "settings": openSettingsWindow(); return L("Einstellungen", "Settings")
        default: return L("Das kann ich (noch) nicht", "I can't do that (yet)")
        }
    }

    // winkomfort://gamemode/on · winkomfort://awake/60 · winkomfort://explorer/Downloads · winkomfort://onenote/notebook
    // Links können auch von Webseiten kommen – deshalb nur harmlose Befehle mit geprüften Werten (keine Apps, keine freien Texte, keine KI)
    private static let linkArgs: [String: Set<String>] = [
        "gamemode": ["on", "off"], "snap": ["left", "right", "max", "restore"],
        "dark": ["on", "off"], "tasks": [""], "clipboard": [""], "settings": [""],
    ]
    @MainActor static func handle(_ url: URL) {
        guard url.scheme == "winkomfort", let host = url.host?.lowercased() else { return }
        let arg = (url.path.removingPercentEncoding ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let ok: Bool
        switch host {
        case "awake": ok = arg.allSatisfy(\.isNumber) && (Int(arg) ?? 9999) <= 600
        case "volume": ok = arg.allSatisfy(\.isNumber) && (Int(arg) ?? 999) <= 100
        case "explorer":
            // nur Ordner innerhalb deines Benutzerordners, ohne „..“
            ok = !arg.contains("..") && arg.range(of: #"^[\p{L}\p{N} _./-]*$"#, options: .regularExpression) != nil
        default: ok = linkArgs[host]?.contains(arg.lowercased()) == true
        }
        guard ok else { Toast.show(L("Link-Befehl nicht erlaubt", "Link command not allowed"), symbol: "hand.raised"); return }
        let a = host == "explorer" ? (arg.isEmpty ? "~" : "~/" + arg) : arg
        Toast.show(run("\(host)(\(a))"), symbol: "wand.and.stars")
    }

    // Zeitangaben selbst lesen – das kleine Sprachmodell verrechnet sich bei Zahlwörtern
    @MainActor private static var minutesOverride: Int?
    static func minutes(in text: String) -> Int? { TimeParse.minutes(in: text) }

    // Modell vorladen, sobald jemand tippt – der erste Aufruf nach dem Start dauert sonst lange
    static func prewarm() {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    @MainActor static func ask(_ text: String) {
        minutesOverride = minutes(in: text)
        Toast.show(L("Denke nach …", "Thinking…"), symbol: "sparkles")
        Task { @MainActor in
            let cmd = await command(for: text)
            wkLog("KI → \(cmd.map { String($0.prefix { $0 != "(" }) } ?? "nicht verfügbar")") // nur der Befehlsname, nie dein Text
            guard let cmd else {
                Toast.show(L("Apple Intelligence ist nicht verfügbar", "Apple Intelligence isn't available"), symbol: "exclamationmark.triangle"); return
            }
            Toast.show(run(cmd), symbol: "sparkles")
            minutesOverride = nil
        }
    }
}

// „Frag WinKomfort“: kleines Eingabefeld in der Bildschirmmitte, ↩ führt aus, Esc schließt
final class AskModel: ObservableObject { @Published var text = ""; @Published var token = 0 }

@MainActor enum AskPanel {
    private static var panel: KeyPanel?
    private static let model = AskModel()

    static func toggle() { if panel?.isVisible == true { panel?.orderOut(nil) } else { show() } }

    static func show() {
        guard Assistant.available else {
            Toast.show(L("KI-Befehle brauchen Apple Intelligence (Systemeinstellungen › Apple Intelligence & Siri)",
                         "AI commands need Apple Intelligence (System Settings › Apple Intelligence & Siri)"), symbol: "sparkles"); return
        }
        model.text = ""
        Assistant.prewarm()
        model.token += 1 // Fokus bei jedem Öffnen ins Feld
        let p = panel ?? {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.becomesKeyOnlyIfNeeded = false
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = fixedHost(AskView(model: model))
            panel = p
            return p
        }()
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        p.setFrameOrigin(NSPoint(x: v.midX - 260, y: v.minY + v.height * 0.62))
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    static func submit() {
        let t = model.text.trimmingCharacters(in: .whitespaces)
        panel?.orderOut(nil)
        guard !t.isEmpty else { return }
        Assistant.ask(t)
    }
    static func hide() { panel?.orderOut(nil) }
}

struct AskView: View {
    @ObservedObject var model: AskModel
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
            TextField(L("Was soll passieren? z. B. „Game Mode an“, „Mac 1 Stunde wach“", "What should happen? e.g. “Game Mode on”, “keep Mac awake 1 hour”"), text: $model.text)
                .textFieldStyle(.plain).font(.title3)
                .focused($focused)
                .onSubmit { AskPanel.submit() }
                .onExitCommand { AskPanel.hide() }
        }
        .padding(.horizontal, 18)
        .frame(width: 520, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .onAppear { focused = true }
        .onChange(of: model.token) { _, _ in focused = true }
    }
}

// MARK: - Siri & Kurzbefehle: fertige, signierte Kurzbefehle (Aktion „URL öffnen“ → winkomfort://…).
// Nach dem Hinzufügen versteht Siri den Namen: „Hey Siri, Game Mode an“.
enum SiriShortcuts {
    struct Item: Identifiable { let id: String; let name: String; let url: String; let symbol: String }
    static var items: [Item] {
        [
            Item(id: "gmon", name: L("Game Mode an", "Game Mode on"), url: "winkomfort://gamemode/on", symbol: "gamecontroller.fill"),
            Item(id: "gmoff", name: L("Game Mode aus", "Game Mode off"), url: "winkomfort://gamemode/off", symbol: "gamecontroller"),
            Item(id: "awake", name: L("Mac wach halten", "Keep Mac awake"), url: "winkomfort://awake/60", symbol: "cup.and.saucer.fill"),
            Item(id: "awakeoff", name: L("Mac darf schlafen", "Mac may sleep"), url: "winkomfort://awake/0", symbol: "moon.zzz"),
            Item(id: "downloads", name: L("Downloads zeigen", "Show Downloads"), url: "winkomfort://explorer/Downloads", symbol: "arrow.down.circle"),
            Item(id: "tasks", name: L("Task-Manager öffnen", "Open Task Manager"), url: "winkomfort://tasks", symbol: "list.bullet.rectangle"),
        ]
    }

    // Kurzbefehl-Datei bauen, mit macOS signieren und zum Hinzufügen öffnen
    @MainActor static func add(_ item: Item) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WinKomfort-Shortcuts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("\(item.id)-raw.shortcut"), signed = dir.appendingPathComponent("\(item.name).shortcut")
        let wf: [String: Any] = [
            "WFWorkflowClientVersion": "2605.0.5", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [],
            "WFWorkflowActions": [["WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
                                   "WFWorkflowActionParameters": ["WFInput": ["Value": ["string": item.url, "attachmentsByRange": [String: Any]()],
                                                                              "WFSerializationType": "WFTextTokenString"]]]],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: wf, format: .binary, options: 0), (try? data.write(to: raw)) != nil else { return }
        Toast.show(L("Kurzbefehl wird vorbereitet …", "Preparing shortcut…"), symbol: "wand.and.stars")
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: signed)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["sign", "--mode", "anyone", "--input", raw.path, "--output", signed.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil
            if ok { p.waitUntilExit() }
            DispatchQueue.main.async {
                if ok && p.terminationStatus == 0 { NSWorkspace.shared.open(signed) } // Kurzbefehle fragt „Hinzufügen?“
                else { MainActor.assumeIsolated { Toast.show(L("Kurzbefehl konnte nicht erstellt werden", "Couldn't create the shortcut"), symbol: "exclamationmark.triangle") } }
            }
        }
    }
}

struct SiriSection: View {
    var body: some View {
        Section {
            ForEach(SiriShortcuts.items) { item in
                HStack {
                    Label(item.name, systemImage: item.symbol)
                    Spacer()
                    Button(L("Hinzufügen", "Add")) { SiriShortcuts.add(item) }
                        .accessibilityLabel(L("\(item.name) zu Kurzbefehlen hinzufügen", "Add \(item.name) to Shortcuts"))
                }
            }
        } header: { Text(L("Siri & Kurzbefehle", "Siri & Shortcuts")) } footer: {
            Text(L("Nach dem Hinzufügen reicht „Hey Siri, Game Mode an“. Für alles andere: ⌃⌥K und einfach sagen, was passieren soll.",
                   "After adding, just say “Hey Siri, Game Mode on”. For anything else: ⌃⌥K and type what should happen."))
        }
    }
}
