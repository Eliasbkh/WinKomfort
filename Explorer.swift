// Explorer: eigener Dateimanager in drei Stilen (GNOME Dateien, KDE Dolphin, Windows 11).
// Läuft nur, solange ein Fenster offen ist: Ordner werden im Hintergrund gelesen, Symbole und Vorschaubilder erst,
// wenn sie sichtbar sind. Leertaste = Quick Look von macOS.
import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Sprache: dieselbe Wahl wie das App-Paket (Systemsprache oder Einstellung „Sprache“) – so passt alles zusammen
func L(_ de: String, _ en: String) -> String {
    (Bundle.main.preferredLocalizations.first ?? "de").hasPrefix("de") ? de : en
}

enum ExplorerStyle: String, CaseIterable, Identifiable {
    case gnome, dolphin, windows
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gnome: "GNOME"
        case .dolphin: "KDE Dolphin"
        case .windows: "Windows 11"
        }
    }
    var hint: String {
        switch self {
        case .gnome: L("Aufgeräumt, große Symbole, Pfad als Knöpfe", "Clean, large icons, clickable path")
        case .dolphin: L("Viele Infos: Infoleiste, freier Speicher, Zoom", "Information-rich: info panel, free space, zoom")
        case .windows: L("Befehlsleiste und Detailansicht wie in Windows", "Command bar and details view like Windows")
        }
    }
    static var current: ExplorerStyle {
        ExplorerStyle(rawValue: UserDefaults.standard.string(forKey: "explorerStyle") ?? "") ?? .gnome
    }
}

// Schnellfilter über der Liste: nur Arten, die im Ordner vorkommen
enum FileFilter: String, CaseIterable {
    case all, folders, images, documents, pdf, video, audio, archives, code
    var title: String {
        switch self {
        case .all: L("Alle", "All"); case .folders: L("Ordner", "Folders"); case .images: L("Bilder", "Images"); case .documents: L("Dokumente", "Documents")
        case .pdf: "PDF"; case .video: L("Videos", "Videos"); case .audio: L("Musik", "Audio"); case .archives: L("Archive", "Archives"); case .code: "Code"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"; case .folders: "folder"; case .images: "photo"; case .documents: "doc.text"; case .pdf: "doc.richtext"
        case .video: "film"; case .audio: "music.note"; case .archives: "archivebox"; case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
    func match(_ f: FileItem) -> Bool {
        if self == .all { return true }
        if f.opensAsFolder { return self == .folders }
        guard let t = UTType(filenameExtension: f.url.pathExtension.lowercased()) else { return false }
        switch self {
        case .images: return t.conforms(to: .image)
        case .pdf: return t.conforms(to: .pdf)
        case .video: return t.conforms(to: .movie) || t.conforms(to: .video)
        case .audio: return t.conforms(to: .audio)
        case .archives: return t.conforms(to: .archive) || ["zip", "rar", "7z", "gz", "tar", "dmg"].contains(f.url.pathExtension.lowercased())
        case .code: return t.conforms(to: .sourceCode) || t.conforms(to: .script) || ["json", "xml", "html", "css", "yml", "yaml", "md"].contains(f.url.pathExtension.lowercased())
        case .documents: return !t.conforms(to: .pdf) && (t.conforms(to: .text) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) || ["doc", "docx", "pages", "odt", "rtf", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "one"].contains(f.url.pathExtension.lowercased())) && !FileFilter.code.match(f)
        default: return false
        }
    }
}

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDir: Bool
    let isPackage: Bool
    let size: Int64?
    let modified: Date?
    let kind: String
    var id: URL { url }
    var opensAsFolder: Bool { isDir && !isPackage }
    var sizeSort: Int64 { size ?? -1 }
    var dateSort: Date { modified ?? .distantPast }
}

// MARK: - Modell eines Explorer-Fensters

