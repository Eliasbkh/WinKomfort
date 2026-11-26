// Task-Manager: Speicher wie in der Aktivitätsanzeige (Footprint), Helfer der richtigen App zugeordnet, Aufräumen mit Rückfrage
import AppKit
import SwiftUI
import Darwin
import CoreAudio

struct TaskRow: Identifiable {
    let id: pid_t          // die verantwortliche App bzw. der Prozess
    let name: String
    let path: String
    let icon: NSImage?
    let cpu: Double
    let mem: Double
    let power: Double      // Prozessor-Energie in Milliwatt (macOS-Energiezähler je Prozess)
    let count: Int         // Prozesse insgesamt
    let kind: Kind
    enum Kind { case app, background, system }
}

struct MemoryInfo {
    var total = 0.0, used = 0.0, cached = 0.0, swap = 0.0, level = 1
    static func read() -> MemoryInfo {
        var m = MemoryInfo(), st = vm_statistics64(), n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &st) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) } }
        let page = Double(vm_kernel_page_size)
        m.total = Double(ProcessInfo.processInfo.physicalMemory)
        m.used = (Double(st.internal_page_count) - Double(st.purgeable_count) + Double(st.wire_count) + Double(st.compressor_page_count)) * page
        m.cached = (Double(st.external_page_count) + Double(st.purgeable_count)) * page
        var sw = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 { m.swap = Double(sw.xsu_used) }
        var lv: Int32 = 1
        size = 4
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lv, &size, nil, 0) == 0 { m.level = Int(lv) }
        return m
    }
}

// Alle lesbaren Prozesse messen (im Hintergrund, nur solange das Fenster offen ist)
actor TaskSampler {
    struct Proc: Sendable { let pid: pid_t, owner: pid_t, mem: Double, cpu: Double, power: Double }
    private var last: [pid_t: (ticks: UInt64, at: UInt64, nj: UInt64)] = [:]
    private static let responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
    func sample() -> [Proc] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * 4))
        guard n > 0 else { return [] }
        let now = mach_absolute_time()
        var seen: [pid_t: (ticks: UInt64, at: UInt64, nj: UInt64)] = [:]
        let secs = Self.seconds
        let out = pids.prefix(Int(n)).compactMap { p -> Proc? in
            var u = rusage_info_v6()
            guard p > 0, withUnsafeMutablePointer(to: &u, { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V6, $0) } }) == 0 else { return nil }
            let t = u.ri_user_time &+ u.ri_system_time // gleiche Einheit wie mach_absolute_time → Anteil direkt teilbar
            seen[p] = (t, now, u.ri_energy_nj)
            let cpu = last[p].map { o in now > o.at && t >= o.ticks ? Double(t - o.ticks) / Double(now - o.at) * 100 : 0 } ?? 0
            // Nanojoule pro Sekunde / 10⁶ = Milliwatt
            let mw = last[p].map { o in now > o.at && u.ri_energy_nj >= o.nj ? Double(u.ri_energy_nj - o.nj) / (Double(now - o.at) * secs) / 1e6 : 0 } ?? 0
            let r = Self.responsible?(p) ?? p
            return Proc(pid: p, owner: r > 0 ? r : p, mem: Double(u.ri_phys_footprint), cpu: cpu, power: mw)
        }
        last = seen
        return out
    }
    // Sekunden je mach_absolute_time-Tick
    static let seconds: Double = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) / 1e9 }()
    nonisolated static func path(_ p: pid_t) -> String {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(p, &b, 4096) > 0 ? String(cString: b) : ""
    }
}

@MainActor final class TaskModel: ObservableObject {
    static let shared = TaskModel()
    enum Tab { case apps, background, all }
    @Published var rows: [TaskRow] = []
    @Published var memory = MemoryInfo()
    @Published var selection: Set<pid_t> = []
    @Published var sortOrder = [KeyPathComparator(\TaskRow.mem, order: .reverse)]
    @Published var tab = Tab.apps { didSet { selection = [] } }
    @Published var query = ""
    @Published var cleaning = false
    @Published var candidates: [CleanItem] = []
    private let sampler = TaskSampler()
    private var timer: Timer?
    private var busy = false
    private var icons: [String: NSImage] = [:]

