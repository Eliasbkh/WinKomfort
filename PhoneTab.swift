import SwiftUI

struct PhoneTab: View {
    @AppStorage("buds") private var buds = false
    @AppStorage("budsMic") private var mic = false
    @ObservedObject private var b = Buds.shared
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(L("Verbinden …", "Connect…")) { openRemote() }
                } label: {
                    Text(L("Handy als Fernbedienung und zweiter Bildschirm", "Phone as remote and second display"))
                    Text(L("QR-Code scannen, keine App nötig. Kürzel: \(HotAction.remote.current?.display ?? "–")", "Scan a QR code, no app needed. Shortcut: \(HotAction.remote.current?.display ?? "–")"))
                }
            } header: { Text(L("Handy", "Phone")) }
            Section {
                Toggle(isOn: $buds) {
                    Text(L("Galaxy Buds einbinden", "Integrate Galaxy Buds"))
                    Text(L("Akku und Geräuschsteuerung. macOS fragt einmal nach Bluetooth.", "Battery and noise control. macOS asks for Bluetooth once."))
                }
                .onChange(of: buds) { _, on in if on { b.connect() } }
                if buds {
                    LabeledContent(b.name ?? "Galaxy Buds") {
                        if let l = b.status.left, let r = b.status.right { Text(L("Links \(l) % · Rechts \(r) %", "Left \(l)% · Right \(r)%") + (b.status.box.map { L(" · Etui \($0) %", " · Case \($0)%") } ?? "")).monospacedDigit() }
                        else { Text(b.message.isEmpty ? "–" : b.message).foregroundStyle(.secondary) }
                    }
                    Picker(L("Geräuschsteuerung", "Noise control"), selection: Binding(get: { b.status.mode ?? -1 }, set: { b.setMode($0) })) {
                        if b.status.mode == nil { Text("–").tag(-1) }
                        ForEach(Buds.modes, id: \.0) { m in Text(L(m.1, m.2)).tag(m.0) }
                    }
                    .disabled(b.status.mode == nil)
                }
                Toggle(isOn: $mic) {
                    Text(L("Immer das Mac-Mikrofon benutzen", "Always use the Mac microphone"))
                    Text(L("Sonst schaltet macOS die Buds beim Sprechen in den dumpfen Telefon-Modus.", "Otherwise macOS switches the Buds to muffled phone quality while you talk."))
                }
                .onChange(of: mic) { _, _ in BudsMic.update() }
            } header: { Text("Galaxy Buds") }
        }
        .formStyle(.grouped)
        .onAppear { b.appear() }
        .onDisappear { b.disappear() }
    }
}

struct BudsMenu: View {
    @ObservedObject private var b = Buds.shared
    private var title: String {
        guard let l = b.status.left, let r = b.status.right else { return "Galaxy Buds" }
        return "Buds: \(l) % · \(r) %"
    }
    var body: some View {
        Menu(title) {
            ForEach(Buds.modes, id: \.0) { m in
                Button { b.setMode(m.0) } label: { if b.status.mode == m.0 { Image(systemName: "checkmark") }; Text(L(m.1, m.2)) }
            }
        }
    }
}