@MainActor final class ExplorerModel: ObservableObject {
    @Published private(set) var url: URL { didSet { if url != oldValue { filter = .all } } } // neuer Ordner: wieder alles zeigen
    @Published private(set) var items: [FileItem] = []
    @Published var selection: Set<URL> = []
    @Published var batch: [FileItem]?
    @Published var grid: Bool
    @Published var query = "" { didSet { if query != oldValue { scheduleDeepSearch() } } }
    @Published var filter = FileFilter.all
    @Published private(set) var deepHits: [FileItem] = [] // Treffer in Unterordnern (macOS-Suchindex)
    @Published private(set) var recents = false             // Seitenleiste „Zuletzt benutzt“
    @Published var folderSizes = UserDefaults.standard.bool(forKey: "explorerFolderSizes") {
        didSet { UserDefaults.standard.set(folderSizes, forKey: "explorerFolderSizes"); computeFolderSizes() }
    }
    private var sizeTask: Task<Void, Never>?
    @Published private(set) var volumesTick = 0 // USB-Stick rein/raus → Seitenleiste neu
    private var mountTokens: [NSObjectProtocol] = []
    private var mdq: NSMetadataQuery?
    private var mdqToken: NSObjectProtocol?
    private var deepTask: DispatchWorkItem?
    @Published var showHidden = UserDefaults.standard.bool(forKey: "explorerHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "explorerHidden"); reload() }
    }
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]
    @Published var iconSize: Double = 64
    @Published var error: String?
    @Published var renaming: FileItem?
    @Published var searchFocus = 0
    @Published var searching = false
    @Published private(set) var freeSpace: Int64?
    private(set) var back: [URL] = [], forward: [URL] = []
    weak var window: ExplorerWindow?
    private var watcher: DispatchSourceFileSystemObject?
    private var loadID = 0
    private static var cutURLs: [URL] = [] // ⌘X merkt sich die Dateien; ⌘V verschiebt sie

    init(_ url: URL, style: ExplorerStyle) {
        self.url = url
        grid = style != .windows
        reload()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountTokens.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.volumesTick += 1 } })
        }
    }

    var visible: [FileItem] {
        if recents { return filter == .all ? items : items.filter(filter.match) } // schon nach Datum sortiert
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) }
        if !q.isEmpty {
            let here = Set(list.map(\.url))
            list += deepHits.filter { !here.contains($0.url) }
        }
        if filter != .all { list = list.filter(filter.match) }
        // Ordner immer zuerst, wie in allen drei Vorbildern
        let sorted = list.sorted(using: sortOrder)
        return sorted.filter(\.opensAsFolder) + sorted.filter { !$0.opensAsFolder }
    }
    var selectedItems: [FileItem] { visible.filter { selection.contains($0.url) } } // inkl. Treffern aus Unterordnern
    var title: String { FileManager.default.displayName(atPath: url.path) }

    // Pfad als Knöpfe; der Benutzerordner ist der Anfang (wie bei GNOME/Dolphin)
    var crumbs: [URL] {
        if recents { return [] }
        var out: [URL] = [], u = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        while true {
            out.insert(u, at: 0)
            if u.path == home.path || u.path == "/" { break }
            let parent = u.deletingLastPathComponent()
            if parent.path == u.path { break }
            u = parent
        }
        return out
    }

    func open(_ u: URL, record: Bool = true) {
        if recents { recents = false; stopQuery(); url = u; reload(); window?.title = title; return }
        guard u.standardizedFileURL != url.standardizedFileURL else { return }
        if record { back.append(url); forward = [] }
        url = u
        window?.title = title // Name im Tab und im Fenster-Menü
        selection = []
        query = ""
        reload()
    }
    func goBack() { guard let u = back.popLast() else { return }; forward.append(url); open(u, record: false) }
    func goForward() { guard let u = forward.popLast() else { return }; back.append(url); open(u, record: false) }
    func goUp() { let p = url.deletingLastPathComponent(); if p.path != url.path { open(p) } }

    func reload() {
        if recents { return } // „Zuletzt benutzt“ hat keinen Ordner zum Neuladen
        loadID += 1
        let id = loadID, dir = url, hidden = showHidden
        watch(dir)
        Task.detached(priority: .userInitiated) {
            let result = ExplorerModel.read(dir, hidden: hidden)
            let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            await MainActor.run {
                guard id == self.loadID else { return } // inzwischen woanders hin navigiert
                switch result {
                case .success(let list): self.items = list; self.error = nil; self.computeFolderSizes()
                case .failure: self.items = []; self.error = L("Dieser Ordner kann nicht gelesen werden.", "This folder can't be read.")
                }
                self.freeSpace = free
                self.selection = self.selection.filter { u in self.items.contains { $0.url == u } || self.deepHits.contains { $0.url == u } }
            }
        }
    }

    nonisolated static func read(_ dir: URL, hidden: Bool) -> Result<[FileItem], Error> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .localizedNameKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                     options: hidden ? [] : [.skipsHiddenFiles])
            return .success(urls.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return FileItem(url: u, name: v?.localizedName ?? u.lastPathComponent, isDir: v?.isDirectory ?? false,
                                isPackage: v?.isPackage ?? false, size: (v?.isDirectory ?? false) ? nil : v?.fileSize.map(Int64.init),
                                modified: v?.contentModificationDate, kind: v?.localizedTypeDescription ?? "")
            })
        } catch { return .failure(error) }
    }

    // Ordner beobachten: ändert sich etwas (auch durch andere Apps), neu lesen – ohne Polling
    private func watch(_ dir: URL) {
        watcher?.cancel()
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { watcher = nil; return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadSoon() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
    private var reloadPending = false
    private func reloadSoon() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in MainActor.assumeIsolated { self?.reloadPending = false; self?.reload() } }
    }
    func stop() {
        watcher?.cancel(); watcher = nil; stopQuery(); sizeTask?.cancel()
        mountTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; mountTokens = []
    }

    // Ordnergrößen nacheinander im Hintergrund berechnen; beim Ordnerwechsel abbrechen
    private func computeFolderSizes() {
        sizeTask?.cancel()
        guard folderSizes, !recents else { return }
        let folders = items.filter(\.opensAsFolder).map(\.url), dir = url
        sizeTask = Task { [weak self] in
            for f in folders {
                guard let size = await FolderSize.shared.size(of: f) else { return }
                guard let self, !Task.isCancelled, self.url == dir, let i = self.items.firstIndex(where: { $0.url == f }) else { return }
                let o = self.items[i]
                self.items[i] = FileItem(url: o.url, name: o.name, isDir: o.isDir, isPackage: o.isPackage, size: size, modified: o.modified, kind: o.kind)
            }
        }
    }

    // MARK: Suche in Unterordnern und „Zuletzt benutzt“ – über den Suchindex von macOS, nichts wird selbst durchsucht

    private func stopQuery() {
        mdq?.stop(); mdq = nil
        if let t = mdqToken { NotificationCenter.default.removeObserver(t) }
        mdqToken = nil
    }
    private func runQuery(_ predicate: NSPredicate, scope: [Any], sort: [NSSortDescriptor] = [], limit: Int, done: @escaping ([FileItem]) -> Void) {
        stopQuery()
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = scope
        q.sortDescriptors = sort
        mdqToken = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                q.disableUpdates()
                let urls = (0..<min(q.resultCount, limit)).compactMap { (q.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }.map(URL.init(fileURLWithPath:))
                q.stop()
                Task.detached(priority: .userInitiated) {
                    let found = ExplorerModel.describe(urls)
                    await MainActor.run { done(found) }
                }
                self?.mdq = nil
            }
        }
        mdq = q
        q.start()
    }
    nonisolated static func describe(_ urls: [URL]) -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .localizedNameKey]
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
            return FileItem(url: u, name: v.localizedName ?? u.lastPathComponent, isDir: v.isDirectory ?? false, isPackage: v.isPackage ?? false,
                            size: (v.isDirectory ?? false) ? nil : v.fileSize.map(Int64.init), modified: v.contentModificationDate, kind: v.localizedTypeDescription ?? "")
        }
    }
    private func scheduleDeepSearch() {
        deepTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !recents else { deepHits = []; return }
        let scope = url
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.runQuery(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, q), scope: [scope], limit: 200) { [weak self] hits in
                    guard let self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
                    self.deepHits = hits
                }
            }
        }
        deepTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work) // erst suchen, wenn kurz nicht getippt wird
    }
    func openRecents() {
        back.append(url); forward = []
        recents = true
        watcher?.cancel(); watcher = nil
        loadID += 1 // ein noch laufendes Neuladen des alten Ordners verwerfen
        selection = []; query = ""; items = []
        window?.title = L("Zuletzt benutzt", "Recents")
        let since = Date().addingTimeInterval(-30 * 86400) as NSDate
        let home = FileManager.default.homeDirectoryForCurrentUser
        runQuery(NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentTypeTree != 'public.folder' AND kMDItemContentTypeTree != 'com.apple.application'", since),
                 scope: [home], sort: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)], limit: 150) { [weak self] found in
            guard let self, self.recents else { return }
            self.items = found
        }
    }

    // MARK: Aktionen

    func activate(_ item: FileItem) {
        if item.opensAsFolder { open(item.url) } else { NSWorkspace.shared.open(item.url) }
    }
    func openSelection() {
        let sel = selectedItems
        if sel.count == 1 { activate(sel[0]) } else { sel.filter { !$0.opensAsFolder }.forEach { NSWorkspace.shared.open($0.url) } }
    }
    func click(_ item: FileItem, _ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else if flags.contains(.shift), let anchor = visible.firstIndex(where: { selection.contains($0.url) }),
                  let i = visible.firstIndex(of: item) {
            selection = Set(visible[min(anchor, i)...max(anchor, i)].map(\.url))
        } else {
            selection = [item.url]
        }
    }
    func selectAll() { selection = Set(visible.map(\.url)) }
    // Pfeiltasten im Raster: ←→ ein Feld, ↑↓ eine Reihe (Spaltenzahl aus Fensterbreite und Symbolgröße)
    func moveSelection(_ dx: Int, _ dy: Int, width: CGFloat) {
        let v = visible
        guard !v.isEmpty else { return }
        let cell = max(iconSize, 64) + 44
        let cols = max(1, Int((width - 20) / cell))
        let cur = v.lastIndex { selection.contains($0.url) } ?? -1
        let next = cur < 0 ? 0 : min(max(cur + dx + dy * cols, 0), v.count - 1)
        selection = [v[next].url]
        scrollTarget = v[next].url
    }
    @Published var scrollTarget: URL?

    func newFolder() {
        guard !recents else { NSSound.beep(); return }
        var target = url.appendingPathComponent(L("Neuer Ordner", "New Folder")), n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.appendingPathComponent(L("Neuer Ordner", "New Folder") + " \(n)"); n += 1
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            selection = [target]
            renaming = FileItem(url: target, name: target.lastPathComponent, isDir: true, isPackage: false, size: nil, modified: nil, kind: "")
        } catch { fail(error) }
    }
    func startRename() {
        if selectedItems.count > 1 { batch = selectedItems } else if let i = selectedItems.first { renaming = i }
    }
    // Alle auf einmal: erst auf Zwischennamen, dann auf die neuen – so kollidiert nichts, und nie wird etwas überschrieben
    func renameAll(_ items: [FileItem], _ new: [String]) {
        var done: [(URL, URL)] = []
        do {
            let pairs: [(URL, URL, URL)] = Swift.zip(items, new).filter { $0.0.url.lastPathComponent != $0.1 }.map { i, n in (i.url, i.url.deletingLastPathComponent().appendingPathComponent(n), i.url.deletingLastPathComponent().appendingPathComponent(".wk-\(UUID().uuidString)")) }
            for p in pairs { try FileManager.default.moveItem(at: p.0, to: p.2); done.append((p.0, p.2)) }
            for (k, p) in pairs.enumerated() { try FileManager.default.moveItem(at: p.2, to: p.1); done[k] = (p.0, p.1) }
            selection = Set(pairs.map(\.1))
        } catch {
            // alles zurück, wieder über Zwischennamen (bei vertauschten Namen wäre das Ziel sonst belegt)
            let tmp = done.map { ($0.0, $0.1, $0.0.deletingLastPathComponent().appendingPathComponent(".wk-\(UUID().uuidString)")) }
            for t in tmp { try? FileManager.default.moveItem(at: t.1, to: t.2) }
            for t in tmp { try? FileManager.default.moveItem(at: t.2, to: t.0) }
            fail(error)
        }
    }
    func rename(_ item: FileItem, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != item.url.lastPathComponent, !clean.contains("/") else { return }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(clean)
        do { try FileManager.default.moveItem(at: item.url, to: target); selection = [target] } catch { fail(error) }
    }
    // In den Papierkorb (rückholbar, wie im Finder) – nie endgültig löschen
    func trash() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, err in
            if let err { DispatchQueue.main.async { self?.fail(err) } }
        }
    }
    func copy(cut: Bool) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        ExplorerModel.cutURLs = cut ? urls : []
        if cut { Toast.show(L("Ausgeschnitten – mit ⌘V verschieben", "Cut – press ⌘V to move"), symbol: "scissors") }
    }
    func paste() {
        guard !recents else { NSSound.beep(); return }
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        let move = !ExplorerModel.cutURLs.isEmpty && Set(ExplorerModel.cutURLs) == Set(urls)
        transfer(urls, move: move)
        if move { ExplorerModel.cutURLs = [] }
    }
    // Kopieren/Verschieben im Hintergrund; Namenskonflikt → „Name 2“, nie überschreiben
    func transfer(_ urls: [URL], move: Bool, to dir: URL? = nil) {
        let dest = dir ?? url
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var failed: Error?
            for src in urls where src.deletingLastPathComponent().standardizedFileURL != dest.standardizedFileURL || !move {
                if dest.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") || dest.standardizedFileURL == src.standardizedFileURL { continue } // nicht in sich selbst
                var target = dest.appendingPathComponent(src.lastPathComponent), n = 2
                let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
                while fm.fileExists(atPath: target.path) {
                    target = dest.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
                }
                do { if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) } } catch { failed = error }
            }
            if let failed { await MainActor.run { self.fail(failed) } }
        }
    }
    func newTextFile() {
        guard !recents else { NSSound.beep(); return }
        var target = url.appendingPathComponent(L("Neue Textdatei.txt", "New Text File.txt")), n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.appendingPathComponent(L("Neue Textdatei \(n).txt", "New Text File \(n).txt")); n += 1
        }
        guard FileManager.default.createFile(atPath: target.path, contents: Data()) else { NSSound.beep(); return }
        selection = [target]
        renaming = FileItem(url: target, name: target.lastPathComponent, isDir: false, isPackage: false, size: 0, modified: nil, kind: "")
    }
    // Wie „Senden an › ZIP-komprimierter Ordner“ – im Hintergrund, Name wie die Datei bzw. „Archiv.zip“
    func zip() {
        let sel = selectedItems
        guard !sel.isEmpty else { return }
        // Ordner der Dateien (auch bei Suchtreffern aus Unterordnern und „Zuletzt benutzt“) – nur Dateien aus einem Ordner
        let dir = sel[0].url.deletingLastPathComponent()
        guard sel.allSatisfy({ $0.url.deletingLastPathComponent() == dir }) else { NSSound.beep(); return }
        let first = sel[0]
        let base = sel.count == 1 ? (first.isDir ? first.url.lastPathComponent : first.url.deletingPathExtension().lastPathComponent) : L("Archiv", "Archive")
        var target = dir.appendingPathComponent(base + ".zip"), n = 2
        while FileManager.default.fileExists(atPath: target.path) { target = dir.appendingPathComponent("\(base) \(n).zip"); n += 1 }
        let names = sel.map { $0.url.lastPathComponent }, out = target
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            // „./“ davor: Dateinamen, die mit „-“ beginnen, dürfen nicht als zip-Option gelten
            p.arguments = ["-r", "-q", "-y", out.path] + names.map { "./" + $0 } + ["-x", "*.DS_Store"]
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            if p.terminationStatus != 0 { await MainActor.run { Toast.show(L("ZIP konnte nicht erstellt werden", "Couldn't create the ZIP"), symbol: "exclamationmark.triangle") } }
        }
    }
    func copyPath() {
        let paths = (selectedItems.isEmpty ? [url] : selectedItems.map(\.url)).map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }
    func openWith(_ app: URL) {
        NSWorkspace.shared.open(selectedItems.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    func showInFinder() { FolderHandler.revealInFinder(selectedItems.isEmpty ? [url] : selectedItems.map(\.url)) }
    func openTerminal() {
        if let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    func quickLook() {
        guard UserDefaults.standard.object(forKey: "explorerQuickLook") as? Bool ?? true, let w = window else { return }
        w.ql.urls = selectedItems.map(\.url)
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil) }
        else if !w.ql.urls.isEmpty { panel.makeKeyAndOrderFront(nil); panel.reloadData() }
    }
    func fail(_ e: Error) { NSSound.beep(); error = e.localizedDescription }

    var status: String {
        let n = visible.count
        let sel = selectedItems
        var s = n == 1 ? L("1 Objekt", "1 item") : L("\(n) Objekte", "\(n) items")
        if !sel.isEmpty {
            s += " · " + L("\(sel.count) ausgewählt", "\(sel.count) selected")
            let bytes = sel.compactMap(\.size).reduce(0, +)
            if bytes > 0 { s += " (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" }
        }
        return s
    }
}

