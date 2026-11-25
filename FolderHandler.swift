// „Im Finder zeigen“ aus anderen Apps im WinKomfort-Explorer öffnen – jederzeit zurücknehmbar.
// Das Öffnen von Ordnern selbst lässt macOS seit 27 nicht umstellen (LSSetDefaultRoleHandler: −50).
import AppKit

@MainActor enum FolderHandler {
    private static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    private static let id = "de.winkomfort.app"

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "explorerDefault")
        let viewer = CFPreferencesCopyAppValue("NSFileViewer" as CFString, kCFPreferencesAnyApplication) as? String
        // Einen fremden Datei-Manager nur ersetzen, nie beim Ausschalten löschen
        if on || viewer == id {
            CFPreferencesSetValue("NSFileViewer" as CFString, on ? id as CFString : nil, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    // Andere Apps schicken Ordner (öffnen) oder Dateien (zeigen). Dateien werden nie gestartet, nur im Ordner markiert.
    static func open(_ urls: [URL], select: Bool = false) {
        var shown: [URL: Set<URL>] = [:]
        for u in urls.prefix(20) where u.isFileURL {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if !select, v?.isDirectory == true, v?.isPackage != true { shown[u.standardizedFileURL, default: []].formUnion([]) }
            else if FileManager.default.fileExists(atPath: u.path) { shown[u.deletingLastPathComponent().standardizedFileURL, default: []].insert(u.standardizedFileURL) }
        }
        for (dir, sel) in shown.prefix(5) {
            openExplorer(dir)
            guard !sel.isEmpty, let m = explorerWindows.last?.model else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { m.selection = Set(m.visible.map(\.url).filter { sel.contains($0.standardizedFileURL) }) }
        }
    }

    // „Im Finder zeigen“ kommt als Apple-Event misc/mvis
    static func setup() {
        NSAppleEventManager.shared().setEventHandler(Reveal.shared, andSelector: #selector(Reveal.handle(_:reply:)), forEventClass: 0x6D697363, andEventID: 0x6D766973)
    }
    private final class Reveal: NSObject {
        static let shared = Reveal()
        @objc func handle(_ e: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let list = e.paramDescriptor(forKeyword: 0x2D2D2D2D) else { return }
            let items = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap { list.atIndex($0) } : [list]
            let urls = items.compactMap { $0.fileURLValue }
            MainActor.assumeIsolated { FolderHandler.show(urls) }
        }
    }
    private static func show(_ urls: [URL]) {
        // Hier immer im übergeordneten Ordner markieren (auch Ordner)
        for (dir, items) in Dictionary(grouping: urls.prefix(50), by: { $0.deletingLastPathComponent().standardizedFileURL }).prefix(5) {
            openExplorer(dir)
            guard let m = explorerWindows.last?.model else { continue }
            let sel = Set(items.map(\.standardizedFileURL))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { m.selection = Set(m.visible.map(\.url).filter { sel.contains($0.standardizedFileURL) }) }
        }
    }
    // Ausdrücklich den Finder benutzen (nicht wieder uns selbst)
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let items = urls.prefix(50).map { "POSIX file \"" + $0.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" as alias" }.joined(separator: ", ")
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\"\nreveal {\(items)}\nactivate\nend tell")?.executeAndReturnError(&err)
        if err != nil { NSWorkspace.shared.open(finder) }
    }
}
