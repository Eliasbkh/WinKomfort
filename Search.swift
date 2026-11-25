import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - Suche: Apps, Dateien, Befehle, Verlauf, Emoji, Rechnen – alles über die Tastatur
// Sparsam: kein eigenes Indizieren; die Dateisuche läuft nur, während das Fenster offen ist, und stoppt nach dem ersten Ergebnis-Schwung.

struct SearchHit: Identifiable {
    enum Kind { case calc, app, file, web, ai, action, clip, emoji, snippet, slash }
    let kind: Kind
    let title: String
    let subtitle: String
    let path: String? // Pfad, Adresse oder Kennung
    var symbol = "gearshape"
    var section = ""
    var accessory = ""
    var index: Int? = nil // bei .slash: Ergebniszeile (nil = Befehl aus der Liste)
    var id: String { "\(section)|\(kind)|\(index ?? -1)|\(path ?? title)" }
}

struct SearchAction: Identifiable {
    let title: String, symbol: String, key: String
    let run: @MainActor () -> Void
    var id: String { title }
}

@MainActor final class SearchModel: ObservableObject {
    static let shared = SearchModel()
    enum Mode { case root, clip, emoji }
    @Published var query = "" { didSet { if query != oldValue { selected = 0; actionsOpen = false; update() } } }
    @Published private(set) var hits: [SearchHit] = []
    @Published var selected = 0
    @Published private(set) var mode = Mode.root
    @Published var actionsOpen = false { didSet { actionSelected = 0 } }
    @Published var actionSelected = 0
    private var files: [SearchHit] = []
    private let mdq = NSMetadataQuery()
    @Published private(set) var favorites = UserDefaults.standard.stringArray(forKey: "searchFavorites") ?? []

    var placeholder: String {
        switch mode {
        case .root: L("Suchen oder „/“ für Befehle …", "Search, or type “/” for commands…")
        case .clip: L("Zwischenablage durchsuchen …", "Search clipboard…")
        case .emoji: L("Emoji suchen …", "Search emoji…")
        }
    }
    var current: SearchHit? { hits.indices.contains(selected) ? hits[selected] : nil }

