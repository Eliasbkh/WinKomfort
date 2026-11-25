// Emoji-Suche: Namen aus Unicode (englisch) plus deutsche Stichwörter für die gängigsten
import Foundation

enum Emoji {
    private static let german: [String: String] = [
        "😀": "lachen grinsen", "😂": "lachen tränen", "🤣": "lachen", "😊": "lächeln", "😍": "verliebt", "😘": "kuss", "😭": "weinen traurig", "😢": "traurig weinen", "😡": "wütend sauer", "😎": "cool sonnenbrille",
        "🤔": "denken nachdenken", "😴": "schlafen müde", "🤯": "explodiert kopf", "🥳": "party feiern", "😅": "schwitzen", "😱": "schock schreien", "🙄": "augen rollen", "😉": "zwinkern", "🤗": "umarmen", "🥺": "bitte",
        "👍": "daumen hoch ja", "👎": "daumen runter nein", "👏": "klatschen", "🙏": "danke bitte beten", "💪": "stark muskel", "👋": "winken hallo tschüss", "👌": "ok", "✌": "frieden", "🤝": "hand geben", "👀": "augen schauen",
        "❤": "herz rot liebe", "💔": "gebrochenes herz", "💙": "herz blau", "💚": "herz grün", "💛": "herz gelb", "🧡": "herz orange", "💜": "herz lila", "🖤": "herz schwarz",
        "🔥": "feuer", "✨": "funkeln glitzer", "⭐": "stern", "🎉": "party konfetti feiern", "🎂": "kuchen geburtstag", "🎁": "geschenk", "✅": "haken fertig", "❌": "kreuz falsch", "⚠": "warnung achtung", "❗": "ausrufezeichen",
        "❓": "fragezeichen", "💡": "idee glühbirne", "🚀": "rakete", "⏰": "wecker zeit", "📅": "kalender", "📌": "pin", "📎": "büroklammer", "📚": "bücher schule lernen", "✏": "stift schreiben", "💻": "laptop computer", "📱": "handy",
        "🏠": "haus zuhause", "🚗": "auto", "🚲": "fahrrad", "⚽": "fußball", "🎮": "spiel controller", "🎵": "musik note", "☕": "kaffee", "🍕": "pizza", "🍺": "bier", "🍎": "apfel", "🌞": "sonne", "☀": "sonne", "🌧": "regen", "❄": "schnee",
        "🌈": "regenbogen", "🐶": "hund", "🐱": "katze", "🤖": "roboter", "💀": "totenkopf", "💩": "kacke", "👑": "krone", "💰": "geld", "🔒": "schloss gesperrt", "🔑": "schlüssel", "➡": "pfeil rechts", "⬅": "pfeil links",
    ]
    static let all: [(char: String, name: String)] = [0x203C...0x3299, 0x1F300...0x1FAFF].flatMap { $0 }.compactMap { v in
        guard let u = Unicode.Scalar(UInt32(v)), u.properties.isEmoji, !u.properties.isEmojiModifier, let n = u.properties.name else { return nil }
        let c = String(u), name = n.lowercased()
        guard !name.contains("regional indicator") else { return nil }
        return (u.properties.isEmojiPresentation ? c : c + "\u{FE0F}", name + (german[c].map { " · " + $0 } ?? ""))
    }
    static func search(_ q: String) -> [(char: String, name: String)] {
        let words = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(separator: " ")
        if words.isEmpty { return all.filter { german[String($0.char.unicodeScalars.first!)] != nil } }
        return Array(all.filter { e in
            let n = e.name.folding(options: .diacriticInsensitive, locale: nil)
            return words.allSatisfy { w in n.split { $0 == " " || $0 == "·" }.contains { $0.hasPrefix(w) } }
        }.sorted { ($0.name.contains("·") ? 0 : 1) < ($1.name.contains("·") ? 0 : 1) }.prefix(80))
    }
}
