// OneNote → PDF ohne OneNote fernzusteuern: Die Original-Abschnittsdateien (.one) werden mit deiner eigenen
// Microsoft-Anmeldung (einmal in WinKomfort, danach unsichtbar) von SharePoint/OneDrive geladen, lokal umgewandelt
// (Open-Source-Umwandler aus Joplin, im App-Paket) und zu einer kleinen PDF zusammengesetzt.
// Geladene Abschnitte bleiben zwischengespeichert: Beim nächsten Mal wird nur Geändertes neu geladen.
import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

// Kleines Protokoll für Fehlersuche (rotiert bei 1 MB) – ~/Library/Logs/WinKomfort.log
func wkLog(_ text: String) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/WinKomfort.log")
    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}

enum OneNoteCloud {
    struct Target {
        let host: String        // https://firma.sharepoint.com
        let site: String        // /sites/Name oder /personal/name
        let section: String     // serverrelativer Pfad der .one-Datei
        let pageID: String?
        var order: [String] = [] // Abschnitte/Gruppen in der Reihenfolge der OneNote-Seitenleiste
    }
    struct Failure: Error { let text: String }

    // MARK: 1. Ziel über „Link kopieren“ aus OneNote holen (Menüpunkt per Bedienungshilfen, Zwischenablage bleibt erhalten)

