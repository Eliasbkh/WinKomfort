// KI-Befehle: normale Sätze („halt den Mac eine Stunde wach“) werden mit Apples Sprachmodell auf dem Gerät
// (Apple Intelligence, offline, kostenlos) in genau einen WinKomfort-Befehl übersetzt und ausgeführt.
// Ausgewählte, harmlose Befehle gibt es auch als Links (winkomfort://gamemode/on …) – für Kurzbefehle und damit auch für Siri.
import AppKit
import FoundationModels

enum Assistant {
    // Befehlsliste für das Sprachmodell – kurz halten, damit es schnell und eindeutig bleibt
    private static let instructions = """
    Übersetze den Wunsch in GENAU EINEN Befehl und antworte nur mit dem Befehl, ohne Erklärung.
    Befehle:
    explorer(PFAD) – Ordner öffnen. PFAD z. B. ~/Downloads, ~/Documents, ~/Desktop, ~/Pictures, ~
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
        case "gamemode":
            if on != GameMode.shared.active { GameMode.shared.toggle() }
            return on ? L("Game Mode an", "Game Mode on") : L("Game Mode aus", "Game Mode off")
        case "awake":
            let m = Int(arg.filter(\.isNumber)) ?? 60
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
        "gamemode": ["on", "off"], "onenote": ["page", "section", "notebook"], "snap": ["left", "right", "max", "restore"],
        "dark": ["on", "off"], "screenoff": [""], "tasks": [""], "clipboard": [""], "settings": [""],
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

    @MainActor static func ask(_ text: String) {
        Toast.show(L("Denke nach …", "Thinking…"), symbol: "sparkles")
        Task { @MainActor in
            guard let cmd = await command(for: text) else {
                Toast.show(L("Apple Intelligence ist nicht verfügbar", "Apple Intelligence isn't available"), symbol: "exclamationmark.triangle"); return
            }
            Toast.show(run(cmd), symbol: "sparkles")
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