// MARK: - Fenster: Tasten wie in Linux/Windows, Quick Look

final class QLSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

final class ExplorerWindow: NSWindow {
    let ql = QLSource()
    var model: ExplorerModel?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = ql; panel.delegate = ql }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    // Tasten zentral abfangen, damit sie in Raster und Liste gleich wirken – nicht, während man tippt
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, let m = model, !(firstResponder is NSText), MainActor.assumeIsolated({ m.renaming == nil && m.batch == nil }),
           MainActor.assumeIsolated({ handle(e, m) }) { return }
        if e.type == .leftMouseDown, let m = model, MainActor.assumeIsolated({ listBand(e, m) }) { return }
        super.sendEvent(e)
    }
    // ⌘-Kürzel vor der Menüleiste, sonst schnappt sich „Bearbeiten › Kopieren“ das ⌘C (und kopiert keine Dateien)
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.type == .keyDown, e.modifierFlags.contains(.command), let m = model, !(firstResponder is NSText),
           MainActor.assumeIsolated({ m.renaming == nil && attachedSheet == nil && handle(e, m) }) { return true }
        return super.performKeyEquivalent(with: e)
    }
    // Zwei Explorer nebeneinander auf dem Bildschirm dieses Fensters (je eine Hälfte)
    @MainActor func splitView() {
        guard let screen = screen ?? NSScreen.main, let m = model else { return }
        let v = screen.visibleFrame, half = (v.width / 2).rounded()
        setFrameAutosaveName("") // halbe Größe nicht als Standard für neue Fenster merken
        setFrame(NSRect(x: v.minX, y: v.minY, width: half, height: v.height), display: true, animate: true)
        openExplorer(m.recents ? FileManager.default.homeDirectoryForCurrentUser : m.url, split: true)
        explorerWindows.last?.setFrame(NSRect(x: v.minX + half, y: v.minY, width: v.width - half, height: v.height), display: true, animate: true)
    }

    // Breite des Dateibereichs ungefähr: Fenster minus Seitenleiste (und Infoleiste bei Dolphin)
    private var gridWidth: CGFloat { frame.width - (ExplorerStyle.current == .dolphin ? 400 : 200) }

    @MainActor private func handle(_ e: NSEvent, _ m: ExplorerModel) -> Bool {
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (Int(e.keyCode), f) {
        case (49, []): m.quickLook()
        case (36, []), (76, []): m.openSelection()
        case (120, []): m.startRename()
        case (51, .command), (117, []): m.trash()
        case (51, []): m.goBack() // ⌫ = zurück wie unter Linux/Windows
        case (8, .command): m.copy(cut: false)
        case (7, .command): m.copy(cut: true)
        case (9, .command): m.paste()
        case (0, .command): m.selectAll()
        case (45, [.command, .shift]): m.newFolder()
        case (126, .command): m.goUp()
        case (125, .command): m.openSelection()
        case (123, []) where m.grid: m.moveSelection(-1, 0, width: gridWidth)
        case (124, []) where m.grid: m.moveSelection(1, 0, width: gridWidth)
        case (126, []) where m.grid: m.moveSelection(0, -1, width: gridWidth)
        case (125, []) where m.grid: m.moveSelection(0, 1, width: gridWidth)
        case (33, .command), (123, .command): m.goBack()
        case (30, .command), (124, .command): m.goForward()
        case (47, [.command, .shift]): m.showHidden.toggle()
        case (3, .command): m.searchFocus += 1
        case (15, .command), (96, []): m.reload() // ⌘R / F5
        case (17, .command): openExplorer(m.url, tabOf: self) // ⌘T: neuer Tab im selben Ordner
        case (99, []): splitView() // F3 wie in Dolphin: zweite Ansicht daneben
        default: return false
        }
        return true
    }
}

