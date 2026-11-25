// Schul-Befehle der Suche: Chemie, Wahrheitstabelle, Zahlensysteme, Diagrammdaten, Ablaufpläne, Würfel. Reine Logik → testbar.
import Foundation

enum SchoolLogic {
    // MARK: Chemie
    static let elements: [(s: String, name: String, m: Double)] = {
        let raw = "H Wasserstoff 1.008,He Helium 4.0026,Li Lithium 6.94,Be Beryllium 9.0122,B Bor 10.81,C Kohlenstoff 12.011,N Stickstoff 14.007,O Sauerstoff 15.999,F Fluor 18.998,Ne Neon 20.180,Na Natrium 22.990,Mg Magnesium 24.305,Al Aluminium 26.982,Si Silicium 28.085,P Phosphor 30.974,S Schwefel 32.06,Cl Chlor 35.45,Ar Argon 39.95,K Kalium 39.098,Ca Calcium 40.078,Sc Scandium 44.956,Ti Titan 47.867,V Vanadium 50.942,Cr Chrom 51.996,Mn Mangan 54.938,Fe Eisen 55.845,Co Cobalt 58.933,Ni Nickel 58.693,Cu Kupfer 63.546,Zn Zink 65.38,Ga Gallium 69.723,Ge Germanium 72.630,As Arsen 74.922,Se Selen 78.971,Br Brom 79.904,Kr Krypton 83.798,Rb Rubidium 85.468,Sr Strontium 87.62,Y Yttrium 88.906,Zr Zirconium 91.224,Nb Niob 92.906,Mo Molybdän 95.95,Tc Technetium 98,Ru Ruthenium 101.07,Rh Rhodium 102.91,Pd Palladium 106.42,Ag Silber 107.87,Cd Cadmium 112.41,In Indium 114.82,Sn Zinn 118.71,Sb Antimon 121.76,Te Tellur 127.60,I Iod 126.90,Xe Xenon 131.29,Cs Caesium 132.91,Ba Barium 137.33,La Lanthan 138.91,Ce Cer 140.12,Pr Praseodym 140.91,Nd Neodym 144.24,Pm Promethium 145,Sm Samarium 150.36,Eu Europium 151.96,Gd Gadolinium 157.25,Tb Terbium 158.93,Dy Dysprosium 162.50,Ho Holmium 164.93,Er Erbium 167.26,Tm Thulium 168.93,Yb Ytterbium 173.05,Lu Lutetium 174.97,Hf Hafnium 178.49,Ta Tantal 180.95,W Wolfram 183.84,Re Rhenium 186.21,Os Osmium 190.23,Ir Iridium 192.22,Pt Platin 195.08,Au Gold 196.97,Hg Quecksilber 200.59,Tl Thallium 204.38,Pb Blei 207.2,Bi Bismut 208.98,Po Polonium 209,At Astat 210,Rn Radon 222,Fr Francium 223,Ra Radium 226,Ac Actinium 227,Th Thorium 232.04,Pa Protactinium 231.04,U Uran 238.03,Np Neptunium 237,Pu Plutonium 244"
        return raw.split(separator: ",").map { let p = $0.split(separator: " "); return (String(p[0]), String(p[1]), Double(p[2])!) }
    }()
    // „Ca(OH)2“ → Teilchen je Element
    static func formula(_ t: String) -> [(String, Int)]? {
        let c = Array(t.trimmingCharacters(in: .whitespaces).map { x -> Character in let sub: [Character: Character] = ["₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9"]; return sub[x] ?? x })
        var i = 0
        func number() -> Int? { var s = ""; while i < c.count, c[i].isASCII, c[i].isNumber { s.append(c[i]); i += 1 }; return s.isEmpty ? 1 : Int(s).flatMap { (1...9999).contains($0) ? $0 : nil } }
        func group(_ depth: Int) -> [String: Int]? {
            var out: [String: Int] = [:]
            while i < c.count, c[i] != ")" {
                var part: [String: Int] = [:]
                if c[i] == "(" {
                    i += 1
                    guard depth < 5, let g = group(depth + 1), i < c.count, c[i] == ")" else { return nil }
                    i += 1
                    part = g
                } else {
                    guard c[i].isUppercase else { return nil }
                    var s = String(c[i])
                    i += 1
                    if i < c.count, c[i].isLowercase { s.append(c[i]); i += 1 }
                    guard elements.contains(where: { $0.s == s }) else { return nil }
                    part = [s: 1]
                }
                guard let n = number() else { return nil }
                for (k, v) in part { out[k, default: 0] += v * n }
            }
            return out
        }
        guard c.count < 60, let g = group(0), i == c.count, !g.isEmpty else { return nil }
        return elements.compactMap { e in g[e.s].map { (e.s, $0) } }
    }
    static func molarMass(_ t: String) -> Double? { formula(t)?.reduce(0) { s, p in s + elements.first { $0.s == p.0 }!.m * Double(p.1) } }
    static func pretty(_ t: String) -> String { // H2O → H₂O
        var out = "", prev: Character = " "
        for ch in t { out.append(ch.isNumber && (prev.isLetter || prev == ")" || "₀₁₂₃₄₅₆₇₈₉".contains(prev)) ? Array("₀₁₂₃₄₅₆₇₈₉")[ch.wholeNumberValue ?? 0] : ch); prev = out.last! }
        return out
    }

