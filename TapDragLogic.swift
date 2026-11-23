// Erkennung „2× tippen, liegen lassen, ziehen“ wie bei Windows – reine Logik ohne Systemaufrufe, damit sie testbar ist.
// Eingabe je Trackpad-Frame: Positionen der Finger, die WIRKLICH aufliegen (0…1), und die Zeit.
// Ausgabe: Maustaste drücken / loslassen.
struct TapDragLogic {
    enum Action: Equatable { case none, press, release }
    struct Point: Equatable { var x, y: Double }

    static let maxTap = 0.22      // so kurz ist ein Tippen höchstens
    static let tapMove = 0.02     // so wenig darf sich ein Tippen bewegen (≈ 3 mm)
    static let maxGap = 0.35      // so schnell muss die zweite Berührung nach dem Tippen kommen
    static let sameSpot = 0.08    // so nah an der Tipp-Stelle muss sie liegen (≈ 1 cm)
    static let dragMove = 0.008   // ab dieser Bewegung des zweiten Fingers beginnt das Ziehen sofort
    static let holdToDrag = 0.18  // oder ab so langem Liegenlassen (sonst ist es ein Doppelklick)

    private var touchStart: Double?
    private var startPos = Point(x: 0, y: 0)
    private var lastPos = Point(x: 0, y: 0)
    private var moved = 0.0
    private var maxFingers = 0
    private var lastTap: (time: Double, pos: Point)?
    private var armed = false
    private(set) var dragging = false

    private static func dist(_ a: Point, _ b: Point) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    mutating func frame(touching: [Point], time t: Double) -> Action {
        if let p = touching.first {
            if touchStart == nil { // Finger aufgesetzt
                touchStart = t
                startPos = p
                moved = 0
                maxFingers = touching.count
                armed = touching.count == 1 && lastTap.map { t - $0.time <= Self.maxGap && Self.dist(p, $0.pos) <= Self.sameSpot } == true
                lastTap = nil
            }
            lastPos = p
            moved = max(moved, Self.dist(p, startPos))
            maxFingers = max(maxFingers, touching.count)
            if maxFingers > 1 && !dragging { armed = false } // zwei Finger = Scrollen, kein Ziehen
            if armed, !dragging, let s = touchStart, moved >= Self.dragMove || t - s >= Self.holdToDrag {
                dragging = true
                return .press
            }
            return .none
        }
        // Kein Finger liegt mehr auf
        guard let s = touchStart else { return .none }
        touchStart = nil
        armed = false
        if dragging {
            dragging = false
            return .release
        }
        let isTap = maxFingers == 1 && t - s <= Self.maxTap && moved <= Self.tapMove
        lastTap = isTap ? (t, lastPos) : nil
        return .none
    }
}
