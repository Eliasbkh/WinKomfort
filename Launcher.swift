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
        case .action: SystemAction(rawValue: k.target)?.title ?? k.target
        case .remap: L("Kürzel umlegen", "Remap shortcut")
        }
    }
    func icon(_ k: LaunchKey) -> NSImage {
        switch k.kind {
        case .app, .file: NSWorkspace.shared.icon(forFile: k.target)
        case .web: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        case .shortcut: NSImage(systemSymbolName: "square.2.layers.3d", accessibilityDescription: nil)!
        case .action: NSImage(systemSymbolName: SystemAction(rawValue: k.target)?.symbol ?? "gearshape", accessibilityDescription: nil)!
        case .remap: NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)!
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
        case .action: if SystemAction(rawValue: k.target)?.perform() != true { failed() }
        case .remap: if let o = k.output { Self.press(o) } else { failed() }
        case .command: run("/bin/zsh", ["-lc", k.target], failed)
        }
    }
    // Kombination drücken, unabhängig davon, welche Tasten du gerade noch hältst
    static func press(_ s: Shortcut) {
        let src = CGEventSource(stateID: .privateState)
        var f = CGEventFlags()
        if s.mods & Shortcut.command != 0 { f.insert(.maskCommand) }
        if s.mods & Shortcut.shift != 0 { f.insert(.maskShift) }
        if s.mods & Shortcut.option != 0 { f.insert(.maskAlternate) }
        if s.mods & Shortcut.control != 0 { f.insert(.maskControl) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(s.code), keyDown: down)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
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
    func setShortcut(_ id: UUID, _ s: Shortcut?, output: Bool) {
        guard let i = keys.firstIndex(where: { $0.id == id }) else { return }
        if output { keys[i].output = s } else { keys[i].shortcut = s }
    }

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
                    } else if k.kind == .remap {
                        Text(L("Drückt", "Presses")).foregroundStyle(.secondary)
                        recordButton(k, output: true)
                        Spacer(minLength: 0)
                    } else {
                        Text(l.title(k)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(k.target)
                    }
                    recordButton(k, output: false)
                    if HotKey.failedLaunch.contains(k.id) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help(L("Schon von macOS oder einer anderen App belegt", "Already used by macOS or another app"))
                    }
                    Button { l.perform(k) } label: { Image(systemName: "play") }.buttonStyle(.borderless)
                        .help(L("Jetzt ausprobieren", "Try now")).accessibilityLabel(L("\(l.title(k)) ausprobieren", "Try \(l.title(k))")).disabled(k.kind == .remap ? k.output == nil : k.target.isEmpty)
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
                Menu(L("Systemaktion", "System action")) {
                    ForEach(SystemAction.allCases, id: \.self) { a in Button(a.title) { l.add(.action, a.rawValue) } }
                }
                Button(L("Kürzel umlegen", "Remap shortcut")) { l.add(.remap, "") }
                Button(L("Terminal-Befehl", "Terminal command")) { l.add(.command, "") }
            }
            .fixedSize()
        } header: { Text(L("Eigene Kürzel", "Custom shortcuts")) } footer: {
            Text(r.recordingLaunch != nil || !r.message.isEmpty && r.recording == nil ? (r.message.isEmpty ? tr("Klicken, dann die neue Kombination drücken. Esc bricht ab, ⌫ schaltet das Kürzel aus.") : r.message)
                 : L("Ist die App schon vorne, blendet dasselbe Kürzel sie aus. „Kürzel umlegen“ drückt eine andere Kombination für dich, z. B. ⌃⌥Q → ⌘Q.",
                     "If the app is already in front, the same shortcut hides it. “Remap shortcut” presses another combination for you, e.g. ⌃⌥Q → ⌘Q."))
        }
        .onAppear { l.loadAppleShortcuts() }
    }

    private func recordButton(_ k: LaunchKey, output: Bool) -> some View {
        let on = r.recordingLaunch == k.id && r.output == output, value = output ? k.output : k.shortcut
        return Button { on ? r.stop() : r.start(launch: k.id, output: output) } label: {
            Text(on ? tr("Kürzel drücken …") : (value?.display ?? (output ? L("Ziel wählen", "Set target") : L("Kürzel festlegen", "Set shortcut"))))
                .frame(minWidth: 104).foregroundStyle(on ? Color.accentColor : value == nil ? .secondary : .primary)
        }
        .accessibilityLabel("\(l.title(k)): \(value?.display ?? L("kein Kürzel", "no shortcut"))")
    }
}

// Aktionen, für die macOS kein oder nur ein festes Kürzel hat
enum SystemAction: String, CaseIterable {
    case fullscreen, minimize, closeWindow, hide, hideOthers, quit, missionControl, appWindows, showDesktop
    case lock, displayOff, screenshotArea, screenshotFull, dark, mute, volumeUp, volumeDown, playPause, nextTrack, previousTrack, scale

