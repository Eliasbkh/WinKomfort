// Der Assistent handelt: Kalender, Erinnerungen, Dateien, Bildschirm, Wetter, Mac – alles ohne fremden Server (außer Wetter)
import AppKit
import AVFoundation
import Contacts
import EventKit
import IOKit.ps
import ScreenCaptureKit
import Speech
import SwiftUI

// Karte unter einer Antwort
struct AICard: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, event, reminder, newEvent, newReminder, done }
    var id = UUID()
    var kind: Kind
    var title: String
    var detail = ""
    var path: String?
    var start: Date?
    var hasTime: Bool?
}

// Gemerktes über den Nutzer – nur auf diesem Mac
enum AIMemory {
    static var all: [String] {
        get { UserDefaults.standard.stringArray(forKey: "aiMemory") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(60)), forKey: "aiMemory") }
    }
    static var prompt: String { all.isEmpty ? "" : "\nDas hat dir der Nutzer über sich gesagt („ich“ = der Nutzer): " + all.map { String($0.prefix(160)) }.suffix(20).joined(separator: "; ") + ". Nutze es nur, wenn es zur Frage passt." }
}

@MainActor enum AIAct {
    struct Outcome {
        var text: String?        // fertige Antwort
        var material = ""        // persönliche Infos, zu denen das Modell antworten soll
        var images: [AIDoc] = []
        var cards: [AICard] = []
        var sources: [AISource] = []
    }
    private static let store = EKEventStore()

