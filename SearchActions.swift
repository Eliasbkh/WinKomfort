// Aktionen in der Suche: Systemaktionen, WinKomfort-Funktionen, Einstellungsseiten und eigene Kürzel
import AppKit

@MainActor enum SearchActions {
    private static let hot: [(HotAction, String)] = [(.explorer, "folder"), (.remote, "iphone.gen3"), (.note, "note.text"), (.tasks, "list.bullet.rectangle"),
                                                     (.snapLeft, "rectangle.lefthalf.filled"), (.snapRight, "rectangle.righthalf.filled"), (.snapMax, "rectangle.fill"), (.gameMode, "gamecontroller"), (.onenote, "doc.richtext"), (.ask, "sparkles")]
    // Deutsch und Englisch finden, egal in welcher Sprache die App läuft
    private static let both = [
        "sys:fullscreen": "Vollbild,Fullscreen", "sys:minimize": "Minimieren,Minimize", "sys:closeWindow": "Schließen,Close", "sys:hide": "Ausblenden,Hide",
        "sys:hideOthers": "Andere ausblenden,Hide others", "sys:quit": "Beenden,Quit", "sys:missionControl": "Alle Fenster,Mission Control", "sys:showDesktop": "Schreibtisch,Desktop",
        "sys:lock": "Sperren,Lock", "sys:displayOff": "Bildschirm aus,Display off", "sys:screenshotArea": "Screenshot,Bildschirmfoto,Ausschnitt", "sys:screenshotFull": "Screenshot,Bildschirmfoto",
        "sys:dark": "Dunkelmodus,Dark mode,Hell", "sys:mute": "Stumm,Ton,Mute", "sys:volumeUp": "Lauter,Volume", "sys:volumeDown": "Leiser,Volume", "sys:playPause": "Pause,Play,Wiedergabe",
        "sys:nextTrack": "Nächster Titel,Next", "sys:previousTrack": "Vorheriger Titel,Previous", "hot:explorer": "Explorer,Dateien,Files", "hot:remote": "Fernbedienung,Handy,Remote,Phone",
        "hot:note": "Notiz,Schnellnotiz,Quick note", "hot:tasks": "Task-Manager,Taskmanager", "mode:clip": "Zwischenablage,Clipboard,Verlauf,History", "mode:emoji": "Emoji,Smiley", "hot:snapLeft": "Links,Left", "hot:snapRight": "Rechts,Right", "hot:snapMax": "Maximieren,Maximize", "win:center": "Zentrieren,Center", "hot:gameMode": "Game Mode,Spielmodus",
        "hot:onenote": "OneNote PDF", "hot:ask": "KI,AI", "pane:phone": "Galaxy Buds,Samsung",
    ]
    static func match(_ q: String) -> [SearchHit] {
        guard q.count >= 2 else { return [] }
        let all = entries
        var hits = all.compactMap { a -> (Entry, Double)? in
            guard let m = rate(q, a) else { return nil }
            return (a, a.id.hasPrefix("pane:") ? m - 0.15 : m) // Funktion vor Einstellungsseite
        }.filter { $0.1 >= 0.7 }.sorted { $0.1 > $1.1 }.prefix(4).map { hit($0.0, section) }
        // „timer 5 min“, „10 min timer“
        if q.lowercased().contains("timer"), let m = TimeParse.minutes(in: q.lowercased().replacingOccurrences(of: "timer", with: " ")), (1...1440).contains(m) {
            hits.insert(hit(Entry(id: "timer:\(m)", title: L("Timer: \(m) Minuten starten", "Start timer: \(m) minutes"), sub: "", symbol: "timer"), section), at: 0)
        }
        if SearchRank.match(q, "Timer") != nil {
            for t in SearchTimer.shared.running { hits.append(hit(Entry(id: "untimer:\(t.id)", title: L("Timer stoppen (endet \(t.end.formatted(date: .omitted, time: .shortened)))", "Stop timer (ends \(t.end.formatted(date: .omitted, time: .shortened)))"), sub: "", symbol: "timer"), section)) }
        }
        return hits
    }
    private struct Entry { let id: String, title: String, sub: String, symbol: String }
    private static var section: String { L("Befehle", "Commands") }
    private static func hit(_ e: Entry, _ section: String) -> SearchHit { SearchHit(kind: .action, title: e.title, subtitle: e.sub, path: e.id, symbol: e.symbol, section: section, accessory: L("Befehl", "Command")) }
    private static func rate(_ q: String, _ e: Entry) -> Double? { ([e.title] + (both[e.id]?.components(separatedBy: ",") ?? []) + frames.filter { "win:" + $0.0 == e.id }.flatMap { [$0.1, $0.2].flatMap { [$0, $0.components(separatedBy: ": ").last!] } }).compactMap { SearchRank.match(q, $0) }.max() }
    static func quality(_ q: String, _ h: SearchHit) -> Double { rate(q, Entry(id: h.path ?? "", title: h.title, sub: "", symbol: "")) ?? (h.path?.hasPrefix("timer:") == true ? 1 : 0) }
    static var suggested: [SearchHit] { entries.filter { ["mode:clip", "mode:emoji", "hot:explorer", "hot:remote", "hot:note"].contains($0.id) }.map { hit($0, section) } }

