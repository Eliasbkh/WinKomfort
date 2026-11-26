// Akku-Optimierer: misst, welche Apps wirklich Energie ziehen, drosselt sie nur im Hintergrund und macht alles rückgängig
import AppKit
import Darwin
import FoundationModels
import IOKit.ps
import SwiftUI

@MainActor final class Battery: ObservableObject {
    static let shared = Battery()
    struct Step: Identifiable { let id = UUID(); let time = Date(); let text: String }
    @Published var apps: [BatteryLogic.AppUse] = []
    @Published var measuring = false
    @Published var charge: Int?
    @Published var onPower = false
    @Published var minutesLeft: Int?
    @Published var advice: String?
    @Published var thinking = false
    @Published var steps: [Step] = []
    // Apps (Paketpfade), die im Hintergrund sparen sollen – bleibt über Neustarts erhalten
    @Published private(set) var saving: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "batterySaving") ?? []) {
        didSet { UserDefaults.standard.set(Array(saving), forKey: "batterySaving") }
    }
    private var tokens: [NSObjectProtocol] = []
    private var tick: Timer?, refresh: Timer?
    private var slowed: Set<Int32> = []

    static func open() {
        let first = windows["battery"] == nil
        showWindow("battery", "Akku", onClose: { MainActor.assumeIsolated { Battery.shared.refresh?.invalidate(); Battery.shared.refresh = nil } }) { BatteryView() }
        windows["battery"]?.title = L("Akku", "Battery")
        if first { windows["battery"]?.setContentSize(NSSize(width: 720, height: 640)); windows["battery"]?.center(); windows["battery"]?.setFrameAutosaveName("WinKomfortBattery") }
        shared.measure()
        shared.refresh?.invalidate()
        shared.refresh = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in MainActor.assumeIsolated { Battery.shared.measure() } }
    }

    // Beim Start: falls WinKomfort vorher abgestürzt ist, erst alles freigeben, dann sauber neu anwenden
    func setup() {
        for b in saving { set(b, slow: false) }
        guard tokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            tokens.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Battery.shared.apply() } })
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Battery.shared.releaseAll(log: false) } }
        apply()
    }

    // MARK: Messen
    func measure() {
        guard !measuring else { return }
        measuring = true
        readBattery()
        Task.detached(priority: .utility) {
            // macOS-Energiezähler je Prozess, zweimal im Abstand von 2 s gelesen → Milliwatt (kein Hilfsprogramm nötig)
            let a = Battery.counters(); try? await Task.sleep(for: .seconds(2)); let b = Battery.counters()
            let dt = Double(b.at &- a.at) * TaskSampler.seconds
            let samples = b.list.compactMap { pid, v -> BatteryLogic.Sample? in
                guard let o = a.list[pid], v.nj >= o.nj, v.t >= o.t, dt > 0 else { return nil }
                return BatteryLogic.Sample(pid: pid, name: (Battery.path(pid) as NSString?)?.lastPathComponent ?? "PID \(pid)", cpu: Double(v.t - o.t) * TaskSampler.seconds / dt * 100, power: Double(v.nj - o.nj) / dt / 1e6)
            }
            let g = BatteryLogic.group(samples, path: Battery.path)
            await MainActor.run { let s = Battery.shared; s.apps = Array(g.prefix(25)); s.measuring = false }
        }
    }
    private func readBattery() {
        guard let i = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let l = IOPSCopyPowerSourcesList(i)?.takeRetainedValue() as? [CFTypeRef], let p = l.first,
              let d = IOPSGetPowerSourceDescription(i, p)?.takeUnretainedValue() as? [String: Any] else { charge = nil; return }
        charge = d[kIOPSCurrentCapacityKey] as? Int
        onPower = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        minutesLeft = (d[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 && !onPower ? $0 : nil }
    }
    nonisolated static func counters() -> (at: UInt64, list: [Int32: (nj: UInt64, t: UInt64)]) {
        var pids = [Int32](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * 4)), now = mach_absolute_time()
        var out: [Int32: (nj: UInt64, t: UInt64)] = [:]
        for p in pids.prefix(Int(max(n, 0))) where p > 0 {
            var u = rusage_info_v6()
            if withUnsafeMutablePointer(to: &u, { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V6, $0) } }) == 0 { out[p] = (u.ri_energy_nj, u.ri_user_time &+ u.ri_system_time) }
        }
        return (now, out)
    }
    static func watts(_ mw: Double) -> String { BatteryLogic.watts(mw) }
    nonisolated static func path(_ pid: Int32) -> String? {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &b, UInt32(b.count)) > 0 ? String(cString: b) : nil
    }
    nonisolated static func pids(of bundle: String) -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var all = [Int32](repeating: 0, count: Int(n) + 64)
        let c = proc_listallpids(&all, Int32(all.count * MemoryLayout<Int32>.size))
        return all.prefix(Int(max(c, 0))).filter { $0 > 0 && (path($0)?.hasPrefix(bundle + "/") ?? false) }
    }

    // MARK: Sparen im Hintergrund (macOS-Hintergrundstufe: sparsame Kerne, weniger Rechenzeit; sofort umkehrbar)
    func isSaving(_ a: BatteryLogic.AppUse) -> Bool { saving.contains(a.id) }
    func toggle(_ a: BatteryLogic.AppUse) {
        if saving.contains(a.id) {
            saving.remove(a.id); set(a.id, slow: false)
            steps.insert(Step(text: L("\(a.name): Sparen beendet, läuft wieder normal", "\(a.name): saving stopped, running normally")), at: 0)
        } else {
            saving.insert(a.id)
            steps.insert(Step(text: L("\(a.name): spart jetzt im Hintergrund. Sobald du sie benutzt, läuft sie mit voller Leistung.", "\(a.name): now saves energy in the background. Full speed as soon as you use it.")), at: 0)
            setup(); apply()
        }
    }
    func releaseAll(log: Bool = true) {
        for b in saving { set(b, slow: false) }
        if log, !saving.isEmpty { steps.insert(Step(text: L("Alles rückgängig gemacht, alle Apps laufen normal", "Everything undone, all apps run normally")), at: 0) }
        if log { saving = [] }
    }
    // Vordergrund-App immer frei, alle anderen markierten drosseln; neue Tabs/Hilfsprozesse alle 20 s mitnehmen
    func apply() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        for b in saving { set(b, slow: b != front) }
        if !saving.isEmpty, tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { Battery.shared.apply() } }
            tick?.tolerance = 5
        } else if saving.isEmpty { tick?.invalidate(); tick = nil }
    }
    private func set(_ bundle: String, slow: Bool) {
        for pid in Self.pids(of: bundle) {
            if slow { if setpriority(PRIO_DARWIN_PROCESS, UInt32(pid), PRIO_DARWIN_BG) == 0 { slowed.insert(pid) } }
            else { _ = setpriority(PRIO_DARWIN_PROCESS, UInt32(pid), 0); slowed.remove(pid) }
        }
    }
    func quit(_ a: BatteryLogic.AppUse) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == a.id }) else { return }
        let al = NSAlert(); al.messageText = L("\(a.name) beenden?", "Quit \(a.name)?")
        al.informativeText = L("Die App wird normal beendet und fragt bei Ungesichertem nach. Öffnen kannst du sie jederzeit wieder.", "The app quits normally and asks about unsaved work. You can reopen it anytime.")
        al.addButton(withTitle: L("Beenden", "Quit")); al.addButton(withTitle: L("Abbrechen", "Cancel"))
        guard al.runModal() == .alertFirstButtonReturn else { return }
        app.terminate()
        steps.insert(Step(text: L("\(a.name) beendet (über das Dock wieder öffnen)", "\(a.name) quit (reopen from the Dock)")), at: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { Battery.shared.measure() } }
    }

    // MARK: KI: in normalen Worten erklären, was zieht und was hilft
    func explain() {
        guard AI.ready(), !apps.isEmpty else { return }
        thinking = true
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        let table = apps.prefix(12).map { a in "\(a.name): \(BatteryLogic.watts(a.power)), CPU \(Int(a.cpu.rounded())) %" + (a.isApp ? (a.id == front ? ", gerade im Vordergrund" : ", im Hintergrund") : ", Systemdienst") + (saving.contains(a.id) ? ", spart schon" : "") }.joined(separator: "\n")
        let state = (charge.map { "Akku \($0) %" } ?? "") + (onPower ? ", am Netzteil" : "") + (minutesLeft.map { ", reicht noch etwa \($0 / 60) h \($0 % 60) min" } ?? "")
        Task {
            defer { thinking = false }
            guard #available(macOS 26.0, *) else { return }
            let s = LanguageModelSession(instructions: "Du hilfst einem Schüler, am Mac Akku zu sparen. Antworte auf Deutsch, kurz, in 3 bis 6 Stichpunkten. Nenne die größten Verbraucher, warum sie vermutlich viel ziehen (z. B. Browser: viele Tabs, Videos, Animationen; WindowServer: Bildschirm, Animationen, externe Monitore; mds/mdworker: Spotlight indiziert gerade) und was hilft. WinKomfort kann Apps im Hintergrund sparen lassen (volle Leistung, sobald man sie benutzt) oder beenden. Erfinde keine Zahlen, nutze nur die Messung.")
            advice = try? await s.respond(to: "Messung (Prozessor-Leistung je App, über 1 W ist viel, unter 50 mW kaum etwas):\n\(table)\n\(state)").content
        }
    }
}

