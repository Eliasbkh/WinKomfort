// Trackpad-Waage: reine Rechnung (testbar) – glätten, Null setzen, mit bekanntem Gewicht abgleichen.
struct ScaleLogic {
    private var recent: [Double] = []
    private(set) var tare = 0.0
    var factor = 1.0

    // Rohdruck je Frame. Median gegen Ausreißer (Finger zittert); ohne Berührung beginnt die Messung neu.
    mutating func add(_ raw: Double?) {
        guard let raw, raw.isFinite, raw >= 0 else { recent = []; return }
        recent.append(raw)
        if recent.count > 15 { recent.removeFirst() }
    }
    var raw: Double? { recent.isEmpty ? nil : recent.sorted()[recent.count / 2] }
    var grams: Double? { raw.map { max(0, ($0 - tare) * factor) } }
    var stable: Bool { recent.count == 15 && (recent.max()! - recent.min()!) <= 4 }
    mutating func zero() { if let raw { tare = raw } }
    // Bekanntes Gewicht liegt auf → Umrechnung; false, wenn zu wenig Druck für einen sinnvollen Abgleich
    mutating func calibrate(to known: Double) -> Bool {
        guard known > 0, known.isFinite, let raw, raw - tare >= 5 else { return false }
        factor = known / (raw - tare)
        return true
    }
}
