// Werkzeuge für Informationstechnik (TGI): Netze, Schaltalgebra, Zahlen, Struktogramm, Klassendiagramm, Elektrotechnik. Reine Logik, testbar.
import Foundation

enum TechLogic {
    // MARK: IPv4-Subnetz
    struct Net: Equatable { var ip, mask: UInt32; var prefix: Int
        var network: UInt32 { ip & mask }
        var broadcast: UInt32 { network | ~mask }
        var hosts: Int { prefix >= 31 ? (prefix == 31 ? 2 : 1) : Int(~mask) - 1 }
        var first: UInt32 { prefix >= 31 ? network : network + 1 }
        var last: UInt32 { prefix >= 31 ? broadcast : broadcast - 1 }
    }
    static func ip(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var r: UInt32 = 0
        for x in p { guard let b = UInt8(x), x.count <= 3 else { return nil }; r = r << 8 | UInt32(b) }
        return r
    }
    static func dotted(_ v: UInt32) -> String { [24, 16, 8, 0].map { String(v >> UInt32($0) & 255) }.joined(separator: ".") }
    static func bits(_ v: UInt32) -> String { [24, 16, 8, 0].map { let s = String(v >> UInt32($0) & 255, radix: 2); return String(repeating: "0", count: 8 - s.count) + s }.joined(separator: ".") }
    static func mask(_ n: Int) -> UInt32 { n == 0 ? 0 : UInt32.max << UInt32(32 - n) }
    // „192.168.1.10/26“ oder „192.168.1.10 255.255.255.192“
    static func net(_ s: String) -> Net? {
        let p = s.split { " /".contains($0) }.map(String.init)
        guard p.count >= 2, let a = ip(p[0]) else { return nil }
        if let n = Int(p[1]), (0...32).contains(n) { return Net(ip: a, mask: mask(n), prefix: n) }
        guard let m = ip(p[1]), (~m) & (~m &+ 1) == 0 else { return nil } // nur zusammenhängende Einsen
        return Net(ip: a, mask: m, prefix: m.nonzeroBitCount)
    }
    // Netz in n gleich große Teile
    static func split(_ n: Net, _ parts: Int) -> [Net]? {
        guard parts > 1, parts <= 1024 else { return nil }
        let add = Int(ceil(log2(Double(parts)))), p = n.prefix + add
        guard p <= 30 else { return nil }
        return (0..<parts).map { Net(ip: n.network + UInt32($0) << UInt32(32 - p), mask: mask(p), prefix: p) }
    }
    // VLSM: Hostzahlen → passende Netze, größte zuerst
    static func vlsm(_ n: Net, _ need: [Int]) -> [(Int, Net)]? {
        var at = UInt64(n.network), out: [(Int, Net)] = []
        for h in need.sorted(by: >) {
            guard h > 0, h < 1 << 24 else { return nil }
            let p = 32 - Int(ceil(log2(Double(h + 2)))), size = UInt64(1) << UInt64(32 - p)
            at = (at + size - 1) / size * size
            guard p >= n.prefix, at + size - 1 <= UInt64(n.broadcast) else { return nil }
            out.append((h, Net(ip: UInt32(at), mask: mask(p), prefix: p)))
            at += size
        }
        return out
    }