    init() {
        mdq.searchScopes = [NSMetadataQueryUserHomeScope]
        mdq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mdq, queue: .main) { _ in
            MainActor.assumeIsolated { SearchModel.shared.collectFiles() }
        }
    }

    private func collectFiles() {
        let q = query.trimmingCharacters(in: .whitespaces)
        let pick = AppUsage.shared.pick(q)
        let found = (0..<min(mdq.resultCount, 200)).compactMap { i -> (SearchHit, Double)? in
            guard let item = mdq.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.hasSuffix(".app"), !path.contains("/Library/"), !path.contains("/.") , !path.contains("/node_modules/") else { return nil }
            let name = (path as NSString).lastPathComponent
            let dir = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            // Passender Name zuerst, kürzlich geöffnete Dateien angehoben
            let last = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            let used = last.map { SearchRank.decayed(3, since: $0, now: Date()) } ?? 0
            let m = SearchRank.match(q, (name as NSString).deletingPathExtension) ?? 0.5
            return (SearchHit(kind: .file, title: name, subtitle: dir, path: path, section: L("Dateien", "Files")), SearchRank.total(m, usage: used) + (path == pick ? 1 : 0))
        }
        files = found.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        mdq.stop() // fertig gesammelt – nichts läuft weiter im Hintergrund
        rebuild()
    }

    func enter(_ m: Mode) { mode = m; query = ""; selected = 0; files = []; mdq.stop(); rebuild() }

    private func update() {
        mdq.stop()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard mode == .root else { rebuild(); return }
        // Bisherige Dateien, die noch passen, stehen lassen – sonst springt die Liste bei jedem Buchstaben
        files = q.count >= 2 ? files.filter { SearchRank.fold($0.title).contains(SearchRank.fold(q)) } : []
        rebuild()
        guard q.count >= 2, !q.hasPrefix("/") else { return }
        mdq.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, q)
        mdq.start()
    }

    private func app(_ e: AppEntry, _ section: String) -> SearchHit {
        SearchHit(kind: .app, title: e.name, subtitle: "", path: e.path, section: section, accessory: "App")
    }
    private func calc(_ title: String, _ sub: String) -> SearchHit { SearchHit(kind: .calc, title: title, subtitle: sub, path: nil, section: L("Ergebnis", "Result"), accessory: L("Kopieren", "Copy")) }

    private func rebuild() {
        let keep = current?.id
        let q = query.trimmingCharacters(in: .whitespaces)
        var h: [SearchHit] = []
        switch mode {
        case .clip:
            h = ClipHistory.shared.items.compactMap { c in
                let t = c.text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)).replacingOccurrences(of: "\n", with: " ") } ?? L("Bild", "Image")
                guard q.isEmpty || SearchRank.fold(c.text ?? t).contains(SearchRank.fold(q)) else { return nil }
                return SearchHit(kind: .clip, title: t, subtitle: "", path: c.id.uuidString, symbol: c.image == nil ? "doc.plaintext" : "photo", section: L("Zwischenablage", "Clipboard"))
            }
        case .emoji:
            h = Emoji.search(q).map { SearchHit(kind: .emoji, title: $0.name, subtitle: "", path: $0.char, section: "Emoji") }
        case .root: h = root(q)
        }
        hits = h
        // Kommen Dateien nach, bleibt die Auswahl auf demselben Eintrag (außer ganz oben)
        if selected > 0, let i = h.firstIndex(where: { $0.id == keep }) { selected = i } else { selected = min(selected, max(h.count - 1, 0)) }
    }

    private func root(_ q: String) -> [SearchHit] {
        var h: [SearchHit] = []
        if q.isEmpty {
            let all = StartModel.shared.all
            let fav = favorites.compactMap { p in all.first { $0.path == p } }
            h += fav.map { app($0, L("Favoriten", "Favorites")) }
            h += AppUsage.shared.frequent(all.filter { !favorites.contains($0.path) }, 7).map { app($0, L("Häufig benutzt", "Frequently used")) }
            return h + SearchActions.suggested
        }
        if q.hasPrefix("/") { return SearchSlash.hits(query) }
        if let v = Calc.evaluate(q) { h.append(calc(Calc.format(v), q)) }
        if let c = Convert.evaluate(q) { h.append(calc("\(Calc.format(c.value)) \(c.unit)", q)) }
        let apps = StartModel.shared.match(q).prefix(6).map { app($0, L("Apps", "Apps")) }
        // Ganze Sätze („halt den Mac wach“) → KI-Befehl; ganz oben, wenn keine App passt
        let web = SearchWeb.hits(q)
        let ai = h.isEmpty && q.split(separator: " ").count >= 2 && Assistant.availableCached
            ? SearchHit(kind: .ai, title: tr("Mit KI ausführen: „%@“", q), subtitle: "", path: nil, section: L("Weitere", "More"), accessory: "Apple Intelligence") : nil
        let actions = SearchActions.match(q)
        if web.count > 1, apps.isEmpty { h += web.dropLast() } // Adresse oder Kurzwahl („yt katzen“) ist gemeint
        else if let ai, apps.isEmpty, actions.isEmpty { h.append(ai) }
        // Passt ein Befehl genauer als jede App („sperren“, „explorer“), steht er oben
        let best = StartModel.shared.match(q).first.flatMap { SearchRank.match(q, $0.name) } ?? 0
        let first = actions.first.map { SearchActions.quality(q, $0) } ?? 0
        h += first > best + 0.05 ? actions + apps : apps + actions
        h += Snippets.load().filter { !$0.key.isEmpty && (SearchRank.match(q, $0.key) ?? SearchRank.match(q, $0.text) ?? 0) >= 0.6 }.prefix(3)
            .map { SearchHit(kind: .snippet, title: $0.text.replacingOccurrences(of: "\n", with: " "), subtitle: $0.key, path: $0.id.uuidString, symbol: "text.quote", section: L("Text-Kürzel", "Snippets"), accessory: L("Einfügen", "Insert")) }
        h += files
        if let ai, !h.contains(where: { $0.kind == .ai }) { h.append(ai) }
        return h + web.filter { w in !h.contains { $0.id == w.id } }
    }

    func move(_ d: Int) {
        if actionsOpen { let n = actions.count; if n > 0 { actionSelected = (actionSelected + d + n) % n } }
        else if !hits.isEmpty { selected = (selected + d + hits.count) % hits.count }
    }

    func submit() {
        if actionsOpen { let a = actions; if a.indices.contains(actionSelected) { a[actionSelected].run() } }
        else { openSelected() }
    }
    // Esc: erst Aktionen zu, dann Suchtext, dann zurück, dann Fenster zu
    func escape() {
        if actionsOpen { actionsOpen = false } else if !query.isEmpty { query = "" } else if mode != .root { enter(.root) } else { SearchPanel.hide() }
    }

    private func openFile(_ path: String, show: Bool) {
        let u = URL(fileURLWithPath: path), v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if show || (v?.isDirectory == true && v?.isPackage != true) { FolderHandler.open([u], select: show) } else { NSWorkspace.shared.open(u) }
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        SearchPanel.hide()
        Toast.show(L("Kopiert", "Copied"), symbol: "doc.on.doc")
    }
    // Nach dem Schließen ausführen – „Vollbild“, Einfügen & Co. gelten für das Fenster dahinter
    private func after(_ work: @escaping @MainActor () -> Void) {
        SearchPanel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { MainActor.assumeIsolated { work() } }
    }

    // show: ⌘↩ zeigt die Datei im Explorer
    func openSelected(show: Bool = false) {
        guard let hit = current else { return }
        switch hit.kind {
        case .app:
            AppUsage.shared.picked(query, hit.path!)
            if show { openFile(hit.path!, show: true) } else { NSWorkspace.shared.open(URL(fileURLWithPath: hit.path!)) }
            SearchPanel.hide()
        case .file:
            AppUsage.shared.picked(query, hit.path!)
            openFile(hit.path!, show: show)
            SearchPanel.hide()
        case .action:
            switch hit.path! {
            case "mode:clip": enter(.clip)
            case "mode:emoji": enter(.emoji)
            case let id: after { SearchActions.run(id) }
            }
        case .clip:
            guard let i = ClipHistory.shared.items.firstIndex(where: { $0.id.uuidString == hit.path }) else { return }
            after { ClipHistory.shared.paste(i) }
        case .emoji:
            let c = hit.path!
            after { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() ? self.copy(c) : Snippets.type(Snippet(key: "", text: c)) }
        case .snippet:
            guard let s = Snippets.load().first(where: { $0.id.uuidString == hit.path }) else { return }
            after { Snippets.type(s) }
        case .calc: copy(hit.title)
        case .slash:
            guard hit.index != nil else { complete(hit); return }
            switch SearchSlash.act(query, hit) {
            case .copy(let t)?: copy(t)
            case .run(let work)?: after(work)
            case nil: break
            }
        case .ai:
            let q = query
            SearchPanel.hide()
            Assistant.ask(q)
        case .web:
            if let u = URL(string: hit.path!) { NSWorkspace.shared.open(u) }
            SearchPanel.hide()
        }
    }

    // Befehl aus der Liste: ohne Eingabe gleich ausführen, sonst „/name “ ergänzen
    func complete(_ hit: SearchHit) {
        switch hit.title {
        case "/clip": enter(.clip)
        case "/emoji": enter(.emoji)
        case "/help": query = "/"
        default:
            let direct = hit.title == query.trimmingCharacters(in: .whitespaces)
            query = hit.title + " "
            if direct, hits.contains(where: { $0.index != nil }) { return }
        }
    }

    // ⌘K
    var actions: [SearchAction] {
        guard let hit = current else { return [] }
        var a = [SearchAction(title: primary(hit), symbol: "return", key: "↩") { self.openSelected() }]
        if hit.kind == .app || hit.kind == .file, let p = hit.path {
            a.append(SearchAction(title: L("Im Explorer zeigen", "Show in Explorer"), symbol: "folder", key: "⌘↩") { self.openSelected(show: true) })
            a.append(SearchAction(title: L("Pfad kopieren", "Copy path"), symbol: "doc.on.doc", key: "") { self.copy(p) })
        }
        if hit.kind == .app, let p = hit.path {
            let fav = favorites.contains(p)
            a.append(SearchAction(title: fav ? L("Aus Favoriten entfernen", "Remove from favorites") : L("Zu Favoriten", "Add to favorites"), symbol: fav ? "star.slash" : "star", key: "") {
                if fav { self.favorites.removeAll { $0 == p } } else { self.favorites.append(p) }
                UserDefaults.standard.set(self.favorites, forKey: "searchFavorites")
                self.actionsOpen = false
                self.rebuild()
            })
            if let r = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: p).standardizedFileURL.path }) {
                a.append(SearchAction(title: L("App beenden", "Quit app"), symbol: "power", key: "") { r.terminate(); SearchPanel.hide() })
                a.append(SearchAction(title: L("Sofort beenden", "Force quit"), symbol: "xmark.octagon", key: "") { r.forceTerminate(); SearchPanel.hide() })
            }
        }
        if hit.kind == .emoji { let c = hit.path!; a.append(SearchAction(title: L("Kopieren", "Copy"), symbol: "doc.on.doc", key: "") { self.copy(c) }) }
        if hit.kind == .clip {
            a.append(SearchAction(title: L("Aus Verlauf löschen", "Delete from history"), symbol: "trash", key: "") {
                if let i = ClipHistory.shared.items.firstIndex(where: { $0.id.uuidString == hit.path }) { ClipHistory.shared.remove(at: i) }
                self.actionsOpen = false
                self.rebuild()
            })
        }
        return a
    }
    func primary(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .app, .file, .web: L("Öffnen", "Open")
        case .calc: L("Kopieren", "Copy")
        case .clip, .emoji, .snippet: L("Einfügen", "Insert")
        case .slash: hit.index == nil ? L("Auswählen", "Choose") : hit.accessory.isEmpty ? L("Ausführen", "Run") : L("Kopieren", "Copy")
        case .action, .ai: L("Ausführen", "Run")
        }
    }

    func reset() {
        mdq.stop()
        files = []
        mode = .root
        actionsOpen = false
        query = ""
        selected = 0
        rebuild()
    }

    func icon(_ hit: SearchHit) -> NSImage? {
        switch hit.kind {
        case .app, .file: StartModel.shared.icon(hit.path!)
        case .slash: hit.path.map { StartModel.shared.icon($0) }
        case .clip: ClipHistory.shared.items.first { $0.id.uuidString == hit.path }?.image
        default: nil
        }
    }
    func symbol(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .calc: "equal"
        case .web: hit.symbol
        case .ai: "sparkles"
        default: hit.symbol
        }
    }
}

