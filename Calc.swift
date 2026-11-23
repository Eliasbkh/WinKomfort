import Foundation

// Kleiner Rechner für die Suche: + − × ÷ ^ %, Klammern, Komma oder Punkt als Dezimalzeichen.
// Eigener Parser statt NSExpression – der stürzt bei unfertigen Eingaben wie „2+“ ab.
enum Calc {
    static func evaluate(_ input: String) -> Double? {
        let s = input.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: " ", with: "")
        // Nur Rechnungen, keine einzelnen Zahlen (sonst wäre jede Suche nach „2024“ ein Rechenergebnis)
        guard !s.isEmpty, s.contains(where: { "+-*/^%(".contains($0) }),
              s.allSatisfy({ $0.isNumber || ".+-*/^%()".contains($0) }) else { return nil }
        var p = Parser(chars: Array(s))
        guard let v = p.expression(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func expression() -> Double? {        // Summe
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {              // Produkt
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let r = power() else { return nil }
                v = c == "*" ? v * r : v / r
            }
            return v
        }
        mutating func power() -> Double? {             // Potenz (rechtsassoziativ)
            guard let b = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return Foundation.pow(b, e)
            }
            return b
        }
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            guard var v = atom() else { return nil }
            while peek() == "%" { i += 1; v /= 100 }   // 50% = 0,5
            return v
        }
        mutating func atom() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = expression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }

    // 3 → „3“, 0,1+0,2 → „0,3“ (deutsches Komma, ohne Rundungsrauschen)
    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 10
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