    static func target(_ scope: OneNotePDF.Scope) -> Target? {
        let titles = scope == .page ? ["Copy Link to Page", "Link zur Seite kopieren"] : ["Copy Link to Section", "Link zum Abschnitt kopieren"]
        // OneNote reagiert direkt nach dem Start manchmal nicht auf den ersten Menü-Klick → bis zu 3 Versuche
        var link: String?
        for attempt in 0..<3 where link == nil { if attempt > 0 { usleep(700_000) }; link = copyLink(titles) }
        guard let link, let line = link.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("onenote:") }) else { return nil }
        var s = String(line.dropFirst("onenote:".count))
        var pageID: String?
        if let r = s.range(of: #"page-id=\{([0-9A-Fa-f-]{36})\}"#, options: .regularExpression) {
            pageID = String(s[r]).replacingOccurrences(of: "page-id={", with: "").replacingOccurrences(of: "}", with: "").uppercased()
        }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        guard let u = URL(string: s), let scheme = u.scheme, let host = u.host else { return nil }
        let path = u.path // schon dekodiert
        let parts = path.split(separator: "/")
        guard parts.count > 2, ["sites", "teams", "personal"].contains(parts[0]), path.lowercased().hasSuffix(".one") else { return nil }
        return Target(host: "\(scheme)://\(host)", site: "/\(parts[0])/\(parts[1])", section: path, pageID: pageID, order: sidebarOrder())
    }

    // Namen in der Abschnittsliste von OneNote (nur lesen)
    private static func sidebarOrder() -> [String] {
        guard let ax = UIAuto.app(OneNotePDF.bundle) else { return [] }
        let wins = UIAuto.attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for w in wins {
            guard let list = UIAuto.elements(w, windowsOnly: false).first(where: { UIAuto.role($0) == "AXOutline" && UIAuto.label($0) == "List of Sections" }) else { continue }
            return (UIAuto.attr(list, kAXRowsAttribute) as? [AXUIElement] ?? []).compactMap { r in
                UIAuto.elements(r, windowsOnly: false).lazy.map(UIAuto.label).first { !$0.isEmpty }
            }
        }
        return []
    }

    private static func copyLink(_ titles: [String]) -> String? {
        guard let ax = UIAuto.app(OneNotePDF.bundle), let bar = UIAuto.attr(ax, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
              let item = UIAuto.elements(bar, windowsOnly: false).first(where: { titles.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }) else { return nil }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { i in i.types.compactMap { t in i.data(forType: t).map { (t, $0) } } } ?? []
        let count = pb.changeCount
        UIAuto.press(item)
        for _ in 0..<60 where pb.changeCount == count { usleep(50_000) }
        let link = pb.changeCount != count ? pb.string(forType: .string) : nil
        // Zwischenablage wiederherstellen (auch damit der Verlauf den Link nicht als „kopiert“ zeigt)
        pb.clearContents()
        pb.writeObjects(saved.map { pairs in let i = NSPasteboardItem(); pairs.forEach { i.setData($1, forType: $0) }; return i })
        DispatchQueue.main.async { MainActor.assumeIsolated { ClipHistory.shared.skipCurrent() } }
        return link
    }

    // MARK: 2.–5. Gesamter Ablauf

    @MainActor static func export(_ scope: OneNotePDF.Scope, _ t: Target) async -> Result<URL, Failure> {
        let session = SPSession.shared
        let started = Date()
        wkLog("OneNote: Start \(scope) \(t.section)")
        defer { wkLog("OneNote: Ende nach \(Int(Date().timeIntervalSince(started))) s") }
        do {
            try await session.login(host: t.host, site: t.site)
            let sectionFolder = (t.section as NSString).deletingLastPathComponent
            // Notizbuch-Wurzel: oberster Ordner, der noch eine .onetoc2 enthält (Abschnittsgruppen haben eigene)
            var root = sectionFolder
            if scope == .notebook {
                while true {
                    let parent = (root as NSString).deletingLastPathComponent
                    guard parent.count > t.site.count, try await session.list(parent, recursive: false).contains(where: { $0.path.hasSuffix(".onetoc2") }) else { break }
                    root = parent
                }
            }
            let remote: [SPSession.Item] = scope == .notebook
                ? try await session.list(root, recursive: true).filter { !$0.path.contains("/OneNote_RecycleBin/") && ($0.path.hasSuffix(".one") || $0.path.hasSuffix(".onetoc2")) }
                : try await session.list(sectionFolder, recursive: false).filter { $0.path == t.section }
            guard !remote.isEmpty else { return .failure(Failure(text: L("Keine OneNote-Dateien gefunden", "No OneNote files found"))) }

            // Laden – nur, was sich geändert hat
            let cache = cacheDir(t.host).appendingPathComponent(root)
            let todo = remote.filter { !isCached($0, in: cache, root: root) }
            if !todo.isEmpty {
                let mb = todo.reduce(0) { $0 + $1.size } / 1_000_000
                Toast.show(L("OneNote: lade \(todo.count) Datei(en), \(mb) MB …", "OneNote: downloading \(todo.count) file(s), \(mb) MB…"), symbol: "icloud.and.arrow.down")
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var running = 0
                    for item in todo {
                        if running >= 4 { try await group.next(); running -= 1 }
                        let dest = cache.appendingPathComponent(String(item.path.dropFirst(root.count)))
                        group.addTask { @MainActor in try await session.download(item, host: t.host, site: t.site, to: dest) }
                        running += 1
                    }
                    try await group.waitForAll()
                }
            }
            Toast.show(L("OneNote: PDF wird erstellt …", "OneNote: creating PDF…"), symbol: "doc.richtext")

            // Umwandeln (im Hintergrund, Abschnitte gleichzeitig). Die Notizbuch-Datei (.onetoc2) liest der Umwandler
            // nicht zuverlässig – deshalb jeder Abschnitt einzeln, Reihenfolge wie in der OneNote-Seitenleiste.
            let sections: [String] = scope == .notebook
                ? OneNoteOrder.sort(remote.map(\.path).filter { $0.hasSuffix(".one") }.map { String($0.dropFirst(root.count)) }, order: t.order)
                : [String(t.section.dropFirst(root.count))]
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("WinKomfort-OneNote-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let indexes: [URL?] = try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
                for (i, rel) in sections.enumerated() {
                    group.addTask { (i, try? await convert(cache.appendingPathComponent(rel), into: work.appendingPathComponent("\(i)"))) }
                }
                var out = [URL?](repeating: nil, count: sections.count)
                for try await (i, u) in group { out[i] = u }
                return out
            }
            guard indexes.contains(where: { $0 != nil }) else { throw Failure(text: L("OneNote-Datei konnte nicht gelesen werden", "Couldn't read the OneNote file")) }
            // Abschnitte, die der Umwandler nicht lesen konnte, nicht stillschweigend weglassen
            let skipped = zip(sections, indexes).filter { $0.1 == nil }.map { (($0.0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            if !skipped.isEmpty {
                wkLog("OneNote: übersprungen \(skipped)")
                Toast.show(L("Nicht lesbar, übersprungen: \(skipped.joined(separator: ", "))", "Couldn't read, skipped: \(skipped.joined(separator: ", "))"), symbol: "exclamationmark.triangle")
            }

            // Seitenreihenfolge, bei „Diese Seite“ nur die passende Seite
            var pages = indexes.compactMap { $0 }.flatMap(pageOrder)
            if scope == .page, let id = t.pageID {
                pages = pages.filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("content=\"{\(id)}\"") == true }
            }
            guard !pages.isEmpty else { return .failure(Failure(text: L("Keine Seiten gefunden", "No pages found"))) }

            let quality = PDFQuality.current
            let dirs = Set(pages.map { $0.deletingLastPathComponent() })
            await Task.detached(priority: .userInitiated) { dirs.forEach { compressImages(in: $0, maxPx: quality.maxPx, q: quality.jpeg) } }.value

            let name: String = {
                switch scope {
                case .notebook: return (root as NSString).lastPathComponent
                case .section: return ((t.section as NSString).lastPathComponent as NSString).deletingPathExtension
                case .page: return pages.first.map { $0.deletingPathExtension().lastPathComponent } ?? "OneNote"
                }
            }()
            let out = uniqueDownload(name)
            try await PageRenderer().render(pages, root: work.resolvingSymlinksInPath(), to: out)
            return .success(out)
        } catch let e as Failure {
            wkLog("OneNote: Fehler \(e.text)")
            return .failure(e)
        } catch {
            return .failure(Failure(text: error.localizedDescription))
        }
    }

    // MARK: Zwischenspeicher

    static func cacheDir(_ host: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.winkomfort.app/OneNote", isDirectory: true)
        return base.appendingPathComponent(URL(string: host)?.host ?? "unbekannt", isDirectory: true)
    }
    private static func isCached(_ item: SPSession.Item, in cache: URL, root: String) -> Bool {
        let f = cache.appendingPathComponent(String(item.path.dropFirst(root.count)))
        guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        return v.fileSize == item.size && (v.contentModificationDate ?? .distantPast) >= item.modified.addingTimeInterval(-2)
    }

    // MARK: Umwandeln mit dem mitgelieferten Programm

    static func convert(_ input: URL, into out: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "onenote-html") else { throw Failure(text: L("Umwandler fehlt im App-Paket", "Converter missing from app bundle")) }
        let status: Int32 = try await Task.detached {
            let p = Process()
            p.executableURL = tool
            p.arguments = [input.path, out.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        guard status == 0 else { throw Failure(text: L("OneNote-Datei konnte nicht gelesen werden", "Couldn't read the OneNote file")) }
        // Index-Datei: beim Notizbuch die des Notizbuchs, sonst die des Abschnitts
        let htmls = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        if let idx = htmls.first(where: { $0.pathExtension == "html" }) { return idx }
        // Notizbuch: <out>/<Name>/<Name>.html bzw. index
        let nested = htmls.first { $0.hasDirectoryPath }
        if let n = nested, let idx = (try? FileManager.default.contentsOfDirectory(at: n, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "html" }) { return idx }
        throw Failure(text: L("Umwandlung lieferte nichts", "Conversion produced nothing"))
    }

    // Reihenfolge der Seiten aus den Index-Dateien (Notizbuch-Index verweist auf Abschnitts-Indizes)
    static func pageOrder(_ index: URL) -> [URL] {
        guard let html = try? String(contentsOf: index, encoding: .utf8) else { return [] }
        let base = index.deletingLastPathComponent()
        let re = try! NSRegularExpression(pattern: #"<a href="([^"]+)""#)
        var out: [URL] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html), let rel = String(html[r]).removingPercentEncoding, !rel.hasPrefix("http") else { continue }
            let trimmed = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
            // resolvingSymlinks statt standardized: /var und /private/var müssen gleich geschrieben sein, sonst verweigert WebKit das Lesen
            let u = base.appendingPathComponent(trimmed).resolvingSymlinksInPath()
            guard u != index.resolvingSymlinksInPath(), FileManager.default.fileExists(atPath: u.path) else { continue }
            // Verweis auf einen Abschnitts-Index (enthält selbst eine Seitenliste mit <nav>)
            if let sub = try? String(contentsOf: u, encoding: .utf8), sub.contains("<nav>"), sub.contains("target=\"content\"") {
                out += pageOrder(u)
            } else if !out.contains(u) {
                out.append(u)
            }
        }
        return out
    }

    static func uniqueDownload(_ name: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = downloads.appendingPathComponent("\(clean).pdf"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = downloads.appendingPathComponent("\(clean) \(n).pdf"); n += 1 }
        return url
    }

    // MARK: Bilder verkleinern (gleicher Dateiname – WebKit erkennt das Format am Inhalt)

    static func compressImages(in dir: URL, maxPx: Int, q: Double) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            guard ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff"].contains(f.pathExtension.lowercased()),
                  let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 40_000 || max(w, h) > maxPx else { continue }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxPx),
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { continue }
            // Fast farblose Bilder (gedruckte Arbeitsblätter) als Graustufen: gleiche Lesbarkeit, deutlich kleiner
            let gray = isGrayish(img)
            guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(.white) // JPEG kennt keine Transparenz
            ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let data = NSMutableData()
            guard let out = ctx.makeImage(), let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dst, out, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            if CGImageDestinationFinalize(dst), data.length < size { data.write(to: f, atomically: true) }
        }
    }
}