    var sorted: [TaskRow] {
        rows.filter { r in (tab == .all || r.kind == (tab == .apps ? .app : .background)) && (query.isEmpty || r.name.localizedCaseInsensitiveContains(query)) }.sorted(using: sortOrder)
    }
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { TaskModel.shared.refresh() } }
        timer?.tolerance = 0.5
    }
    func stop() { timer?.invalidate(); timer = nil; cleaning = false; query = "" }

    func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            let procs = await sampler.sample()
            apply(procs)
            busy = false
        }
    }
    private func apply(_ procs: [TaskSampler.Proc]) {
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }) { a, _ in a }
        var sum: [pid_t: (mem: Double, cpu: Double, power: Double, n: Int)] = [:]
        for p in procs {
            let s = sum[p.owner] ?? (0, 0, 0, 0)
            sum[p.owner] = (s.mem + p.mem, s.cpu + p.cpu, s.power + p.power, s.n + 1)
        }
        rows = sum.map { pid, s in
            let app = apps[pid]
            let exe = TaskSampler.path(pid), path = app?.bundleURL?.path ?? exe
            let system = exe.isEmpty || ["/System/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"].contains { exe.hasPrefix($0) }
            let kind: TaskRow.Kind = app?.activationPolicy == .regular ? .app : system || pid == getpid() ? .system : .background
            let name = app?.localizedName ?? Self.name(exe, pid)
            if icons[path] == nil, !path.isEmpty, kind != .system || app != nil { icons[path] = app?.icon ?? NSWorkspace.shared.icon(forFile: path) }
            return TaskRow(id: pid, name: name, path: path, icon: icons[path], cpu: s.cpu, mem: s.mem, power: s.power, count: s.n, kind: kind)
        }
        memory = MemoryInfo.read()
        let alive = Set(rows.map(\.id))
        if !selection.isSubset(of: alive) { selection.formIntersection(alive) }
    }
    // Bei node, python & Co. steht sonst nur der Programmname da – das Skript sagt, was es ist
    private static func name(_ exe: String, _ pid: pid_t) -> String {
        let base = (exe as NSString).lastPathComponent
        return base.isEmpty ? "PID \(pid)" : base
    }

    // Nur eigene Prozesse; Systemdienste nie
    func canEnd(_ r: TaskRow) -> Bool { r.kind != .system && r.id != getpid() && NSRunningApplication(processIdentifier: r.id)?.bundleIdentifier != "com.apple.finder" }
    func end(_ ids: Set<pid_t>, force: Bool) {
        for r in rows where ids.contains(r.id) && canEnd(r) {
            if let a = NSRunningApplication(processIdentifier: r.id) { _ = force ? a.forceTerminate() : a.terminate() }
            else if TaskSampler.path(r.id) == r.path { kill(r.id, force ? SIGKILL : SIGTERM) } // Prozessnummer inzwischen neu vergeben? Dann nichts tun
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { TaskModel.shared.refresh() } }
    }
    // Beenden und neu öffnen – hilft gegen Apps, die mit der Zeit immer mehr Speicher belegen
    func restart(_ r: TaskRow) {
        guard canEnd(r), let a = NSRunningApplication(processIdentifier: r.id), let url = a.bundleURL else { return }
        a.terminate()
        func wait(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if a.isTerminated { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                else if n > 0 { wait(n - 1) } // fragt vielleicht noch nach dem Sichern
            }
        }
        wait(60)
    }

    // MARK: Aufräumen
    struct CleanItem: Identifiable { let row: TaskRow; let reason: String; var on: Bool; var id: pid_t { row.id } }
    func suggest() {
        let playing = Audio.playing()
        candidates = rows.filter(canEnd).compactMap { r in
            let app = NSRunningApplication(processIdentifier: r.id)
            guard app?.isActive != true, !playing.contains(r.id), !AutoQuit.isKept(app?.bundleIdentifier) else { return nil }
            if r.kind == .app {
                let idle = AppUsage.shared.idleMinutes(r.id)
                if idle >= 30 { return CleanItem(row: r, reason: L("seit \(Self.ago(idle)) nicht benutzt", "unused for \(Self.ago(idle))"), on: !AutoQuit.careful(app?.bundleIdentifier)) }
                return r.mem > 1e9 ? CleanItem(row: r, reason: L("belegt sehr viel Speicher – Neustart hilft oft (Rechtsklick)", "uses a lot of memory – restarting often helps (right-click)"), on: false) : nil
            }
            if AutoQuit.careful(r.name) { return nil } // z. B. laufende Claude-Sitzungen
            if r.mem > 1e9 { return CleanItem(row: r, reason: L("Hintergrund, belegt sehr viel Speicher", "background, uses a lot of memory"), on: false) }
            if r.cpu > 15 { return CleanItem(row: r, reason: L("Hintergrund, braucht viel CPU", "background, uses a lot of CPU"), on: false) }
            return r.mem > 2e8 ? CleanItem(row: r, reason: L("Hintergrund", "background"), on: false) : nil
        }.sorted { ($0.on ? 1 : 0, $0.row.mem) > ($1.on ? 1 : 0, $1.row.mem) }
        cleaning = true
    }
    func clean() {
        end(Set(candidates.filter(\.on).map(\.id)), force: false)
        cleaning = false
    }
    private static func ago(_ m: Int) -> String { m < 60 ? "\(m) min" : m < 1440 ? "\(m / 60) h" : L("\(m / 1440) Tagen", "\(m / 1440) days") }
}

