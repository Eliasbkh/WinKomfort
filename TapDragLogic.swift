// Erkennung „2× tippen, liegen lassen, ziehen“ wie bei Windows – reine Logik ohne Systemaufrufe, damit sie testbar ist.
// Eingabe: Fingeranzahl + Zeitstempel jedes Trackpad-Frames. Ausgabe: Maustaste drücken / loslassen.
struct TapDragLogic {
    enum Action: Equatable { case none, press, release }

    static let maxTap = 0.25     // so kurz ist ein Tippen höchstens
    static let maxGap = 0.35     // so schnell muss die zweite Berührung nach dem Tippen kommen
    static let holdToDrag = 0.12 // so lange muss der zweite Finger liegen, damit es Ziehen ist (sonst Doppelklick)

    private var touchStart: Double?
    private var maxFingers = 0
    private var lastTapEnd: Double?
    private var armed = false
    private(set) var dragging = false

    mutating func frame(fingers: Int, time t: Double) -> Action {
        if fingers > 0 {
            if touchStart == nil { // Finger aufgesetzt
                touchStart = t
                maxFingers = fingers
                armed = fingers == 1 && lastTapEnd.map { t - $0 <= Self.maxGap } == true
            }
            maxFingers = max(maxFingers, fingers)
            if maxFingers > 1 { armed = false } // Zwei Finger = Scrollen, kein Ziehen
            if armed, !dragging, let s = touchStart, t - s >= Self.holdToDrag {
                dragging = true
                return .press
            }
            return .none
        }
        // Alle Finger weg
        guard let s = touchStart else { return .none }
        touchStart = nil
        armed = false
        if dragging {
            dragging = false
            lastTapEnd = nil
            return .release
        }
        lastTapEnd = (maxFingers == 1 && t - s <= Self.maxTap) ? t : nil
        return .none
    }
}
