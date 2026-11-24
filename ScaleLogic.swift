// Trackpad-Waage: reine Rechnung (testbar) – glätten, Finger automatisch abziehen, mit bekanntem Gewicht abgleichen.
struct ScaleLogic {
    static let window = 15        // Frames je Messung (Median gegen zitternde Finger)
    static let steadyRange = 6.0  // so wenig darf der Druck in dieser Zeit schwanken
    static let settle = 60        // so viele Frames (≈ ½ s) liegt der Finger, bevor er abgezogen wird
    private var recent: [Double] = []
    private var frames = 0
    private(set) var tare: Double?
    private(set) var held: Double? // letzter ruhiger Wert – bleibt stehen, wenn der Finger weggeht
    var factor = 1.0
    var finger = true // false: der Gegenstand berührt das Trackpad selbst (leitend) – nichts abziehen

    // Rohdruck je Frame; nil = nichts berührt das Trackpad
    mutating func add(_ raw: Double?) {
        guard let raw, raw.isFinite, raw >= 0 else { recent = []; frames = 0; tare = nil; return }
        if recent.isEmpty { held = nil } // neue Messung
        recent.append(raw)
        frames += 1
        if recent.count > Self.window { recent.removeFirst() }
        if !finger, tare == nil { tare = 0 }
        if tare == nil, frames >= Self.settle, steady { zero() }
        if steady, let g = live { held = g }
    }
    private var raw: Double? { recent.isEmpty ? nil : recent.sorted()[recent.count / 2] }
    private var live: Double? { tare.flatMap { t in raw.map { max(0, ($0 - t) * factor) } } }
    var touching: Bool { !recent.isEmpty }
    var steady: Bool { recent.count == Self.window && recent.max()! - recent.min()! <= Self.steadyRange }
    var grams: Double? { touching ? live : held }
    mutating func zero() { if let raw { tare = raw; held = nil } }
    // Bekanntes Gewicht liegt auf → Umrechnung; false, wenn zu wenig Druck für einen sinnvollen Abgleich
    mutating func calibrate(to known: Double) -> Bool {
        guard known > 0, known.isFinite, let raw, let tare, raw - tare >= 5 else { return false }
        factor = known / (raw - tare)
        return true
    }
    // Skala des Zifferblatts: kleinste Stufe, in die der Wert passt
    static func range(_ g: Double) -> Double { [100, 250, 500, 1000, 2000].first { g <= $0 } ?? 4000 }
}