// Welche Apps geben gerade Ton aus?
enum Audio {
    static func playing() -> Set<pid_t> {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &n) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(n) / 4)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &n, &ids) == noErr else { return [] }
        func get(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0, n = UInt32(4)
            AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v)
            return v
        }
        let resp = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
        var out: Set<pid_t> = []
        for i in ids where get(i, kAudioProcessPropertyIsRunning) != 0 { // Ton aus oder Mikrofon an
            let p = pid_t(bitPattern: get(i, kAudioProcessPropertyPID))
            out.insert(p)
            if let r = resp?(p) { out.insert(r) }
        }
        return out
    }
}

// Unbenutzte Apps nach einer Weile von selbst beenden (aus, bis du es einschaltest)
@MainActor enum AutoQuit {
    private static var timer: Timer?
    static var minutes: Int { UserDefaults.standard.integer(forKey: "autoQuitMinutes") }
    static var kept: [String] { UserDefaults.standard.stringArray(forKey: "autoQuitKeep") ?? [] }
    static func isKept(_ id: String?) -> Bool { id.map(kept.contains) ?? false }
    static func toggleKeep(_ id: String) {
        UserDefaults.standard.set(kept.contains(id) ? kept.filter { $0 != id } : kept + [id], forKey: "autoQuitKeep")
    }
    // Hier läuft oft etwas im Hintergrund weiter: nie von selbst, nie vorausgewählt
    static func careful(_ id: String?) -> Bool {
        guard let id else { return true }
        return ["terminal", "iterm", "kitty", "ghostty", "warp", "claude", "xcode", "vscode", "jetbrains", "cursor", "docker", "parallels", "virtualbox", "utm", "vmware", "steam", "minecraft", "modrinth", "obs", "handbrake",
                "ffmpeg", "final-cut", "imovie", "garageband", "logic", "davinci", "blender", "transmission", "qbittorrent", "onedrive", "dropbox", "whatsapp", "teams", "zoom", "discord", "facetime", "activitymonitor"]
            .contains { id.lowercased().contains($0) }
    }
    static func update() {
        timer?.invalidate()
        timer = nil
        guard minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { check() } }
        timer?.tolerance = 20
    }
    private static func check() {
        let idle = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isActive && $0.processIdentifier != getpid() && $0.bundleIdentifier != "com.apple.finder"
                && !isKept($0.bundleIdentifier) && !careful($0.bundleIdentifier) && AppUsage.shared.idleMinutes($0.processIdentifier) >= minutes
        }
        guard !idle.isEmpty else { return }
        let playing = Audio.playing()
        for a in idle where !playing.contains(a.processIdentifier) {
            a.terminate() // normales Beenden: ungesicherte Dokumente fragen nach
            AppUsage.shared.touch(a.processIdentifier) // fragt sie nach, nicht jede Minute erneut drängeln
        }
    }
}

