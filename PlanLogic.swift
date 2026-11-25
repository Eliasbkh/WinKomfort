// Schule: Stundenplan, Aufgaben, Noten, Lernkarten – Daten und Rechnen, testbar
import Foundation

enum Plan {
    struct Lesson: Codable, Identifiable, Equatable { var id = UUID(); var day = 2; var start = 455; var end = 500; var subject = ""; var room = ""; var week = 0 } // day 2 = Montag; week 0 = jede, 1 = A, 2 = B
    struct Task: Codable, Identifiable, Equatable { var id = UUID(); var subject = ""; var text = ""; var due: Date; var exam = false; var done = false }
    struct Grade: Codable, Identifiable, Equatable { var id = UUID(); var subject = ""; var value = 1.0; var weight = 1.0; var name = ""; var date = Date() }
    struct Card: Codable, Identifiable, Equatable { var id = UUID(); var front = ""; var back = ""; var box = 0; var due = Date.distantPast; var right = 0; var wrong = 0 }
    struct Deck: Codable, Identifiable, Equatable { var id = UUID(); var name = ""; var cards: [Card] = [] }
    struct Book: Codable, Equatable {
        var lessons: [Lesson] = [], tasks: [Task] = [], grades: [Grade] = [], decks: [Deck] = []
        var points = true          // Punkte 0–15 (Oberstufe) statt Noten 1–6
        var aWeekOdd = true        // A-Woche = ungerade Kalenderwoche
        init() {}
        // Fehlende Felder in älteren Dateien füllen statt die Datei zu verwerfen
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            func list<T: Decodable>(_ k: CodingKeys) -> [T] { ((try? c.decode([Lossy<T>].self, forKey: k)) ?? []).compactMap(\.value) }
            lessons = list(.lessons); tasks = list(.tasks); grades = list(.grades); decks = list(.decks)
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
    static func lessons(_ b: Book, on d: Date, _ cal: Calendar = ActLogic.cal) -> [Lesson] {
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
        for s in b.lessons.map(\.subject) + b.grades.map(\.subject) + b.tasks.map(\.subject) where !s.isEmpty && !out.contains(s) { out.append(s) }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    // Fach im Satz: „Mathe S. 43“ oder „M …“ nur bei ganzem Wort; längster Treffer gewinnt
    static func subject(in s: String, _ b: Book) -> String? {
        let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
        return subjects(b).filter { f in let l = f.lowercased(); return words.contains(l) || (l.count > 4 && words.contains { $0.count > 3 && (l.hasPrefix($0) || $0.hasPrefix(l)) }) }.max { $0.count < $1.count }
    }

    // MARK: Noten
    static func average(_ g: [Grade]) -> Double? { let w = g.reduce(0) { $0 + $1.weight }; return w > 0 ? g.reduce(0) { $0 + $1.value * $1.weight } / w : nil }
    static func overall(_ b: Book) -> Double? { let a = subjects(b).compactMap { s in average(b.grades.filter { $0.subject == s }) }; return a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
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
    static func needed(_ g: [Grade], goal: Double, weight: Double) -> Double {
        let w = g.reduce(0) { $0 + $1.weight }
        return (goal * (w + weight) - g.reduce(0) { $0 + $1.value * $1.weight }) / weight
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
}
