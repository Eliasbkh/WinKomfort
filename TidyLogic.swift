// Notizen schön machen: einfache Auszeichnung (# Überschrift, - Punkt, Formeln mit ^ und _) → HTML für OneNote
// und lesbarer Klartext. Ohne AppKit, testbar.
import Foundation

enum TidyLogic {
    private static let mathFont = "font-family:'Cambria Math','STIX Two Math','Times New Roman',serif;font-size:13pt"

    // Erkannte Textzeilen (Box 0…1, Ursprung unten links) in Leserichtung, Einrückung aus dem linken Rand
    static func lines(_ boxes: [(text: String, x: Double, y: Double, h: Double)]) -> String {
        guard let left = boxes.map(\.x).min() else { return "" }
        var rows: [[(text: String, x: Double, y: Double, h: Double)]] = []
        for b in boxes.sorted(by: { $0.y > $1.y }) { // gleiche Höhe = gleiche Zeile
            if let r = rows.last?.first, abs(r.y - b.y) < min(r.h, b.h) * 0.5 { rows[rows.count - 1].append(b) } else { rows.append([b]) }
        }
        return rows.map { r in
            let r = r.sorted { $0.x < $1.x }
            return String(repeating: "  ", count: min(4, Int(((r[0].x - left) / 0.045).rounded()))) + r.map(\.text).joined(separator: "  ")
        }.joined(separator: "\n")
    }