    static func handle(_ q: String, others: [AIConversation], status: @escaping @MainActor (String) -> Void) async throws -> Outcome? {
        let c = ActLogic.candidates(q)
        guard !c.isEmpty, let kind = try await choose(q, c) else { return nil }
        wkLog("KI-Aktion → \(kind.rawValue)") // nur die Art, nie der Inhalt
        switch kind {
        case .mac:
            guard let cmd = await Assistant.command(for: q) else { return nil }
            if cmd.lowercased().hasPrefix("none") { return nil }
            return Outcome(text: Assistant.run(cmd, spoken: q) + ".")
        case .timer:
            guard let m = TimeParse.minutes(in: q.lowercased().replacingOccurrences(of: "timer", with: " ")), (1...1440).contains(m) else { return Outcome(text: L("Wie lange soll der Timer laufen? Zum Beispiel „Timer 10 Minuten“.", "How long? For example “timer 10 minutes”.")) }
            SearchTimer.shared.start(m)
            return Outcome(text: L("Timer läuft: \(m) Minuten.", "Timer running: \(m) minutes."))
        case .homework:
            guard let t = School.shared.add(q, exam: q.lowercased().range(of: "klausur|klassenarbeit", options: .regularExpression) != nil) else { return nil }
            return Outcome(text: L("Notiert bis \(t.due.formatted(.dateTime.weekday(.wide).day().month())): ", "Noted for \(t.due.formatted(.dateTime.weekday(.wide).day().month())): ") + (t.subject.isEmpty ? "" : "**\(t.subject)** ") + t.text)
        case .lessons:
            let b = School.shared.book, open = b.tasks.filter { !$0.done }.sorted { $0.due < $1.due }
            guard !b.lessons.isEmpty || !open.isEmpty else { return Outcome(text: L("Dein Stundenplan ist noch leer. Du findest ihn mit „/schule“ in der Suche.", "Your timetable is empty. Open it with “/school” in search.")) }
            if q.lowercased().contains("hausaufgabe") || q.lowercased().contains("homework") { return Outcome(text: open.isEmpty ? L("Nichts offen.", "Nothing open.") : open.prefix(10).map { "- **\($0.subject.isEmpty ? L("Sonstiges", "Other") : $0.subject)** \($0.text), \($0.due.formatted(.dateTime.weekday(.wide).day().month()))" }.joined(separator: "\n")) }
            if q.lowercased().contains("nächste stunde"), let l = Plan.now(b, Date()).next { return Outcome(text: "\(Plan.clock(l.start)): **\(l.subject)**" + (l.room.isEmpty ? "" : ", " + l.room)) }
            if let f = Plan.subject(in: q, b), q.lowercased().contains("wann"), let d = Plan.nextDate(b, subject: f, after: Date()) { return Outcome(text: "**\(f)**: \(d.formatted(.dateTime.weekday(.wide).day().month()))" + (Plan.lessons(b, on: d).first { $0.subject == f }.map { ", " + Plan.clock($0.start) } ?? "")) }
            let d = ActLogic.when(q)?.date ?? Date(), l = Plan.lessons(b, on: d)
            return Outcome(text: l.isEmpty ? L("Da hast du keinen Unterricht.", "You have no classes then.") : l.map { "- \(Plan.clock($0.start)) – \(Plan.clock($0.end)) **\($0.subject)**" + ($0.room.isEmpty ? "" : ", " + $0.room) }.joined(separator: "\n"))
        case .grades:
            let b = School.shared.book
            guard let o = Plan.overall(b) else { return Outcome(text: L("Noch keine Noten eingetragen (Suche: „/schule“).", "No grades yet (search: “/school”).")) }
            return Outcome(text: L("Gesamt: **\(Plan.text(o, b.points))**", "Overall: **\(Plan.text(o, b.points))**") + "\n\n" + Plan.subjects(b).compactMap { n in Plan.average(b, n).map { "- \(n): \(Plan.text($0, b.points))" } }.joined(separator: "\n"))
        case .music:
            let l = q.lowercased()
            SystemAction.media(l.contains("nächst") || l.contains("next") || l.contains("weiter") && !l.contains("weiterspiel") ? 17 : l.contains("vorige") || l.contains("zurück") || l.contains("previous") ? 18 : 16)
            return Outcome(text: L("Erledigt.", "Done."))
        case .remember:
            let f = ActLogic.fact(q)
            guard f.count > 2 else { return nil }
            AIMemory.all.append(f)
            return Outcome(text: L("Gemerkt: \(f)", "I'll remember: \(f)"))
        case .forget:
            let w = Set(AILogic.words(q)).subtracting(["vergiss", "vergessen", "forget", "dass", "alles", "über", "mich"])
            let before = AIMemory.all
            if q.lowercased().contains("alles"), w.isEmpty { AIMemory.all = [] } else { AIMemory.all = before.filter { m in Set(AILogic.words(m)).isDisjoint(with: w) } }
            return Outcome(text: AIMemory.all.count == before.count ? L("Dazu hatte ich mir nichts gemerkt.", "I had nothing stored about that.") : L("Vergessen.", "Forgotten."))
        case .eventNew, .reminderNew:
            let t = ActLogic.title(q)
            guard !t.isEmpty else { return Outcome(text: L("Wie soll das heißen und wann?", "What should it be called, and when?")) }
            let w = ActLogic.when(q)
            if kind == .eventNew, w == nil { return Outcome(text: L("Wann ist „\(t)“? Sag zum Beispiel „Trag \(t) morgen um 15 Uhr ein“.", "When is “\(t)”? For example “add \(t) tomorrow at 15:00”.")) }
            // Erst nach deinem Klick wird etwas eingetragen
            return Outcome(text: kind == .eventNew ? L("So trage ich es ein:", "I'll add this:") : L("So erinnere ich dich:", "I'll remind you:"),
                           cards: [AICard(kind: kind == .eventNew ? .newEvent : .newReminder, title: t, start: w?.date, hasTime: w?.hasTime)])
        case .calendar: return try await calendar(q)
        case .reminders: return try await reminders()
        case .files:
            status(L("Sucht Dateien", "Searching files"))
            let f = await files(q)
            return f.isEmpty ? Outcome(text: L("Dazu habe ich keine Datei gefunden.", "I found no matching file.")) : Outcome(text: f.count == 1 ? L("Das habe ich gefunden:", "Found this:") : L("Das passt am besten:", "Best matches:"), cards: f)
        case .screen:
            status(L("Sieht sich den Bildschirm an", "Looking at your screen"))
            guard let d = await screen() else { return Outcome(text: L("Dafür braucht WinKomfort die Freigabe „Bildschirmaufnahme“ (Systemeinstellungen › Datenschutz & Sicherheit) und ein geöffnetes Fenster.", "This needs the Screen Recording permission (System Settings › Privacy & Security) and an open window.")) }
            return Outcome(images: [d])
        case .status: return Outcome(material: statusText())
        case .weather:
            status(L("Holt das Wetter", "Getting the weather"))
            return await weather(q)
        case .contact: return try await contact(q)
        case .past:
            let text = others.map { c in L("Gespräch vom ", "Conversation on ") + c.date.formatted(date: .abbreviated, time: .omitted) + ": " + c.messages.filter { $0.failed != true }.map { ($0.user ? L("Nutzer: ", "User: ") : L("Du: ", "You: ")) + String($0.text.prefix(700)) }.joined(separator: "\n") }.joined(separator: "\n\n")
            return text.isEmpty ? nil : Outcome(material: L("Frühere Gespräche", "Earlier conversations") + ":\n" + AILogic.wrap(AILogic.relevant(text, q, budget: 6000)))
        }
    }
    // Mehrere Deutungen oder eine normale Frage? Das Modell entscheidet nur zwischen den Treffern
    private static func choose(_ q: String, _ c: [ActLogic.Kind]) async throws -> ActLogic.Kind? {
        let list = c.enumerated().map { "\($0.offset + 1) = \($0.element.help)" }.joined(separator: "\n")
        let r = try await AIRun.answer([AITurn(user: true, text: "Möglichkeiten:\n\(list)\n0 = nichts davon, eine allgemeine Frage oder Bitte (erklären, schreiben, übersetzen, Wissen)\n\nEingabe des Nutzers: „\(q)“\n\nNummer:")],
                                       system: "Du ordnest eine Eingabe genau einer Möglichkeit zu. Antworte nur mit der Nummer.", tools: false, show: { _ in })
        return ActLogic.choice(r, c)
    }