    // MARK: Wahrheitstabelle
    indirect enum Bool3 { case v(String), not(Bool3), and(Bool3, Bool3), or(Bool3, Bool3), xor(Bool3, Bool3), imp(Bool3, Bool3), eq(Bool3, Bool3), const(Bool) }
    static func truth(_ s: String) -> (vars: [String], rows: [[Bool]])? {
        var t = " " + s.lowercased() + " "
        for (a, b) in [("<->", "="), ("<=>", "="), ("⇔", "="), ("->", ">"), ("=>", ">"), ("⇒", ">"), ("→", ">"), ("&&", "&"), ("||", "|"), ("∧", "&"), ("∨", "|"), ("¬", "!"), ("~", "!"), ("*", "&"), ("+", "|"), ("⊕", "^")] { t = t.replacingOccurrences(of: a, with: b) }
        for (a, b) in [("und", "&"), ("and", "&"), ("oder", "|"), ("or", "|"), ("xor", "^"), ("nicht", "!"), ("not", "!"), ("nand", "n"), ("nor", "m")] where a != "nand" && a != "nor" {
            t = t.replacingOccurrences(of: "\\b\(a)\\b", with: b, options: .regularExpression)
        }
        let c = Array(t.filter { !$0.isWhitespace })
        guard !c.isEmpty, c.count < 200 else { return nil }
        var i = 0, names: Set<String> = [], depth = 0
        func bin(_ level: Int) -> Bool3? {
            if level == 5 { return unary() }
            guard var a = bin(level + 1) else { return nil }
            let op = Array("=>|^&")[level]
            while i < c.count, c[i] == op {
                i += 1
                guard let b = bin(level + 1) else { return nil }
                switch op { case "=": a = .eq(a, b); case ">": a = .imp(a, b); case "|": a = .or(a, b); case "^": a = .xor(a, b); default: a = .and(a, b) }
            }
            return a
        }
        func unary() -> Bool3? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 50, i < c.count else { return nil }
            if c[i] == "!" { i += 1; return unary().map { .not($0) } }
            if c[i] == "(" { i += 1; guard let x = bin(0), i < c.count, c[i] == ")" else { return nil }; i += 1; return x }
            if c[i] == "0" || c[i] == "1" { i += 1; return .const(c[i - 1] == "1") }
            var n = ""
            while i < c.count, c[i].isLetter || !n.isEmpty && c[i].isNumber { n.append(c[i]); i += 1 }
            guard !n.isEmpty else { return nil }
            names.insert(n)
            return .v(n)
        }
        guard let e = bin(0), i == c.count, (1...6).contains(names.count) else { return nil }
        let vars = names.sorted()
        func run(_ x: Bool3, _ m: [String: Bool]) -> Bool {
            switch x {
            case .v(let n): return m[n]!
            case .const(let b): return b
            case .not(let a): return !run(a, m)
            case .and(let a, let b): return run(a, m) && run(b, m)
            case .or(let a, let b): return run(a, m) || run(b, m)
            case .xor(let a, let b): return run(a, m) != run(b, m)
            case .imp(let a, let b): return !run(a, m) || run(b, m)
            case .eq(let a, let b): return run(a, m) == run(b, m)
            }
        }
        return (vars, (0..<(1 << vars.count)).map { k in
            let vals = vars.indices.map { k >> (vars.count - 1 - $0) & 1 == 1 }
            return vals + [run(e, Dictionary(uniqueKeysWithValues: zip(vars, vals)))]
        })
    }

    // MARK: Zahlensysteme
    static func bases(_ s: String) -> (dec: String, bin: String, hex: String, oct: String)? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        let neg = t.hasPrefix("-"), u = neg ? String(t.dropFirst()) : t
        let v: UInt64?
        if u.hasPrefix("0x") { v = UInt64(u.dropFirst(2), radix: 16) } else if u.hasPrefix("0b") { v = UInt64(u.dropFirst(2), radix: 2) } else if u.hasPrefix("0o") { v = UInt64(u.dropFirst(2), radix: 8) }
        else if u.hasPrefix("#") { v = UInt64(u.dropFirst(), radix: 16) } else { v = UInt64(u) ?? (u.contains(where: { "abcdef".contains($0) }) ? UInt64(u, radix: 16) : nil) }
        guard let v, !u.hasPrefix("+") else { return nil }
        let m = neg ? "-" : "", b = String(v, radix: 2)
        let padded = String(repeating: "0", count: (4 - b.count % 4) % 4) + b
        let grouped = stride(from: 0, to: padded.count, by: 4).map { String(Array(padded)[$0..<($0 + 4)]) }.joined(separator: " ")
        return (m + String(v), m + grouped, m + "0x" + String(v, radix: 16).uppercased(), m + "0o" + String(v, radix: 8))
    }

    // MARK: Diagramm: „Mo 3, Di 5,5“, „3 5 8“ oder „Mathe: 2; Deutsch: 1,7“
    static func chart(_ s: String) -> [(String, Double)]? {
        func cut(_ sep: String) -> [String] { s.replacingOccurrences(of: sep, with: "\u{1}", options: .regularExpression).split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        // „1,7, 2“: Komma direkt vor einer Ziffer ist das Dezimalkomma
        var parts = s.contains(";") ? cut(";") : s.contains("\n") ? cut("\n") : cut(",(?!\\d)")
        if parts.count == 1 {
            let w = s.split(separator: " ").map(String.init)
            parts = w.count > 1 && w.allSatisfy { Double($0.replacingOccurrences(of: ",", with: ".")) != nil } ? w : cut(",")
        }
        let out = parts.enumerated().compactMap { i, p -> (String, Double)? in
            let w = p.replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "=", with: " ").split(separator: " ").map(String.init)
            guard let l = w.last, let v = Double(l.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")), v.isFinite, abs(v) < 1e12 else { return nil }
            let name = w.dropLast().joined(separator: " ")
            return (name.isEmpty ? "\(i + 1)" : name, v)
        }
        return out.count == parts.count && (2...40).contains(out.count) ? out : nil
    }

    // MARK: Ablaufplan: „Start -> Prüfen?; Prüfen? -ja-> Fertig; Prüfen? -nein-> Start“
    struct Flow: Equatable { var nodes: [String]; var edges: [Edge]; struct Edge: Equatable { let a: Int, b: Int, label: String } }
    static func flow(_ s: String) -> Flow? {
        var f = Flow(nodes: [], edges: [])
        func id(_ n: String) -> Int { if let i = f.nodes.firstIndex(of: n) { return i }; f.nodes.append(n); return f.nodes.count - 1 }
        let re = try! NSRegularExpression(pattern: #"\s*(?:-([^-<>;\n]+)->|->|→)\s*"#)
        for line in s.split(whereSeparator: { $0 == ";" || $0 == "\n" }).map(String.init) {
            var last: Int?, label = "", pos = line.startIndex
            func node(_ t: Substring) -> Bool {
                let n = t.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return false }
                let k = id(n)
                if let l = last { f.edges.append(.init(a: l, b: k, label: label)) }
                last = k
                return true
            }
            for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let r = Range(m.range, in: line)!
                guard node(line[pos..<r.lowerBound]) else { return nil }
                label = Range(m.range(at: 1), in: line).map { line[$0].trimmingCharacters(in: .whitespaces) } ?? ""
                pos = r.upperBound
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, !node(line[pos...]), last != nil { return nil }
        }
        return f.edges.isEmpty || f.nodes.count > 40 ? nil : f
    }
    // Ebenen von oben nach unten (Rückwärtskanten ignorieren)
    static func levels(_ f: Flow) -> [Int] {
        var l = [Int](repeating: 0, count: f.nodes.count), seen = Set<Int>(), path = Set<Int>(), back = Set<Int>()
        func dfs(_ n: Int) { seen.insert(n); path.insert(n); for (k, e) in f.edges.enumerated() where e.a == n { if path.contains(e.b) { back.insert(k) } else if !seen.contains(e.b) { dfs(e.b) } }; path.remove(n) }
        for n in f.nodes.indices where !seen.contains(n) { dfs(n) }
        for _ in f.nodes { for (k, e) in f.edges.enumerated() where !back.contains(k) { l[e.b] = max(l[e.b], l[e.a] + 1) } }
        return l
    }

    // MARK: Würfel „2d6“, „3“, „d20“
    static func dice(_ s: String) -> (n: Int, sides: Int)? {
        let t = s.lowercased().replacingOccurrences(of: "w", with: "d").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return (1, 6) }
        let p = t.split(separator: "d", omittingEmptySubsequences: false).map(String.init)
        if p.count == 1 { return Int(p[0]).flatMap { (1...10).contains($0) ? ($0, 6) : nil } }
        guard p.count == 2, let n = p[0].isEmpty ? 1 : Int(p[0]), let d = Int(p[1]), (1...10).contains(n), (2...1000).contains(d) else { return nil }
        return (n, d)
    }
}