struct TaskView: View {
    @ObservedObject var m = TaskModel.shared
    @AppStorage("autoQuitMinutes") private var autoQuit = 0
    private func size(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L("Anzeige", "View"), selection: $m.tab) {
                    Text(L("Apps", "Apps")).tag(TaskModel.Tab.apps)
                    Text(L("Hintergrund", "Background")).tag(TaskModel.Tab.background)
                    Text(L("Alle", "All")).tag(TaskModel.Tab.all)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                TextField(L("Suchen", "Search"), text: $m.query).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .padding(10)
            memory.padding(.horizontal, 12).padding(.bottom, 10)
            Table(m.sorted, selection: $m.selection, sortOrder: $m.sortOrder) {
                TableColumn("Name", value: \.name) { r in
                    HStack {
                        if let i = r.icon { Image(nsImage: i).resizable().frame(width: 18, height: 18).accessibilityHidden(true) }
                        Text(r.name).lineLimit(1)
                        if r.count > 1 { Text("\(r.count)").font(.caption).foregroundStyle(.secondary).help(L("\(r.count) Prozesse", "\(r.count) processes")) }
                    }
                }
                TableColumn("CPU", value: \.cpu) { r in Text(r.cpu.formatted(.number.precision(.fractionLength(1))) + " %").monospacedDigit() }.width(70)
                TableColumn(L("Speicher", "Memory"), value: \.mem) { r in Text(size(r.mem)).monospacedDigit().fontWeight(r.mem > 1e9 ? .semibold : .regular) }.width(100)
                TableColumn(L("Energie", "Energy"), value: \.power) { r in Text(Battery.watts(r.power)).monospacedDigit().foregroundStyle(r.power >= 1000 ? Color.red : r.power >= 300 ? Color.orange : .primary).fontWeight(r.power >= 300 ? .semibold : .regular) }.width(80)
            }
            .contextMenu(forSelectionType: pid_t.self) { ids in menu(ids) }
            HStack {
                Picker(L("Unbenutzte Apps beenden", "Quit unused apps"), selection: $autoQuit) {
                    Text(L("nie", "never")).tag(0)
                    ForEach([1, 2, 4, 8], id: \.self) { Text(L("nach \($0) h", "after \($0) h")).tag($0 * 60) }
                }
                .fixedSize()
                .help(L("Nicht bei Ton, Terminal, Claude, Nachrichten-Apps und Apps auf deiner Ausnahmeliste.", "Never for audio, terminals, Claude, messengers and apps on your exception list."))
                .onChange(of: autoQuit) { _, _ in AutoQuit.update() }
                Spacer()
                Button(L("Aufräumen …", "Clean up…")) { m.suggest() }
                Button(L("Task beenden", "End task")) { m.end(m.selection, force: false) }
                    .keyboardShortcut(.defaultAction).disabled(!m.rows.contains { m.selection.contains($0.id) && m.canEnd($0) })
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 480)
        .sheet(isPresented: $m.cleaning) { cleanSheet }
    }