    // MARK: Schaltfunktion vereinfachen (Quine–McCluskey, bis 6 Variablen)
    struct Term: Hashable { var care, value: Int } // care = welche Variablen zählen
    static func primes(_ on: [Int], dontCare: [Int] = [], vars n: Int) -> [Term] {
        var cur = Set((on + dontCare).map { Term(care: (1 << n) - 1, value: $0) }), out = Set<Term>()
        while !cur.isEmpty {
            var next = Set<Term>(), used = Set<Term>()
            for a in cur { for k in 0..<n where a.care >> k & 1 == 1 {
                let b = Term(care: a.care, value: a.value ^ (1 << k))
                if cur.contains(b) { next.insert(Term(care: a.care & ~(1 << k), value: a.value & ~(1 << k))); used.insert(a) }
            } }
            out.formUnion(cur.subtracting(used))
            cur = next
        }
        return out.sorted { ($0.care.nonzeroBitCount, $0.care, $0.value) < ($1.care.nonzeroBitCount, $1.care, $1.value) }
    }
    static func minimize(_ on: [Int], dontCare: [Int] = [], vars n: Int) -> [Term] {
        guard !on.isEmpty else { return [] }
        let p = primes(on, dontCare: dontCare, vars: n)
        func covers(_ t: Term, _ m: Int) -> Bool { m & t.care == t.value }
        // kleinste Überdeckung: erst wesentliche, dann erschöpfend (wenige bleiben übrig), sonst gierig
        var chosen: [Term] = [], open = Set(on)
        for m in on { let c = p.filter { covers($0, m) }; if c.count == 1, !chosen.contains(c[0]) { chosen.append(c[0]) } }
        open = open.filter { m in !chosen.contains { covers($0, m) } }
        let rest = p.filter { t in !chosen.contains(t) && open.contains { covers(t, $0) } }
        if !open.isEmpty, rest.count <= 16 {
            var best: [Term]?, bestCost = (Int.max, Int.max)
            for s in 1..<(1 << rest.count) {
                let pick = rest.indices.filter { s >> $0 & 1 == 1 }.map { rest[$0] }
                let cost = (pick.count, pick.reduce(0) { $0 + $1.care.nonzeroBitCount })
                if cost < bestCost, open.allSatisfy({ m in pick.contains { covers($0, m) } }) { best = pick; bestCost = cost }
            }
            chosen += best ?? []
        } else {
            while !open.isEmpty, let t = rest.max(by: { a, b in open.filter { covers(a, $0) }.count < open.filter { covers(b, $0) }.count }) {
                chosen.append(t); open = open.filter { !covers(t, $0) }
            }
        }
        return chosen
    }
    static func dnf(_ t: [Term], _ names: [String], always: Bool) -> String {
        if t.isEmpty { return "0" }
        if t.contains(where: { $0.care == 0 }) { return "1" }
        let n = names.count
        return t.map { x in (0..<n).filter { x.care >> (n - 1 - $0) & 1 == 1 }.map { (x.value >> (n - 1 - $0) & 1 == 1 ? "" : "¬") + names[$0] }.joined(separator: " ∧ ") }
            .map { t.count > 1 && $0.contains("∧") ? "(\($0))" : $0 }.joined(separator: " ∨ ")
    }
    static func gray(_ n: Int) -> [Int] { (0..<(1 << n)).map { $0 ^ ($0 >> 1) } }