@MainActor var explorerWindows: [ExplorerWindow] = []

@MainActor func openExplorer(_ url: URL? = nil, tabOf parent: NSWindow? = nil, query: String? = nil, split: Bool = false) {
    let style = ExplorerStyle.current
    let start = url ?? FileManager.default.homeDirectoryForCurrentUser
    let model = ExplorerModel(start, style: style)
    let w = ExplorerWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.isReleasedWhenClosed = false
    w.minSize = NSSize(width: 620, height: 380)
    w.tabbingIdentifier = "WinKomfortExplorer" // macOS-Tabs: ⌘T, Tabs ziehen, ⌘⇧\\ Übersicht
    // neue Fenster wie in macOS eingestellt; ⌘T immer als Tab – aber nie an ein Fenster auf einem anderen Schreibtisch (sonst springt macOS dorthin)
    w.tabbingMode = split || !explorerWindows.contains(where: \.isOnActiveSpace) ? .disallowed : .automatic
    stayHere(w)
    w.model = model
    model.window = w
    if let query, !query.isEmpty { model.searching = true; model.query = query } // z. B. von der KI: „finde meine Bewerbung“
    w.title = model.title
    let host = NSHostingController(rootView: ExplorerView(model: model, style: style))
    host.sizingOptions = [] // sonst schrumpft SwiftUI das Fenster auf die Mindestgröße
    w.contentViewController = host
    w.setContentSize(NSSize(width: 980, height: 620))
    if !split { w.setFrameAutosaveName("WinKomfortExplorer") }
    if !w.setFrameUsingName("WinKomfortExplorer") || w.frame.width < 700 { w.setContentSize(NSSize(width: 980, height: 620)); w.center() }
    if parent == nil, let last = explorerWindows.last(where: \.isOnActiveSpace) { w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26)) }
    var token: NSObjectProtocol?
    token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
        MainActor.assumeIsolated {
            model.stop()
            explorerWindows.removeAll { $0 === w }
            if let token { NotificationCenter.default.removeObserver(token) } // sonst bleiben Fenster und Modell im Speicher
        }
    }
    explorerWindows.append(w)
    NSApp.activate(ignoringOtherApps: true)
    if let parent, parent.isOnActiveSpace { parent.addTabbedWindow(w, ordered: .above) }
    w.makeKeyAndOrderFront(nil)
    // Nicht im Suchfeld starten – sonst greifen ↩, Leertaste, ⌫ erst nach einem Klick
    DispatchQueue.main.async { w.makeFirstResponder(nil) }
}

// MARK: - Symbole und Vorschaubilder (nur sichtbare, mit Zwischenspeicher)

@MainActor final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 600 }
    func icon(_ url: URL) -> NSImage {
        let key = url.path as NSString
        if let i = cache.object(forKey: key) { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(i, forKey: key)
        return i
    }
    func thumb(_ key: String) -> NSImage? { cache.object(forKey: ("t:" + key) as NSString) }
    func setThumb(_ img: NSImage, _ key: String) { cache.setObject(img, forKey: ("t:" + key) as NSString) }
}

