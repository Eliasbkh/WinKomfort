// Eigene Tastenkürzel: Apps, Dateien/Ordner, Webseiten, Kurzbefehle und Befehle starten
import AppKit
import SwiftUI

@MainActor final class Launcher: ObservableObject {
    static let shared = Launcher()
    @Published var keys: [LaunchKey] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(keys), forKey: "launchKeys") }
    }
    @Published var appleShortcuts: [String] = []
    init() { keys = UserDefaults.standard.data(forKey: "launchKeys").flatMap { try? JSONDecoder().decode([LaunchKey].self, from: $0) } ?? [] }

    func title(_ k: LaunchKey) -> String {
        switch k.kind {
        case .app: FileManager.default.displayName(atPath: k.target).replacingOccurrences(of: ".app", with: "")
        case .file: (k.target as NSString).lastPathComponent
        case .web, .shortcut, .command: k.target
        }
    }
    func icon(_ k: LaunchKey) -> NSImage {
        switch k.kind {
        case .app, .file: NSWorkspace.shared.icon(forFile: k.target)
        case .web: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        case .shortcut: NSImage(systemSymbolName: "square.2.layers.3d", accessibilityDescription: nil)!
        case .command: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
        }
    }

    func perform(_ k: LaunchKey) {
        let name = title(k)
        let failed = { DispatchQueue.main.async { Toast.show(L("„\(name)“ ließ sich nicht starten", "Couldn't start “\(name)”"), symbol: "exclamationmark.triangle") } }
        switch k.kind {
        case .app:
            let url = URL(fileURLWithPath: k.target)
            // Schon vorne → ausblenden, sonst öffnen bzw. nach vorne holen
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleURL?.standardizedFileURL == url.standardizedFileURL { front.hide(); return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, e in if e != nil { failed() } }
        case .file:
            let url = URL(fileURLWithPath: k.target)
            if !FileManager.default.fileExists(atPath: k.target) || !NSWorkspace.shared.open(url) { failed() }
        case .web:
            guard let url = LaunchLogic.url(k.target), NSWorkspace.shared.open(url) else { failed(); return }
        case .shortcut: run("/usr/bin/shortcuts", ["run", k.target], failed)
        case .command: run("/bin/zsh", ["-lc", k.target], failed)
        }
    }
    private func run(_ exe: String, _ args: [String], _ failed: @escaping () -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { if $0.terminationStatus != 0 { failed() } }
        do { try p.run() } catch { failed() }
    }

    func add(_ kind: LaunchKind, _ target: String) { keys.append(LaunchKey(kind: kind, target: target)) }
    func pick(_ kind: LaunchKind) {
        let p = NSOpenPanel()
        p.canChooseDirectories = kind == .file
        p.allowsMultipleSelection = true
        if kind == .app { p.directoryURL = URL(fileURLWithPath: "/Applications"); p.allowedContentTypes = [.application] }
        if p.runModal() == .OK { p.urls.forEach { add(kind, $0.path) } }
    }
    func remove(_ k: LaunchKey) { keys.removeAll { $0.id == k.id }; HotKey.registerAll() }
    func setShortcut(_ id: UUID, _ s: Shortcut?) { if let i = keys.firstIndex(where: { $0.id == id }) { keys[i].shortcut = s } }

    func loadAppleShortcuts() {
        Task.detached(priority: .utility) {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            let names = String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
            await MainActor.run { Launcher.shared.appleShortcuts = names }
        }
    }
}

struct LauncherSection: View {
    @ObservedObject var l = Launcher.shared
    @ObservedObject var r = ShortcutRecorder.shared
    var body: some View {
        Section {
            if l.keys.isEmpty {
                Text(L("Noch keine eigenen Kürzel. Beispiel: ⌃⌥F öffnet Firefox.", "No custom shortcuts yet. Example: ⌃⌥F opens Firefox.")).foregroundStyle(.secondary)
            }
            ForEach($l.keys) { $k in
                HStack(spacing: 8) {
                    Image(nsImage: l.icon(k)).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22).accessibilityHidden(true)
                    if k.kind == .web || k.kind == .command {
                        TextField("", text: $k.target, prompt: Text(k.kind == .web ? "github.com" : "say Hallo")).labelsHidden()
                            .accessibilityLabel(k.kind == .web ? L("Webseite", "Website") : L("Befehl", "Command"))
                    } else {
                        Text(l.title(k)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(k.target)
                    }
                    Button { r.recordingLaunch == k.id ? r.stop() : r.start(launch: k.id) } label: {
                        Text(r.recordingLaunch == k.id ? tr("Kürzel drücken …") : (k.shortcut?.display ?? L("Kürzel festlegen", "Set shortcut")))
                            .frame(minWidth: 110).foregroundStyle(r.recordingLaunch == k.id ? Color.accentColor : k.shortcut == nil ? .secondary : .primary)
                    }
                    .accessibilityLabel("\(l.title(k)): \(k.shortcut?.display ?? L("kein Kürzel", "no shortcut"))")
                    if HotKey.failedLaunch.contains(k.id) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help(L("Schon von macOS oder einer anderen App belegt", "Already used by macOS or another app"))
                    }
                    Button { l.perform(k) } label: { Image(systemName: "play") }.buttonStyle(.borderless)
                        .help(L("Jetzt ausprobieren", "Try now")).accessibilityLabel(L("\(l.title(k)) ausprobieren", "Try \(l.title(k))")).disabled(k.target.isEmpty)
                    Button { l.remove(k) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        .help(L("Entfernen", "Remove")).accessibilityLabel(L("\(l.title(k)) entfernen", "Remove \(l.title(k))"))
                }
            }
            Menu(L("Hinzufügen", "Add")) {
                Button(L("App …", "App…")) { l.pick(.app) }
                Button(L("Datei oder Ordner …", "File or folder…")) { l.pick(.file) }
                Button(L("Webseite", "Website")) { l.add(.web, "") }
                Menu(L("Kurzbefehl", "Shortcut")) {
                    if l.appleShortcuts.isEmpty { Text(L("Keine Kurzbefehle gefunden", "No shortcuts found")) }
                    ForEach(l.appleShortcuts, id: \.self) { n in Button(n) { l.add(.shortcut, n) } }
                }
                Button(L("Terminal-Befehl", "Terminal command")) { l.add(.command, "") }
            }
            .fixedSize()
        } header: { Text(L("Eigene Kürzel", "Custom shortcuts")) } footer: {
            Text(L("Ist die App schon vorne, blendet dasselbe Kürzel sie aus.", "If the app is already in front, the same shortcut hides it."))
        }
        .onAppear { l.loadAppleShortcuts() }
    }
}