    // MARK: Zahlen
    static func ieee(_ s: String) -> (bits: String, hex: String, sign: Int, exp: Int, mant: String, value: Float)? {
        guard let f = Float(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { return nil }
        let b = f.bitPattern, t = String(b, radix: 2), x = String(repeating: "0", count: 32 - t.count) + t
        return ("\(x.prefix(1)) \(x.dropFirst().prefix(8)) \(x.suffix(23))", String(format: "0x%08X", b), Int(b >> 31), Int(b >> 23 & 255), String(x.suffix(23)), f)
    }
    static func twos(_ v: Int, _ bits: Int) -> String? {
        guard bits < 63, v >= -(1 << (bits - 1)), v < 1 << (bits - 1) else { return nil }
        let u = v < 0 ? (1 << bits) + v : v, s = String(u, radix: 2), p = String(repeating: "0", count: bits - s.count) + s
        return stride(from: 0, to: bits, by: 4).map { i in String(Array(p)[i..<min(i + 4, bits)]) }.joined(separator: " ")
    }

    // MARK: Elektrotechnik
    // „U=12 R=470“, „12V 20mA“ → alle vier Größen
    static func ohm(_ s: String) -> (u: Double, i: Double, r: Double, p: Double)? {
        var v: [Character: Double] = [:]
        for m in s.matches(of: #/(?:([UIRPuirp])\s*=\s*)?([0-9]+(?:[.,][0-9]+)?(?:e-?[0-9]+)?)\s*(m|µ|u|k|M|G|n)?(V|A|Ω|Ohm|ohm|W)?/#) {
            let scale: [Substring: Double] = ["n": 1e-9, "µ": 1e-6, "u": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9]
            guard let n = Double(m.2.replacingOccurrences(of: ",", with: ".")) else { continue }
            let key: Character? = m.1.flatMap { $0.uppercased().first } ?? m.4.map { $0 == "V" ? "U" : $0 == "A" ? "I" : $0 == "W" ? "P" : "R" } ?? (m.3 == "k" || m.3 == "M" ? "R" : nil)
            guard let key else { continue }
            v[key] = n * (m.3.flatMap { scale[$0] } ?? 1)
        }
        guard v.count == 2 else { return nil }
        var u = v["U"], i = v["I"], r = v["R"], p = v["P"]
        if let a = u, let b = i { r = a / b; p = a * b } else if let a = u, let b = r { i = a / b; p = a * a / b } else if let a = u, let b = p { i = b / a; r = a * a / b }
        else if let a = i, let b = r { u = a * b; p = a * a * b } else if let a = i, let b = p { u = b / a; r = b / (a * a) } else if let a = r, let b = p { u = (a * b).squareRoot(); i = (b / a).squareRoot() }
        guard let u, let i, let r, let p, [u, i, r, p].allSatisfy(\.isFinite) else { return nil }
        return (u, i, r, p)
    }
    static func si(_ v: Double, _ unit: String) -> String {
        if v == 0 { return "0 " + unit }
        let steps: [(Double, String)] = [(1e9, "G"), (1e6, "M"), (1e3, "k"), (1, ""), (1e-3, "m"), (1e-6, "µ"), (1e-9, "n")]
        let (f, p) = steps.first { abs(v) >= $0.0 * 0.9999999 } ?? (1e-12, "p")
        let x = v / f, d = Double(String(format: "%.4g", x)) ?? x
        return Calc.format(d) + " " + p + unit
    }
    static let colors = ["schwarz", "braun", "rot", "orange", "gelb", "grün", "blau", "violett", "grau", "weiß"]
    // „gelb violett rot gold“ → 4,7 kΩ ±5 %
    static func resistor(_ s: String) -> (ohm: Double, tol: String)? {
        let alias = ["gruen": "grün", "lila": "violett", "weiss": "weiß", "black": "schwarz", "brown": "braun", "red": "rot", "yellow": "gelb", "green": "grün", "blue": "blau", "violet": "violett", "purple": "violett", "grey": "grau", "gray": "grau", "white": "weiß", "silver": "silber"]
        let w = s.lowercased().split { " ,-".contains($0) }.map { alias[String($0)] ?? String($0) }
        guard (3...6).contains(w.count) else { return nil }
        let digits = w.count >= 5 ? 3 : 2
        var v = 0.0
        for k in 0..<digits { guard let d = colors.firstIndex(of: w[k]) else { return nil }; v = v * 10 + Double(d) }
        guard let m: Double = w[digits] == "gold" ? -1 : w[digits] == "silber" ? -2 : colors.firstIndex(of: w[digits]).map(Double.init) else { return nil }
        let tol = ["braun": "1", "rot": "2", "grün": "0,5", "blau": "0,25", "violett": "0,1", "gold": "5", "silber": "10"]
        return (v * pow(10, m), w.count > digits + 1 ? tol[w[digits + 1]] ?? "20" : "20")
    }

    // MARK: Struktogramm (Nassi–Shneiderman) aus einfachem Pseudocode
    indirect enum Block: Equatable { case step(String), branch(String, [Block], [Block]), loop(String, [Block]), until(String, [Block]), cases(String, [(String, [Block])])
        static func == (a: Block, b: Block) -> Bool { String(describing: a) == String(describing: b) }
    }
    // wenn/if … sonst/else … ende; solange/while/für/for … ende; wiederhole/do … bis/until …; Einrückung oder „ende“ oder { }
    static func nsd(_ src: String) -> [Block]? {
        struct Line { let depth: Int, text: String }
        var depth = 0
        let raw = src.replacingOccurrences(of: ";", with: "\n").replacingOccurrences(of: "{", with: "{\n").replacingOccurrences(of: "}", with: "\n}\n").components(separatedBy: "\n")
        let braces = src.contains("{")
        var lines: [Line] = []
        for r in raw {
            var t = r.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if braces {
                if t == "}" { depth = max(0, depth - 1); continue }
                let opens = t.hasSuffix("{")
                if opens { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
                if !t.isEmpty { lines.append(Line(depth: depth, text: t)) }
                if opens { depth += 1 }
            } else {
                let ind = !src.contains("\n") ? 0 : r.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                lines.append(Line(depth: ind, text: t))
            }
            if lines.count > 300 { return nil }
        }
        guard !lines.isEmpty else { return nil }
        var i = 0
        func word(_ t: String) -> (String, String) {
            let w = String(t.prefix { $0.isLetter }).lowercased()
            var r = String(t.dropFirst(w.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            for s in [" dann", " then", " tue", " do"] where r.lowercased().hasSuffix(s) { r = String(r.dropLast(s.count)) }
            if r.hasPrefix("("), r.hasSuffix(")"), r.dropFirst().dropLast().allSatisfy({ $0 != "(" && $0 != ")" }) { r = String(r.dropFirst().dropLast()) }
            return (w, r)
        }
        let ends: Set<String> = ["ende", "end", "endif", "endwhile", "endfor", "wend", "fi", "done"]
        func block(_ min: Int, _ level: Int) -> [Block] {
            var out: [Block] = []
            guard level < 24 else { return out }
            while i < lines.count, lines[i].depth >= min {
                let l = lines[i], (w, rest) = word(l.text)
                if ends.contains(w) || ["sonst", "else", "elif", "bis", "until"].contains(w) { return out }
                i += 1
                // ohne Einrückung gilt bis „ende“
                func body() -> [Block] { let deeper = i < lines.count && lines[i].depth > l.depth; return block(deeper ? lines[i].depth : l.depth, level + 1) }
                func end() { if i < lines.count, lines[i].depth >= l.depth, ends.contains(word(lines[i].text).0) { i += 1 } }
                switch w {
                case "wenn", "if", "falls":
                    func tail() -> [Block] {
                        guard i < lines.count, lines[i].depth == l.depth else { return [] }
                        let (w2, r2) = word(lines[i].text)
                        if w2 == "elif" || (["sonst", "else"].contains(w2) && ["wenn", "if"].contains(word(r2).0)) {
                            i += 1
                            let cond = w2 == "elif" ? r2 : word(r2).1
                            return [.branch(cond, body(), tail())]
                        }
                        if ["sonst", "else"].contains(w2) { i += 1; return (r2.isEmpty ? [] : [.step(r2)]) + body() }
                        return []
                    }
                    let a = body()
                    out.append(.branch(rest, a, tail())); end()
                case "solange", "while", "für", "fuer", "for": out.append(.loop((w == "while" || w == "solange" ? "solange " : "für ") + rest, body())); end()
                case "wiederhole", "do", "repeat":
                    let b = body()
                    var cond = rest
                    if i < lines.count, lines[i].depth >= min {
                        let (w2, r2) = word(lines[i].text)
                        if ["bis", "until"].contains(w2) { cond = "bis " + r2; i += 1 } else if ["solange", "while"].contains(w2) { cond = "solange " + r2; i += 1 }
                    }
                    out.append(.until(cond, b))
                default: out.append(.step(l.text))
                }
            }
            return out
        }
        var all: [Block] = []
        while i < lines.count { let before = i; all += block(0, 0); if i == before { i += 1 } } // überzähliges „ende“ überspringen
        return all.isEmpty ? nil : all
    }

    // MARK: Klassendiagramm: „Tier: -name: String, +fressen(); Hund < Tier: +bellen()“
    struct Cls: Equatable { var name: String, parent: String?, fields: [String], methods: [String] }
    static func uml(_ s: String) -> [Cls]? {
        let out = s.split { $0 == ";" || $0 == "\n" }.compactMap { part -> Cls? in
            let p = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = p.first, !head.isEmpty else { return nil }
            let h = head.components(separatedBy: "<").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let f = h[0].first, f.isLetter else { return nil }
            var items: [String] = [], cur = "", depth = 0
            for c in p.count > 1 ? p[1] : "" { // Kommas in Klammern gehören zu den Parametern
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                if c == ",", depth <= 0 { items.append(cur); cur = "" } else { cur.append(c) }
            }
            items.append(cur)
            items = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { "+-#~".contains($0.first!) ? $0 : "+" + $0 }
            return Cls(name: h[0], parent: h.count > 1 && !h[1].isEmpty ? h[1] : nil, fields: items.filter { !$0.contains("(") }, methods: items.filter { $0.contains("(") })
        }
        return out.isEmpty || out.count > 20 ? nil : out
    }

    // MARK: Zeitstempel
    static func unix(_ s: String) -> Date? {
        guard let n = Double(s), n > 100_000_000, n < 1e14 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }
    // Regulärer Ausdruck „/muster/ text“
    static func regex(_ s: String) -> (pattern: String, text: String)? {
        guard s.hasPrefix("/"), let e = s.dropFirst().lastIndex(of: "/"), e > s.index(after: s.startIndex) else { return nil }
        return (String(s[s.index(after: s.startIndex)..<e]), String(s[s.index(after: e)...]).trimmingCharacters(in: .whitespaces))
    }
}
