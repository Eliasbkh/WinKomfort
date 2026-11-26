// Eigene Handschrift: Vorlage, Buchstaben in Stiftstriche umrechnen, Text setzen – ohne AppKit, testbar
import CoreGraphics
import Foundation

enum HandLogic {
    // MARK: Vorlage (A4 in Punkt, Ursprung oben links)
    static let chars: [Character] = Array("abcdefghijklmnopqrstuvwxyzäöüßABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÜ0123456789.,:;!?-()\"'/+=%&")
    static let page = CGSize(width: 595, height: 842)
    static let cols = 14, cell = CGSize(width: 37, height: 52), labelHeight: CGFloat = 12
    static let grid = CGPoint(x: (595 - 14 * 37) / 2, y: 112)
    static let markerSize: CGFloat = 14
    // Mittelpunkte der vier Passmarken (oben links, oben rechts, unten rechts, unten links)
    static let markers: [CGPoint] = [CGPoint(x: 34, y: 34), CGPoint(x: 561, y: 34), CGPoint(x: 561, y: 808), CGPoint(x: 34, y: 808)]
    // jedes Zeichen zweimal: zwei Varianten für natürliche Abwechslung
    static var slots: [(char: Character, variant: Int)] { chars.flatMap { c in [(c, 0), (c, 1)] } }
    static func box(_ i: Int) -> CGRect { CGRect(x: grid.x + CGFloat(i % cols) * cell.width, y: grid.y + CGFloat(i / cols) * cell.height, width: cell.width, height: cell.height) }
    static func area(_ i: Int) -> CGRect { let b = box(i); return CGRect(x: b.minX + 2.5, y: b.minY + labelHeight + 1.5, width: b.width - 5, height: b.height - labelHeight - 4) }
    static let baselineShare: CGFloat = 0.7 // Grundlinie bei 70 % der Schreibfläche, darunter Platz für g, p, q
    static func baseline(_ i: Int) -> CGFloat { let a = area(i); return a.minY + a.height * baselineShare }
    static func em(_ i: Int) -> CGFloat { area(i).height * baselineShare } // Höhe eines Großbuchstabens

    // MARK: Schrift
    struct Glyph: Codable, Equatable { var strokes: [[CGPoint]]; var width: CGFloat } // x ab linkem Rand, y nach oben ab Grundlinie, Einheit em
    struct Font: Codable, Equatable {
        var glyphs: [String: [Glyph]] = [:]
        var pen: CGFloat = 0.06 // Strichstärke in em
        var missing: [Character] { HandLogic.chars.filter { glyphs[String($0)]?.isEmpty ?? true } }
    }

