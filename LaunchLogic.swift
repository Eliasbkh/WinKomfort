// Eigene Kürzel: was ein Kürzel starten kann (reine Daten, testbar)
import Foundation

enum LaunchKind: String, Codable, CaseIterable { case app, file, web, shortcut, command }

struct LaunchKey: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: LaunchKind
    var target: String      // Pfad, Adresse, Name des Kurzbefehls oder Befehl
    var shortcut: Shortcut?
}

enum LaunchLogic {
    // „github.com“ → https://github.com; andere Schemata (mailto:, spotify: …) bleiben
    static func url(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        return URL(string: t.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:(?![0-9])", options: .regularExpression) != nil ? t : "https://" + t)
    }
}
