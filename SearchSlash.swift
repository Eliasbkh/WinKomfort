// /Befehle in der Suche: „/“ zeigt alle, Tab ergänzt, ↩ führt aus
import AppKit
import CoreServices

@MainActor enum SearchSlash {
    // Ergebnis einer Eingabe: was dasteht und was ↩ macht
    enum Act { case copy(String), run(@MainActor () -> Void) }
    struct Row { var title: String; var sub = ""; var act: Act; var app: String? = nil }
    struct Command {
        let name: String, hint: String, text: String, symbol: String
        var needsArg = false
        let rows: @MainActor (String) -> [Row] // leer = Eingabe passt (noch) nicht
    }

    private static var clip: String { NSPasteboard.general.string(forType: .string) ?? "" }
    private static func input(_ a: String) -> String { a.isEmpty ? clip : a }
    private static func copy(_ title: String, _ sub: String = "", _ value: String? = nil) -> Row { Row(title: title, sub: sub, act: .copy(value ?? title)) }
    private static func go(_ title: String, _ sub: String = "", _ work: @escaping @MainActor () -> Void) -> Row { Row(title: title, sub: sub, act: .run(work)) }
    private static func short(_ s: String) -> String { String(s.replacingOccurrences(of: "\n", with: " ").prefix(90)) }
    // Text umwandeln: eigener Text oder Zwischenablage
    private static func change(_ a: String, _ f: (String) -> String?) -> [Row] {
        let t = input(a)
        guard !t.isEmpty, t.count < 500_000, let r = f(t) else { return [] }
        return [copy(short(r), a.isEmpty ? L("aus der Zwischenablage", "from clipboard") : "", r)]
    }
    @discardableResult private static func launch(_ exe: String, _ args: [String]) -> Bool { (try? Process.run(URL(fileURLWithPath: exe), arguments: args)) != nil }
    private static func web(_ site: String, _ base: String, _ a: String) -> [Row] {
        a.isEmpty ? [] : [go(L("\(site): „\(a)“", "\(site): “\(a)”")) { if let u = URL(string: SearchWeb.url(base, a)) { NSWorkspace.shared.open(u) } }]
    }