    // Formelzeile: Vergleichszeichen, Zahlen/Variablen, höchstens ein längeres Wort („Fläche = a * b“)
    static func isFormula(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.range(of: #"[=<>≤≥≈≠]"#, options: .regularExpression) != nil, t.range(of: #"[0-9]|\b[a-zA-Z]\b"#, options: .regularExpression) != nil else { return false }
        let words = t.split { !$0.isLetter }.filter { $0.count >= 3 && !greek.keys.contains(String($0)) && !["sqrt", "wurzel", "sin", "cos", "tan", "log", "lim"].contains($0.lowercased()) }
        return words.count <= 1
    }
    static let greek: [String: String] = ["pi": "π", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "Δ", "Delta": "Δ", "lambda": "λ", "omega": "ω", "Omega": "Ω", "theta": "θ", "sigma": "σ", "phi": "φ", "mu": "μ", "epsilon": "ε"]

    private static func re(_ s: String, _ p: String, _ t: String) -> String { s.replacingOccurrences(of: p, with: t, options: .regularExpression) }
    private static let group = #"\(([^()]*(?:\([^()]*\)[^()]*)*)\)"# // Klammer mit höchstens einer Ebene darin

    // Eine Zeile → HTML: Sonderzeichen, Hoch-/Tiefstellung, Wurzel, Malpunkt, **fett**
    static func inline(_ s: String, formula: Bool) -> String {
        var t = s
        for (a, b) in [("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("+-", "±"), ("~=", "≈"), ("=>", "⇒"), ("->", "→")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        t = re(t, #"\*\*(.+?)\*\*"#, "<b>$1</b>")
        t = re(t, #"(?<=[\w)²³])\s*\*\s*(?=[\w(])"#, " · ")
        t = re(t, #"(?i)\b(?:sqrt|wurzel)\s*"# + group, "√<span style=\"text-decoration:overline\">$1</span>")
        t = re(t, #"\^\{([^{}]+)\}"#, "<sup>$1</sup>")
        t = re(t, #"\^"# + group, "<sup>$1</sup>")
        t = re(t, #"\^\s?(-?\d+(?:[.,]\d+)?|-?[A-Za-zα-ω])"#, "<sup>$1</sup>")
        t = re(t, #"_\{([^{}]+)\}"#, "<sub>$1</sub>")
        t = re(t, #"_"# + group, "<sub>$1</sub>")
        t = re(t, #"(?<=[A-Za-zα-ωΔΩ)])_([A-Za-z0-9]+)"#, "<sub>$1</sub>")
        if formula { for (w, g) in greek { t = re(t, "\\b\(w)\\b", g) }; t = re(t, #"Δ\s+(?=[A-Za-z])"#, "Δ") } // Δv statt Δ v
        return t
    }

    struct Line: Equatable { enum Kind: Equatable { case h1, h2, h3, bullet, number, text, blank }; let kind: Kind; let level: Int; let text: String }
    static func parse(_ markup: String) -> [Line] {
        let raw = rawParse(markup)
        var out: [Line] = [], last = -1 // Ebene des letzten Listenpunkts; -1 = keine Liste offen
        for (i, l) in raw.enumerated() {
            switch l.kind {
            case .bullet, .number:
                let lv = min(l.level, last + 1) // keine Ebene überspringen
                out.append(Line(kind: l.kind, level: lv, text: l.text)); last = lv
            case .blank: // Leerzeile mitten in einer Liste weglassen, sonst zerfällt sie
                if last >= 0, let n = raw[(i + 1)...].first(where: { $0.kind != .blank }), n.kind == .bullet || n.kind == .number { continue }
                out.append(l); last = -1
            default: out.append(l); last = -1
            }
        }
        return out
    }
    private static func rawParse(_ markup: String) -> [Line] {
        markup.replacingOccurrences(of: "\t", with: "  ").components(separatedBy: .newlines).map { raw in
            let indent = raw.prefix { $0 == " " }.count
            let t = raw.trimmingCharacters(in: .whitespaces)
            let level = min(5, indent / 2)
            if t.isEmpty { return Line(kind: .blank, level: 0, text: "") }
            for (p, k) in [("### ", Line.Kind.h3), ("## ", .h2), ("# ", .h1)] where t.hasPrefix(p) { return Line(kind: k, level: 0, text: String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)) }
            for p in ["- ", "• ", "* ", "– ", "· "] where t.hasPrefix(p) { return Line(kind: .bullet, level: level, text: String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)) }
            if let r = t.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) { return Line(kind: .number, level: level, text: String(t[r.upperBound...])) }
            return Line(kind: .text, level: level, text: t)
        }
    }

    static func html(_ markup: String) -> String {
        var out = "", open: [String] = [] // offene Listen, innen zuletzt
        func close(to n: Int) { while open.count > n { out += "</\(open.removeLast())>" } }
        for l in parse(markup) {
            let f = isFormula(l.text), body = inline(l.text, formula: f)
            let content = f ? "<span style=\"\(mathFont)\">\(body)</span>" : body
            switch l.kind {
            case .bullet, .number:
                let tag = l.kind == .bullet ? "ul" : "ol"
                if open.count > l.level + 1 { close(to: l.level + 1) }
                if open.count == l.level + 1, open.last != tag { close(to: l.level) }
                while open.count < l.level + 1 { out += "<\(tag)>"; open.append(tag) }
                out += "<li>\(content)</li>"
            case .blank: close(to: 0)
            default:
                close(to: 0)
                switch l.kind {
                case .h1: out += "<h1 style=\"font-size:20pt\">\(body)</h1>"
                case .h2: out += "<h2 style=\"font-size:16pt\">\(body)</h2>"
                case .h3: out += "<h3 style=\"font-size:13pt\">\(body)</h3>"
                default: out += "<p style=\"margin:4px 0 4px \(l.level * 28 + (f ? 28 : 0))px\">\(content)</p>"
                }
            }
        }
        close(to: 0)
        return "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:Calibri,'Helvetica Neue',sans-serif;font-size:11pt\">\(out)</body></html>"
    }

    // Klartext für Apps ohne Formatierung: Hochzahlen als ² usw., wo es Unicode-Zeichen gibt
    static func plain(_ markup: String) -> String {
        let sup = Dictionary(uniqueKeysWithValues: zip("0123456789+-=()abcdefghijklmnoprstuvwxyz", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ"))
        let sub = Dictionary(uniqueKeysWithValues: zip("0123456789+-=()", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎"))
        func map(_ s: String, _ m: [Character: Character]) -> String? { let r = s.compactMap { m[$0] }; return r.count == s.count ? String(r) : nil }
        var n = 0
        return parse(markup).map { l in
            var t = l.text.replacingOccurrences(of: "**", with: "")
            for (a, b) in [("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("+-", "±"), ("~=", "≈"), ("=>", "⇒"), ("->", "→")] { t = t.replacingOccurrences(of: a, with: b) }
            t = re(t, #"(?<=[\w)])\s*\*\s*(?=[\w(])"#, " · ")
            for (p, m) in [(#"\^\(([^()]+)\)|\^(-?\d+|-?[a-z])"#, sup), (#"_\(([^()]+)\)|_(\d+)"#, sub)] {
                let ns = t as NSString
                for r in try! NSRegularExpression(pattern: p).matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let inner = String(ns.substring(with: r.range).dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    if let u = map(inner, m), let rr = Range(r.range, in: t) { t.replaceSubrange(rr, with: u) } // sonst bleibt ^(…) stehen
                }
            }
            if l.kind == .number { n += 1 } else if l.kind != .blank { n = 0 }
            let pad = String(repeating: "\t", count: l.level)
            switch l.kind {
            case .h1, .h2, .h3: return t
            case .bullet: return pad + "• " + t
            case .number: return pad + "\(n). " + t
            case .blank: return ""
            case .text: return pad + t
            }
        }.joined(separator: "\n")
    }

    // Lange Texte in Stücke fürs Modell (≈ 2500 Zeichen), an Leerzeilen getrennt
    static func chunks(_ s: String, max: Int = 2500) -> [String] {
        var out: [String] = [], cur = ""
        for p in s.components(separatedBy: "\n\n") {
            if !cur.isEmpty, cur.count + p.count > max { out.append(cur); cur = "" }
            if p.count > max { // sehr langer Absatz: an Zeilen trennen
                for line in p.components(separatedBy: "\n") { if !cur.isEmpty, cur.count + line.count > max { out.append(cur); cur = "" }; cur += (cur.isEmpty ? "" : "\n") + line }
            } else { cur += (cur.isEmpty ? "" : "\n\n") + p }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
    // Hat das Modell Inhalt verschluckt? Vergleich der Buchstaben und Ziffern
    static func kept(_ input: String, _ output: String) -> Bool {
        let a = input.filter { $0.isLetter || $0.isNumber }.count, b = output.filter { $0.isLetter || $0.isNumber }.count
        return a < 40 || Double(b) >= Double(a) * 0.7
    }
    // Antwort aufräumen: Codeblöcke und Vorreden wie „Hier ist …:“ weg
    static func clean(_ r: String) -> String {
        var lines = r.replacingOccurrences(of: "```", with: "").components(separatedBy: .newlines)
        if let f = lines.first?.lowercased(), f.hasSuffix(":"), f.hasPrefix("hier") || f.hasPrefix("here") || f.contains("übersichtlich") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