// Im Web: Adresse direkt öffnen, Kurzwahl („yt katzen“, „w berlin“) oder suchen
enum SearchWeb {
    private static let sites: [(String, String, String)] = [("g", "Google", "https://www.google.com/search?q="), ("yt", "YouTube", "https://www.youtube.com/results?search_query="),
        ("w", "Wikipedia", "https://de.wikipedia.org/w/index.php?search="), ("gh", "GitHub", "https://github.com/search?q="), ("maps", "Google Maps", "https://www.google.com/maps/search/"),
        ("dl", "DeepL", "https://www.deepl.com/translator#de/en/"), ("a", "Amazon", "https://www.amazon.de/s?k=")]
    static func url(_ base: String, _ q: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        return base + (q.addingPercentEncoding(withAllowedCharacters: ok) ?? "")
    }
    static func hits(_ q: String) -> [SearchHit] {
        let section = "Web"
        var h: [SearchHit] = []
        if q.range(of: #"^(https?://)?[\w-]+(\.[\w-]+)*\.[a-zA-Z]{2,}(/\S*)?$"#, options: .regularExpression) != nil, let u = LaunchLogic.url(q) {
            h.append(SearchHit(kind: .web, title: L("\(q) öffnen", "Open \(q)"), subtitle: "", path: u.absoluteString, symbol: "link", section: section, accessory: "Web"))
        }
        let p = q.split(separator: " ", maxSplits: 1).map(String.init)
        if p.count == 2, let s = sites.first(where: { $0.0 == p[0].lowercased() }) {
            h.append(SearchHit(kind: .web, title: L("\(s.1) nach „\(p[1])“ durchsuchen", "Search \(s.1) for “\(p[1])”"), subtitle: "", path: url(s.2, p[1]), symbol: "magnifyingglass", section: section))
        }
        h.append(SearchHit(kind: .web, title: tr("Im Web suchen: „%@“", q), subtitle: "", path: url(sites[0].2, q), symbol: "globe", section: section))
        return h
    }
}