    static let all: [Command] = [
        Command(name: "timer", hint: L("Minuten", "minutes"), text: L("Timer starten", "Start a timer"), symbol: "timer", needsArg: true) { a in
            guard let m = Int(a) ?? TimeParse.minutes(in: a), (1...1440).contains(m) else { return [] }
            return [go(L("Timer: \(m) Minuten", "Timer: \(m) minutes")) { SearchTimer.shared.start(m) }]
        },
        Command(name: "pomodoro", hint: "", text: L("25 Minuten lernen", "Focus for 25 minutes"), symbol: "brain.head.profile") { _ in [go(L("25 Minuten starten", "Start 25 minutes")) { SearchTimer.shared.start(25) }] },
        Command(name: "note", hint: L("Text", "text"), text: L("An die Schnellnotiz anhängen", "Append to Quick Note"), symbol: "note.text", needsArg: true) { a in
            a.isEmpty ? [] : [go(L("Notieren: \(a)", "Note: \(a)")) { QuickNote.shared.append(a); Toast.show(L("Notiert", "Noted"), symbol: "note.text") }]
        },
        Command(name: "kill", hint: L("App", "app"), text: L("Laufende App beenden", "Quit a running app"), symbol: "xmark.octagon") { a in
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != "com.apple.finder" }
                .compactMap { r in (r.localizedName ?? "").isEmpty ? nil : (r, a.isEmpty ? 0.5 : SearchRank.match(a, r.localizedName!) ?? 0) }.filter { $0.1 > 0.3 }.sorted { $0.1 > $1.1 }
                .map { r, _ in Row(title: L("\(r.localizedName!) beenden", "Quit \(r.localizedName!)"), act: .run { r.terminate() }, app: r.bundleURL?.path) }
        },
        Command(name: "define", hint: L("Wort", "word"), text: L("Im Wörterbuch nachschlagen", "Look up in dictionary"), symbol: "character.book.closed", needsArg: true) { a in
            guard !a.isEmpty, let d = DCSCopyTextDefinition(nil, a as CFString, CFRange(location: 0, length: (a as NSString).length))?.takeRetainedValue() as String? else { return [] }
            return [go(short(d), L("↩ im Lexikon", "↩ in Dictionary")) { if let u = URL(string: SearchWeb.url("dict://", a)) { NSWorkspace.shared.open(u) } }]
        },
        Command(name: "translate", hint: L("Text", "text"), text: L("Mit DeepL ins Englische", "Translate with DeepL (to English)"), symbol: "globe.europe.africa", needsArg: true) { web("DeepL", "https://www.deepl.com/translator#de/en/", $0) },
        Command(name: "deutsch", hint: L("Text", "text"), text: L("Mit DeepL ins Deutsche", "Translate with DeepL (to German)"), symbol: "globe.europe.africa", needsArg: true) { web("DeepL", "https://www.deepl.com/translator#en/de/", $0) },
        Command(name: "yt", hint: L("Suche", "query"), text: "YouTube", symbol: "play.rectangle", needsArg: true) { web("YouTube", "https://www.youtube.com/results?search_query=", $0) },
        Command(name: "wiki", hint: L("Suche", "query"), text: "Wikipedia", symbol: "book", needsArg: true) { web("Wikipedia", "https://de.wikipedia.org/w/index.php?search=", $0) },
        Command(name: "github", hint: L("Suche", "query"), text: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", needsArg: true) { web("GitHub", "https://github.com/search?q=", $0) },
        Command(name: "maps", hint: L("Ort", "place"), text: "Google Maps", symbol: "map", needsArg: true) { web("Google Maps", "https://www.google.com/maps/search/", $0) },
        Command(name: "ai", hint: L("Befehl", "command"), text: L("Mit Apple Intelligence ausführen", "Do it with Apple Intelligence"), symbol: "sparkles", needsArg: true) { a in a.isEmpty ? [] : [go(L("Ausführen: \(a)", "Do: \(a)")) { Assistant.ask(a) }] },
        Command(name: "password", hint: L("Länge", "length"), text: L("Sicheres Passwort erzeugen", "Generate a secure password"), symbol: "key") { a in
            [go(L("Passwort mit \(min(max(Int(a) ?? 20, 8), 128)) Zeichen kopieren", "Copy a \(min(max(Int(a) ?? 20, 8), 128))-character password"), L("wird nicht im Verlauf gespeichert", "not kept in history")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(SlashLogic.password(Int(a) ?? 20), forType: .string)
                pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
                ClipHistory.shared.skipCurrent()
                Toast.show(L("Passwort kopiert", "Password copied"), symbol: "key")
            }]
        },
        Command(name: "uuid", hint: "", text: L("Eindeutige Kennung", "Unique identifier"), symbol: "number") { _ in [go(L("Neue UUID kopieren", "Copy a new UUID")) { put(UUID().uuidString) }] },
        Command(name: "color", hint: "#hex", text: L("Farbe umrechnen", "Convert a color"), symbol: "paintpalette", needsArg: true) { a in
            guard let c = SlashLogic.color(a) else { return [] }
            return [copy(c.hex), copy(c.rgb), copy(c.hsl)]
        },
        Command(name: "qr", hint: L("Text oder Link", "text or link"), text: L("QR-Code anzeigen", "Show a QR code"), symbol: "qrcode") { a in
            let t = input(a)
            guard !t.isEmpty, t.utf8.count < 1200 else { return [] }
            return [go(L("QR-Code: \(short(t))", "QR code: \(short(t))")) { showQR(t) }]
        },
        Command(name: "upper", hint: L("Text", "text"), text: L("GROSSBUCHSTABEN", "UPPERCASE"), symbol: "textformat.size.larger") { change($0) { $0.uppercased() } },
        Command(name: "lower", hint: L("Text", "text"), text: L("kleinbuchstaben", "lowercase"), symbol: "textformat.size.smaller") { change($0) { $0.lowercased() } },
        Command(name: "trim", hint: L("Text", "text"), text: L("Leerzeichen und Formatierung entfernen", "Strip spaces and formatting"), symbol: "scissors") { change($0) { $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") } },
        Command(name: "json", hint: "JSON", text: L("JSON schön formatieren", "Format JSON"), symbol: "curlybraces") { change($0, SlashLogic.json) },
        Command(name: "base64", hint: L("Text", "text"), text: L("In Base64 umwandeln", "Encode as Base64"), symbol: "lock.doc") { change($0) { Data($0.utf8).base64EncodedString() } },
        Command(name: "unbase64", hint: "Base64", text: L("Base64 lesen", "Decode Base64"), symbol: "lock.open") { change($0) { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { String(data: $0, encoding: .utf8) } } },
        Command(name: "url", hint: L("Text", "text"), text: L("Für Links kodieren", "URL-encode"), symbol: "link") { change($0) { SearchWeb.url("", $0) } },
        Command(name: "count", hint: L("Text", "text"), text: L("Wörter und Zeichen zählen", "Count words and characters"), symbol: "textformat.123") { a in
            let t = input(a), c = SlashLogic.count(t)
            return t.isEmpty ? [] : [copy(L("\(c.words) Wörter · \(c.chars) Zeichen · \(c.lines) Zeilen", "\(c.words) words · \(c.chars) characters · \(c.lines) lines"), a.isEmpty ? L("aus der Zwischenablage", "from clipboard") : "")]
        },
        Command(name: "random", hint: "1-100", text: L("Zufallszahl", "Random number"), symbol: "dice") { a in
            guard let r = SlashLogic.range(a) else { return [] }
            return [go(L("Zahl von \(r.lowerBound) bis \(r.upperBound)", "Number from \(r.lowerBound) to \(r.upperBound)")) { let n = Int.random(in: r); put("\(n)", toast: "\(n)", "dice") }]
        },
        Command(name: "coin", hint: "", text: L("Münze werfen", "Flip a coin"), symbol: "circle.lefthalf.filled") { _ in [go(L("Münze werfen", "Flip a coin")) { Toast.show(Bool.random() ? L("Kopf", "Heads") : L("Zahl", "Tails"), symbol: "circle.lefthalf.filled", seconds: 3) }] },
        Command(name: "pick", hint: "a, b, c", text: L("Zufällig auswählen", "Pick one at random"), symbol: "hand.point.up.left", needsArg: true) { a in
            let o = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return o.count < 2 ? [] : [go(L("Eins von \(o.count) ziehen", "Pick one of \(o.count)")) { Toast.show(o.randomElement()!, symbol: "hand.point.up.left", seconds: 4) }]
        },
        Command(name: "days", hint: "24.12.", text: L("Tage bis zu einem Datum", "Days until a date"), symbol: "calendar", needsArg: true) { a in
            SlashLogic.days(a, today: Date()).map { [copy($0 < 0 ? L("vor \(-$0) Tagen", "\(-$0) days ago") : L("noch \($0) Tage", "\($0) days left"))] } ?? []
        },
        Command(name: "date", hint: "", text: L("Datum, Uhrzeit, Kalenderwoche", "Date, time, week number"), symbol: "calendar.badge.clock") { _ in
            let n = Date()
            return [copy(n.formatted(date: .complete, time: .omitted)), copy(n.formatted(date: .omitted, time: .shortened)), copy(L("KW \(Calendar(identifier: .iso8601).component(.weekOfYear, from: n))", "Week \(Calendar(identifier: .iso8601).component(.weekOfYear, from: n))"))]
        },
        Command(name: "say", hint: L("Text", "text"), text: L("Vorlesen lassen", "Read aloud"), symbol: "speaker.wave.2") { a in
            let t = input(a)
            return t.isEmpty || t.count > 5000 ? [] : [go(L("Vorlesen: \(short(t))", "Say: \(short(t))")) { launch("/usr/bin/say", ["--", t]) }, go(L("Vorlesen stoppen", "Stop reading")) { launch("/usr/bin/killall", ["say"]) }]
        },
        Command(name: "volume", hint: "0-100", text: L("Lautstärke setzen", "Set volume"), symbol: "speaker.wave.3", needsArg: true) { a in
            guard let v = Int(a), (0...100).contains(v) else { return [] }
            return [go(L("Lautstärke \(v) %", "Volume \(v)%")) { NSAppleScript(source: "set volume output volume \(v)")?.executeAndReturnError(nil) }]
        },
        Command(name: "awake", hint: L("Minuten", "minutes"), text: L("Mac wach halten, auch zugeklappt", "Keep Mac awake, even with the lid closed"), symbol: "cup.and.saucer") { a in
            let m = Int(a) ?? TimeParse.minutes(in: a)
            if !a.isEmpty, m == nil || !(1...1440).contains(m!) { return [] }
            var r = [go(m.map { L("Wach für \($0) Minuten", "Awake for \($0) minutes") } ?? L("Wach ohne Ende", "Awake indefinitely")) { Awake.shared.start(.system, minutes: m) }]
            if Awake.shared.mode != nil { r.insert(go(L("Wach bleiben beenden", "Stop staying awake")) { Awake.shared.stop() }, at: 0) }
            return r
        },
        Command(name: "wifi", hint: "on / off", text: L("WLAN ein- oder ausschalten", "Turn Wi-Fi on or off"), symbol: "wifi") { a in
            ["on", "off"].filter { a.isEmpty || $0.hasPrefix(a.lowercased()) }.map { s in go("WLAN " + (s == "on" ? L("an", "on") : L("aus", "off"))) { launch("/usr/sbin/networksetup", ["-setairportpower", "en0", s]) } }
        },
        Command(name: "eject", hint: "", text: L("Laufwerke auswerfen", "Eject drives"), symbol: "eject") { _ in
            (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeNameKey], options: [.skipHiddenVolumes]) ?? []).compactMap { u in
                let v = try? u.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeNameKey])
                guard v?.volumeIsEjectable == true || v?.volumeIsRemovable == true else { return nil }
                return go(L("\(v?.volumeName ?? u.lastPathComponent) auswerfen", "Eject \(v?.volumeName ?? u.lastPathComponent)")) {
                    do { try NSWorkspace.shared.unmountAndEjectDevice(at: u); Toast.show(L("Ausgeworfen", "Ejected"), symbol: "eject") } catch { Toast.show(L("Wird noch benutzt", "Still in use"), symbol: "exclamationmark.triangle") }
                }
            }
        },
        Command(name: "buds", hint: L("Modus", "mode"), text: L("Galaxy Buds umschalten", "Switch Galaxy Buds mode"), symbol: "earbuds") { a in
            Buds.enabled ? Buds.modes.filter { a.isEmpty || SearchRank.match(a, $0.1) != nil || SearchRank.match(a, $0.2) != nil }.map { m in go("Buds: " + L(m.1, m.2)) { Buds.shared.setMode(m.0) } } : []
        },
        Command(name: "ocr", hint: "", text: L("Text vom Bildschirm kopieren", "Copy text from screen"), symbol: "text.viewfinder") { _ in [go(L("Bereich wählen", "Select an area")) { Tools.capture(qr: false) }] },
        Command(name: "scan", hint: "", text: L("QR-Code vom Bildschirm lesen", "Scan QR code on screen"), symbol: "qrcode.viewfinder") { _ in [go(L("Bereich wählen", "Select an area")) { Tools.capture(qr: true) }] },
        Command(name: "pipette", hint: "", text: L("Farbe vom Bildschirm aufnehmen", "Pick color from screen"), symbol: "eyedropper") { _ in [go(L("Farbe wählen", "Pick a color")) { Tools.pickColor() }] },
        Command(name: "mic", hint: "", text: L("Mikrofon ein/aus", "Toggle microphone"), symbol: "mic.slash") { _ in [go(L("Mikrofon umschalten", "Toggle microphone")) { Tools.toggleMic() }] },
        Command(name: "clean", hint: "", text: L("Putzmodus: Bildschirm schwarz, Tastatur gesperrt", "Cleaning mode: black screen, keyboard locked"), symbol: "bubbles.and.sparkles") { _ in [go(L("Putzmodus starten (Esc 2 s halten beendet)", "Start cleaning mode (hold Esc 2 s to exit)")) { CleaningMode.start() }] },
        Command(name: "ram", hint: "", text: L("Speicher ansehen und aufräumen", "View and clean up memory"), symbol: "memorychip") { _ in
            let m = MemoryInfo.read(), f = { (b: Double) in ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
            return [go(L("Belegt \(f(m.used)) von \(f(m.total))", "Used \(f(m.used)) of \(f(m.total))"), L("↩ Task-Manager", "↩ Task Manager")) { openTaskManager() }]
        },
        Command(name: "clip", hint: "", text: L("Zwischenablage-Verlauf", "Clipboard history"), symbol: "doc.on.clipboard") { _ in [] },
        Command(name: "emoji", hint: "", text: L("Emoji suchen", "Search emoji"), symbol: "face.smiling") { _ in [] },
        Command(name: "help", hint: "", text: L("Alle /Befehle", "All /commands"), symbol: "questionmark.circle") { _ in [] },
    ]

    static func hits(_ q: String) -> [SearchHit] {
        guard let (name, arg) = SlashLogic.split(q) else { return [] }
        let section = L("Befehle", "Commands")
        if let c = all.first(where: { $0.name == name }), name != "help" {
            let rows = c.rows(arg)
            if !rows.isEmpty { return rows.enumerated().map { i, r in SearchHit(kind: .slash, title: r.title, subtitle: r.sub, path: r.app, symbol: c.symbol, section: "/" + c.name, accessory: copies(r) ? L("Kopieren", "Copy") : "", index: i) } }
            return [list(c, section)]
        }
        let n = name == "help" ? "" : name
        return all.filter { n.isEmpty || $0.name.hasPrefix(n) || (SearchRank.match(n, $0.text) ?? 0) >= 0.8 }
            .sorted { ($0.name.hasPrefix(n) ? 0 : 1) < ($1.name.hasPrefix(n) ? 0 : 1) }.map { list($0, section) }
    }
    private static func copies(_ r: Row) -> Bool { if case .copy = r.act { return true }; return false }
    private static func list(_ c: Command, _ section: String) -> SearchHit {
        SearchHit(kind: .slash, title: "/" + c.name, subtitle: c.text, path: nil, symbol: c.symbol, section: section, accessory: c.hint)
    }
    // true = Suche schließen und `act` ausführen; sonst ist die Eingabe ergänzt
    static func act(_ q: String, _ hit: SearchHit) -> Act? {
        guard let i = hit.index, let (name, arg) = SlashLogic.split(q), let c = all.first(where: { $0.name == name }) else { return nil }
        let rows = c.rows(arg)
        return rows.indices.contains(i) ? rows[i].act : nil
    }
    static func put(_ s: String, toast: String? = nil, _ symbol: String = "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        Toast.show(toast ?? L("Kopiert", "Copied"), symbol: symbol, seconds: toast == nil ? 1.4 : 3)
    }
    private static func showQR(_ t: String) {
        windows["qr"]?.close()
        windows["qr"] = nil
        showWindow("qr", "QR-Code") { QRView(text: t) }
    }
}
