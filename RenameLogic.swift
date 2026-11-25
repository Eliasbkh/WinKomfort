// Mehrere Dateien umbenennen: neue Namen berechnen (reine Logik, testbar)
import Foundation

enum RenameLogic {
    enum Mode { case number, replace }
    static func names(_ old: [String], mode: Mode, a: String, b: String) -> [String] {
        let width = max(String(old.count).count, 2)
        return old.enumerated().map { i, n in
            switch mode {
            case .number:
                let ext = (n as NSString).pathExtension
                return a.trimmingCharacters(in: .whitespaces) + " " + String(format: "%0\(width)d", i + 1) + (ext.isEmpty ? "" : "." + ext)
            case .replace: return a.isEmpty ? n : n.replacingOccurrences(of: a, with: b)
            }
        }
    }
    // nil = in Ordnung, sonst der Grund
    enum Problem { case empty, slash, twice, exists }
    static func problem(_ old: [String], _ new: [String], taken: Set<String>) -> Problem? {
        if new.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix(".") && !old.contains($0) }) { return .empty }
        if new.contains(where: { $0.contains("/") || $0.contains(":") }) { return .slash }
        if Set(new.map { $0.lowercased() }).count != new.count { return .twice }
        let others = Set(taken.map { $0.lowercased() }).subtracting(old.map { $0.lowercased() })
        return new.contains { others.contains($0.lowercased()) } ? .exists : nil
    }
}