@MainActor enum SearchPanel {
    private static var panel: KeyPanel?
    private static let size = NSSize(width: 760, height: 480)
    private static var hiding = false

    static func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    static func hide() {
        guard !hiding else { return }
        hiding = true
        panel?.orderOut(nil)
        SearchModel.shared.reset()
        hiding = false
    }
    // Beim Start einmal unsichtbar bauen – dann ist das Suchfeld beim ersten Öffnen sofort da
    static func prepare() { _ = panel ?? make(); panel?.contentView?.layoutSubtreeIfNeeded() }

    static func show() {
        StartModel.shared.reload() // App-Liste frisch (dauert nur Millisekunden)
        SearchModel.shared.reset()
        let p = panel ?? make()
        // Feste Größe an fester Stelle: nichts wächst oder springt beim Tippen
        let v = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!).visibleFrame
        p.setFrame(NSRect(x: (v.midX - size.width / 2).rounded(), y: max(v.minY + 8, (v.maxY - v.height * 0.18 - size.height).rounded()), width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        p.makeKey()
        focusField()
    }

    // Textfeld aktivieren (blinkender Cursor). Klappt es nicht sofort, gleich noch einmal versuchen
    static func focusField(retries: Int = 3) {
        guard let p = panel, p.isVisible else { return }
        if !(p.firstResponder is NSTextView), let f = SearchField.current {
            p.makeKey()
            p.makeFirstResponder(f)
            (f.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (f.stringValue as NSString).length, length: 0))
        }
        if !(p.firstResponder is NSTextView), retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { focusField(retries: retries - 1) } }
        }
    }

    private static func make() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fixedHost(SearchView())
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { hide() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard panel?.isKeyWindow == true else { return e }
            return MainActor.assumeIsolated { key(e) } ? nil : e
        }
        panel = p
        return p
    }

    private static func key(_ e: NSEvent) -> Bool {
        let m = SearchModel.shared, f = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if f == .command {
            if e.charactersIgnoringModifiers == "k" { if !m.actions.isEmpty { m.actionsOpen.toggle() }; return true }
            if e.keyCode == 36 || e.keyCode == 76 { m.openSelected(show: true); return true }
            // ⌘1–9: Eintrag direkt öffnen
            if let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n), m.hits.indices.contains(n - 1) { m.selected = n - 1; m.actionsOpen = false; m.openSelected(); return true }
        }
        switch e.keyCode {
        case 53: m.escape(); return true
        case 125: m.move(1); return true
        case 126: m.move(-1); return true
        case 36, 76: m.submit(); return true
        case 48 where m.current?.kind == .slash && m.current?.index == nil: m.complete(m.current!); return true // Tab ergänzt /Befehle
        case 48: m.move(f.contains(.shift) ? -1 : 1); return true
        case 51 where m.query.isEmpty && m.mode != .root: m.enter(.root); return true
        default: break
        }
        // ⌥ noch gedrückt vom Öffnen mit ⌥ Leertaste? Dann normale Buchstaben statt ®, ∑ & Co.
        if e.modifierFlags.contains(.option), !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
           let plain = e.charactersIgnoringModifiers, plain.count == 1, plain.first!.isLetter || plain.first!.isNumber {
            m.query += e.modifierFlags.contains(.shift) ? plain.uppercased() : plain
            return true
        }
        // Textfeld in den ersten Millisekunden noch nicht bereit? Dann selbst ins Suchfeld schreiben – kein Buchstabe geht verloren
        if !(panel?.firstResponder is NSTextView), !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
           let chars = e.characters, !chars.isEmpty {
            if e.keyCode == 51 { _ = m.query.popLast() } // Rückschritt
            else if chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) { m.query += chars }
            focusField(retries: 0)
            return true
        }
        return false
    }
}

