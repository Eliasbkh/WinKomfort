// Formeln verstehen („(-b+-sqrt(b^2-4ac))/(2a)“ oder LaTeX) und als MathML, LaTeX, UnicodeMath ausgeben, rechnen, ableiten. Reine Logik → testbar.
import Foundation

indirect enum MathNode: Equatable {
    case num(String), id(String), op(String), text(String)
    case row([MathNode])                       // mit Operatoren dazwischen, z. B. a + b = c
    case mul([MathNode])                       // Produkt; Zeichen aus `dot`
    case frac(MathNode, MathNode)
    case script(MathNode, sub: MathNode?, sup: MathNode?)
    case sqrt(MathNode), root(MathNode, MathNode)
    case fn(String, MathNode)                  // sin(x)
    case paren(String, MathNode, String)
    case matrix([[MathNode]])
    case accent(String, MathNode)              // vec, bar, hat
    case neg(MathNode), fact(MathNode)
}

enum MathExpr {
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "arcsin", "arccos", "arctan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "ln", "log", "lg", "exp", "lim", "max", "min", "det", "gcd", "ggt", "kgv", "sgn"]
    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "oo": "∞", "inf": "∞", "infty": "∞", "unendlich": "∞",
        "RR": "ℝ", "NN": "ℕ", "ZZ": "ℤ", "QQ": "ℚ", "CC": "ℂ", "hbar": "ℏ", "partial": "∂", "nabla": "∇", "emptyset": "∅", "dots": "…", "ldots": "…", "cdots": "⋯", "degree": "°",
    ]
    static let big = ["sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮"]
    static let wordOps = ["cdot": "⋅", "times": "×", "in": "∈", "notin": "∉", "subset": "⊂", "cup": "∪", "cap": "∩", "and": "∧", "or": "∨", "wedge": "∧", "vee": "∨", "neg": "¬", "forall": "∀", "exists": "∃", "to": "→", "rightarrow": "→", "Rightarrow": "⇒", "Leftrightarrow": "⇔", "leftarrow": "←", "mapsto": "↦",
                           "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "pm": "±", "mp": "∓", "perp": "⊥", "parallel": "∥", "propto": "∝", "div": "÷", "setminus": "∖"]
    private static let charOps: [(String, String)] = [("<=>", "⇔"), ("<->", "⇔"), ("->", "→"), ("=>", "⇒"), ("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("~=", "≈"), ("+-", "±"), ("-+", "∓"), ("==", "≡"), ("=", "="), ("<", "<"), (">", ">"),
                                                      ("≤", "≤"), ("≥", "≥"), ("≠", "≠"), ("≈", "≈"), ("±", "±"), ("→", "→"), ("⇒", "⇒"), ("⇔", "⇔"), ("∈", "∈"), ("∧", "∧"), ("∨", "∨"), (",", ","), (";", ";"), (":", ":")]
    private static let sums: Set<String> = ["+", "−", "±", "∓", "∪", "∩", "∧", "∨", "∖"]

    // MARK: Lesen
    private enum Tok: Equatable { case num(String), word(String), cmd(String), sym(String) }
    private static func lex(_ s: String) -> [Tok]? {
        var out: [Tok] = [], c = Array(s), i = 0
        if c.count > 600 { return nil }
        c = Array(String(c).replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "·", with: "*").replacingOccurrences(of: "\\left", with: "").replacingOccurrences(of: "\\right", with: ""))
        let sup: [Character: String] = ["²": "2", "³": "3", "⁴": "4"]
        var lists: [Bool] = [] // offene Klammern; true = Komma trennt (Matrix, root(…), frac(…))
        outer: while i < c.count {
            let ch = c[i]
            if "([{".contains(ch) { lists.append(ch == "[" || ch == "(" && (out.last == .word("root") || out.last == .word("frac"))) } else if ")]}".contains(ch), !lists.isEmpty { lists.removeLast() }
            if ch.isWhitespace || ch == "$" { i += 1; continue }
            if let d = sup[ch] { out += [.sym("^"), .num(d)]; i += 1; continue }
            if ch.isASCII, ch.isNumber {
                var j = i, dot = false
                while j < c.count, c[j].isASCII && c[j].isNumber || !dot && (c[j] == "." || c[j] == "," && lists.last != true) && j + 1 < c.count && c[j + 1].isNumber { if !c[j].isNumber { dot = true }; j += 1 }
                out.append(.num(String(c[i..<j]).replacingOccurrences(of: ",", with: ".")))
                i = j
                continue
            }
            if ch == "\\" {
                var j = i + 1
                while j < c.count, c[j].isASCII, c[j].isLetter { j += 1 }
                if j == i + 1 { if j < c.count, c[j] == "\\" { out.append(.sym("\\\\")); i += 2 } else { i += 2; if j < c.count, "{}".contains(c[j]) { out.append(.sym(c[j] == "{" ? "\\{" : "\\}")) } }; continue }
                out.append(.cmd(String(c[i + 1..<j])))
                i = j
                continue
            }
            if ch == "\"" {
                var j = i + 1
                while j < c.count, c[j] != "\"" { j += 1 }
                out.append(.cmd("\"" + String(c[i + 1..<j])))
                i = min(j + 1, c.count)
                continue
            }
            if ch.isLetter, ch.isASCII {
                var j = i
                while j < c.count, c[j].isASCII, c[j].isLetter { j += 1 }
                var w = String(c[i..<j])
                while !w.isEmpty { // bekanntes Wort, sonst einzelne Buchstaben (abc = a·b·c)
                    if known(w) { out.append(.word(w)); break }
                    out.append(.word(String(w.removeFirst())))
                }
                i = j
                continue
            }
            for (a, b) in charOps where a.count <= c.count - i && String(c[i..<(i + a.count)]) == a { out.append(.sym(b)); i += a.count; continue outer }
            out.append(.sym(ch == "-" ? "−" : String(ch)))
            i += 1
        }
        return out
    }
    private static func known(_ w: String) -> Bool {
        functions.contains(w) || symbols[w] != nil || big[w] != nil || ["sqrt", "root", "cbrt", "abs", "frac", "vec", "bar", "hat", "dot", "in", "to", "and", "or"].contains(w) || w.count == 1
    }

    static func parse(_ s: String) -> MathNode? {
        guard let t = lex(s), !t.isEmpty else { return nil }
        var p = Parser(t: t)
        guard let n = p.list(), p.i == t.count else { return nil }
        return n
    }

    private struct Parser {
        let t: [Tok]
        var i = 0, depth = 0
        var peek: Tok? { i < t.count ? t[i] : nil }
        mutating func eat(_ s: String) -> Bool { if peek == .sym(s) { i += 1; return true }; return false }
        static func relation(_ s: String) -> Bool { ["=", "<", ">", "≤", "≥", "≠", "≈", "≡", "→", "⇒", "⇔", "∈", "∉", "⊂", ",", ";", ":", "←", "↦", "∼", "⊥", "∥", "∝"].contains(s) }
        func opHere() -> String? {
            switch peek {
            case .sym(let s)?: return s
            case .cmd(let w)?: return MathExpr.wordOps[w]
            case .word(let w)? where ["in", "to", "and", "or"].contains(w): return MathExpr.wordOps[w]
            default: return nil
            }
        }
        mutating func list() -> MathNode? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 60 else { return nil }
            guard let a = sum() else { return nil }
            var out = [a]
            while let o = opHere(), Self.relation(o) {
                i += 1
                out.append(.op(o))
                if let b = sum() { out.append(b) } else if peek != nil, !closing { return nil }
            }
            return out.count == 1 ? out[0] : .row(out)
        }
        var closing: Bool { if case .sym(let s)? = peek { return [")", "]", "}", "|", "\\}"].contains(s) }; return false }
        mutating func sum() -> MathNode? {
            var out: [MathNode] = []
            if let o = opHere(), ["+", "−", "±", "∓", "¬", "∀", "∃"].contains(o) {
                i += 1
                guard let p = product() else { return nil }
                out = o == "−" ? [.neg(p)] : [.op(o), p]
            } else { guard let p = product() else { return nil }; out = [p] }
            while let o = opHere(), MathExpr.sums.contains(o) {
                i += 1
                guard let p = product() else { return nil }
                out += [.op(o), p]
            }
            return out.count == 1 ? out[0] : .row(out)
        }
        mutating func product() -> MathNode? {
            guard let a = factor() else { return nil }
            var out = [a]
            while true {
                if let o = opHere(), ["*", "⋅", "×", "÷", "∗"].contains(o) {
                    i += 1
                    guard let b = factor() else { return nil }
                    if o == "÷" { out.append(.op("÷")) } else { out.append(.op(o == "*" || o == "∗" ? "⋅" : o)) }
                    out.append(b)
                } else if eat("/") {
                    guard let b = factor() else { return nil }
                    out[out.count - 1] = .frac(strip(out.last!), strip(b))
                } else if starts { guard let b = factor() else { return nil }; out.append(b) } else { break }
            }
            return out.count == 1 ? out[0] : .mul(out)
        }
        var starts: Bool {
            switch peek {
            case .num?: return true
            case .word(let w)?: return !["in", "to", "and", "or"].contains(w)
            case .cmd(let w)?: return MathExpr.wordOps[w] == nil && !["end"].contains(w)
            case .sym(let s)?: return ["(", "[", "{", "\\{", "∞", "π", "√", "∑", "∫"].contains(s) || s.count == 1 && s.first!.isLetter
            default: return false
            }
        }
        func strip(_ n: MathNode) -> MathNode { if case .paren("(", let x, ")") = n { return x }; return n }
        mutating func factor() -> MathNode? {
            if eat("−") { return factor().map { .neg($0) } }
            if eat("+") { return factor() }
            guard var a = atom() else { return nil }
            while true {
                if eat("!") { a = .fact(a); continue }
                var sub: MathNode?, sup: MathNode?
                while true {
                    if sub == nil, eat("_") { guard let x = scriptArg() else { return nil }; sub = x }
                    else if sup == nil, eat("^") { guard let x = scriptArg() else { return nil }; sup = x }
                    else if sup == nil, eat("'") { sup = .op("′") } else { break }
                }
                if sub == nil, sup == nil { break }
                a = .script(a, sub: sub, sup: sup)
            }
            // sin x, sin^2 x: Funktion nimmt das Nächste als Argument
            if case .id(let f) = base(a), MathExpr.functions.contains(f), !MathExpr.isLim(.id(f)), starts {
                guard let x = factor() else { return nil }
                return .fn2(a, x)
            }
            return a
        }
        func base(_ n: MathNode) -> MathNode { if case .script(let b, _, _) = n { return b }; return n }
        mutating func scriptArg() -> MathNode? {
            if eat("−") { return scriptArg().map { .neg($0) } }
            if eat("+") { return .op("+") }
            if case .num(let n)? = peek { i += 1; return .num(n) }
            if peek == .sym("*") { i += 1; return .op("∗") }
            return atom().map(strip)
        }
        mutating func arg() -> MathNode? { atom().map(strip) }
        mutating func atom() -> MathNode? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 60, let tok = peek else { return nil }
            i += 1
            switch tok {
            case .num(let n): return .num(n)
            case .cmd(let w) where w.hasPrefix("\""): return .text(String(w.dropFirst()))
            case .word(let w): return named(w)
            case .cmd(let w):
                switch w {
                case "frac", "dfrac", "tfrac": return arg().flatMap { a in arg().map { .frac(a, $0) } }
                case "sqrt":
                    if eat("[") { guard let n = list(), eat("]"), let x = arg() else { return nil }; return .root(n, x) }
                    return arg().map { .sqrt($0) }
                case "text", "mathrm", "operatorname":
                    guard eat("{") else { return nil }
                    var s = ""
                    while let k = peek, k != .sym("}") { i += 1; switch k { case .num(let x), .word(let x), .cmd(let x), .sym(let x): s += x } }
                    return eat("}") ? .text(s) : nil
                case "vec", "bar", "overline", "hat", "dot": return arg().map { .accent(w == "overline" ? "bar" : w, $0) }
                case "mathbb": return arg().map { n in if case .id(let x) = n, let m = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ"][x] { return .id(m) }; return n }
                case "quad", "qquad": return .op("\u{2003}")
                case "begin":
                    guard eat("{") else { return nil }
                    while let k = peek, k != .sym("}") { i += 1; _ = k }
                    guard eat("}") else { return nil }
                    var rows: [[MathNode]] = [[]]
                    while let k = peek {
                        if k == .cmd("end") { i += 1; guard eat("{") else { return nil }; while let z = peek, z != .sym("}") { i += 1; _ = z }; return eat("}") ? .matrix(rows) : nil }
                        if eat("&") { continue }
                        if eat("\\\\") { rows.append([]); continue }
                        guard let x = sum() else { return nil }
                        rows[rows.count - 1].append(x)
                    }
                    return nil
                default: return named(w)
                }
            case .sym(let s):
                switch s {
                case "(":
                    guard let x = list(), eat(")") else { return nil }
                    return .paren("(", x, ")")
                case "{", "\\{":
                    guard let x = list(), eat(s == "{" ? "}" : "\\}") else { return nil }
                    return s == "{" ? x : .paren("{", x, "}")
                case "[":
                    if peek == .sym("[") {
                        var rows: [[MathNode]] = []
                        repeat {
                            guard eat("[") else { return nil }
                            var r: [MathNode] = []
                            repeat { guard let x = sum() else { return nil }; r.append(x) } while eat(",")
                            guard eat("]") else { return nil }
                            rows.append(r)
                        } while eat(",")
                        return eat("]") ? .matrix(rows) : nil
                    }
                    guard let x = list(), eat("]") else { return nil }
                    return .paren("[", x, "]")
                case "|":
                    guard let x = list(), eat("|") else { return nil }
                    return .paren("|", x, "|")
                case "√": return arg().map { .sqrt($0) }
                case "∞", "π": return .id(s)
                case "∑", "∫": return .op(s)
                default: return s.count == 1 && s.first!.isLetter ? .id(s) : nil
                }
            }
        }
        mutating func named(_ w: String) -> MathNode? {
            switch w {
            case "sqrt": return arg().map { .sqrt($0) }
            case "cbrt": return arg().map { .root(.num("3"), $0) }
            case "abs": return arg().map { .paren("|", $0, "|") }
            case "vec", "bar", "hat": return arg().map { .accent(w, $0) }
            case "root":
                guard eat("("), let n = sum(), eat(","), let x = sum(), eat(")") else { return nil }
                return .root(n, x)
            case "frac":
                guard eat("("), let n = sum(), eat(","), let x = sum(), eat(")") else { return nil }
                return .frac(n, x)
            default: break
            }
            if let b = MathExpr.big[w] { return .op(b) }
            if let s = MathExpr.symbols[w] { return .id(s) }
            if let o = MathExpr.wordOps[w] { return .op(o) }
            return .id(w)
        }
    }

    // MARK: Ausgeben
    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    private static func num(_ s: String) -> String { s.replacingOccurrences(of: ".", with: ",") }
    private static func isBig(_ n: MathNode) -> String? { if case .op(let o) = n, ["∑", "∏", "∫", "∬", "∮"].contains(o) { return o }; return nil }
    fileprivate static func isLim(_ n: MathNode) -> Bool { [.id("lim"), .id("max"), .id("min")].contains(n) }

    static func mathML(_ n: MathNode) -> String {
        func m(_ x: MathNode) -> String { mathML(x) }
        func r(_ x: MathNode) -> String { "<mrow>" + m(x) + "</mrow>" }
        switch n {
        case .num(let s): return "<mn>\(num(s))</mn>"
        case .id(let s): return functions.contains(s) ? "<mi>\(s)</mi>" : s.count > 1 ? "<mtext>\(esc(s))</mtext>" : "<mi>\(esc(s))</mi>"
        case .op(let s): return "<mo>\(esc(s))</mo>"
        case .text(let s): return "<mtext>\(esc(s))</mtext>"
        case .row(let a): return a.map(m).joined()
        case .mul(let a):
            var out = ""
            for (k, x) in a.enumerated() {
                if k > 0, case .num = x, case .num = a[k - 1] { out += "<mo>⋅</mo>" }
                out += m(x)
            }
            return out
        case .frac(let a, let b): return "<mfrac>\(r(a))\(r(b))</mfrac>"
        case .script(let b, let sub, let sup):
            if case .fn(let f, let x) = b, sub == nil, let p = sup { return "<msup><mi>\(f)</mi>\(r(p))</msup><mo>&#x2061;</mo>" + m(x) }
            let under = isBig(b).map { !"∫∬∮".contains($0) } ?? isLim(b)
            switch (sub, sup) {
            case (let s?, let p?): return under ? "<munderover>\(r(b))\(r(s))\(r(p))</munderover>" : "<msubsup>\(r(b))\(r(s))\(r(p))</msubsup>"
            case (let s?, nil): return under ? "<munder>\(r(b))\(r(s))</munder>" : "<msub>\(r(b))\(r(s))</msub>"
            case (nil, let p?): return "<msup>\(r(b))\(r(p))</msup>"
            default: return m(b)
            }
        case .sqrt(let x): return "<msqrt>\(m(x))</msqrt>"
        case .root(let n, let x): return "<mroot>\(r(x))\(r(n))</mroot>"
        case .fn(let f, let x): return "<mi>\(f)</mi><mo>&#x2061;</mo>" + m(x)
        case .paren(let a, let x, let b): return "<mrow><mo stretchy=\"true\">\(a)</mo>\(m(x))<mo stretchy=\"true\">\(b)</mo></mrow>"
        case .matrix(let rows): return "<mrow><mo stretchy=\"true\">(</mo><mtable>" + rows.map { "<mtr>" + $0.map { "<mtd>\(m($0))</mtd>" }.joined() + "</mtr>" }.joined() + "</mtable><mo stretchy=\"true\">)</mo></mrow>"
        case .accent(let k, let x): return "<mover accent=\"true\">\(r(x))<mo>\(["vec": "→", "bar": "¯", "hat": "^", "dot": "˙"][k] ?? "¯")</mo></mover>"
        case .neg(let x): return "<mrow><mo>−</mo>\(m(x))</mrow>"
        case .fact(let x): return m(x) + "<mo>!</mo>"
        }
    }
    static func document(_ n: MathNode) -> String { "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\"><mrow>" + mathML(n) + "</mrow></math>" }

    static func latex(_ n: MathNode) -> String {
        func l(_ x: MathNode) -> String { latex(x) }
        let rev = Dictionary(symbols.map { ($0.value, "\\" + ($0.key == "oo" || $0.key == "inf" || $0.key == "unendlich" ? "infty" : $0.key)) }) { a, b in a.count > b.count ? a : b }
        switch n {
        case .num(let s): return s.replacingOccurrences(of: ".", with: "{,}")
        case .id(let s): return functions.contains(s) ? "\\" + (["asin": "arcsin", "acos": "arccos", "atan": "arctan"][s] ?? s) : ["ℝ": "\\mathbb{R}", "ℕ": "\\mathbb{N}", "ℤ": "\\mathbb{Z}", "ℚ": "\\mathbb{Q}", "ℂ": "\\mathbb{C}"][s] ?? rev[s] ?? s
        case .op(let s):
            let map = ["⋅": "\\cdot ", "±": "\\pm ", "∓": "\\mp ", "≤": "\\le ", "≥": "\\ge ", "≠": "\\ne ", "≈": "\\approx ", "→": "\\to ", "⇒": "\\Rightarrow ", "⇔": "\\Leftrightarrow ", "∈": "\\in ", "∑": "\\sum ", "∏": "\\prod ", "∫": "\\int ", "−": "-", "×": "\\times ", "∧": "\\wedge ", "∨": "\\vee ", "¬": "\\neg ", "′": "'", "∗": "*", "≡": "\\equiv "]
            return map[s] ?? s
        case .text(let s): return "\\text{\(s)}"
        case .row(let a): return a.map(l).joined(separator: " ")
        case .mul(let a):
            var o = ""
            for (k, x) in a.enumerated() { if k > 0, case .num = x, case .num = a[k - 1] { o += "\\cdot " } else if k > 0, o.last?.isLetter == true { o += " " }; o += l(x) }
            return o
        case .frac(let a, let b): return "\\frac{\(l(a))}{\(l(b))}"
        case .script(let b, let sub, let sup):
            if case .fn(let f, let x) = b, sub == nil, let p = sup { return "\\\(f)^{\(l(p))} " + l(x) }
            let base = l(b).trimmingCharacters(in: .whitespaces)
            return base + (sub.map { "_{\(l($0))}" } ?? "") + (sup.map { $0 == .op("′") ? "'" : "^{\(l($0))}" } ?? "")
        case .sqrt(let x): return "\\sqrt{\(l(x))}"
        case .root(let k, let x): return "\\sqrt[\(l(k))]{\(l(x))}"
        case .fn(let f, let x): return "\\\(f) " + l(x)
        case .paren(let a, let x, let b): return "\\left\(a == "{" ? "\\{" : a)\(l(x))\\right\(b == "}" ? "\\}" : b)"
        case .matrix(let rows): return "\\begin{pmatrix}" + rows.map { $0.map(l).joined(separator: " & ") }.joined(separator: " \\\\ ") + "\\end{pmatrix}"
        case .accent(let k, let x): return "\\\(k){\(l(x))}"
        case .neg(let x): return "-" + l(x)
        case .fact(let x): return l(x) + "!"
        }
    }

    // UnicodeMath: genau das, was man in OneNote/Word unter „Einfügen › Formel“ eintippt
    static func unicode(_ n: MathNode) -> String {
        func u(_ x: MathNode) -> String { unicode(x) }
        func g(_ x: MathNode) -> String {
            switch x { case .num, .id, .paren: return u(x); default: return "(" + u(x) + ")" }
        }
        switch n {
        case .num(let s): return num(s)
        case .id(let s), .op(let s): return s
        case .text(let s): return "\"\(s)\""
        case .row(let a): return a.map(u).joined()
        case .mul(let a):
            var o = ""
            for (k, x) in a.enumerated() { if k > 0, case .num = x, case .num = a[k - 1] { o += "⋅" }; o += u(x) }
            return o
        case .frac(let a, let b): return g(a) + "/" + g(b)
        case .script(.fn(let f, let x), nil, let p?): return f + "^" + g(p) + "\u{2061}" + g(x)
        case .script(let b, let sub, let sup): return u(b) + (sub.map { "_" + g($0) } ?? "") + (sup.map { $0 == .op("′") ? "′" : "^" + g($0) } ?? "") + (isBig(b) != nil ? "▒" : "")
        case .sqrt(let x): return "√(" + u(x) + ")"
        case .root(let k, let x): return "√(" + u(k) + "&" + u(x) + ")"
        case .fn(let f, let x): return f + "\u{2061}" + g(x)
        case .paren(let a, let x, let b): return a + u(x) + b
        case .matrix(let rows): return "(■(" + rows.map { $0.map(u).joined(separator: "&") }.joined(separator: "@") + "))"
        case .accent(let k, let x): return g(x) + (["vec": "\u{20D7}", "bar": "\u{0305}", "hat": "\u{0302}", "dot": "\u{0307}"][k] ?? "")
        case .neg(let x): return "−" + u(x)
        case .fact(let x): return u(x) + "!"
        }
    }

    // MARK: Rechnen
    static func eval(_ n: MathNode, _ v: [String: Double] = [:]) -> Double? {
        func e(_ x: MathNode) -> Double? { eval(x, v) }
        switch n {
        case .num(let s): return Double(s)
        case .id(let s): return v[s] ?? (s == "π" ? .pi : s == "e" ? M_E : s == "∞" ? .infinity : nil)
        case .neg(let x): return e(x).map { -$0 }
        case .paren(let a, let x, _): return e(x).map { a == "|" ? abs($0) : $0 }
        case .frac(let a, let b): return e(a).flatMap { x in e(b).flatMap { $0 == 0 ? nil : x / $0 } }
        case .sqrt(let x): return e(x).flatMap { $0 < 0 ? nil : $0.squareRoot() }
        case .root(let k, let x):
            guard let k = e(k), let x = e(x), k != 0 else { return nil }
            return x < 0 ? (k.truncatingRemainder(dividingBy: 2) == 0 ? nil : -pow(-x, 1 / k)) : pow(x, 1 / k)
        case .fact(let x):
            guard let k = e(x), k >= 0, k <= 170, k == k.rounded() else { return nil }
            return tgamma(k + 1).rounded()
        case .script(let b, let sub, let sup):
            if case .id(let s) = b, let sub { let name = s + "_" + unicode(sub); if let x = v[name] { return sup.map { e($0).map { pow(x, $0) } } ?? x } }
            guard sub == nil, let p = sup, let x = e(b), let k = e(p) else { return nil }
            let r = pow(x, k)
            return r.isNaN ? nil : r
        case .fn(let f, let x): return e(x).flatMap { call(f, $0) }
        case .row(let a):
            guard var s = a.first.flatMap({ $0 == .op("+") ? 0 : e($0) }) else { return nil }
            var i = a.first == .op("+") ? 0 : 1
            while i + 1 < a.count {
                guard case .op(let o) = a[i], let x = e(a[i + 1]) else { return nil }
                switch o { case "+": s += x; case "−": s -= x; default: return nil }
                i += 2
            }
            return i == a.count ? s : nil
        case .mul(let a): return product(a, v)
        default: return nil
        }
    }
    static func call(_ f: String, _ x: Double) -> Double? {
        let r: Double
        switch f {
        case "sin": r = sin(x); case "cos": r = cos(x); case "tan": r = tan(x); case "cot": r = 1 / tan(x)
        case "arcsin", "asin": r = asin(x); case "arccos", "acos": r = acos(x); case "arctan", "atan": r = atan(x)
        case "sinh": r = sinh(x); case "cosh": r = cosh(x); case "tanh": r = tanh(x)
        case "ln": r = log(x); case "log", "lg": r = log10(x); case "exp": r = exp(x); case "sgn": r = x > 0 ? 1 : x < 0 ? -1 : 0
        default: return nil
        }
        return r.isNaN ? nil : r
    }
    private static func product(_ a: [MathNode], _ v: [String: Double]) -> Double? {
        // ∑, ∏, ∫ wirken auf alles rechts davon
        if let k = a.firstIndex(where: { if case .script(let b, _, _) = $0 { return isBig(b) != nil }; return false }), case .script(let b, let sub?, let sup?) = a[k], let o = isBig(b) {
            guard let before = k == 0 ? 1 : product(Array(a[..<k]), v), let hi = eval(sup, v) else { return nil }
            var body = Array(a[(k + 1)...])
            guard !body.isEmpty else { return nil }
            if o == "∫" {
                guard let lo = eval(sub, v), lo.isFinite, hi.isFinite, body.count >= 2, case .id(let x) = body.last!, body[body.count - 2] == .id("d") else { return nil }
                body.removeLast(2)
                let n = 2000, h = (hi - lo) / Double(n)
                var s = 0.0
                for i in 0...n {
                    var vv = v
                    vv[x] = lo + Double(i) * h
                    guard let y = body.isEmpty ? 1 : product(body, vv), y.isFinite else { return nil }
                    s += y * (i == 0 || i == n ? 1 : i % 2 == 1 ? 4 : 2)
                }
                return before * s * h / 3
            }
            guard case .row(let r) = sub, r.count == 3, case .id(let x) = r[0], r[1] == .op("="), let lo = eval(r[2], v), hi.isFinite, hi - lo < 100_000, lo == lo.rounded() else { return nil }
            var s = o == "∑" ? 0.0 : 1.0
            var i = lo
            while i <= hi {
                var vv = v
                vv[x] = i
                guard let y = product(body, vv) else { return nil }
                s = o == "∑" ? s + y : s * y
                i += 1
            }
            return before * s
        }
        var r = 1.0, div = false
        for x in a {
            if x == .op("⋅") || x == .op("×") { continue }
            if x == .op("÷") { div = true; continue }
            guard let y = eval(x, v) else { return nil }
            if div { if y == 0 { return nil }; r /= y; div = false } else { r *= y }
        }
        return r
    }
    static func variables(_ n: MathNode) -> Set<String> {
        switch n {
        case .id(let s): return s == "π" || s == "e" || s == "∞" || functions.contains(s) ? [] : [s]
        case .row(let a), .mul(let a): return a.reduce(into: []) { $0.formUnion(variables($1)) }
        case .frac(let a, let b), .root(let a, let b): return variables(a).union(variables(b))
        case .script(let b, let s, let p): return variables(b).union(s.map(variables) ?? []).union(p.map(variables) ?? [])
        case .sqrt(let x), .fn(_, let x), .paren(_, let x, _), .accent(_, let x), .neg(let x), .fact(let x): return variables(x)
        case .matrix(let r): return r.flatMap { $0 }.reduce(into: []) { $0.formUnion(variables($1)) }
        default: return []
        }
    }
    // Gleichung → linke minus rechte Seite
    static func sides(_ n: MathNode) -> (MathNode, MathNode)? {
        if case .row(let a) = n, let k = a.firstIndex(of: .op("=")), !a[(k + 1)...].contains(.op("=")), k > 0, k + 1 < a.count {
            func j(_ x: [MathNode]) -> MathNode { x.count == 1 ? x[0] : .row(x) }
            return (j(Array(a[..<k])), j(Array(a[(k + 1)...])))
        }
        return nil
    }
    // Reelle Nullstellen numerisch in −100…100 (Vorzeichenwechsel und Berührstellen)
    static func roots(_ f: (Double) -> Double?) -> [Double] {
        var out: [Double] = []
        func add(_ x: Double) {
            let r = (x * 1e8).rounded() / 1e8, nice = abs(r - r.rounded()) < 1e-6 ? r.rounded() : r
            if out.count < 24, !out.contains(where: { abs($0 - nice) < 1e-5 }) { out.append(nice == 0 ? 0 : nice) }
        }
        let n = 8000
        var px: Double?, py = 0.0, pp: (Double, Double)?
        for i in 0...n {
            let x = -100 + 200 * Double(i) / Double(n) + 1e-9
            guard let y = f(x), y.isFinite else { px = nil; pp = nil; continue }
            if y == 0 { add(x) }
            if let a = px, py * y < 0 {
                var lo = a, hi = x, fl = py, ok = true
                for _ in 0..<80 {
                    let m = (lo + hi) / 2
                    guard let fm = f(m), fm.isFinite else { ok = false; break }
                    if fl * fm <= 0 { hi = m } else { lo = m; fl = fm }
                }
                if ok, let z = f((lo + hi) / 2), abs(z) < max(1e-4, min(abs(py), abs(y))) { add((lo + hi) / 2) } // Polstelle ist keine Nullstelle
            } else if let a = px, let q = pp, abs(py) < abs(q.1), abs(py) < abs(y), abs(py) < 0.05 {
                var lo = q.0, hi = x
                for _ in 0..<100 { let a1 = lo + (hi - lo) / 3, b1 = hi - (hi - lo) / 3; if abs(f(a1) ?? 9) < abs(f(b1) ?? 9) { hi = b1 } else { lo = a1 } }
                if abs(f((lo + hi) / 2) ?? 1) < 1e-9 { add((lo + hi) / 2) }
                _ = a
            }
            if let a = px { pp = (a, py) }
            px = x
            py = y
        }
        return out.sorted()
    }

    // MARK: Ableiten
    static func diff(_ n: MathNode, _ x: String) -> MathNode? { raw(n, x).map(simplify) }
    private static func raw(_ n: MathNode, _ x: String) -> MathNode? {
        if !variables(n).contains(x) { return .num("0") }
        switch n {
        case .id: return .num("1")
        case .neg(let a): return raw(a, x).map { .neg($0) }
        case .paren("(", let a, _): return raw(a, x)
        case .row(let a):
            var out: [MathNode] = []
            for t in a { if case .op(let o) = t { guard o == "+" || o == "−" else { return nil }; out.append(t) } else { guard let d = raw(t, x) else { return nil }; out.append(d) } }
            return .row(out)
        case .mul(let a):
            let f = a.filter { $0 != .op("⋅") && $0 != .op("×") }
            guard !f.contains(where: { if case .op = $0 { return true }; if case .script(let b, _, _) = $0 { return isBig(b) != nil }; return false }) else { return nil }
            var terms: [MathNode] = []
            for k in f.indices where variables(f[k]).contains(x) {
                guard let d = raw(f[k], x) else { return nil }
                var t = f
                t[k] = d
                terms += terms.isEmpty ? [.mul(t)] : [.op("+"), .mul(t)]
            }
            return terms.count == 1 ? terms[0] : .row(terms)
        case .frac(let a, let b):
            if !variables(b).contains(x) { return raw(a, x).map { .frac($0, b) } }
            guard let da = raw(a, x), let db = raw(b, x) else { return nil }
            return .frac(.row([.mul([da, wrap(b)]), .op("−"), .mul([wrap(a), db])]), .script(wrap(b), sub: nil, sup: .num("2")))
        case .sqrt(let a): return raw(a, x).map { .frac($0, .mul([.num("2"), .sqrt(a)])) }
        case .script(let b, nil, let p?):
            if case .id(let f) = b, functions.contains(f) { return nil }
            if !variables(p).contains(x) {
                guard let d = raw(b, x) else { return nil }
                let k: MathNode = eval(p).map { number($0 - 1) } ?? .row([p, .op("−"), .num("1")])
                return .mul([p, .script(b, sub: nil, sup: k), d])
            }
            guard let d = raw(p, x), !variables(b).contains(x) else { return nil }
            return b == .id("e") ? .mul([n, d]) : .mul([n, .fn("ln", .paren("(", b, ")")), d])
        case .fn(let f, let a):
            guard let d = raw(a, x) else { return nil }
            let g: MathNode
            switch f {
            case "sin": g = .fn("cos", a)
            case "cos": g = .neg(.fn("sin", a))
            case "tan": g = .frac(.num("1"), .script(.paren("(", .fn("cos", a), ")"), sub: nil, sup: .num("2")))
            case "ln": g = .frac(.num("1"), strip(a))
            case "log", "lg": g = .frac(.num("1"), .mul([strip(a), .fn("ln", .paren("(", .num("10"), ")"))]))
            case "exp": g = n
            default: return nil
            }
            return .mul([g, d])
        default: return nil
        }
    }
    private static func strip(_ n: MathNode) -> MathNode { if case .paren("(", let x, _) = n { return x }; return n }
    private static func wrap(_ n: MathNode) -> MathNode { switch n { case .row, .neg, .mul: return .paren("(", n, ")"); default: return n } }
    static func number(_ d: Double) -> MathNode {
        let s = d == d.rounded() && abs(d) < 1e15 ? String(Int(abs(d))) : String(abs((d * 1e6).rounded() / 1e6))
        return d < 0 ? .neg(.num(s)) : .num(s)
    }
    static func simplify(_ n: MathNode) -> MathNode {
        switch n {
        case .neg(let a):
            let s = simplify(a)
            if s == .num("0") { return s }
            if case .neg(let b) = s { return b }
            return .neg(s)
        case .paren("(", let a, let z):
            let s = simplify(a)
            switch s { case .num, .id, .fn, .sqrt: return s; default: return .paren("(", s, z) }
        case .fn(let f, let a):
            let s = simplify(a)
            if case .paren = s { return .fn(f, s) }
            return .fn(f, .paren("(", s, ")"))
        case .script(let b, let sub, let p?):
            let q = simplify(p), c = simplify(b)
            if q == .num("1") { return c }
            if q == .num("0") { return .num("1") }
            return .script(c, sub: sub, sup: q)
        case .sqrt(let a): return .sqrt(simplify(a))
        case .frac(let a, let b):
            let x = simplify(a), y = simplify(b)
            if x == .num("0") { return x }
            if y == .num("1") { return x }
            return .frac(x, y)
        case .mul(let a):
            var k = 1.0, f: [MathNode] = []
            func take(_ x: MathNode) {
                switch x {
                case .op("⋅"), .op("×"): break
                case .num(let s): k *= Double(s) ?? 1
                case .neg(let y): k = -k; take(y)
                case .mul(let l): l.forEach(take)
                default: f.append(x)
                }
            }
            a.map(simplify).forEach { if case .paren("(", let x, _) = $0, !{ if case .row = x { return true }; return false }() { take(x) } else { take($0) } }
            if k == 0 { return .num("0") }
            f = f.map { if case .row = $0 { return .paren("(", $0, ")") }; return $0 }
            if f.isEmpty { return number(k) }
            let body: MathNode = abs(k) == 1 ? (f.count == 1 ? f[0] : .mul(f)) : .mul([number(abs(k))] + f)
            return k < 0 ? .neg(body) : body
        case .row(let a):
            var out: [MathNode] = [], sign = "+", k = 0.0
            for t in a {
                if case .op(let o) = t { sign = o; continue }
                var x = simplify(t)
                if case .neg(let y) = x { x = y; sign = sign == "−" ? "+" : "−" }
                if case .num(let s) = x { k += (Double(s) ?? 0) * (sign == "−" ? -1 : 1); sign = "+"; continue }
                if case .row = x { x = sign == "−" ? .paren("(", x, ")") : x }
                if out.isEmpty { out = sign == "−" ? [.neg(x)] : [x] } else { out += [.op(sign), x] }
                sign = "+"
            }
            if k != 0 { if out.isEmpty { return number(k) }; out += [.op(k < 0 ? "−" : "+"), number(abs(k))] }
            return out.isEmpty ? .num("0") : out.count == 1 ? out[0] : .row(out)
        default: return n
        }
    }
}

extension MathNode {
    // f oder f^2 angewandt auf x
    static func fn2(_ f: MathNode, _ x: MathNode) -> MathNode {
        if case .id(let s) = f { return .fn(s, x) }
        if case .script(.id(let s), nil, let p?) = f, p != .neg(.num("1")) { return .script(.fn(s, x), sub: nil, sup: p) }
        return .mul([f, x])
    }
}
