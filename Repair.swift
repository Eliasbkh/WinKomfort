// Selbstreparatur: Nach dem Aufwachen, nach einem Bildschirmwechsel oder auf Knopfdruck alle Dienste neu aufsetzen.
// macOS verwirft gelegentlich Event-Taps und Tastenkürzel (Ruhezustand, Updates, Rechteänderungen) – das fängt das hier ab.
import AppKit
import SwiftUI

@MainActor enum Repair {
    private static var tokens: [NSObjectProtocol] = []

    static func setup() {
        guard tokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                // kurz warten, bis macOS nach dem Aufwachen wieder alles bereit hat
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { Repair.run(quiet: true) } }
            })
        }
    }

    // Alles still neu starten – jeder Dienst prüft selbst, ob er eingeschaltet ist
    static func run(quiet: Bool) {
        HotKey.registerAll()
        if UserDefaults.standard.bool(forKey: "startMenu") { StartKey.stop(); StartKey.start() }
        FinderCut.stop(); FinderCut.start()
        if let drag = features.first(where: { $0.id == "drag" }), isOn(drag) { TapDragFix.stop(); TapDragFix.start() }
        MouseScroll.stop(); MouseScroll.update()
        DockReveal.stop(); DockReveal.start()
        ClipHistory.shared.start()
        SystemMonitor.shared.update()
        if UserDefaults.standard.bool(forKey: "closeQuits") { CloseWatcher.shared.setEnabled(true) }
        wkLog("Selbstreparatur (\(quiet ? "automatisch" : "von Hand")): Kürzel-Fehler \(HotKey.failed.count)")
        if !quiet { Toast.show(L("Alle Dienste neu gestartet", "All services restarted"), symbol: "wrench.and.screwdriver") }
    }

    struct Check: Identifiable { let id: String; let ok: Bool; let text: String; let fix: String? }

    static func checks() -> [Check] {
        var c: [Check] = []
        c.append(Check(id: "ax", ok: AXIsProcessTrusted(), text: L("Bedienungshilfen erlaubt", "Accessibility allowed"),
                       fix: L("Systemeinstellungen › Datenschutz › Bedienungshilfen › WinKomfort einschalten", "System Settings › Privacy › Accessibility › turn on WinKomfort")))
        c.append(Check(id: "screen", ok: CGPreflightScreenCaptureAccess(), text: L("Bildschirmaufnahme erlaubt (Vorschaubilder)", "Screen Recording allowed (previews)"),
                       fix: L("Nur für Vorschaubilder im Fenster-Umschalter nötig", "Only needed for window switcher previews")))
        let failed = HotKey.failed.map { tr($0.title) }
        c.append(Check(id: "keys", ok: failed.isEmpty, text: failed.isEmpty ? L("Alle Tastenkürzel aktiv", "All shortcuts active") : L("Belegt: \(failed.joined(separator: ", "))", "In use: \(failed.joined(separator: ", "))"),
                       fix: L("Andere App nutzt das Kürzel – unter Tastenkürzel ein anderes wählen", "Another app uses it – pick another under Shortcuts")))
        c.append(Check(id: "login", ok: SMAppServiceStatusIsEnabled(), text: L("Startet bei der Anmeldung", "Opens at login"),
                       fix: L("Unter Allgemein einschalten", "Turn on under General")))
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("de.winkomfort.app/OneNote")
        let mb = (FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +) ?? 0) / 1_000_000
        c.append(Check(id: "cache", ok: true, text: L("OneNote-Zwischenspeicher: \(mb) MB", "OneNote cache: \(mb) MB"), fix: nil))
        return c
    }

    static func clearOneNoteCache() {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("de.winkomfort.app/OneNote")
        try? FileManager.default.removeItem(at: cache)
        Toast.show(L("OneNote-Zwischenspeicher geleert", "OneNote cache cleared"), symbol: "trash")
    }
}

import ServiceManagement
func SMAppServiceStatusIsEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

final class RepairModel: ObservableObject { @Published var tick = 0 }

struct RepairSection: View {
    @StateObject private var m = RepairModel()
    var body: some View {
        let checks = { _ = m.tick; return Repair.checks() }()
        Section {
            ForEach(checks) { c in
                HStack(alignment: .top) {
                    Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(c.ok ? Color.green : Color.orange).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.text)
                        if !c.ok, let f = c.fix { Text(f).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Button(L("Reparieren", "Repair")) { Repair.run(quiet: false); m.tick += 1 }
                Button(L("Protokoll zeigen", "Show log")) {
                    let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/WinKomfort.log")
                    if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) } else { Toast.show(L("Noch kein Protokoll", "No log yet"), symbol: "doc.text") }
                }
                Button(L("OneNote-Zwischenspeicher leeren", "Clear OneNote cache")) { Repair.clearOneNoteCache(); m.tick += 1 }
            }
        } header: { Text(L("Selbsttest", "Self-check")) } footer: {
            Text(L("WinKomfort repariert sich nach dem Aufwachen automatisch. Der Knopf macht dasselbe sofort.", "WinKomfort repairs itself automatically after waking. The button does the same right away."))
        }
        .onAppear { m.tick += 1 }
    }
}