// Echtes macOS-Textfeld statt SwiftUI-TextField: lässt sich im schwebenden Panel zuverlässig aktivieren (mit Cursor)
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    static weak var current: NSTextField?

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 22)
        f.placeholderString = SearchModel.shared.placeholder
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.delegate = context.coordinator
        f.setAccessibilityLabel(tr("Suche"))
        SearchField.current = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.placeholderString != SearchModel.shared.placeholder { f.placeholderString = SearchModel.shared.placeholder }
        guard f.stringValue != text else { return }
        f.stringValue = text
        (f.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) // Cursor ans Ende
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ n: Notification) { parent.text = (n.object as? NSTextField)?.stringValue ?? "" }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

struct SearchView: View {
    @ObservedObject var m = SearchModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if m.mode == .root { Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true) }
                else {
                    Button { m.enter(.root) } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)) }
                        .buttonStyle(.borderless).accessibilityLabel(L("Zurück", "Back"))
                }
                SearchField(text: $m.query) { m.submit() }
            }
            .padding(.horizontal, 20).frame(height: 60)
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 760, height: 480)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottomTrailing) { if m.actionsOpen { actionList.padding(.trailing, 12).padding(.bottom, 50) } }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("oben")
                if m.hits.isEmpty {
                    Text(m.mode == .clip && m.query.isEmpty ? L("Noch nichts kopiert", "Nothing copied yet") : L("Nichts gefunden", "Nothing found"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 130)
                }
                if m.mode == .root, m.query.hasPrefix("/"), let p = SearchSlash.preview(m.query) {
                    p.frame(maxWidth: .infinity).frame(height: 190).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 10).padding(.top, 10)
                }
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(m.hits.enumerated()), id: \.element.id) { i, hit in
                        if !hit.section.isEmpty, i == 0 || m.hits[i - 1].section != hit.section {
                            Text(hit.section).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, i == 0 ? 4 : 12).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(i, hit)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: m.selected) { _, i in if i == 0 { proxy.scrollTo("oben", anchor: .top) } else if m.hits.indices.contains(i) { proxy.scrollTo(m.hits[i].id) } }
            .onChange(of: m.query) { _, _ in proxy.scrollTo("oben", anchor: .top) }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ i: Int, _ hit: SearchHit) -> some View {
        let sel = i == m.selected
        return HStack(spacing: 14) {
            icon(hit).frame(width: 40, height: 40)
            Text(hit.title).font(hit.kind == .calc ? .title2.weight(.medium) : .title3).lineLimit(1).truncationMode(hit.kind == .file ? .middle : .tail).layoutPriority(1)
            if !hit.subtitle.isEmpty { Text(hit.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 8)
            if !hit.accessory.isEmpty { Text(hit.accessory).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, 12).frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 10).fill(sel ? AnyShapeStyle(.primary.opacity(0.11)) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onTapGesture { m.selected = i; m.actionsOpen = false; m.openSelected() }
        .id(hit.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { m.selected = i; m.openSelected() }
    }

    @ViewBuilder private func icon(_ hit: SearchHit) -> some View {
        if hit.kind == .emoji { Text(hit.path!).font(.system(size: 30)) }
        else if let img = m.icon(hit) { Image(nsImage: img).resizable().interpolation(.high).scaledToFit() }
        else {
            Image(systemName: m.symbol(hit)).font(.system(size: 19, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 36, height: 36).background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(m.mode == .clip ? L("Zwischenablage", "Clipboard") : m.mode == .emoji ? "Emoji" : m.query.hasPrefix("/") ? L("Tab ergänzt", "Tab completes") : "WinKomfort").foregroundStyle(.secondary)
            Spacer()
            if let h = m.current {
                key(m.primary(h), "↩") { m.openSelected() }
                Divider().frame(height: 16)
                key(L("Aktionen", "Actions"), "⌘K") { m.actionsOpen.toggle() }
            }
        }
        .font(.callout).padding(.horizontal, 16).frame(height: 42)
    }
    private func key(_ title: String, _ k: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Text(title)
                Text(k).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 3).background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .buttonStyle(.plain)
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(m.actions.enumerated()), id: \.element.id) { i, a in
                Button { a.run() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: a.symbol).frame(width: 20)
                        Text(a.title)
                        Spacer()
                        if !a.key.isEmpty { Text(a.key).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 7).fill(i == m.actionSelected ? AnyShapeStyle(.primary.opacity(0.13)) : AnyShapeStyle(.clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(i == m.actionSelected ? .isSelected : [])
            }
        }
        .padding(6).frame(width: 290)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

struct QRView: View {
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            if let i = RemoteView.qr(text) { Image(nsImage: i).interpolation(.none).resizable().frame(width: 260, height: 260).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("QR-Code") }
            Text(text).lineLimit(3).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(24).frame(width: 340)
    }
}