struct FileIcon: View {
    let item: FileItem
    let size: CGFloat
    var thumbnails = true
    @StateObject private var loader = TextBox<NSImage>()
    private var thumb: NSImage? { loader.value }
    private var key: String { "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(Int(size))" }
    var body: some View {
        Image(nsImage: thumb ?? IconCache.shared.icon(item.url))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: key) {
                guard thumbnails, !item.isDir, size >= 48 else { return }
                if let t = IconCache.shared.thumb(key) { loader.value = t; return }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                    IconCache.shared.setThumb(rep.nsImage, key)
                    loader.value = rep.nsImage
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Orte in der Seitenleiste

struct Place: Identifiable, Hashable {
    let url: URL
    let title: String
    let symbol: String
    var id: URL { url }
}

@MainActor enum Places {
    static func standard() -> [Place] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        var list = [Place(url: home, title: L("Persönlicher Ordner", "Home"), symbol: "house")]
        let dirs: [(FileManager.SearchPathDirectory, String, String, String)] = [
            (.desktopDirectory, "Schreibtisch", "Desktop", "menubar.dock.rectangle"),
            (.documentDirectory, "Dokumente", "Documents", "doc"),
            (.downloadsDirectory, "Downloads", "Downloads", "arrow.down.circle"),
            (.picturesDirectory, "Bilder", "Pictures", "photo"),
            (.musicDirectory, "Musik", "Music", "music.note"),
            (.moviesDirectory, "Filme", "Movies", "film"),
        ]
        for (d, de, en, sym) in dirs { if let u = fm.urls(for: d, in: .userDomainMask).first { list.append(Place(url: u, title: L(de, en), symbol: sym)) } }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { list.append(Place(url: icloud, title: "iCloud Drive", symbol: "icloud")) }
        list.append(Place(url: URL(fileURLWithPath: "/Applications"), title: L("Programme", "Applications"), symbol: "square.grid.2x2"))
        return list
    }
    static func volumes() -> [Place] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Place(url: u, title: v?.volumeLocalizedName ?? u.lastPathComponent,
                         symbol: (v?.volumeIsInternal ?? true) ? "internaldrive" : "externaldrive")
        }
    }
}

// MARK: - Ansicht

struct ExplorerView: View {
    @ObservedObject var model: ExplorerModel
    @ObservedObject private var phone = PhoneWatch.shared
    let style: ExplorerStyle
    var preview = false // in den Einstellungen: nur ansehen
    @FocusState private var searchFocused: Bool
    @StateObject private var tiles = TileFrames()
    private var searching: Bool { model.searching }

