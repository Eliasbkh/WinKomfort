// Rangfolge der Suche: wie gut der Name passt, wie oft und zuletzt benutzt. Reine Logik → testbar.
import Foundation

enum SearchRank {
    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil) }

    // Güte 0…1 (nil = passt nicht): genau > Anfang > Wortanfang > Anfangsbuchstaben > enthalten > Buchstaben der Reihe nach
    static func match(_ query: String, _ name: String) -> Double? {
        let q = fold(query), n = fold(name)
        guard !q.isEmpty else { return nil }
        if n == q { return 1 }
        if n.hasPrefix(q) { return 0.9 }
        let words = n.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 0.8 }
        if q.count >= 2, String(words.compactMap(\.first)).hasPrefix(q) { return 0.75 }
        // „VisualStudioCode“ → V S C
        if q.count >= 2, fold(String(name.filter(\.isUppercase))).hasPrefix(q) { return 0.7 }
        if n.contains(q) { return 0.6 }
        guard q.count >= 3, n.first == q.first else { return nil }
        var i = n.startIndex
        for c in q { guard let f = n[i...].firstIndex(of: c) else { return nil }; i = n.index(after: f) }
        return 0.4
    }
    // Benutzung verblasst: nach 14 Tagen zählt sie halb
    static func decayed(_ score: Double, since: Date, now: Date) -> Double { score * pow(0.5, max(0, now.timeIntervalSince(since)) / (14 * 86400)) }
    // Häufig benutzt hebt um höchstens 0,25 an – ein deutlich besserer Namenstreffer bleibt vorne
    static func total(_ match: Double, usage: Double) -> Double { match + 0.25 * usage / (usage + 5) }
}