    // MARK: Kalender und Erinnerungen
    private static func allowed(_ t: EKEntityType) async throws {
        let ok = t == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        guard ok else { throw AIFail.text(t == .event ? L("WinKomfort darf nicht auf den Kalender zugreifen. Erlaube es in Systemeinstellungen › Datenschutz & Sicherheit › Kalender.", "WinKomfort can't access your calendar. Allow it in System Settings › Privacy & Security › Calendars.") : L("WinKomfort darf nicht auf die Erinnerungen zugreifen. Erlaube es in Systemeinstellungen › Datenschutz & Sicherheit › Erinnerungen.", "WinKomfort can't access Reminders. Allow it in System Settings › Privacy & Security › Reminders.")) }
    }
    private static func calendar(_ q: String) async throws -> Outcome {
        try await allowed(.event)
        ActLogic.english = L("de", "en") == "en"
        let r = ActLogic.range(q)
        let ev = store.events(matching: store.predicateForEvents(withStart: r.from, end: r.to, calendars: nil)).sorted { $0.startDate < $1.startDate }.prefix(30)
        if ev.isEmpty { return Outcome(text: L("\(r.title.prefix(1).uppercased() + r.title.dropFirst()): keine Termine.", "Nothing \(r.title).")) }
        let one = r.to.timeIntervalSince(r.from) <= 90_000
        let cards = ev.map { e in
            AICard(kind: .event, title: e.title ?? "", detail: (one ? "" : e.startDate.formatted(.dateTime.weekday(.abbreviated).day().month()) + " · ") + (e.isAllDay ? L("ganztägig", "all day") : e.startDate.formatted(date: .omitted, time: .shortened) + " – " + e.endDate.formatted(date: .omitted, time: .shortened)) + (e.location.map { $0.isEmpty ? "" : " · " + String($0.prefix(60)) } ?? ""), start: e.startDate)
        }
        return Outcome(text: L("\(r.title.prefix(1).uppercased() + r.title.dropFirst()): \(ev.count == 1 ? "1 Termin" : "\(ev.count) Termine").", "\(r.title.prefix(1).uppercased() + r.title.dropFirst()): \(ev.count) event\(ev.count == 1 ? "" : "s")."), cards: Array(cards))
    }
    private static func reminders() async throws -> Outcome {
        try await allowed(.reminder)
        let l: [(String, Date?)] = await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { @Sendable r in
                c.resume(returning: (r ?? []).map { ($0.title ?? "", $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) }) })
            }
        }
        let s = l.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }.prefix(20)
        if s.isEmpty { return Outcome(text: L("Keine offenen Erinnerungen.", "No open reminders.")) }
        return Outcome(text: L("\(l.count) offen:", "\(l.count) open:"), cards: s.map { AICard(kind: .reminder, title: $0.0, detail: $0.1.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "") })
    }
    static func create(_ c: AICard) async throws {
        if c.kind == .newEvent {
            try await allowed(.event)
            guard let s = c.start, let cal = store.defaultCalendarForNewEvents else { throw AIFail.text(L("Es gibt keinen Kalender zum Eintragen.", "There's no calendar to add to.")) }
            let e = EKEvent(eventStore: store)
            e.title = c.title; e.startDate = s; e.isAllDay = c.hasTime != true
            e.endDate = c.hasTime == true ? s.addingTimeInterval(3600) : s
            e.calendar = cal
            try store.save(e, span: .thisEvent)
        } else {
            try await allowed(.reminder)
            guard let cal = store.defaultCalendarForNewReminders() else { throw AIFail.text(L("Es gibt keine Erinnerungsliste.", "There's no reminders list.")) }
            let r = EKReminder(eventStore: store)
            r.title = c.title; r.calendar = cal
            if let s = c.start {
                r.dueDateComponents = Calendar.current.dateComponents(c.hasTime == true ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: s)
                if c.hasTime == true { r.addAlarm(EKAlarm(absoluteDate: s)) }
            }
            try store.save(r, commit: true)
        }
    }

    // MARK: Dateien (Suchindex von macOS)
    private static func files(_ q: String) async -> [AICard] {
        let words = ActLogic.fileWords(q), types = ActLogic.fileTypes(q)
        guard !words.isEmpty || !types.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [AICard] in
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "") }
            let t = types.map { "kMDItemFSName == \"*.\($0)\"c" }.joined(separator: " || ")
            func run(_ p: String) -> [String] {
                guard let m = MDQueryCreate(nil, (t.isEmpty ? p : p.isEmpty ? t : "(\(p)) && (\(t))") as CFString, nil, nil) else { return [] }
                MDQuerySetSearchScope(m, [NSHomeDirectory()] as CFArray, 0)
                MDQuerySetMaxCount(m, 300)
                guard MDQueryExecute(m, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
                return (0..<MDQueryGetResultCount(m)).compactMap { i in
                    guard let p = MDQueryGetResultAtIndex(m, i) else { return nil }
                    return MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(p).takeUnretainedValue(), kMDItemPath) as? String
                }
            }
            let name = words.map { "kMDItemFSName == \"*\(esc($0))*\"cd" }, text = words.map { "kMDItemTextContent == \"\(esc($0))*\"cd" }
            var found = run(name.joined(separator: " && "))
            if found.isEmpty, !words.isEmpty { found = run(text.joined(separator: " && ")) }
            if found.isEmpty, words.count > 1 { found = run(name.joined(separator: " || ")) }
            let skip = ["/Library/", "/node_modules/", "/.", ".app/"]
            let dated = found.filter { p in !skip.contains { p.contains($0) } }.map { ($0, (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
            return dated.sorted { $0.1 > $1.1 }.prefix(6).map { p, d in
                AICard(kind: .file, title: (p as NSString).lastPathComponent, detail: ((p as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath + " · " + d.formatted(date: .abbreviated, time: .omitted), path: p)
            }
        }.value
    }

    // MARK: Bildschirm: vorderstes Fenster der App, aus der man kommt
    static var lastApp: pid_t?
    static func screen() async -> AIDoc? {
        guard CGPreflightScreenCaptureAccess() else { CGRequestScreenCaptureAccess(); return nil }
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let mine = getpid()
        let wins = c.windows.filter { $0.owningApplication?.processID != mine && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150 }.sorted { (order.firstIndex(of: $0.windowID) ?? 999) < (order.firstIndex(of: $1.windowID) ?? 999) }
        guard let w = wins.first(where: { $0.owningApplication?.processID == lastApp }) ?? wins.first else { return nil }
        let cfg = SCStreamConfiguration()
        let f = min(2, 3000 / max(w.frame.width, w.frame.height))
        cfg.width = Int(w.frame.width * f); cfg.height = Int(w.frame.height * f); cfg.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return nil }
        let name = w.owningApplication?.applicationName ?? L("Fenster", "Window")
        return await Task.detached(priority: .userInitiated) { AIRead.image(img, name: name) }.value
    }

    // MARK: Mac, Wetter, Kontakte
    private static func statusText() -> String {
        var t = ["macOS " + ProcessInfo.processInfo.operatingSystemVersionString, "Arbeitsspeicher insgesamt: \(ProcessInfo.processInfo.physicalMemory >> 30) GB"]
        if let i = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let l = IOPSCopyPowerSourcesList(i)?.takeRetainedValue() as? [CFTypeRef], let p = l.first, let d = IOPSGetPowerSourceDescription(i, p)?.takeUnretainedValue() as? [String: Any] {
            t.append("Akku: \(d[kIOPSCurrentCapacityKey] as? Int ?? 0) %, " + (d[kIOPSIsChargingKey] as? Bool == true ? "lädt" : d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue ? "am Netzteil" : "im Akkubetrieb"))
            if let m = d[kIOPSTimeToEmptyKey] as? Int, m > 0, d[kIOPSIsChargingKey] as? Bool != true { t.append("Reicht noch etwa \(m / 60) h \(m % 60) min") }
        }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]), let f = v.volumeAvailableCapacityForImportantUsage, let a = v.volumeTotalCapacity {
            t.append("Speicherplatz frei: \(ByteCountFormatter.string(fromByteCount: f, countStyle: .file)) von \(ByteCountFormatter.string(fromByteCount: Int64(a), countStyle: .file))")
        }
        return "Zustand dieses Macs (aktuell, genau so verwenden, nur das Gefragte nennen): " + t.joined(separator: "; ")
    }
    private static func weather(_ q: String) async -> Outcome {
        guard AIChat.shared.web else { return Outcome(text: L("Fürs Wetter brauche ich das Internet. Schalte unten „Internet“ ein; dann geht nur der Ort an open-meteo.com.", "I need the internet for weather. Turn on “Internet” below; only the place is sent to open-meteo.com.")) }
        // Ort aus der Frage, sonst aus dem Gemerkten („ich wohne in Köln“)
        guard let place = ActLogic.place(q) ?? AIMemory.all.reversed().first(where: { $0.lowercased().contains("wohn") || $0.lowercased().contains("live in") }).flatMap(ActLogic.place) else {
            return Outcome(text: L("Für welchen Ort? Sag einmal „Merk dir, dass ich in Köln wohne“, dann weiß ich es immer.", "Which place? Say “Remember that I live in Cologne” once and I'll know.")) }
        func json(_ u: String, _ p: [String: String]) async -> [String: Any]? {
            var c = URLComponents(string: u)!
            c.queryItems = p.map { URLQueryItem(name: $0, value: $1) }
            guard let (d, _) = try? await URLSession.shared.data(for: URLRequest(url: c.url!, timeoutInterval: 8)) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        guard let g = await json("https://geocoding-api.open-meteo.com/v1/search", ["name": place, "count": "1", "language": L("de", "en")]) else { return Outcome(text: L("Das Wetter ist gerade nicht erreichbar.", "Weather is unavailable right now.")) }
        guard let r = (g["results"] as? [[String: Any]])?.first, let la = r["latitude"] as? Double, let lo = r["longitude"] as? Double else { return Outcome(text: L("Den Ort „\(place)“ kenne ich nicht.", "I don't know the place “\(place)”.")) }
        guard let w = await json("https://api.open-meteo.com/v1/forecast", ["latitude": "\(la)", "longitude": "\(lo)", "current": "temperature_2m,weather_code,wind_speed_10m", "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max", "timezone": "auto", "forecast_days": "7"]),
              let now = w["current"] as? [String: Any], let d = w["daily"] as? [String: Any], let codes = d["weather_code"] as? [Int], let hi = d["temperature_2m_max"] as? [Double], let low = d["temperature_2m_min"] as? [Double] else { return Outcome(text: L("Das Wetter ist gerade nicht erreichbar.", "Weather is unavailable right now.")) }
        let rain = d["precipitation_probability_max"] as? [Int?] ?? []
        func day(_ i: Int) -> String { let c = ActLogic.weather(codes[i]); return "\(L(c.0, c.1)), \(Int(low[i].rounded())) – \(Int(hi[i].rounded())) °C" + (rain.indices.contains(i) && rain[i] != nil ? L(", Regen \(rain[i]!) %", ", rain \(rain[i]!)%") : "") }
        let name = r["name"] as? String ?? place, l = q.lowercased()
        let src = [AISource(title: "Open-Meteo", url: "https://open-meteo.com/")]
        if l.contains("woche") || l.contains("wochenende") || l.contains("week") || l.contains("tage") {
            let rows = codes.indices.filter { hi.indices.contains($0) && low.indices.contains($0) }.map { i in "| \(Date().addingTimeInterval(Double(i) * 86400).formatted(.dateTime.weekday(.wide).day().month())) | \(day(i)) |" }
            return Outcome(text: "**\(name)**\n\n| \(L("Tag", "Day")) | \(L("Wetter", "Weather")) |\n|---|---|\n" + rows.joined(separator: "\n"), sources: src)
        }
        let i = ActLogic.when(q).map { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: $0.date)).day ?? 0 } ?? 0
        guard codes.indices.contains(i), hi.indices.contains(i), low.indices.contains(i) else { return Outcome(text: L("So weit reicht die Vorhersage nicht (7 Tage).", "The forecast only covers 7 days.")) }
        if i == 0, let t = now["temperature_2m"] as? Double, let c = now["weather_code"] as? Int { let s = ActLogic.weather(c); return Outcome(text: L("In \(name) sind es gerade **\(Int(t.rounded())) °C**, \(s.0). Heute: \(day(0)).", "It's **\(Int(t.rounded())) °C** in \(name), \(s.1). Today: \(day(0))."), sources: src) }
        return Outcome(text: "**\(name), \(Date().addingTimeInterval(Double(i) * 86400).formatted(.dateTime.weekday(.wide).day().month()))**: \(day(i)).", sources: src)
    }
    private static func contact(_ q: String) async throws -> Outcome {
        let s = CNContactStore()
        guard try await s.requestAccess(for: .contacts) else { throw AIFail.text(L("WinKomfort darf nicht auf die Kontakte zugreifen (Systemeinstellungen › Datenschutz & Sicherheit › Kontakte).", "WinKomfort can't access your contacts (System Settings › Privacy & Security › Contacts).")) }
        let drop: Set<String> = ["nummer", "telefonnummer", "handynummer", "handy", "adresse", "geburtstag", "mail", "email", "kontakt", "von", "hat", "gib", "lautet", "welche", "number", "phone", "birthday", "address"]
        let words = AILogic.words(q).filter { !drop.contains($0) }
        let found = try await Task.detached { () -> [String] in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey] as [CNKeyDescriptor]
            var out: [String] = []
            for w in words {
                for c in try s.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: w), keysToFetch: keys).prefix(4) {
                    var l = ["**\(c.givenName) \(c.familyName)**"]
                    l += c.phoneNumbers.map { "- Telefon: " + $0.value.stringValue } + c.emailAddresses.map { "- E-Mail: " + ($0.value as String) }
                    l += c.postalAddresses.map { "- Adresse: " + CNPostalAddressFormatter().string(from: $0.value).replacingOccurrences(of: "\n", with: ", ") }
                    if let b = c.birthday, let d = b.day, let m = b.month { l.append("- Geburtstag: \(d).\(m).\(b.year.map(String.init) ?? "")") }
                    let t = l.joined(separator: "\n")
                    if !out.contains(t) { out.append(t) }
                }
            }
            return out
        }.value
        return Outcome(text: found.isEmpty ? L("Dazu habe ich keinen Kontakt gefunden.", "I found no matching contact.") : found.prefix(4).joined(separator: "\n\n"))
    }
}