extension OneNoteCloud {
    // Stichprobe auf 48 px: höchste Farbsättigung unter 6 % → als Graustufen speichern
    static func isGrayish(_ img: CGImage) -> Bool {
        let n = 48
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var colored = 0
        for i in 0..<(n * n) {
            let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
            if max(r, g, b) - min(r, g, b) > 40 { colored += 1 }
        }
        return colored < n * n / 50 // < 2 % farbige Pixel (z. B. ein kleines Logo)
    }
}

// Qualitätsstufen: Kompakt (Standard) ≈ 120 dpi, gut lesbar · Hoch ≈ 200 dpi
enum PDFQuality: String, CaseIterable, Identifiable {
    case tiny, compact, balanced, high
    var id: String { rawValue }
    var maxPx: Int { switch self { case .tiny: 800; case .compact: 1000; case .balanced: 1400; case .high: 2200 } }
    var jpeg: Double { switch self { case .tiny: 0.3; case .compact: 0.35; case .balanced: 0.5; case .high: 0.75 } }
    var title: String {
        switch self {
        case .tiny: L("Sehr klein (zum Verschicken)", "Very small (for sending)")
        case .compact: L("Klein (gut lesbar)", "Small (readable)")
        case .balanced: L("Ausgewogen", "Balanced")
        case .high: L("Hohe Qualität", "High quality")
        }
    }
    static var current: PDFQuality { PDFQuality(rawValue: UserDefaults.standard.string(forKey: "onenoteQuality") ?? "") ?? .compact }
}

