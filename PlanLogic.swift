// Schule: Stundenplan, Aufgaben, Noten, Lernkarten – Daten und Rechnen, testbar
import Foundation

enum Plan {
    struct Lesson: Codable, Identifiable, Equatable { var id = UUID(); var day = 2; var start = 455; var end = 500; var subject = ""; var room = ""; var week = 0; var date: Date? = nil; var off: Bool? = nil } // day 2 = Montag; week 0 = jede, 1 = A, 2 = B; date nur bei abgeglichenen Stunden aus WebUntis, off = Entfall
    struct Task: Codable, Identifiable, Equatable { var id = UUID(); var subject = ""; var text = ""; var due: Date; var exam = false; var done = false }
    struct Grade: Codable, Identifiable, Equatable { var id = UUID(); var subject = ""; var value = 1.0; var weight = 1.0; var name = ""; var date = Date(); var oral: Bool? = nil; var isOral: Bool { oral == true } } // weight zählt innerhalb von schriftlich bzw. mündlich
    struct Card: Codable, Identifiable, Equatable { var id = UUID(); var front = ""; var back = ""; var box = 0; var due = Date.distantPast; var right = 0; var wrong = 0 }
    struct Subject: Codable, Identifiable, Equatable { var id = UUID(); var name = ""; var written = 50 } // Anteil schriftlich in Prozent
    struct Untis: Codable, Equatable { var server = "", school = "", user = "", name = "" } // Passwort liegt im Schlüsselbund
    struct Deck: Codable, Identifiable, Equatable { var id = UUID(); var name = ""; var cards: [Card] = [] }
    struct Book: Codable, Equatable {
        var lessons: [Lesson] = [], tasks: [Task] = [], grades: [Grade] = [], decks: [Deck] = [], subjects: [Subject] = []
        var untis: Untis?, dated: [Lesson] = [], datedFrom: Date?, datedTo: Date?, synced: Date? // echter Plan aus WebUntis für datedFrom..<datedTo
        var points = true          // Punkte 0–15 (Oberstufe) statt Noten 1–6
        var aWeekOdd = true        // A-Woche = ungerade Kalenderwoche
        init() {}
        // Fehlende Felder in älteren Dateien füllen statt die Datei zu verwerfen
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            func list<T: Decodable>(_ k: CodingKeys) -> [T] { ((try? c.decode([Lossy<T>].self, forKey: k)) ?? []).compactMap(\.value) }
            lessons = list(.lessons); tasks = list(.tasks); grades = list(.grades); decks = list(.decks); subjects = list(.subjects); dated = list(.dated)
            untis = try? c.decode(Untis.self, forKey: .untis); datedFrom = try? c.decode(Date.self, forKey: .datedFrom); datedTo = try? c.decode(Date.self, forKey: .datedTo); synced = try? c.decode(Date.self, forKey: .synced)
            points = (try? c.decode(Bool.self, forKey: .points)) ?? true
            aWeekOdd = (try? c.decode(Bool.self, forKey: .aWeekOdd)) ?? true
        }
    }
    struct Lossy<T: Decodable>: Decodable { let value: T?; init(from d: Decoder) throws { value = try? T(from: d) } }

    static func clock(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }
    static func minutes(_ s: String) -> Int? {
        let p = s.split { ":.".contains($0) }
        guard let h = p.first.flatMap({ Int($0) }), (0..<24).contains(h), p.count <= 2 else { return nil }
        let m = p.count == 2 ? Int(p[1]) : 0
        guard let m, (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    static func lessons(_ b: Book, on d: Date, _ cal: Calendar = ActLogic.cal) -> [Lesson] { day(b, d, cal).filter { $0.off != true } }
    // Mit Entfall; im abgeglichenen Zeitraum der echte Plan aus WebUntis
    static func day(_ b: Book, _ d: Date, _ cal: Calendar = ActLogic.cal) -> [Lesson] {
        if let f = b.datedFrom, let t = b.datedTo, f <= d, d < t { return b.dated.filter { $0.date.map { cal.isDate($0, inSameDayAs: d) } == true }.sorted { $0.start < $1.start } }
        let wd = cal.component(.weekday, from: d), odd = isoWeek(d, cal) % 2 == 1
        return b.lessons.filter { $0.day == wd && ($0.week == 0 || ($0.week == 1) == (odd == b.aWeekOdd)) }.sorted { $0.start < $1.start }
    }
    static func isoWeek(_ d: Date, _ cal: Calendar) -> Int { var c = cal; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c.component(.weekOfYear, from: d) }
    // Jetzt und danach
    static func now(_ b: Book, _ d: Date, _ cal: Calendar = ActLogic.cal) -> (current: Lesson?, next: Lesson?) {
        let m = cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d), l = lessons(b, on: d, cal)
        return (l.first { $0.start <= m && m < $0.end }, l.first { $0.start > m })
    }
    static func nextDate(_ b: Book, subject: String, after d: Date, _ cal: Calendar = ActLogic.cal) -> Date? {
        (1...28).lazy.compactMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: d)) }.first { lessons(b, on: $0, cal).contains { $0.subject == subject } }
    }
    static func subjects(_ b: Book) -> [String] {
        var out: [String] = []
        for s in b.subjects.map(\.name) + b.lessons.map(\.subject) + b.grades.map(\.subject) + b.tasks.map(\.subject) where !s.isEmpty && !out.contains(s) { out.append(s) }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    // Fach im Satz: „Mathe S. 43“ oder „M …“ nur bei ganzem Wort; längster Treffer gewinnt
    static func subject(in s: String, _ b: Book) -> String? {
        let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
        return subjects(b).filter { f in let l = f.lowercased(); return words.contains(l) || (l.count > 4 && words.contains { $0.count > 3 && (l.hasPrefix($0) || $0.hasPrefix(l)) }) }.max { $0.count < $1.count }
    }

    // MARK: Noten
    static func mean(_ g: [Grade]) -> Double? { let w = g.reduce(0) { $0 + $1.weight }; return w > 0 ? g.reduce(0) { $0 + $1.value * $1.weight } / w : nil }
    // Schriftlich und mündlich getrennt mitteln, dann nach Anteil verrechnen; fehlt eine Seite, zählt die andere allein
    static func average(_ g: [Grade], written: Double = 0.5) -> Double? {
        let w = mean(g.filter { !$0.isOral }), o = mean(g.filter(\.isOral))
        if let w, let o { return written * w + (1 - written) * o }
        return w ?? o
    }
    static func written(_ b: Book, _ s: String) -> Double { Double(min(max(b.subjects.first { $0.name == s }?.written ?? 50, 0), 100)) / 100 }
    static func average(_ b: Book, _ s: String) -> Double? { average(b.grades.filter { $0.subject == s }, written: written(b, s)) }
    static func overall(_ b: Book) -> Double? { let a = subjects(b).compactMap { average(b, $0) }; return a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
    // Punkte → Note (deutsche Oberstufe): N = (17 − P) / 3
    static func note(fromPoints p: Double) -> Double { min(max((17 - p) / 3, 1), 6) }
    static func text(_ v: Double, _ points: Bool) -> String {
        let s = String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
        return points ? s + " P" : s
    }
    static func valid(_ v: Double, _ points: Bool) -> Bool { points ? (0...15).contains(v) : (1...6).contains(v) }
    static func gradeValue(_ s: String, _ points: Bool) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."), d = 0.0
        if !points, t.hasSuffix("+") { d = -0.25; t.removeLast() } else if !points, t.hasSuffix("-"), t.count > 1 { d = 0.25; t.removeLast() }
        guard let v = Double(t), valid(v + d, points) || valid(v, points) else { return nil }
        return points ? v : min(max(v + d, 1), 6)
    }
    // Was brauche ich als Nächstes, um auf den Wunschschnitt zu kommen?
    // Der Schnitt ist linear in der neuen Note, also reichen zwei Probewerte
    static func needed(_ g: [Grade], goal: Double, weight: Double, oral: Bool = false, written: Double = 0.5) -> Double {
        func f(_ x: Double) -> Double { average(g + [Grade(value: x, weight: weight, oral: oral)], written: written) ?? x }
        let a = f(0), b = f(1)
        return b == a ? .nan : (goal - a) / (b - a)
    }

    // MARK: Lernkarten (Leitner: 0, 1, 2, 4, 8, 16, 32 Tage)
    static let gaps = [0, 1, 2, 4, 8, 16, 32]
    static func answer(_ c: Card, right: Bool, now: Date, _ cal: Calendar = ActLogic.cal) -> Card {
        var c = c
        if right { c.right += 1; c.box = min(c.box + 1, gaps.count - 1) } else { c.wrong += 1; c.box = 0 }
        c.due = right ? cal.date(byAdding: .day, value: gaps[c.box], to: cal.startOfDay(for: now)) ?? now : now
        return c
    }
    static func due(_ d: Deck, _ now: Date) -> [Card] { d.cards.filter { $0.due <= now }.sorted { ($0.box, $0.due) < ($1.box, $1.due) } }
    // Einfügen: „Frage | Antwort“, Tabulator (Quizlet, Anki, Excel) oder „Frage;Antwort“
    static func cards(_ t: String) -> [Card] {
        t.components(separatedBy: .newlines).compactMap { l in
            for sep in ["\t", " | ", "|", ";"] {
                if let r = l.range(of: sep) {
                    let a = l[..<r.lowerBound].trimmingCharacters(in: .whitespaces), b = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    return a.isEmpty || b.isEmpty ? nil : Card(front: a, back: b)
                }
            }
            return nil
        }
    }

    // MARK: Kalenderdatei (.ics, z. B. aus WebUntis) → Stundenplan
    static func ics(_ text: String, _ cal: Calendar = ActLogic.cal) -> [Lesson] {
        // gefaltete Zeilen zusammensetzen
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        func plain(_ s: String) -> String { s.replacingOccurrences(of: #"\,"#, with: ",").replacingOccurrences(of: #"\;"#, with: ";").replacingOccurrences(of: #"\n"#, with: " ").trimmingCharacters(in: .whitespaces) }
        func date(_ line: String) -> Date? {
            guard let v = line.split(separator: ":").last.map(String.init), v.count >= 15 else { return nil } // ganztägig zählt nicht
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd'T'HHmmss"
            f.timeZone = v.hasSuffix("Z") ? TimeZone(identifier: "UTC") : cal.timeZone
            return f.date(from: String(v.prefix(15)))
        }
        var items: [(Lesson, Int, String)] = []
        for ev in t.components(separatedBy: "BEGIN:VEVENT").dropFirst().prefix(5000) {
            var a: Date?, b: Date?, sum = "", loc = "", rule = "", off = false
            for l in ev.components(separatedBy: "END:VEVENT")[0].split(separator: "\n").map(String.init) {
                if l.hasPrefix("DTSTART") { a = date(l) } else if l.hasPrefix("DTEND") { b = date(l) }
                else if l.hasPrefix("SUMMARY"), let c = l.firstIndex(of: ":") { sum = plain(String(l[l.index(after: c)...])) }
                else if l.hasPrefix("LOCATION"), let c = l.firstIndex(of: ":") { loc = plain(String(l[l.index(after: c)...])) }
                else if l.hasPrefix("RRULE") { rule = l } else if l.hasPrefix("STATUS:CANCELLED") { off = true }
            }
            guard !off, let a, let b, !sum.isEmpty, b > a, b.timeIntervalSince(a) < 6 * 3600, cal.isDate(a, inSameDayAs: b) else { continue }
            func m(_ d: Date) -> Int { cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
            items.append((Lesson(day: cal.component(.weekday, from: a), start: m(a), end: m(b), subject: String(sum.prefix(60)), room: String(loc.prefix(30))), isoWeek(a, cal), rule))
        }
        return fold(items)
    }
    // Einzelne Termine (Stunde, Kalenderwoche, Wiederholungsregel) → regelmäßiger Plan mit A/B-Wochen
    static func fold(_ items: [(Lesson, Int, String)]) -> [Lesson] {
        struct Key: Hashable { let day, start, end: Int, subject, room: String }
        var weeks: [Key: Set<Int>] = [:], every = Set<Key>(), all = Set<Int>(), fixed: [Key: Int] = [:]
        for (l, w, rule) in items {
            let k = Key(day: l.day, start: l.start, end: l.end, subject: l.subject, room: l.room)
            if rule.contains("FREQ=WEEKLY") { if rule.contains("INTERVAL=2") { fixed[k] = w % 2 } else { every.insert(k) } }
            weeks[k, default: []].insert(w); all.insert(w)
        }
        let alternating = all.count >= 3
        // Einzelne Vertretungen fallen heraus, wenn die Datei mehrere Wochen umfasst
        return weeks.filter { every.contains($0.key) || fixed[$0.key] != nil || !alternating || $0.value.count >= 2 }.map { k, w in
            let odd = fixed[k] ?? (alternating && !every.contains(k) && Set(w.map { $0 % 2 }).count == 1 && w.count * 2 >= all.count - 1 ? w.first.map { $0 % 2 } : nil)
            return Lesson(day: k.day, start: k.start, end: k.end, subject: k.subject, room: k.room, week: odd.map { $0 == 1 ? 1 : 2 } ?? 0)
        }.sorted { ($0.day, $0.start, $0.subject) < ($1.day, $1.start, $1.subject) }
    }

    // MARK: WebUntis (JSON-RPC getTimetable)
    struct UName: Decodable { let name: String?; let longname: String? }
    struct UPeriod: Decodable { let date: Int; let startTime: Int; let endTime: Int; let su: [UName]?; let ro: [UName]?; let code: String? }
    static func untisDay(_ d: Date, _ cal: Calendar = ActLogic.cal) -> Int { let c = cal.dateComponents([.year, .month, .day], from: d); return c.year! * 10000 + c.month! * 100 + c.day! }
    static func untis(_ p: [UPeriod], _ cal: Calendar = ActLogic.cal) -> [Lesson] {
        p.prefix(5000).compactMap { x in
            guard let d = cal.date(from: DateComponents(year: x.date / 10000, month: x.date / 100 % 100, day: x.date % 100)) else { return nil }
            let s = x.su?.first, n = (s?.longname).flatMap { $0.isEmpty || $0.count > 24 ? nil : $0 } ?? s?.name ?? ""
            let a = x.startTime / 100 * 60 + x.startTime % 100, b = x.endTime / 100 * 60 + x.endTime % 100
            guard !n.isEmpty, a < b, b <= 24 * 60 else { return nil }
            return Lesson(day: cal.component(.weekday, from: d), start: a, end: b, subject: String(n.prefix(60)), room: String((x.ro?.first?.name ?? "").prefix(30)), date: d, off: x.code == "cancelled" ? true : nil)
        }.sorted { ($0.date!, $0.start) < ($1.date!, $1.start) }
    }
    static func regular(_ dated: [Lesson], _ cal: Calendar = ActLogic.cal) -> [Lesson] {
        fold(dated.filter { $0.off != true }.compactMap { l in l.date.map { (Lesson(day: l.day, start: l.start, end: l.end, subject: l.subject, room: l.room), isoWeek($0, cal), "") } })
    }
}
