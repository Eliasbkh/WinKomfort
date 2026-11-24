// Dock anpassen wie in den Systemeinstellungen, nur direkter: Position, Größe, Vergrößerung – mit Live-Wirkung.
import SwiftUI

final class DockModel: ObservableObject {
    @Published var position: String
    @Published var size: Double
    @Published var magnify: Bool
    @Published var magSize: Double
    private var pending: DispatchWorkItem?

    init() {
        let d = UserDefaults(suiteName: "com.apple.dock")
        position = d?.string(forKey: "orientation") ?? "bottom"
        size = d?.double(forKey: "tilesize").nonZero ?? 48
        magnify = d?.bool(forKey: "magnification") ?? false
        magSize = d?.double(forKey: "largesize").nonZero ?? 80
    }

    // Erst schreiben, wenn der Regler kurz ruht – sonst startet das Dock bei jedem Schritt neu
    func apply() {
        pending?.cancel()
        let (p, s, m, ms) = (position, Int(size), magnify, Int(magSize))
        let w = DispatchWorkItem {
            sh(["/usr/bin/defaults", "write", "com.apple.dock", "orientation", "-string", p])
            sh(["/usr/bin/defaults", "write", "com.apple.dock", "tilesize", "-int", "\(s)"])
            sh(["/usr/bin/defaults", "write", "com.apple.dock", "magnification", "-bool", m ? "true" : "false"])
            sh(["/usr/bin/defaults", "write", "com.apple.dock", "largesize", "-int", "\(ms)"])
            sh(["/usr/bin/killall", "Dock"])
            // Dock-Hilfe kennt die Position nur beim Start → neu starten
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { DockReveal.stop(); DockReveal.start() } }
        }
        pending = w
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}

private extension Double { var nonZero: Double? { self == 0 ? nil : self } }

struct DockSettings: View {
    @StateObject private var m = DockModel()
    var body: some View {
        Picker(L("Position des Docks", "Dock position"), selection: $m.position) {
            Text(L("Links", "Left")).tag("left")
            Text(L("Unten", "Bottom")).tag("bottom")
            Text(L("Rechts", "Right")).tag("right")
        }
        .pickerStyle(.segmented)
        .onChange(of: m.position) { _, _ in m.apply() }
        LabeledContent(L("Größe", "Size")) {
            Slider(value: $m.size, in: 16...128, step: 4) { Text(L("Größe", "Size")) }.labelsHidden().frame(width: 220)
        }
        .onChange(of: m.size) { _, _ in m.apply() }
        Toggle(L("Vergrößern, wenn die Maus darüber ist", "Magnify on hover"), isOn: $m.magnify)
            .onChange(of: m.magnify) { _, _ in m.apply() }
        if m.magnify {
            LabeledContent(L("Vergrößerung", "Magnification")) {
                Slider(value: $m.magSize, in: max(m.size, 16)...128, step: 4) { Text(L("Vergrößerung", "Magnification")) }.labelsHidden().frame(width: 220)
            }
            .onChange(of: m.magSize) { _, _ in m.apply() }
        }
    }
}
