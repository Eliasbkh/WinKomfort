// Ein Tastenkürzel: Tastencode + Modifier (Carbon-Werte), dazu der Tastenname, wie er beim Aufnehmen auf
// deiner Tastatur stand (z. B. „Z“ auf deutscher Tastatur, wo eine US-Tastatur „Y“ hätte). Reine Logik → testbar.
struct Shortcut: Codable, Equatable {
    var code: Int
    var mods: Int
    var key: String

    // Carbon-Modifier (dieselben Werte wie controlKey, optionKey … – hier ohne Carbon-Import, damit testbar)
    static let command = 256, shift = 512, option = 2048, control = 4096

    // Namen für Tasten ohne Buchstaben
    static let special: [Int: String] = [
        49: "Leertaste", 53: "⎋", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    static func isFunctionKey(_ code: Int) -> Bool { (special[code] ?? "").hasPrefix("F") }

    init(code: Int, mods: Int, key: String? = nil) {
        self.code = code
        self.mods = mods
        self.key = Shortcut.special[code] ?? key?.uppercased() ?? "?"
    }

    // Reihenfolge wie bei Apple: ⌃ ⌥ ⇧ ⌘, dann die Taste
    var display: String {
        var s = ""
        if mods & Shortcut.control != 0 { s += "⌃" }
        if mods & Shortcut.option != 0 { s += "⌥" }
        if mods & Shortcut.shift != 0 { s += "⇧" }
        if mods & Shortcut.command != 0 { s += "⌘" }
        return key.count > 1 && !s.isEmpty ? s + " " + key : s + key
    }

    // Ohne ⌘, ⌃ oder ⌥ würde ein normaler Buchstabe beim Tippen ausgelöst – das nur bei F-Tasten erlauben
    var isValid: Bool {
        mods & (Shortcut.command | Shortcut.control | Shortcut.option) != 0 || Shortcut.isFunctionKey(code)
    }
}
