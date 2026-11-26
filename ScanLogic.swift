// Blatt scannen: Erkennen, Stillhalten, Hinweise und Papierformat – ohne Kamera testbar
import CoreGraphics
import ImageIO
import Foundation

// Ecken im Kamerabild, 0…1, Ursprung oben links (wie SwiftUI)
struct ScanQuad: Equatable {
    var tl, tr, br, bl: CGPoint
    var points: [CGPoint] { [tl, tr, br, bl] }
    var area: CGFloat { // Gaußsche Trapezformel
        let p = points
        return abs((0..<4).reduce(0) { $0 + p[$1].x * p[($1 + 1) % 4].y - p[($1 + 1) % 4].x * p[$1].y }) / 2
    }
    func moved(from o: ScanQuad) -> CGFloat { zip(points, o.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1 }
    // Ecke für Ecke der Median der letzten Messungen: einzelne Ausreißer verschwinden
    // Liegt der Punkt im Blatt? (Ecken im Uhrzeigersinn oder dagegen)
    func contains(_ p: CGPoint) -> Bool {
        let s = points.indices.map { i -> CGFloat in let a = points[i], b = points[(i + 1) % 4]; return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) }
        return s.allSatisfy { $0 >= 0 } || s.allSatisfy { $0 <= 0 }
    }
    // ein Stück zur Mitte hin: Finger am Rand stören nicht
    func inset(_ t: CGFloat) -> ScanQuad {
        let c = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        return ScanQuad.mix(self, ScanQuad(tl: c, tr: c, br: c, bl: c), t)
    }
    static func median(_ qs: [ScanQuad]) -> ScanQuad? {
        guard !qs.isEmpty else { return nil }
        func m(_ k: KeyPath<ScanQuad, CGPoint>) -> CGPoint {
            let x = qs.map { $0[keyPath: k].x }.sorted(), y = qs.map { $0[keyPath: k].y }.sorted()
            return CGPoint(x: x[x.count / 2], y: y[y.count / 2])
        }
        return ScanQuad(tl: m(\.tl), tr: m(\.tr), br: m(\.br), bl: m(\.bl))
    }
    static func mix(_ a: ScanQuad, _ b: ScanQuad, _ t: CGFloat) -> ScanQuad {
        func m(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
        return ScanQuad(tl: m(a.tl, b.tl), tr: m(a.tr, b.tr), br: m(a.br, b.br), bl: m(a.bl, b.bl))
    }
}

enum ScanLogic {
    enum Hint: Equatable { case empty, small, cutNear, cutFar, cutLeft, cutRight, hand, moving, hold, done }
    static let edge: CGFloat = 0.004, still: CGFloat = 0.02, holdSeconds = 1.2

    // Was soll man tun? Unten im Desk-View-Bild liegt die Seite zu dir, oben die zum Mac
    static func hint(_ q: ScanQuad?, previous: ScanQuad?, hand: Bool = false) -> Hint {
        guard let q else { return .empty }
        if hand { return .hand }
        let p = q.points
        if p.contains(where: { $0.y > 1 - edge }) { return .cutNear }
        if p.contains(where: { $0.y < edge }) { return .cutFar }
        if p.contains(where: { $0.x < edge }) { return .cutLeft }
        if p.contains(where: { $0.x > 1 - edge }) { return .cutRight }
        if q.area < 0.08 { return .small }
        if let previous, q.moved(from: previous) > still { return .moving }
        return .hold
    }
    // Fortschritt wächst nur, solange das Blatt ganz drin ist und stillliegt; Wackeln nimmt schnell wieder etwas weg
    static func step(_ progress: Double, _ h: Hint, dt: Double) -> Double {
        switch h {
        case .hold: return min(1, progress + dt / holdSeconds)
        case .moving, .hand: return max(0, progress - dt * 0.8) // kurzes Wackeln kostet wenig
        default: return 0
        }
    }

    // Seitenverhältnis in echten Pixeln → Papierart und Seitengröße in Punkt (72 pro Zoll)
    enum Kind: String { case a4, letter, card, note, sheet }
    struct Paper: Equatable { let kind: Kind; let size: CGSize }
    static func sides(_ q: ScanQuad, image: CGSize) -> CGSize {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot((a.x - b.x) * image.width, (a.y - b.y) * image.height) }
        return CGSize(width: (d(q.tl, q.tr) + d(q.bl, q.br)) / 2, height: (d(q.tl, q.bl) + d(q.tr, q.br)) / 2)
    }
    static func paper(_ s: CGSize) -> Paper {
        guard s.width > 1, s.height > 1 else { return Paper(kind: .sheet, size: CGSize(width: 595, height: 842)) }
        let portrait = s.height >= s.width, r = max(s.width, s.height) / min(s.width, s.height)
        func page(_ w: CGFloat, _ h: CGFloat, _ n: Kind) -> Paper { Paper(kind: n, size: portrait ? CGSize(width: w, height: h) : CGSize(width: h, height: w)) }
        switch r {
        case 1.28..<1.62: return page(595, 842, .a4) // die Kamera sieht A4 leicht gestaucht oder gestreckt; in Deutschland ist es fast immer A4
        case 1.62..<1.8: return page(360, 360 * r, .card)
        case ..<1.12: return page(500, 500 * r, .note)
        default: return page(595, 595 * r, .sheet)
        }
    }
    // Pixelgröße fürs Ergebnis: 200 dpi, mehr gibt die Kamera nicht ehrlich her
    static func pixels(_ p: Paper, dpi: CGFloat = 200) -> CGSize { CGSize(width: (p.size.width / 72 * dpi).rounded(), height: (p.size.height / 72 * dpi).rounded()) }
    static func fileName(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return "Scan " + f.string(from: d)
    }
    // KI-Antwort „Titel | Art | Fach“ → Teile; Anführungszeichen, Markdown und „Titel:“-Vorsätze weg
    static func guess(_ r: String) -> (title: String, kind: String, subject: String)? {
        guard let line = r.split(separator: "\n").map(String.init).first(where: { $0.contains("|") }) else { return nil }
        let p = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: #"^\s*(\*\*)?(titel|art|fach)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: CharacterSet(charactersIn: " *\"„“'`")) }
        guard p.count >= 2, !p[0].isEmpty else { return nil }
        let s = p.count > 2 && !["-", "leer", "keins", "kein", "none"].contains(p[2].lowercased()) ? p[2] : ""
        return (String(p[0].prefix(60)), String(p[1].prefix(30)), String(s.prefix(30)))
    }
    // Schriftrichtung (0° = von links nach rechts) → Drehung, die das Blatt aufrecht stellt
    static func orientation(degrees a: Double) -> CGImagePropertyOrientation {
        let d = (a.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180 // −180…180
        if abs(d) <= 45 { return .up }
        if abs(d) >= 135 { return .down }
        return d > 0 ? .right : .left
    }
}