// MARK: - Sitzung mit SharePoint/OneDrive über einen unsichtbaren WebKit-Browser (deine eigene Anmeldung)

@MainActor final class SPSession: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    static let shared = SPSession()
    struct Item { let path: String; let size: Int; let modified: Date }

    private lazy var web: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default() // Anmeldung bleibt erhalten
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: cfg)
        w.navigationDelegate = self
        return w
    }()
    private var loaded: CheckedContinuation<Void, Never>?
    private var loginWindow: NSWindow?
    private var downloads: [ObjectIdentifier: (URL, CheckedContinuation<Void, Error>)] = [:]

    // Laden mit Zeitlimit – eine hängende Anmeldeseite darf den Export nie blockieren
    private func load(_ url: URL) async {
        await withCheckedContinuation { c in
            loaded = c
            web.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated { if let l = self?.loaded { self?.loaded = nil; wkLog("OneNote: Laden dauerte zu lange: \(url.host ?? "")"); l.resume() } }
            }
        }
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loaded?.resume(); loaded = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loaded?.resume(); loaded = nil }

    private func signedIn(_ host: String, _ site: String) async -> Bool {
        guard web.url?.host == URL(string: host)?.host else { return false }
        let ok = try? await web.callAsyncJavaScript("const r = await fetch(site + '/_api/web?$select=Title', { headers: { Accept: 'application/json;odata=nometadata' } }); return r.ok;",
                                                    arguments: ["site": site], contentWorld: .defaultClient) as? Bool
        return ok == true
    }

    // Einmalig sichtbar anmelden; danach reicht das gespeicherte Anmelde-Cookie (wird bei Bedarf still erneuert)
    func login(host: String, site: String) async throws {
        if await signedIn(host, site) { return }
        wkLog("OneNote: Anmeldung prüfen \(host)\(site)")
        await load(URL(string: host + site)!)
        for _ in 0..<20 where !(await signedIn(host, site)) { try await Task.sleep(nanoseconds: 300_000_000) } // stille Weiterleitung abwarten
        if await signedIn(host, site) { wkLog("OneNote: still angemeldet"); return }
        wkLog("OneNote: Anmeldefenster nötig")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Bei Microsoft anmelden – für OneNote als PDF", "Sign in to Microsoft – for OneNote to PDF")
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        loginWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        defer { w.orderOut(nil); w.contentView = nil; loginWindow = nil }
        for _ in 0..<600 { // bis 5 Minuten
            try await Task.sleep(nanoseconds: 500_000_000)
            guard w.isVisible else { throw OneNoteCloud.Failure(text: L("Anmeldung abgebrochen", "Sign-in cancelled")) }
            if web.url?.host == URL(string: host)?.host, await signedIn(host, site) { return }
        }
        throw OneNoteCloud.Failure(text: L("Anmeldung nicht abgeschlossen", "Sign-in not completed"))
    }

    // Dateien eines Ordners (serverrelativ) über die SharePoint-Schnittstelle
    func list(_ folder: String, recursive: Bool) async throws -> [Item] {
        let js = """
        const h = { headers: { Accept: 'application/json;odata=nometadata' } };
        const enc = p => encodeURIComponent(p).replace(/'/g, "''");
        async function ls(p) {
          const f = await (await fetch(`${site}/_api/web/GetFolderByServerRelativeUrl('${enc(p)}')/Files?$select=Name,Length,TimeLastModified`, h)).json();
          if (f['odata.error']) throw new Error(f['odata.error'].message.value);
          let out = (f.value || []).map(x => [p + '/' + x.Name, +x.Length, x.TimeLastModified]);
          if (recursive) {
            const d = await (await fetch(`${site}/_api/web/GetFolderByServerRelativeUrl('${enc(p)}')/Folders?$select=Name`, h)).json();
            for (const sub of (d.value || [])) out = out.concat(await ls(p + '/' + sub.Name));
          }
          return out;
        }
        return await ls(folder);
        """
        let site = folder.split(separator: "/").prefix(2).map { "/" + $0 }.joined()
        let raw = try await web.callAsyncJavaScript(js, arguments: ["site": site, "folder": folder, "recursive": recursive], contentWorld: .defaultClient) as? [[Any]] ?? []
        let iso = ISO8601DateFormatter()
        return raw.compactMap { a in
            guard let p = a[0] as? String, let s = a[1] as? Int ?? (a[1] as? Double).map(Int.init) else { return nil }
            return Item(path: p, size: s, modified: (a[2] as? String).flatMap(iso.date) ?? .distantPast)
        }
    }

    func download(_ item: Item, host: String, site: String, to dest: URL) async throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        let enc = item.path.replacingOccurrences(of: "'", with: "''").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&?#'"))) ?? item.path
        let url = URL(string: "\(host)\(site)/_api/web/GetFileByServerRelativeUrl('\(enc)')/$value")!
        let d = await web.startDownload(using: URLRequest(url: url))
        d.delegate = self
        try await withCheckedThrowingContinuation { c in downloads[ObjectIdentifier(d)] = (tmp, c) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        // Änderungsdatum wie auf dem Server → beim nächsten Mal erkennt der Zwischenspeicher „unverändert“
        try? FileManager.default.setAttributes([.modificationDate: item.modified], ofItemAtPath: dest.path)
    }
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        completionHandler(downloads[ObjectIdentifier(d)]?.0)
    }
    func downloadDidFinish(_ d: WKDownload) { downloads.removeValue(forKey: ObjectIdentifier(d))?.1.resume() }
    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) { downloads.removeValue(forKey: ObjectIdentifier(d))?.1.resume(throwing: e) }
}

