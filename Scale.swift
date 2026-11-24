// Trackpad-Waage: liest den Druck des Force-Touch-Trackpads (privates MultitouchSupport, nur solange das Fenster offen ist).
// Das Trackpad misst nur bei Berührung – deshalb liegt ein Finger leicht auf; sein Druck wird automatisch abgezogen.
import AppKit
import SwiftUI

@MainActor final class TrackpadScale: ObservableObject {
    static let shared = TrackpadScale()
    @Published private(set) var grams: Double?
    @Published private(set) var state = State.empty
    @Published private(set) var available = true
    enum State { case empty, taring, measuring, steady, held }
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
                guard (3...5).contains(state) else { continue } // auch leitende Gegenstände, nicht nur Finger
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
        let now: State = !logic.touching ? (logic.held == nil ? .empty : .held) : logic.tare == nil ? .taring : logic.steady ? .steady : .measuring
        if now != state { state = now }
    }

    func start() {
        guard device == nil else { return }
        logic = ScaleLogic()
        let f = UserDefaults.standard.double(forKey: "scaleFactor")
        logic.factor = f > 0 && f.isFinite ? f : 1
        grams = nil; state = .empty; note = ""
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
            note = L("Finger und Gewicht auflegen, Gramm eintragen, dann abgleichen.", "Rest finger and weight, enter the grams, then calibrate.")
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

// Küchenwaage: Teller (sinkt mit dem Gewicht), Zifferblatt mit Zeiger, Digitalanzeige
struct ScaleView: View {
    @ObservedObject var s = TrackpadScale.shared
    @Environment(\.accessibilityReduceMotion) private var calm
    private var g: Double { s.grams ?? 0 }
    private var range: Double { ScaleLogic.range(g) }

    private var hint: (String, String) {
        switch s.state {
        case .empty: (L("Finger leicht aufs Trackpad legen", "Rest a finger lightly on the trackpad"), "hand.point.up.left")
        case .taring: (L("Stillhalten – Finger wird abgezogen …", "Hold still – subtracting your finger…"), "hourglass")
        case .measuring: (L("Misst …", "Measuring…"), "waveform")
        case .steady: g < 1 ? (L("Bereit – Gegenstand dazulegen", "Ready – add the object"), "arrow.down.to.line") : (L("Ruhig", "Steady"), "checkmark.circle.fill")
        case .held: (L("Letzter Wert", "Last reading"), "pin.fill")
        }
    }

    var body: some View {
        if s.available {
            VStack(spacing: 14) {
                scale
                Label(hint.0, systemImage: hint.1).font(.callout).foregroundStyle(.secondary).frame(height: 20)
                Button(L("Null setzen (Leertaste)", "Set zero (Space)")) { s.zero() }
                    .keyboardShortcut(.space, modifiers: []).disabled(s.state == .empty || s.state == .held)
                DisclosureGroup(L("Genauer machen", "Improve accuracy")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(L("Bekanntes Gewicht", "Known weight"), text: $s.known).textFieldStyle(.roundedBorder)
                            Text("g")
                            Button(L("Abgleichen", "Calibrate")) { s.calibrate() }
                            Button(L("Zurücksetzen", "Reset")) { s.resetCalibration() }
                        }
                        if !s.note.isEmpty { Text(s.note).font(.caption) }
                        Text(L("Schätzwert: Das Trackpad misst nur, solange ein Finger oder etwas Leitendes es berührt. Nichts Schweres, Hartes oder Nasses auflegen.",
                               "Estimate: the trackpad only measures while a finger or something conductive touches it. Nothing heavy, hard or wet."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(24).frame(width: 400)
        } else {
            ContentUnavailableView(L("Kein Force-Touch-Trackpad gefunden.", "No Force Touch trackpad found."), systemImage: "scalemass")
                .frame(width: 400, height: 260)
        }
    }

    private var scale: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(LinearGradient(colors: [Color(white: 0.93), Color(white: 0.68)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 250, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                Rectangle().fill(Color(white: 0.55)).frame(width: 46, height: 22)
            }
            .offset(y: min(g / range, 1) * 10)
            .animation(calm ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: g)
            .zIndex(0)
            VStack(spacing: 10) {
                dial
                Text(s.grams.map { "\(Int($0)) g" } ?? "– – –")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.12))
                    .frame(width: 190, height: 52)
                    .background(Color(red: 0.76, green: 0.83, blue: 0.74), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.25)))
            }
            .padding(.vertical, 18).frame(width: 300)
            .background(Color(red: 0.17, green: 0.33, blue: 0.38), in: UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 40, bottomTrailingRadius: 40, topTrailingRadius: 26))
            .zIndex(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Waage", "Scale"))
        .accessibilityValue(s.grams.map { L("\(Int($0)) Gramm", "\(Int($0)) grams") } ?? L("Kein Messwert", "No reading"))
    }

    private var dial: some View {
        ZStack {
            Circle().fill(Color(red: 0.96, green: 0.94, blue: 0.89))
            Canvas { c, size in
                let m = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2
                for i in 0...50 {
                    let a = Angle.degrees(-225 + Double(i) * 5.4).radians, big = i % 10 == 0
                    var p = Path()
                    p.move(to: CGPoint(x: m.x + cos(a) * (r - 8), y: m.y + sin(a) * (r - 8)))
                    p.addLine(to: CGPoint(x: m.x + cos(a) * (r - (big ? 20 : 13)), y: m.y + sin(a) * (r - (big ? 20 : 13))))
                    c.stroke(p, with: .color(Color(white: big ? 0.15 : 0.45)), lineWidth: big ? 2 : 1)
                    if big {
                        c.draw(Text("\(Int(range * Double(i) / 50))").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.2)),
                               at: CGPoint(x: m.x + cos(a) * (r - 35), y: m.y + sin(a) * (r - 35)))
                    }
                }
            }
            Capsule().fill(Color(red: 0.85, green: 0.40, blue: 0.12)).frame(width: 4, height: 54).offset(y: -19)
                .rotationEffect(.degrees(-135 + min(g / range, 1) * 270))
                .animation(calm ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: g / range)
            Circle().fill(Color(white: 0.2)).frame(width: 16, height: 16)
        }
        .frame(width: 180, height: 180)
    }
}
