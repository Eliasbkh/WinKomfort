// Trackpad-Waage: liest den Druck des Force-Touch-Trackpads (privates MultitouchSupport, nur solange das Fenster offen ist).
// Das Trackpad misst nur bei Berührung – deshalb muss ein Finger leicht aufliegen; sein Druck wird auf null gesetzt.
import AppKit
import SwiftUI

@MainActor final class TrackpadScale: ObservableObject {
    static let shared = TrackpadScale()
    @Published private(set) var grams: Double?
    @Published private(set) var stable = false
    @Published private(set) var available = true
    @Published var known = ""
    @Published var note = ""
    private var logic = ScaleLogic()
    private var device: UnsafeMutableRawPointer?

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias DevFn = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private static let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private static func fn<T>(_ n: String, _: T.Type) -> T? {
        guard let lib, let f = dlsym(lib, n) else { return nil }
        return unsafeBitCast(f, to: T.self)
    }
    // MTTouch (96 Byte): Zustand bei 20, Druck bei 52 – auf macOS 27 am eingebauten Trackpad geprüft
    private static let callback: Callback = { _, data, count, _, _ in
        var sum: Double?
        if let data {
            for i in 0..<Int(count) {
                let t = data + i * 96
                let state = t.load(fromByteOffset: 20, as: Int32.self)
                guard state == 3 || state == 4 else { continue }
                sum = (sum ?? 0) + Double(t.load(fromByteOffset: 52, as: Float.self))
            }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { TrackpadScale.shared.sample(sum) } }
        return 0
    }

    private func sample(_ raw: Double?) {
        guard device != nil else { return }
        logic.add(raw)
        let g = logic.grams.map { $0.rounded() }
        if g != grams { grams = g }
        if logic.stable != stable { stable = logic.stable }
    }

    func start() {
        guard device == nil else { return }
        logic = ScaleLogic()
        let f = UserDefaults.standard.double(forKey: "scaleFactor")
        logic.factor = f > 0 && f.isFinite ? f : 1
        grams = nil; note = ""
        guard let dev = Self.fn("MTDeviceCreateDefault", (@convention(c) () -> UnsafeMutableRawPointer?).self)?(),
              let force = Self.fn("MTDeviceSupportsForce", (@convention(c) (UnsafeMutableRawPointer) -> Bool).self), force(dev),
              let register = Self.fn("MTRegisterContactFrameCallback", DevFn.self),
              let run = Self.fn("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self) else { available = false; return }
        available = true
        register(dev, Self.callback)
        _ = run(dev, 0)
        device = dev
    }

    func stop() {
        guard let dev = device else { return }
        device = nil
        Self.fn("MTUnregisterContactFrameCallback", DevFn.self)?(dev, Self.callback)
        _ = Self.fn("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)?(dev)
        Self.fn("MTDeviceRelease", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)?(dev)
        // Das Tipp-Ziehen nutzt dasselbe Trackpad – sicherheitshalber neu aufsetzen
        if let drag = features.first(where: { $0.id == "drag" }), isOn(drag) { TapDragFix.stop(); TapDragFix.start() }
    }

    func zero() { logic.zero(); note = "" }
    func calibrate() {
        let g = Double(known.replacingOccurrences(of: ",", with: ".")) ?? 0
        if logic.calibrate(to: g) {
            UserDefaults.standard.set(logic.factor, forKey: "scaleFactor")
            note = L("Abgeglichen.", "Calibrated.")
        } else {
            note = L("Erst Null setzen, Gewicht auflegen und Gramm eintragen.", "Set zero, add the weight and enter its grams first.")
        }
    }
    func resetCalibration() {
        logic.factor = 1
        UserDefaults.standard.removeObject(forKey: "scaleFactor")
        note = L("Abgleich zurückgesetzt.", "Calibration reset.")
    }
}

@MainActor func openScale() {
    showWindow("scale", "Trackpad-Waage", onClose: { MainActor.assumeIsolated { TrackpadScale.shared.stop() } }) { ScaleView() }
    windows["scale"]?.title = L("Trackpad-Waage", "Trackpad Scale")
    TrackpadScale.shared.start()
}

struct ScaleView: View {
    @ObservedObject var s = TrackpadScale.shared
    var body: some View {
        VStack(spacing: 16) {
            if s.available {
                Text(s.grams.map { "\(Int($0)) g" } ?? "– g")
                    .font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(s.grams == nil ? .secondary : .primary)
                    .accessibilityLabel(s.grams.map { L("\(Int($0)) Gramm", "\(Int($0)) grams") } ?? L("Kein Messwert", "No reading"))
                Label(s.grams == nil ? L("Finger leicht auflegen", "Rest a finger lightly") : s.stable ? L("Ruhig", "Steady") : L("Misst …", "Measuring…"),
                      systemImage: s.grams == nil ? "hand.point.up.left" : s.stable ? "checkmark.circle" : "waveform")
                    .foregroundStyle(.secondary)
                Button(L("Null setzen (Leertaste)", "Set zero (Space)")) { s.zero() }
                    .keyboardShortcut(.space, modifiers: []).disabled(s.grams == nil)
                Text(L("1. Finger leicht auflegen und liegen lassen.\n2. Leertaste drücken.\n3. Gegenstand dazulegen, ohne den Finger zu bewegen.",
                       "1. Rest a finger lightly and keep it there.\n2. Press Space.\n3. Add the object without moving your finger."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    TextField(L("Bekanntes Gewicht", "Known weight"), text: $s.known).frame(width: 140).textFieldStyle(.roundedBorder)
                    Text("g")
                    Button(L("Abgleichen", "Calibrate")) { s.calibrate() }
                    Button(L("Zurücksetzen", "Reset")) { s.resetCalibration() }
                }
                Text(s.note.isEmpty ? L("Nur ein Schätzwert. Leichte, flache Dinge auflegen, nichts Hartes, Nasses oder Schweres.",
                                        "Estimate only. Use light, flat objects, nothing hard, wet or heavy.") : s.note)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(L("Kein Force-Touch-Trackpad gefunden.", "No Force Touch trackpad found.")).font(.headline)
            }
        }
        .padding(24).frame(width: 420)
    }
}