    var body: some View {
        Group {
            switch style {
            case .gnome: gnome
            case .dolphin: dolphin
            case .windows: windows
            }
        }
        .frame(minWidth: preview ? nil : 620, minHeight: preview ? nil : 380)
        .onChange(of: model.searchFocus) { _, _ in model.searching = true; searchFocused = true }
        .sheet(isPresented: Binding(get: { model.batch != nil }, set: { if !$0 { model.batch = nil } })) { if let b = model.batch { BatchRenameSheet(items: b, model: model) } }
        .sheet(item: $model.renaming) { item in RenameSheet(item: item) { model.rename(item, to: $0) } }
        .alert(L("Das ging nicht", "That didn't work"), isPresented: Binding(get: { model.error != nil && !model.items.isEmpty }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    // GNOME Dateien: Seitenleiste bis ganz oben, Kopfleiste mit Pfad-Knöpfen in der Mitte
    private var gnome: some View {
        HStack(spacing: 0) {
            sidebar(grouped: false).frame(width: 200).padding(.top, 40)
                .background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    navButtons(up: false)
                    Spacer(minLength: 8)
                    if searching { searchField.frame(maxWidth: 320) } else { crumbBar(pill: true) }
                    Spacer(minLength: 8)
                    iconButton(searching ? "xmark" : "magnifyingglass", L("Suchen", "Search")) {
                        model.searching.toggle(); searchFocused = model.searching; if !model.searching { model.query = "" }
                    }
                    viewToggle
                    moreMenu
                }
                .padding(.horizontal, 10).frame(height: 52)
                Divider()
                content
            }
        }
    }

    // KDE Dolphin: Werkzeugleiste, Orte links, Infoleiste rechts, Statusleiste mit freiem Speicher und Zoom
    private var dolphin: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                navButtons(up: true)
                crumbBar(pill: false).frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: $model.grid) {
                    Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel(L("Symbole", "Icons"))
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel(L("Details", "Details"))
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                searchField.frame(width: 190)
                moreMenu
            }
            .padding(.leading, 78).padding(.trailing, 10).frame(height: 46)
            Divider()
            HStack(spacing: 0) {
                sidebar(grouped: true).frame(width: 190)
                Divider()
                content
                Divider()
                infoPanel.frame(width: 210)
            }
            Divider()
            HStack(spacing: 10) {
                Text(model.status).lineLimit(1)
                Spacer()
                if let free = model.freeSpace {
                    Text(L("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) frei", "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"))
                }
                if model.grid {
                    Slider(value: $model.iconSize, in: 40...128) { Text(L("Zoom", "Zoom")) }.labelsHidden().frame(width: 110)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 26)
        }
    }

    // Windows 11: Adresszeile oben, Befehlsleiste darunter, Navigationsbereich, Statusleiste
    private var windows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                navButtons(up: true)
                iconButton("arrow.clockwise", L("Aktualisieren", "Refresh")) { model.reload() }
                crumbBar(pill: false)
                    .padding(.horizontal, 6).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                searchField.frame(width: 220)
            }
            .padding(.leading, 78).padding(.trailing, 10).frame(height: 44)
            HStack(spacing: 2) {
                Menu {
                    Button(L("Ordner", "Folder")) { model.newFolder() }
                    Button(L("Textdatei", "Text file")) { model.newTextFile() }
                } label: { Label(L("Neu", "New"), systemImage: "plus.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 18).padding(.horizontal, 6)
                iconButton("scissors", L("Ausschneiden", "Cut")) { model.copy(cut: true) }.disabled(model.selection.isEmpty)
                iconButton("doc.on.doc", L("Kopieren", "Copy")) { model.copy(cut: false) }.disabled(model.selection.isEmpty)
                iconButton("doc.on.clipboard", L("Einfügen", "Paste")) { model.paste() }
                iconButton("character.cursor.ibeam", L("Umbenennen", "Rename")) { model.startRename() }.disabled(model.selection.isEmpty)
                iconButton("trash", L("Löschen", "Delete")) { model.trash() }.disabled(model.selection.isEmpty)
                Divider().frame(height: 18).padding(.horizontal, 6)
                sortMenu
                Menu {
                    Button(L("Details", "Details")) { model.grid = false }
                    Button(L("Große Symbole", "Large icons")) { model.grid = true; model.iconSize = 80 }
                    Button(L("Mittelgroße Symbole", "Medium icons")) { model.grid = true; model.iconSize = 56 }
                    Divider()
                    Toggle(L("Ausgeblendete Elemente", "Hidden items"), isOn: $model.showHidden)
                } label: { Label(L("Anzeigen", "View"), systemImage: "rectangle.grid.1x2") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                moreMenu
            }
            .padding(.horizontal, 10).frame(height: 36)
            Divider()
            HStack(spacing: 0) {
                sidebar(grouped: true).frame(width: 200)
                Divider()
                content
            }
            Divider()
            HStack { Text(model.status); Spacer() }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 24)
        }
    }

    // MARK: Bausteine

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 24) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
    private func navButtons(up: Bool) -> some View {
        HStack(spacing: 2) {
            iconButton("chevron.left", L("Zurück", "Back")) { model.goBack() }.disabled(model.back.isEmpty)
            iconButton("chevron.right", L("Vor", "Forward")) { model.goForward() }.disabled(model.forward.isEmpty)
            if up { iconButton("arrow.up", L("Übergeordneter Ordner", "Up")) { model.goUp() } }
        }
    }
    @ViewBuilder private var searchField: some View {
        let hint = L("In „\(model.title)“ suchen", "Search \(model.title)")
        if preview { // echte Textfelder lassen sich nicht verkleinern und beschriften sich im Formular doppelt
            Text(hint).lineLimit(1).foregroundStyle(.secondary).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        } else {
            TextField(hint, text: $model.query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onExitCommand { model.query = ""; model.searching = false }
        }
    }
    private var viewToggle: some View {
        iconButton(model.grid ? "list.bullet" : "square.grid.2x2", model.grid ? L("Listenansicht", "List view") : L("Rasteransicht", "Grid view")) {
            model.grid.toggle()
        }
    }
    private var sortMenu: some View {
        Menu {
            Button(L("Name", "Name")) { model.sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)] }
            Button(L("Änderungsdatum", "Date modified")) { model.sortOrder = [KeyPathComparator(\FileItem.dateSort, order: .reverse)] }
            Button(L("Größe", "Size")) { model.sortOrder = [KeyPathComparator(\FileItem.sizeSort, order: .reverse)] }
            Button(L("Art", "Type")) { model.sortOrder = [KeyPathComparator(\FileItem.kind, comparator: .localizedStandard)] }
        } label: { Label(L("Sortieren", "Sort"), systemImage: "arrow.up.arrow.down") }
        .menuStyle(.borderlessButton).fixedSize()
    }
    private var moreMenu: some View {
        Menu {
            Button(L("Neuer Ordner", "New folder")) { model.newFolder() }
            Button(L("Neue Textdatei", "New text file")) { model.newTextFile() }
            Button(L("Einfügen", "Paste")) { model.paste() }
            Divider()
            if style != .windows { sortMenu }
            Toggle(L("Versteckte Dateien zeigen", "Show hidden files"), isOn: $model.showHidden)
            Toggle(L("Ordnergrößen anzeigen", "Show folder sizes"), isOn: $model.folderSizes)
            Button(L("Ansicht teilen (F3)", "Split view (F3)")) { model.window?.splitView() }
            Divider()
            Button(L("Im Terminal öffnen", "Open in Terminal")) { model.openTerminal() }
            Button(L("Im Finder zeigen", "Show in Finder")) { model.showInFinder() }
        } label: { Image(systemName: "line.3.horizontal") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("Mehr", "More")).accessibilityLabel(L("Mehr", "More"))
    }

    @ViewBuilder private func crumbBar(pill: Bool) -> some View {
        if model.recents {
            Label(L("Zuletzt benutzt", "Recents"), systemImage: "clock").fontWeight(.semibold).padding(.horizontal, 8)
        } else { crumbs(pill: pill) }
    }
    private func crumbs(pill: Bool) -> some View {
        let crumbs = model.crumbs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: pill ? 2 : 0) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, u in
                    if !pill && i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true) }
                    let last = i == crumbs.count - 1
                    Button { model.open(u) } label: {
                        HStack(spacing: 4) {
                            if i == 0, u.path == FileManager.default.homeDirectoryForCurrentUser.path { Image(systemName: "house") }
                            Text(FileManager.default.displayName(atPath: u.path)).lineLimit(1)
                        }
                        .fontWeight(last ? .semibold : .regular)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background { if pill && last { RoundedRectangle(cornerRadius: 6).fill(.background) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(last ? .primary : .secondary)
                    .dropDestination(for: URL.self) { urls, _ in model.transfer(urls, move: sameVolume(urls, u), to: u); return true }
                }
            }
            .padding(pill ? 3 : 0)
            .background { if pill { RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.7)) } }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sidebar(grouped: Bool) -> some View {
        _ = model.volumesTick // neu zeichnen, wenn Laufwerke kommen oder gehen
        let standard = Places.standard(), volumes = Places.volumes()
        return List {
            Section(grouped ? L("Orte", "Places") : "") {
                Button { model.openRecents() } label: {
                    Label(L("Zuletzt benutzt", "Recents"), systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(model.recents ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) : nil)
                ForEach(standard) { placeRow($0) }
            }
            if !volumes.isEmpty || phone.connected {
                Section(L("Geräte", "Devices")) {
                    ForEach(volumes) { v in
                        HStack(spacing: 4) {
                            placeRow(v)
                            if v.symbol == "externaldrive" {
                                Button { eject(v) } label: { Image(systemName: "eject.fill").font(.caption) }
                                    .buttonStyle(.borderless).help(L("Auswerfen", "Eject")).accessibilityLabel(L("\(v.title) auswerfen", "Eject \(v.title)"))
                            }
                        }
                    }
                    if phone.connected { PhoneRow() }
                }
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden)
    }
    // Sicher auswerfen (wie im Finder); danach zurück in den Benutzerordner, falls man gerade darin war
    private func eject(_ v: Place) {
        if model.url.path.hasPrefix(v.url.path) { model.open(FileManager.default.homeDirectoryForCurrentUser) }
        Task.detached {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: v.url) }
            catch { await MainActor.run { Toast.show(L("„\(v.title)“ wird noch benutzt", "“\(v.title)” is still in use"), symbol: "externaldrive.badge.exclamationmark") } }
        }
    }

    private func placeRow(_ p: Place) -> some View {
        let on = !model.recents && model.url.standardizedFileURL == p.url.standardizedFileURL
        return Button { model.open(p.url) } label: {
            Label(p.title, systemImage: p.symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(on ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) : nil)
        .dropDestination(for: URL.self) { urls, _ in model.transfer(urls, move: sameVolume(urls, p.url), to: p.url); return true }
    }

    // Filter-Chips: nur Arten, die es hier gibt, mit Anzahl
    @ViewBuilder private var filterBar: some View {
        let counts = Dictionary(uniqueKeysWithValues: FileFilter.allCases.dropFirst().map { f in (f, model.items.lazy.filter(f.match).count) })
        let shown = FileFilter.allCases.dropFirst().filter { (counts[$0] ?? 0) > 0 }
        if shown.count > 1 || model.filter != .all {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([FileFilter.all] + shown, id: \.self) { f in
                        let on = model.filter == f
                        Button { withAnimation(.snappy(duration: 0.25)) { model.filter = on && f != .all ? .all : f } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: f.symbol).imageScale(.small)
                                Text(f.title)
                                if f != .all { Text("\(counts[f] ?? 0)").foregroundStyle(on ? Color.white.opacity(0.8) : .secondary).monospacedDigit() }
                            }
                            .font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(on ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                            .foregroundStyle(on ? Color.white : .primary)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
        }
    }
    @ViewBuilder private var content: some View {
        VStack(spacing: 0) { filterBar; listOrGrid }
    }
    @ViewBuilder private var listOrGrid: some View {
        Group {
            if let e = model.error, model.items.isEmpty {
                ContentUnavailableView(e, systemImage: "lock")
            } else if model.visible.isEmpty {
                if model.filter != .all, model.query.isEmpty {
                    ContentUnavailableView(L("Keine \(model.filter.title) in diesem Ordner", "No \(model.filter.title) in this folder"), systemImage: model.filter.symbol)
                } else if model.query.isEmpty {
                    ContentUnavailableView(L("Ordner ist leer", "Folder is empty"), systemImage: "folder",
                                           description: Text(L("Dateien hierher ziehen oder mit ⌘⇧N einen Ordner anlegen.", "Drag files here or press ⌘⇧N for a new folder.")))
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            } else if model.grid {
                gridView
            } else {
                listView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in model.transfer(urls, move: sameVolume(urls, model.url), to: model.url); return true }
        .onDrop(of: [PhoneModel.dragType], isTargeted: nil) { p in model.recents ? false : PhoneModel.shared.dropped(p, to: model.url) }
    }

    private var gridView: some View {
        let size = style == .gnome ? max(model.iconSize, 64) : model.iconSize
        return GeometryReader { area in ScrollViewReader { proxy in ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 40), spacing: 4)], spacing: 4) {
                ForEach(model.visible) { item in
                    let sel = model.selection.contains(item.url)
                    VStack(spacing: 4) {
                        FileIcon(item: item, size: size, thumbnails: !preview)
                        Text(item.name).font(.callout).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                            .padding(.horizontal, 4)
                            .background { if sel { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor) } }
                            .foregroundStyle(sel ? .white : .primary)
                    }
                    .padding(6).frame(maxWidth: .infinity)
                    .background { if sel { RoundedRectangle(cornerRadius: 8).fill(.quaternary) } }
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("grid")) } action: { tiles.frames[item.url] = $0 }
                    .onDisappear { tiles.frames[item.url] = nil } // nie veraltete Lagen treffen
                    .contextMenu { itemMenu(item) }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard item.opensAsFolder else { return false }
                        model.transfer(urls, move: sameVolume(urls, item.url), to: item.url); return true
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { model.selection = [item.url] }
                    .accessibilityAction(named: L("Öffnen", "Open")) { model.activate(item) }
                    .id(item.url)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: area.size.height, alignment: .top) // auch die leere Fläche darunter
            .overlay { if !preview { GridMouse(model: model, tiles: tiles) } }
            .coordinateSpace(.named("grid"))
        }
        .onChange(of: model.scrollTarget) { _, t in if let t { proxy.scrollTo(t) } } // Pfeiltasten: Auswahl bleibt sichtbar
        } }
    }

    private var listView: some View {
        Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(L("Name", "Name"), value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    FileIcon(item: item, size: 18, thumbnails: false)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn(L("Änderungsdatum", "Date modified"), value: \.dateSort) { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–").foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
            TableColumn(L("Art", "Type"), value: \.kind, comparator: .localizedStandard) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
            TableColumn(L("Größe", "Size"), value: \.sizeSort) { item in
                Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let u = urls.first, let item = model.visible.first(where: { $0.url == u }) { itemMenu(item) }
        } primaryAction: { urls in
            model.selection = urls
            model.openSelection()
        }
    }

    @ViewBuilder private func itemMenu(_ item: FileItem) -> some View {
        Button(L("Öffnen", "Open")) { if !model.selection.contains(item.url) { model.selection = [item.url] }; model.openSelection() }
        if !item.opensAsFolder {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url).prefix(12)
            Menu(L("Öffnen mit", "Open With")) {
                ForEach(Array(apps), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path)) { ensure(item); model.openWith(app) }
                }
            }
        }
        if !item.opensAsFolder { Button(L("Vorschau (Leertaste)", "Quick Look (Space)")) { model.selection = [item.url]; model.quickLook() } }
        Divider()
        Button(L("Ausschneiden", "Cut")) { ensure(item); model.copy(cut: true) }
        Button(L("Kopieren", "Copy")) { ensure(item); model.copy(cut: false) }
        Button(L("Umbenennen …", "Rename…")) { ensure(item); model.startRename() }
        Button(L("Als ZIP komprimieren", "Compress to ZIP")) { ensure(item); model.zip() }
        if FileTools.isImage(item.url) || FileTools.isPDF(item.url) { toolsMenu(item) }
        Button(L("In die Ablage", "Add to Shelf")) { ensure(item); Shelf.shared.park(model.selectedItems.map(\.url)) }
        if FileTools.isPDF(item.url) { Button(L("Mit meiner Handschrift ausfüllen", "Fill in my handwriting")) { SheetFiller.open(item.url) } }
        if !item.opensAsFolder { Button(L("KI dazu fragen", "Ask AI about this")) { ensure(item); let u = model.selectedItems.filter { !$0.opensAsFolder }.map(\.url); AI.chat(""); AIChat.shared.attach(u) } }
        Button(L("Pfad kopieren", "Copy Path")) { ensure(item); model.copyPath() }
        Divider()
        Button(L("Im Finder zeigen", "Show in Finder")) { ensure(item); model.showInFinder() }
        Button(L("In den Papierkorb", "Move to Trash"), role: .destructive) { ensure(item); model.trash() }
    }
    private func toolsMenu(_ item: FileItem) -> some View {
        Menu(L("Umwandeln", "Convert")) {
            let sel = model.selection.contains(item.url) ? model.selectedItems.map(\.url) : [item.url], img = sel.filter(FileTools.isImage), pdf = sel.filter(FileTools.isPDF)
            if !img.isEmpty {
                Button(L("Als JPEG", "As JPEG")) { FileTools.run(img) { FileTools.convert($0, to: .jpeg) } }
                Button(L("Als PNG", "As PNG")) { FileTools.run(img) { FileTools.convert($0, to: .png) } }
                Button(L("Verkleinern (zum Hochladen)", "Shrink (for upload)")) { FileTools.run(img) { FileTools.convert($0, to: .jpeg, max: 1920, quality: 0.7, suffix: L(" klein", " small")) } }
            }
            if !pdf.isEmpty { Button(L("PDF verkleinern", "Shrink PDF")) { FileTools.run(pdf) { FileTools.shrink($0) } } }
            let both = sel.filter { FileTools.isImage($0) || FileTools.isPDF($0) }
            if both.count > 1 || !img.isEmpty { Button(both.count > 1 ? L("Zu einer PDF zusammenfügen", "Merge into one PDF") : L("Als PDF", "As PDF")) { FileTools.run([both[0]]) { _ in FileTools.merge(both) } } }
        }
    }
    private func ensure(_ item: FileItem) { if !model.selection.contains(item.url) { model.selection = [item.url] } }

    private var infoPanel: some View {
        VStack(spacing: 10) {
            if let item = model.selectedItems.first, model.selection.count == 1 {
                FileIcon(item: item, size: 128, thumbnails: !preview)
                Text(item.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                VStack(alignment: .leading, spacing: 4) {
                    row(L("Art", "Type"), item.kind)
                    if let s = item.size { row(L("Größe", "Size"), ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
                    if let d = item.modified { row(L("Geändert", "Modified"), d.formatted(date: .abbreviated, time: .shortened)) }
                }
                .font(.caption)
            } else {
                Image(nsImage: IconCache.shared.icon(model.url)).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
                Text(model.title).font(.headline)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary).frame(width: 64, alignment: .leading); Text(v) }
    }
}

// Gleicher Datenträger → verschieben (wie Finder), sonst kopieren
func sameVolume(_ urls: [URL], _ dest: URL) -> Bool {
    func vol(_ u: URL) -> URL? { (try? u.resourceValues(forKeys: [.volumeURLKey]))?.volume }
    guard let d = vol(dest) else { return false }
    return urls.allSatisfy { vol($0) == d }
}

struct BatchRenameSheet: View {
    let items: [FileItem]
    let model: ExplorerModel
    final class Box: ObservableObject { @Published var replace = false; @Published var a = ""; @Published var b = "" }
    @StateObject private var s = Box()
    @Environment(\.dismiss) private var dismiss
    private var old: [String] { items.map(\.url.lastPathComponent) }
    private var new: [String] { RenameLogic.names(old, mode: s.replace ? .replace : .number, a: s.a, b: s.b) }
    private var problem: String? {
        guard !s.a.isEmpty else { return "" }
        guard Set(items.map { $0.url.deletingLastPathComponent() }).count == 1 else { return L("Nur Dateien aus einem Ordner", "Only files from one folder") }
        let dir = items[0].url.deletingLastPathComponent()
        switch RenameLogic.problem(old, new, taken: Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])) {
        case .empty?: return L("Ein Name wäre leer", "A name would be empty")
        case .slash?: return L("„/“ und „:“ sind nicht erlaubt", "“/” and “:” aren't allowed")
        case .twice?: return L("Zwei Dateien hießen gleich", "Two files would have the same name")
        case .exists?: return L("Eine Datei mit diesem Namen gibt es schon", "A file with that name already exists")
        case nil: return old == new ? "" : nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("\(items.count) Dateien umbenennen", "Rename \(items.count) files")).font(.headline)
            Picker("", selection: $s.replace) { Text(L("Durchnummerieren", "Number")).tag(false); Text(L("Ersetzen", "Replace")).tag(true) }.pickerStyle(.segmented).labelsHidden()
            TextField(s.replace ? L("Suchen nach", "Find") : L("Neuer Name", "New name"), text: $s.a)
            if s.replace { TextField(L("Ersetzen durch", "Replace with"), text: $s.b) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(zip(old, new).prefix(4).enumerated()), id: \.offset) { _, p in Text("\(p.0)  →  \(s.a.isEmpty ? p.0 : p.1)").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if items.count > 4 { Text("…").foregroundStyle(.secondary) }
            }
            if let p = problem, !p.isEmpty { Text(p).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Abbrechen", "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Umbenennen", "Rename")) { model.renameAll(items, new); dismiss() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20).frame(width: 440)
    }
}

struct RenameSheet: View {
    let item: FileItem
    let done: (String) -> Void
    @StateObject private var box = TextBox<String>()
    private var name: String { box.value ?? "" }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Umbenennen", "Rename")).font(.headline)
            TextField(L("Name", "Name"), text: Binding(get: { box.value ?? "" }, set: { box.value = $0 })).textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit { done(name); dismiss() }
            if name.contains("/") { Text(L("„/“ ist im Namen nicht erlaubt.", "“/” isn't allowed in names.")).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Abbrechen", "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Umbenennen", "Rename")) { done(name); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }
        .padding(20)
        .onAppear { box.value = item.url.lastPathComponent }
    }
}

// MARK: - Einstellungen: Stil wählen mit Live-Vorschau (echter Benutzerordner, nur ansehen)

struct ExplorerTab: View {
    @AppStorage("explorerDefault") private var explorerDefault = false // zeichnet den Schalter neu
    @AppStorage("explorerStyle") private var style = ExplorerStyle.gnome.rawValue
    @AppStorage("explorerQuickLook") private var quickLook = true
    @StateObject private var previewModel = ExplorerModel(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], style: .gnome)

    var body: some View {
        Form {
            Section {
                // Raster bricht um, statt über den Rand zu ragen
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 12) { cards }
                .padding(.vertical, 4)
            } header: {
                Text(L("Stil", "Style"))
            } footer: {
                Text(L("Die Vorschau zeigt deinen echten Dokumente-Ordner. Neue Fenster öffnen im gewählten Stil.", "The preview shows your real Documents folder. New windows open in the chosen style."))
            }
            Section {
                Toggle(isOn: $quickLook) {
                    Text(L("Leertaste zeigt Vorschau (Quick Look)", "Space shows Quick Look"))
                    Text(L("Wie im Finder: Datei markieren, Leertaste drücken.", "Like Finder: select a file, press Space."))
                }
                Toggle(isOn: Binding(get: { explorerDefault }, set: { FolderHandler.set($0) })) {
                    Text(L("„Im Finder zeigen“ öffnet den Explorer", "“Show in Finder” opens Explorer"))
                    Text(L("Gilt für andere Apps. Doppelklicks auf Ordner bleiben im Finder – das gibt macOS vor.", "Applies to other apps. Double-clicking folders stays in Finder – macOS requires that."))
                }
                LabeledContent(L("Explorer öffnen", "Open Explorer")) {
                    HStack {
                        Text(HotAction.explorer.current?.display ?? L("kein Kürzel", "no shortcut")).foregroundStyle(.secondary)
                        Button(L("Jetzt öffnen", "Open now")) { openExplorer() }
                    }
                }
            } footer: {
                Text(L("Tasten: ↩ öffnen · ⌫ zurück · F2 umbenennen · F3 Ansicht teilen · F5 aktualisieren · ⌘T neuer Tab · ⌘⌫ Papierkorb · ⌘C/⌘X/⌘V · ⌘⇧N neuer Ordner · ⌘F suchen · ⌘⇧. versteckte Dateien",
                       "Keys: ↩ open · ⌫ back · F2 rename · F3 split view · F5 refresh · ⌘T new tab · ⌘⌫ trash · ⌘C/⌘X/⌘V · ⌘⇧N new folder · ⌘F search · ⌘⇧. hidden files"))
            }
        }
        .formStyle(.grouped)
        .onDisappear { previewModel.stop() } // Ordnerbeobachtung der Vorschau freigeben
        .onAppear { previewModel.reload() }
    }

    private var cards: some View {
        ForEach(ExplorerStyle.allCases) { s in
            Button { style = s.rawValue } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ExplorerView(model: previewModel, style: s, preview: true)
                        .frame(width: 760, height: 470)
                        .scaleEffect(0.2, anchor: .topLeading)
                        .frame(width: 152, height: 94, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style == s.rawValue ? Color.accentColor : .secondary.opacity(0.3), lineWidth: style == s.rawValue ? 3 : 1))
                        .allowsHitTesting(false)
                    Text(s.title).font(.headline)
                    Text(s.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 152, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(s.title)
            .accessibilityAddTraits(style == s.rawValue ? .isSelected : [])
        }
    }
}

// Kleiner Zustandsbehälter (statt @State, das hier als Makro nicht verfügbar ist)
final class TextBox<T>: ObservableObject { @Published var value: T? }