    var title: String {
        switch self {
        case .fullscreen: L("Vollbild ein/aus", "Toggle full screen")
        case .minimize: L("Fenster minimieren", "Minimize window")
        case .closeWindow: L("Fenster schließen", "Close window")
        case .hide: L("App ausblenden", "Hide app")
        case .hideOthers: L("Andere Apps ausblenden", "Hide other apps")
        case .quit: L("App beenden", "Quit app")
        case .missionControl: "Mission Control"
        case .appWindows: L("Alle Fenster der App", "All windows of the app")
        case .showDesktop: L("Schreibtisch zeigen", "Show desktop")
        case .lock: L("Bildschirm sperren", "Lock screen")
        case .displayOff: L("Bildschirm aus", "Display off")
        case .screenshotArea: L("Bereich in die Zwischenablage", "Copy screen area")
        case .screenshotFull: L("Bildschirm in die Zwischenablage", "Copy whole screen")
        case .dark: L("Dunkelmodus ein/aus", "Toggle dark mode")
        case .mute: L("Ton ein/aus", "Toggle mute")
        case .volumeUp: L("Lauter", "Volume up")
        case .volumeDown: L("Leiser", "Volume down")
        case .playPause: L("Wiedergabe/Pause", "Play/pause")
        case .nextTrack: L("Nächster Titel", "Next track")
        case .previousTrack: L("Vorheriger Titel", "Previous track")
        case .scale: L("Trackpad-Waage", "Trackpad scale")
        }
    }
    var symbol: String {
        switch self {
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .minimize: "minus.rectangle"
        case .closeWindow: "xmark.rectangle"
        case .hide, .hideOthers: "eye.slash"
        case .quit: "power"
        case .missionControl, .appWindows: "rectangle.3.group"
        case .showDesktop: "menubar.dock.rectangle"
        case .lock: "lock"
        case .displayOff: "display"
        case .screenshotArea, .screenshotFull: "camera.viewfinder"
        case .dark: "circle.lefthalf.filled"
        case .mute: "speaker.slash"
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .playPause: "playpause"
        case .nextTrack: "forward"
        case .previousTrack: "backward"
        case .scale: "scalemass"
        }
    }

    @MainActor func perform() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        switch self {
        case .fullscreen:
            guard let w = Self.window() else { return false }
            let on = UIAuto.attr(w, "AXFullScreen") as? Bool == true
            return AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (on ? kCFBooleanFalse : kCFBooleanTrue)!) == .success
        case .minimize:
            guard let w = Self.window() else { return false }
            return AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case .closeWindow:
            guard let w = Self.window(), let b = UIAuto.attr(w, kAXCloseButtonAttribute) else { return false }
            return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
        case .hide: return front?.hide() ?? false
        case .hideOthers: NSWorkspace.shared.hideOtherApplications(); return true
        case .quit: return front?.bundleIdentifier == "com.apple.finder" ? false : front?.terminate() ?? false
        case .missionControl: return Self.dock("com.apple.expose.awake")
        case .appWindows: return Self.dock("com.apple.expose.front.awake")
        case .showDesktop: return Self.dock("com.apple.showdesktop.awake")
        case .lock:
            guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW), let f = dlsym(h, "SACLockScreenImmediate") else { return false }
            _ = unsafeBitCast(f, to: (@convention(c) () -> Int32).self)()
            return true
        case .displayOff: sh(["/usr/bin/pmset", "displaysleepnow"]); return true
        case .screenshotArea: return Self.spawn("/usr/sbin/screencapture", ["-i", "-c"])
        case .screenshotFull: return Self.spawn("/usr/sbin/screencapture", ["-c"])
        case .dark: return Self.script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .mute: return Self.script("set volume output muted not (output muted of (get volume settings))")
        case .volumeUp: return Self.media(0)
        case .volumeDown: return Self.media(1)
        case .playPause: return Self.media(16)
        case .nextTrack: return Self.media(17)
        case .previousTrack: return Self.media(18)
        case .scale: openScale(); return true
        }
    }
    private static func window() -> AXUIElement? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        return UIAuto.attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
    }
    private static func dock(_ name: String) -> Bool {
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW), let f = dlsym(h, "CoreDockSendNotification") else { return false }
        _ = unsafeBitCast(f, to: (@convention(c) (CFString, Int32) -> Int32).self)(name as CFString, 0)
        return true
    }
    private static func spawn(_ exe: String, _ args: [String]) -> Bool {
        (try? Process.run(URL(fileURLWithPath: exe), arguments: args)) != nil
    }
    private static func script(_ s: String) -> Bool {
        var e: NSDictionary?
        NSAppleScript(source: s)?.executeAndReturnError(&e)
        return e == nil
    }
    // Medientasten der Tastatur
    private static func media(_ key: Int) -> Bool {
        for down in [true, false] {
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00), timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: key << 16 | (down ? 0xA : 0xB) << 8, data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }
}
