import CoreGraphics

// Zielrechteck beim Einrasten per Tastatur – reine Rechnung, damit testbar.
enum SnapMath {
    enum Dir { case left, right, max }

    // Cocoa-Rechteck (Ursprung unten links am Hauptbildschirm) → Bedienungshilfen-Koordinaten (Ursprung oben links)
    static func toAX(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // `v` = sichtbarer Bereich des Bildschirms (ohne Dock/Menüleiste) in AX-Koordinaten
    static func target(_ d: Dir, in v: CGRect) -> CGRect {
        let half = (v.width / 2).rounded()
        switch d {
        case .left: return CGRect(x: v.minX, y: v.minY, width: half, height: v.height)
        case .right: return CGRect(x: v.minX + half, y: v.minY, width: v.width - half, height: v.height)
        case .max: return v
        }
    }

    static func fraction(_ f: CGRect, in v: CGRect) -> CGRect {
        let x = (v.minX + f.minX * v.width).rounded(), y = (v.minY + f.minY * v.height).rounded()
        return CGRect(x: x, y: y, width: (v.minX + f.maxX * v.width).rounded() - x, height: (v.minY + f.maxY * v.height).rounded() - y)
    }
}