    private static let frames: [(String, String, String, CGRect)] = [
        ("topleft", "Fenster: oben links", "Window: top left", CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), ("topright", "Fenster: oben rechts", "Window: top right", CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        ("bottomleft", "Fenster: unten links", "Window: bottom left", CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)), ("bottomright", "Fenster: unten rechts", "Window: bottom right", CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        ("third1", "Fenster: linkes Drittel", "Window: left third", CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)), ("third2", "Fenster: mittleres Drittel", "Window: center third", CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)),
        ("third3", "Fenster: rechtes Drittel", "Window: right third", CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)), ("left23", "Fenster: linke zwei Drittel", "Window: left two thirds", CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)),
        ("right23", "Fenster: rechte zwei Drittel", "Window: right two thirds", CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)), ("center", "Fenster: zentrieren", "Window: center", CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)),
    ]
    private static var entries: [Entry] {
        var all = [Entry(id: "mode:clip", title: L("Zwischenablage-Verlauf", "Clipboard history"), sub: "", symbol: "doc.on.clipboard"), Entry(id: "mode:emoji", title: L("Emoji suchen", "Search emoji"), sub: "", symbol: "face.smiling")]
        for (a, s) in hot { all.append(Entry(id: "hot:" + a.rawValue, title: tr(a.title), sub: a.current?.display ?? "", symbol: s)) }
        for a in SystemAction.allCases { all.append(Entry(id: "sys:" + a.rawValue, title: a.title, sub: "", symbol: a.symbol)) }
        for f in frames { all.append(Entry(id: "win:" + f.0, title: L(f.1, f.2), sub: "", symbol: "macwindow")) }
        for k in Launcher.shared.keys where k.kind != .remap && !k.target.isEmpty { all.append(Entry(id: "key:" + k.id.uuidString, title: Launcher.shared.title(k), sub: k.shortcut?.display ?? "", symbol: "bolt")) }
        for p in Pane.allCases { all.append(Entry(id: "pane:" + p.rawValue, title: tr(p.title), sub: L("Einstellungen", "Settings"), symbol: "gearshape")) }
        if let ip = Remote.address() { all.append(Entry(id: "ip:" + ip, title: L("IP-Adresse kopieren", "Copy IP address"), sub: ip, symbol: "network")) }
        return all
    }
    static func run(_ id: String) {
        guard let i = id.firstIndex(of: ":") else { return }
        let v = String(id[id.index(after: i)...])
        switch id[..<i] {
        case "hot": HotAction(rawValue: v)?.perform()
        case "sys": if SystemAction(rawValue: v)?.perform() != true { Toast.show(L("Das ging nicht", "That didn't work"), symbol: "exclamationmark.triangle") }
        case "key": if let k = Launcher.shared.keys.first(where: { $0.id.uuidString == v }) { Launcher.shared.perform(k) }
        case "win": if let f = frames.first(where: { $0.0 == v }) { Snap.place(f.3) }
        case "timer": if let m = Int(v) { SearchTimer.shared.start(m) }
        case "untimer": SearchTimer.shared.stop(v)
        case "ip":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(v, forType: .string)
            Toast.show(L("Kopiert: \(v)", "Copied: \(v)"), symbol: "network")
        case "pane": openSettingsWindow(Pane(rawValue: v))
        default: break
        }
    }
}

// Kurzzeit-Timer aus der Suche (laufen, solange WinKomfort läuft)
@MainActor final class SearchTimer {
    static let shared = SearchTimer()
    private(set) var running: [(id: String, end: Date, timer: Timer)] = []
    func start(_ minutes: Int) {
        let id = UUID().uuidString, end = Date().addingTimeInterval(Double(minutes) * 60)
        let t = Timer(fire: end, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                SearchTimer.shared.running.removeAll { $0.id == id }
                for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { NSSound(named: "Glass")?.play() } }
                Toast.show(L("Timer abgelaufen (\(minutes) min)", "Timer finished (\(minutes) min)"), symbol: "timer", seconds: 8)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        running.append((id, end, t))
        Toast.show(L("Timer läuft bis \(end.formatted(date: .omitted, time: .shortened))", "Timer runs until \(end.formatted(date: .omitted, time: .shortened))"), symbol: "timer")
    }
    func stop(_ id: String) {
        running.first { $0.id == id }?.timer.invalidate()
        running.removeAll { $0.id == id }
        Toast.show(L("Timer gestoppt", "Timer stopped"), symbol: "timer")
    }
}