    // MARK: Skelett (Zhang-Suen): Tinte auf eine Pixel breite Mittellinie verdünnen
    static func thin(_ b: inout [UInt8], _ w: Int, _ h: Int) {
        guard w > 2, h > 2 else { return }
        func px(_ x: Int, _ y: Int) -> Int { x < 0 || y < 0 || x >= w || y >= h ? 0 : Int(b[y * w + x]) }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var del: [Int] = []
                for y in 1..<(h - 1) { for x in 1..<(w - 1) where b[y * w + x] == 1 {
                    let p = [px(x, y - 1), px(x + 1, y - 1), px(x + 1, y), px(x + 1, y + 1), px(x, y + 1), px(x - 1, y + 1), px(x - 1, y), px(x - 1, y - 1)]
                    let n = p.reduce(0, +)
                    guard n >= 2, n <= 6 else { continue }
                    let a = (0..<8).filter { p[$0] == 0 && p[($0 + 1) % 8] == 1 }.count
                    guard a == 1 else { continue }
                    if pass == 0 ? (p[0] * p[2] * p[4] == 0 && p[2] * p[4] * p[6] == 0) : (p[0] * p[2] * p[6] == 0 && p[0] * p[4] * p[6] == 0) { del.append(y * w + x) }
                } }
                for i in del { b[i] = 0 }
                if !del.isEmpty { changed = true }
            }
        }
    }

    // MARK: Skelett nachfahren: Striche wie mit dem Stift, Enden zuerst, Lücken an Kreuzungen geschlossen
    static func trace(_ b: [UInt8], _ w: Int, _ h: Int) -> [[CGPoint]] {
        var seen = [Bool](repeating: false, count: w * h)
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && b[y * w + x] == 1 }
        let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        func around(_ x: Int, _ y: Int) -> [(Int, Int)] { dirs.map { (x + $0.0, y + $0.1) }.filter { on($0.0, $0.1) } }
        var out: [[CGPoint]] = []
        func walk(_ sx: Int, _ sy: Int) {
            var x = sx, y = sy, line = [CGPoint(x: x, y: y)], last = (0, 0)
            seen[y * w + x] = true
            while true {
                let next = around(x, y).filter { !seen[$0.1 * w + $0.0] }
                guard !next.isEmpty else {
                    // an eine schon gezeichnete Kreuzung anschließen, sonst bleibt eine Lücke
                    if let j = around(x, y).first(where: { $0 != (x - last.0, y - last.1) && line.count > 1 }) { line.append(CGPoint(x: j.0, y: j.1)) }
                    break
                }
                // möglichst geradeaus weiter
                let n = next.max { a, c in (a.0 - x) * last.0 + (a.1 - y) * last.1 < (c.0 - x) * last.0 + (c.1 - y) * last.1 }!
                // Treppenstufen im Skelett: übersprungene Eckpixel gehören zu diesem Strich, sonst werden sie zu Mini-Strichen
                for m in next where m != n && abs(m.0 - n.0) <= 1 && abs(m.1 - n.1) <= 1 { seen[m.1 * w + m.0] = true }
                last = (n.0 - x, n.1 - y); x = n.0; y = n.1
                seen[y * w + x] = true
                line.append(CGPoint(x: x, y: y))
            }
            if line.count >= 3 { out.append(line) }
        }
        // erst von Enden aus, dann übrige Schleifen (o, 0)
        for y in 0..<h { for x in 0..<w where on(x, y) && !seen[y * w + x] && around(x, y).count == 1 { walk(x, y) } }
        for y in 0..<h { for x in 0..<w where on(x, y) && !seen[y * w + x] { walk(x, y) } }
        // Striche, deren Enden sich berühren, zu einem verbinden (geschlossene Bögen wie o)
        var merged: [[CGPoint]] = []
        for s in out {
            if let i = merged.indices.first(where: { hypot(merged[$0].last!.x - s.first!.x, merged[$0].last!.y - s.first!.y) <= 2 }) { merged[i] += s }
            else if let i = merged.indices.first(where: { hypot(merged[$0].last!.x - s.last!.x, merged[$0].last!.y - s.last!.y) <= 2 }) { merged[i] += s.reversed() }
            else { merged.append(s) }
        }
        return merged
    }

    // Ramer-Douglas-Peucker: wenige Punkte, gleiche Form
    static func simplify(_ p: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
        guard p.count > 2 else { return p }
        let a = p.first!, b = p.last!, dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1e-6)
        var far = 0, best: CGFloat = 0
        let closed = hypot(dx, dy) < 1 // Schleife (o): Abstand zum Startpunkt statt zu einer Linie ohne Länge
        for i in 1..<(p.count - 1) { let d = closed ? hypot(p[i].x - a.x, p[i].y - a.y) : abs(dy * p[i].x - dx * p[i].y + b.x * a.y - b.y * a.x) / len; if d > best { best = d; far = i } }
        return best > eps ? Array(simplify(Array(p[...far]), eps).dropLast()) + simplify(Array(p[far...]), eps) : [a, b]
    }
    // Chaikin: Ecken weich, wie mit dem Stift geschwungen
    static func smooth(_ p: [CGPoint]) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out = [p[0]]
        for i in 0..<(p.count - 1) { let a = p[i], b = p[i + 1]; out += [CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25), CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75)] }
        return out + [p[p.count - 1]]
    }

    // Tinte eines Kästchens → Buchstabe in em. b: 1 = Tinte, Größe w×h Pixel, baseline/em in Pixeln
    static func glyph(_ ink: [UInt8], _ w: Int, _ h: Int, baseline: CGFloat, em: CGFloat) -> (glyph: Glyph, pen: CGFloat)? {
        let inkCount = ink.reduce(0) { $0 + Int($1) }
        guard inkCount > 4 else { return nil }
        var b = ink
        thin(&b, w, h)
        let skel = b.reduce(0) { $0 + Int($1) }
        var strokes: [[CGPoint]] = trace(b, w, h).map { smooth(simplify($0, 0.9)) }.filter { s in zip(s, s.dropFirst()).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) } > em * 0.06 }
        if strokes.isEmpty { // Punkt: zu klein für ein Skelett → ein kurzer Tupfer in der Mitte der Tinte
            let pts = (0..<(w * h)).filter { ink[$0] == 1 }.map { CGPoint(x: $0 % w, y: $0 / w) }
            let c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
            strokes = [[c, CGPoint(x: c.x + 0.5, y: c.y + 0.5)]]
        }
        let xs = strokes.flatMap { $0.map(\.x) }, minX = xs.min()!, maxX = xs.max()!
        let g = Glyph(strokes: strokes.map { $0.map { CGPoint(x: ($0.x - minX) / em, y: (baseline - $0.y) / em) } }, width: max((maxX - minX) / em, 0.08))
        return (g, CGFloat(inkCount) / CGFloat(max(skel, 1)) / em)
    }

    // MARK: Text setzen
    struct Rng { var s: UInt64; mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) } }
    static func pick(_ c: Character, _ f: Font) -> [Glyph]? {
        let alt = ["ä": "a", "ö": "o", "ü": "u", "Ä": "A", "Ö": "O", "Ü": "U", "ß": "s", "„": "\"", "“": "\"", "”": "\"", "–": "-", "—": "-", "’": "'", "‘": "'"][String(c)] ?? ""
        for k in [String(c), String(c).lowercased(), String(c).uppercased(), alt, alt.lowercased(), alt.uppercased()] where !k.isEmpty {
            if let g = f.glyphs[k], !g.isEmpty { return g }
        }
        return nil
    }
    // Striche im Zielrechteck (Ursprung oben links, Punkt). size = Höhe eines Großbuchstabens in Punkt
    static func layout(_ text: String, _ f: Font, in r: CGRect, size: CGFloat, seed: UInt64 = 7, lineHeight: CGFloat? = nil) -> (strokes: [[CGPoint]], fits: Bool) {
        var rng = Rng(s: seed), out: [[CGPoint]] = []
        let lh = lineHeight ?? size * 1.55, space = size * 0.42, gap = size * 0.09
        var x = r.minX, base = r.minY + size * 1.05, fits = true
        func width(_ w: Substring) -> CGFloat { w.reduce(0) { $0 + (pick($1, f)?.first?.width ?? 0.5) * size + gap } }
        for (li, para) in text.components(separatedBy: "\n").enumerated() {
            if li > 0 { x = r.minX; base += lh }
            for word in para.split(separator: " ", omittingEmptySubsequences: true) {
                let ww = width(word)
                if x > r.minX, x + ww > r.maxX { x = r.minX; base += lh }
                if base + size * 0.3 > r.maxY { fits = false }
                for c in word {
                    guard let vs = pick(c, f) else { x += size * 0.5; continue }
                    let g = vs[Int(rng.next() * Double(vs.count)) % vs.count]
                    let s = size * (0.96 + rng.next() * 0.08), dy = (rng.next() - 0.5) * size * 0.06, slant = (rng.next() - 0.5) * 0.06
                    for st in g.strokes { out.append(st.map { p in CGPoint(x: x + (p.x + p.y * slant) * s, y: base + dy - p.y * s) }) }
                    x += g.width * s + gap
                }
                x += space
            }
        }
        return (out, fits)
    }
    // größte Schrift, bei der der Text noch ins Feld passt
    static func fit(_ text: String, _ f: Font, in r: CGRect, max big: CGFloat = 11, min small: CGFloat = 4.5) -> CGFloat {
        var s = big
        while s > small, !layout(text, f, in: r, size: s).fits { s -= 0.5 }
        return s
    }
}