    @ViewBuilder private func menu(_ ids: Set<pid_t>) -> some View {
        let rows = m.rows.filter { ids.contains($0.id) }, ok = rows.filter(m.canEnd)
        Button(L("Task beenden", "End task")) { m.end(ids, force: false) }.disabled(ok.isEmpty)
        Button(L("Sofort beenden (erzwingen)", "Force quit")) { m.end(ids, force: true) }.disabled(ok.isEmpty)
        if rows.count == 1, let r = rows.first {
            if r.kind == .app { Button(L("Neu starten", "Restart")) { m.restart(r) }.disabled(ok.isEmpty) }
            if let id = NSRunningApplication(processIdentifier: r.id)?.bundleIdentifier, r.kind != .system {
                Button(AutoQuit.isKept(id) ? L("Aus Ausnahmen entfernen", "Remove exception") : L("Nie automatisch beenden", "Never quit automatically")) { AutoQuit.toggleKeep(id) }
            }
            Divider()
            if !r.path.isEmpty { Button(L("Im Explorer zeigen", "Show in Explorer")) { FolderHandler.open([URL(fileURLWithPath: r.path)], select: true) } }
            Button(L("Aktivitätsanzeige öffnen", "Open Activity Monitor")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        }
    }

    private var memory: some View {
        let i = m.memory, total = max(i.total, 1)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    Rectangle().fill(i.level >= 4 ? Color.red : i.level >= 2 ? .orange : .accentColor).frame(width: g.size.width * min(i.used / total, 1))
                    Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: g.size.width * min(i.cached / total, max(0, 1 - i.used / total)))
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 10).clipShape(Capsule()).accessibilityHidden(true)
            HStack(spacing: 14) {
                Text(L("Belegt \(size(i.used))", "Used \(size(i.used))")).fontWeight(.medium)
                Text(L("Zwischenspeicher \(size(i.cached))", "Cache \(size(i.cached))")).foregroundStyle(.secondary)
                    .help(L("Kopien von Dateien. macOS gibt sie sofort frei, wenn eine App Speicher braucht.", "Copies of files. macOS frees them instantly when an app needs memory."))
                if i.swap > 1e7 { Text(L("Ausgelagert \(size(i.swap))", "Swap \(size(i.swap))")).foregroundStyle(.secondary) }
                Spacer()
                Text(i.level >= 4 ? L("Speicher knapp", "Memory critical") : i.level >= 2 ? L("Speicher wird eng", "Memory under pressure") : L("Genug Speicher frei", "Plenty of memory"))
                    .foregroundStyle(i.level >= 2 ? AnyShapeStyle(i.level >= 4 ? Color.red : .orange) : AnyShapeStyle(.secondary))
            }
            .font(.callout).monospacedDigit()
        }
    }

    private var cleanSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Aufräumen", "Clean up")).font(.title3.weight(.semibold))
            if m.candidates.isEmpty { Text(L("Nichts Unnötiges gefunden.", "Nothing unnecessary found.")).foregroundStyle(.secondary) }
            else {
                Text(L("Diese Programme werden normal beendet. Ungesicherte Dokumente fragen nach.", "These programs quit normally. Unsaved documents will ask.")).foregroundStyle(.secondary)
                List($m.candidates) { $c in
                    Toggle(isOn: $c.on) {
                        HStack {
                            if let i = c.row.icon { Image(nsImage: i).resizable().frame(width: 20, height: 20).accessibilityHidden(true) }
                            VStack(alignment: .leading, spacing: 1) { Text(c.row.name); Text(c.reason).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(size(c.row.mem)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 260)
            }
            HStack {
                let on = m.candidates.filter(\.on)
                if !on.isEmpty { Text(L("Gibt etwa \(size(on.reduce(0) { $0 + $1.row.mem })) frei", "Frees about \(size(on.reduce(0) { $0 + $1.row.mem }))")).foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                Button(L("Abbrechen", "Cancel"), role: .cancel) { m.cleaning = false }.keyboardShortcut(.cancelAction)
                Button(L("\(on.count) beenden", "Quit \(on.count)")) { m.clean() }.keyboardShortcut(.defaultAction).disabled(on.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}

@MainActor func openTaskManager() {
    showWindow("tasks", "Task-Manager", onClose: { MainActor.assumeIsolated { TaskModel.shared.stop() } }) { TaskView() }
    TaskModel.shared.start()
}