// MARK: - Seiten (HTML) → PDF: Text und Handschrift als Vektor, Bilder als kleine JPEGs

@MainActor final class PageRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Never>?
    private var images: [String: CGImage] = [:]
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loaded?.resume(); loaded = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loaded?.resume(); loaded = nil }

    private func image(_ path: String) -> CGImage? {
        if let i = images[path] { return i }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let i = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        images[path] = i
        return i
    }

    func render(_ pages: [URL], root: URL, to out: URL) async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw OneNoteCloud.Failure(text: L("PDF konnte nicht angelegt werden", "Couldn't create the PDF"))
        }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), configuration: cfg)
        web.navigationDelegate = self
        let margin: CGFloat = 28, scale: CGFloat = 0.75 // 96 px = 72 pt, wie beim Drucken
        for (i, p) in pages.enumerated() {
            if i % 25 == 0 && i > 0 { Toast.show(L("OneNote: Seite \(i) von \(pages.count) …", "OneNote: page \(i) of \(pages.count)…"), symbol: "doc.richtext") }
            await withCheckedContinuation { c in loaded = c; web.loadFileURL(p, allowingReadAccessTo: root) }
            // Größe messen (Elemente sind absolut positioniert), Bilder merken und für WebKit ausblenden
            let info = try? await web.callAsyncJavaScript("""
                await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
                let w = 0, h = 0;
                for (const e of document.body.querySelectorAll('*')) { const r = e.getBoundingClientRect(); if (r.width && r.height) { w = Math.max(w, r.right); h = Math.max(h, r.bottom); } }
                const imgs = [...document.images].filter(i => i.naturalWidth > 0).map(i => { const r = i.getBoundingClientRect(); return [r.left + scrollX, r.top + scrollY, r.width, r.height, decodeURIComponent(new URL(i.src).pathname)]; });
                const st = document.createElement('style'); st.textContent = 'img { visibility: hidden !important; }'; document.head.appendChild(st);
                return [Math.ceil(w) + 24, Math.ceil(h) + 24, imgs];
                """, arguments: [:], contentWorld: .page) as? [Any]
            let w = max(info?[0] as? Double ?? 800, 700), h = max(info?[1] as? Double ?? 400, 200)
            let imgs: [(CGRect, String)] = ((info?[2] as? [[Any]]) ?? []).compactMap { a in
                guard a.count == 5, let x = a[0] as? Double, let y = a[1] as? Double, let iw = a[2] as? Double, let ih = a[3] as? Double,
                      let path = a[4] as? String, iw > 0, ih > 0 else { return nil }
                return (CGRect(x: x, y: y, width: iw, height: ih), path)
            }
            web.frame = CGRect(x: 0, y: 0, width: w, height: h)
            // Seite so breit wie der Inhalt, Höhe im A4-Verhältnis; jeder Ausschnitt einzeln (nur seine eigenen Inhalte)
            let pageW = max(w, 794) * scale + 2 * margin, pageH = pageW * 1.4142
            let sliceH = (pageH - 2 * margin) / scale
            var y: Double = 0
            while y < h - 1 {
                let sh = min(sliceH, h - y)
                let conf = WKPDFConfiguration()
                conf.rect = CGRect(x: 0, y: y, width: w, height: sh)
                guard let slice = try? await web.pdf(configuration: conf), let provider = CGDataProvider(data: slice as CFData),
                      let doc = CGPDFDocument(provider), let page = doc.page(at: 1) else { break }
                let src = page.getBoxRect(.mediaBox)
                var mb = CGRect(x: 0, y: 0, width: pageW, height: pageH)
                pdf.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mb, length: MemoryLayout<CGRect>.size)] as CFDictionary)
                pdf.translateBy(x: margin, y: pageH - margin - src.height * scale)
                pdf.scaleBy(x: scale, y: scale)
                pdf.translateBy(x: -src.minX, y: -src.minY)
                pdf.drawPDFPage(page)
                pdf.translateBy(x: src.minX, y: src.minY)
                for (r, path) in imgs where r.maxY > y && r.minY < y + sh {
                    guard let img = image(path) else { continue }
                    pdf.saveGState()
                    pdf.clip(to: CGRect(x: 0, y: src.height - sh, width: w, height: sh))
                    pdf.draw(img, in: CGRect(x: r.minX, y: src.height - (r.maxY - y), width: r.width, height: r.height))
                    pdf.restoreGState()
                }
                pdf.endPDFPage()
                y += sliceH
            }
        }
        pdf.closePDF()
        guard data.write(to: out, atomically: true) else { throw OneNoteCloud.Failure(text: L("PDF konnte nicht gespeichert werden", "Couldn't save the PDF")) }
    }
}
