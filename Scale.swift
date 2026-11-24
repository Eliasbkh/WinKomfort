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
    if let w = windows["scale"] {
        w.title = L("Trackpad-Waage", "Trackpad Scale")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        w.styleMask.remove(.resizable)
        w.isMovableByWindowBackground = true
    }
    TrackpadScale.shared.start()
}

// Ein Messring wie bei Apples Kompass und Wasserwaage: Systemfarben, eine große Zahl, eine Akzentfarbe nur am Zeiger
struct ScaleView: View {
    @ObservedObject var s = TrackpadScale.shared
    @StateObject private var options = HoverBox()
    @Environment(\.accessibilityReduceMotion) private var calm
    private var g: Double { s.grams ?? 0 }
    private var range: Double { ScaleLogic.range(g) }
    private var fraction: Double { min(g / range, 1) }

    private var hint: String {
        switch s.state {
        case .empty: L("Finger leicht auflegen", "Rest a finger lightly")
        case .taring: L("Stillhalten …", "Hold still…")
        case .measuring: L("Misst …", "Measuring…")
        case .steady: g < 1 ? L("Gegenstand dazulegen", "Add the object") : L("Gramm", "Grams")
        case .held: L("Letzter Wert", "Last reading")
        }
    }

    var body: some View {
        Group {
            if s.available { content } else {
                ContentUnavailableView(L("Kein Force-Touch-Trackpad gefunden", "No Force Touch trackpad found"), systemImage: "scalemass")
            }
        }
        .frame(width: 360, height: 404)
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 20) {
            ZStack {
                ScaleRing(fraction: fraction).animation(calm ? nil : .spring(response: 0.4, dampingFraction: 1), value: fraction)
                VStack(spacing: 2) {
                    Text(s.grams.map { "\(Int($0))" } ?? "0")
                        .font(.system(size: 76, weight: .light)).tracking(-2).monospacedDigit()
                        .foregroundStyle(s.grams == nil ? .tertiary : .primary)
                    Text(hint).font(.body).foregroundStyle(.secondary)
                }
                HStack { Text("0"); Spacer(); Text("\(Int(range)) g") }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 212).offset(y: 112)
            }
            .frame(width: 280, height: 280)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Waage", "Scale"))
            .accessibilityValue(s.grams.map { L("\(Int($0)) Gramm", "\(Int($0)) grams") } ?? hint)

            HStack(spacing: 10) {
                Button { s.zero() } label: { Text(L("Null setzen", "Zero")).frame(minWidth: 110) }
                    .keyboardShortcut(.space, modifiers: []).disabled(s.state == .empty || s.state == .held)
                    .help(L("Leertaste", "Space"))
                Button { options.on.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L("Abgleichen", "Calibrate")).accessibilityLabel(L("Abgleichen", "Calibrate"))
                    .popover(isPresented: $options.on, arrowEdge: .bottom) { calibration }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
        .padding(.top, 34)
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Abgleichen", "Calibrate")).font(.headline)
            Text(L("Lege etwas auf, dessen Gewicht du kennst.", "Add something whose weight you know.")).foregroundStyle(.secondary)
            HStack {
                TextField(L("Gewicht", "Weight"), text: $s.known).textFieldStyle(.roundedBorder)
                Text("g").foregroundStyle(.secondary)
            }
            if !s.note.isEmpty { Text(s.note).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L("Zurücksetzen", "Reset")) { s.resetCalibration() }
                Spacer()
                Button(L("Abgleichen", "Calibrate")) { s.calibrate() }.buttonStyle(.borderedProminent).disabled(s.known.isEmpty)
            }
            Divider()
            Text(L("Schätzwert. Das Trackpad misst nur, solange ein Finger oder etwas Leitendes es berührt. Nichts Schweres, Hartes oder Nasses auflegen.",
                   "Estimate. The trackpad only measures while a finger or something conductive touches it. Nothing heavy, hard or wet."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 280)
    }
}

private struct ScaleRing: View, Animatable {
    var fraction: Double
    var animatableData: Double { get { fraction } set { fraction = newValue } }
    var body: some View {
        Canvas { c, size in
            let m = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 4
            func line(_ f: Double, _ from: CGFloat, _ to: CGFloat, _ color: Color, _ w: CGFloat) {
                let a = (135 + f * 270) * .pi / 180
                var p = Path()
                p.move(to: CGPoint(x: m.x + cos(a) * (r - from), y: m.y + sin(a) * (r - from)))
                p.addLine(to: CGPoint(x: m.x + cos(a) * (r - to), y: m.y + sin(a) * (r - to)))
                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            for i in 0...100 {
                let f = Double(i) / 100
                line(f, 4, i % 10 == 0 ? 20 : 14, .primary.opacity(f <= fraction && fraction > 0 ? 0.9 : i % 10 == 0 ? 0.35 : 0.18), 1.5)
            }
            line(fraction, 0, 28, .orange, 3)
        }
    }
}
