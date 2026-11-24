import Foundation

// Reihenfolge der OneNote-Abschnitte wie in der Seitenleiste – reine Logik, damit testbar.
enum OneNoteOrder {
    // rels: Pfade relativ zur Notizbuch-Wurzel („Gruppe/Abschnitt.one“), order: Namen in der Seitenleiste
    static func sort(_ rels: [String], order: [String]) -> [String] {
        func rank(_ name: String) -> Int { order.firstIndex(of: name) ?? Int.max / 2 }
        func key(_ rel: String) -> [Int] {
            let parts = rel.split(separator: "/").map(String.init)
            return parts.enumerated().map { i, p in rank(i == parts.count - 1 ? (p as NSString).deletingPathExtension : p) }
        }
        return rels.sorted { a, b in
            let ka = key(a), kb = key(b)
            if ka != kb { return ka.lexicographicallyPrecedes(kb) }
            return a.localizedStandardCompare(b) == .orderedAscending // Unbekanntes alphabetisch
        }
    }
}
