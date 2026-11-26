// Blatt scannen: Erkennen, Stillhalten, Hinweise und Papierformat – ohne Kamera testbar
import CoreGraphics
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
    static func mix(_ a: ScanQuad, _ b: ScanQuad, _ t: CGFloat) -> ScanQuad {
        func m(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
        return ScanQuad(tl: m(a.tl, b.tl), tr: m(a.tr, b.tr), br: m(a.br, b.br), bl: m(a.bl, b.bl))
    }
}

enum ScanLogic {
    enum Hint: Equatable { case empty, small, cutNear, cutFar, cutSide, moving, hold, done }
    static let edge: CGFloat = 0.015, still: CGFloat = 0.012, holdSeconds = 1.3

    // Was soll man tun? Unten im Desk-View-Bild liegt die Seite zu dir, oben die zum Mac
    static func hint(_ q: ScanQuad?, previous: ScanQuad?) -> Hint {
        guard let q else { return .empty }
        let p = q.points
        if p.contains(where: { $0.y > 1 - edge }) { return .cutNear }
        if p.contains(where: { $0.y < edge }) { return .cutFar }
        if p.contains(where: { $0.x < edge || $0.x > 1 - edge }) { return .cutSide }
        if q.area < 0.08 { return .small }
        if let previous, q.moved(from: previous) > still { return .moving }
        return .hold
    }
    // Fortschritt wächst nur, solange das Blatt ganz drin ist und stillliegt; Wackeln nimmt schnell wieder etwas weg
    static func step(_ progress: Double, _ h: Hint, dt: Double) -> Double {
        switch h {
        case .hold: return min(1, progress + dt / holdSeconds)
        case .moving: return max(0, progress - dt * 2)
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
        case 1.34..<1.52: return page(595, 842, .a4)
        case 1.25..<1.34: return page(612, 792, .letter)
        case 1.52..<1.75: return page(360, 360 * r, .card)
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
}