// MARK: Oberfläche
struct BatteryView: View {
    @ObservedObject var b = Battery.shared
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: b.onPower ? "battery.100.bolt" : "battery.75percent").font(.system(size: 28)).foregroundStyle(b.onPower ? .green : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.charge.map { "\($0) %" } ?? L("Kein Akku", "No battery")).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(b.onPower ? L("Am Netzteil", "On power") : b.minutesLeft.map { L("reicht noch etwa \($0 / 60) h \($0 % 60) min", "about \($0 / 60) h \($0 % 60) min left") } ?? L("im Akkubetrieb", "on battery")).foregroundStyle(.secondary)
                }
                Spacer()
                if b.measuring { ProgressView().controlSize(.small) }
                Button { b.measure() } label: { Label(L("Neu messen", "Measure"), systemImage: "arrow.clockwise") }.disabled(b.measuring)
                if Assistant.available { Button { b.explain() } label: { Label(L("KI-Einschätzung", "AI advice"), systemImage: "sparkles") }.disabled(b.thinking || b.apps.isEmpty) }
            }
            .padding(16)
            if b.thinking || b.advice != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Image(systemName: "sparkles").foregroundStyle(Color.accentColor); Text(L("Einschätzung", "Advice")).font(.headline); Spacer(); if b.thinking { ProgressView().controlSize(.small) } else { Button { b.advice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(L("Schließen", "Close")) } }
                    if let a = b.advice { Text(.init(a)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            List {
                Section(L("Was gerade Energie zieht (Prozessor)", "What uses energy now (processor)")) {
                    if b.apps.isEmpty { Text(b.measuring ? L("Messe ein paar Sekunden …", "Measuring for a few seconds…") : L("Noch keine Messung", "No measurement yet")).foregroundStyle(.secondary) }
                    ForEach(b.apps) { a in row(a) }
                }
                if !b.steps.isEmpty || !b.saving.isEmpty {
                    Section {
                        ForEach(b.steps) { s in HStack(alignment: .top) { Text(s.time.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary); Text(s.text) } }
                    } header: {
                        HStack { Text(L("Was WinKomfort gemacht hat", "What WinKomfort did")); Spacer(); if !b.saving.isEmpty { Button(L("Alles rückgängig", "Undo all")) { b.releaseAll() }.buttonStyle(.link) } }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }
    private func row(_ a: BatteryLogic.AppUse) -> some View {
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path == a.id, lvl = BatteryLogic.level(a.power), save = b.isSaving(a)
        let mine = a.id == Bundle.main.bundlePath, control = a.isApp && !mine // WinKomfort selbst nicht drosseln oder beenden
        let suggest = control && BatteryLogic.worthThrottling(a, front: front) && !save
        return HStack(spacing: 10) {
            Group { if a.id.hasSuffix(".app") { Image(nsImage: NSWorkspace.shared.icon(forFile: a.id)).resizable() } else { Image(systemName: "gearshape.2").foregroundStyle(.secondary) } }.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.name).fontWeight(.medium).lineLimit(1)
                    if save { Text(L("spart im Hintergrund", "saving in background")).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1).background(Color.green.opacity(0.18), in: Capsule()) }
                    else if suggest { Text(L("Vorschlag: sparen", "Suggestion: save")).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1).background(Color.orange.opacity(0.2), in: Capsule()) }
                }
                Text(mine ? L("WinKomfort selbst, gerade beim Messen", "WinKomfort itself, measuring right now") : a.isApp ? (front ? L("gerade im Vordergrund", "in front right now") : L("im Hintergrund", "in the background")) + (a.pids.count > 1 ? L(" · \(a.pids.count) Prozesse", " · \(a.pids.count) processes") : "") : L("Teil von macOS, wird nicht angefasst", "Part of macOS, left alone"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Balken: Energiewert, Farbe nur bei hohem Verbrauch
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(lvl >= 3 ? Color.red : lvl == 2 ? Color.orange : Color.secondary.opacity(0.6)).frame(width: max(4, min(1, a.power / 2000) * 90))
            }
            .frame(width: 90, height: 6)
            .accessibilityLabel(L("Leistung \(BatteryLogic.watts(a.power))", "Power \(BatteryLogic.watts(a.power))"))
            Text(BatteryLogic.watts(a.power)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            if control {
                Toggle(L("Sparen", "Save"), isOn: Binding(get: { save }, set: { _ in b.toggle(a) })).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel(L("\(a.name) im Hintergrund sparen", "Save energy for \(a.name) in the background"))
                    .help(L("Im Hintergrund auf sparsamen Kernen laufen lassen. Sobald du die App benutzt, läuft sie mit voller Leistung.", "Run on efficiency cores while in the background. Full speed as soon as you use it."))
                Button { b.quit(a) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).disabled(front).help(L("Beenden", "Quit")).accessibilityLabel(L("\(a.name) beenden", "Quit \(a.name)"))
            } else { Color.clear.frame(width: 64, height: 1) } // Spalten bleiben bündig
        }
        .padding(.vertical, 2)
    }
}