// MARK: - Sprechen (Erkennung nur auf dem Mac)

@MainActor final class Voice: ObservableObject {
    static let shared = Voice()
    @Published private(set) var on = false
    @Published private(set) var level: Float = 0
    @Published private(set) var text = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?
    private var done: ((String) -> Void)?
    private var session = 0

    func toggle(_ done: @escaping (String) -> Void) { if on { finish() } else { start(done) } }
    private func start(_ done: @escaping (String) -> Void) {
        Speech.stop()
        Task {
            let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { @Sendable s in c.resume(returning: s == .authorized) } }
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard speech, mic else { AIChat.shared.problem = L("Zum Sprechen braucht WinKomfort „Mikrofon“ und „Spracherkennung“ (Systemeinstellungen › Datenschutz & Sicherheit).", "Voice needs Microphone and Speech Recognition (System Settings › Privacy & Security)."); return }
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: L("de-DE", "en-US"))), r.isAvailable, r.supportsOnDeviceRecognition else { AIChat.shared.problem = L("Die Spracherkennung auf dem Mac ist noch nicht geladen. Schalte einmal die Diktierfunktion in Systemeinstellungen › Tastatur ein.", "On-device speech isn't installed yet. Turn on Dictation once in System Settings › Keyboard."); return }
            guard !on else { return }
            let q = SFSpeechAudioBufferRecognitionRequest()
            q.requiresOnDeviceRecognition = true
            q.shouldReportPartialResults = true
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else { AIChat.shared.problem = L("Kein Mikrofon gefunden.", "No microphone found."); return }
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { @Sendable [weak self] b, _ in
                q.append(b)
                guard let p = b.floatChannelData?[0], b.frameLength > 0 else { return }
                var s: Float = 0
                for i in 0..<Int(b.frameLength) { s += p[i] * p[i] }
                let v = min(1, sqrt(s / Float(b.frameLength)) * 12)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.level = v } }
            }
            engine.prepare()
            do { try engine.start() } catch { engine.inputNode.removeTap(onBus: 0); AIChat.shared.problem = L("Das Mikrofon ist gerade nicht verfügbar.", "The microphone isn't available."); return }
            session += 1
            let me = session
            self.done = done; request = q; text = ""; on = true
            wait(6)
            task = r.recognitionTask(with: q) { @Sendable [weak self] res, err in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.on, me == self.session else { return }
                    if let t = res?.bestTranscription.formattedString, !t.isEmpty { self.text = t; self.wait(1.4) } // kurze Pause = fertig
                    if err != nil || res?.isFinal == true { self.finish() }
                } }
            }
        }
    }
    private func wait(_ s: Double) {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { _ in MainActor.assumeIsolated { Voice.shared.finish() } }
    }
    func finish(send: Bool = true) {
        guard on else { return }
        on = false; level = 0; session += 1
        silence?.invalidate(); silence = nil
        engine.stop(); engine.inputNode.removeTap(onBus: 0) // Mikrofon wirklich aus
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines), d = done
        done = nil; text = ""
        if send, !t.isEmpty { d?(t) }
    }
}
