// „Schön machen“: Notizen aus OneNote, Text oder ein Foto (Tafel, Blatt) → KI ordnet, rückt ein, setzt Formeln (29² statt 29^(2))
// → zurück in OneNote einfügen (⌘Z in OneNote macht es rückgängig)
import AppKit
import FoundationModels
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

@MainActor final class Tidy: ObservableObject {
    static let shared = Tidy()
    @Published var input = ""
    @Published var result = ""          // Auszeichnung (# Überschrift, - Punkt, Formeln mit ^ und _)
    @Published var busy: String?
    @Published var note: String?
    @Published var fromOneNote = false
    var image: CGImage?                 // Foto: das Modell sieht es mit, wenn es Bilder kann
    private var job: Task<Void, Never>?

    static func open() {
        let first = windows["tidy"] == nil
        showWindow("tidy", "Schön machen") { TidyView() }
        windows["tidy"]?.title = L("Notizen schön machen", "Tidy up notes")
        if first { windows["tidy"]?.setContentSize(NSSize(width: 860, height: 560)); windows["tidy"]?.center() }
    }
    static func open(text: String) { shared.set(text, image: nil, oneNote: false); open(); shared.run() }

    func set(_ t: String, image: CGImage?, oneNote: Bool) { job?.cancel(); input = t; self.image = image; fromOneNote = oneNote; result = ""; note = nil; busy = nil }

    // Markierten Inhalt aus OneNote holen: OneNote nach vorne, ⌘C, Zwischenablage lesen
    func fromOneNoteSelection() {
        guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; note = L("Erst Bedienungshilfen für WinKomfort erlauben.", "Allow Accessibility for WinKomfort first."); return }
        guard let one = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == OneNotePDF.bundle }) else { note = L("OneNote läuft nicht.", "OneNote isn't running."); return }
        busy = L("Hole die Markierung aus OneNote …", "Getting the selection from OneNote…")
        Task {
            defer { busy = nil }
            guard await Self.front(one) else { note = L("OneNote kam nicht nach vorne.", "OneNote didn't come to the front."); return }
            let pb = NSPasteboard.general, before = pb.changeCount
            Self.key(8) // C
            for _ in 0..<20 where pb.changeCount == before { try? await Task.sleep(for: .milliseconds(50)) }
            Tidy.open()
            guard pb.changeCount != before, let t = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                note = L("Nichts markiert. In OneNote Text markieren (z. B. ⌘A im Notizfeld), dann noch mal.", "Nothing selected. Select text in OneNote (e.g. ⌘A in a note container), then try again."); return
            }
            set(t, image: nil, oneNote: true)
            run()
        }
    }
    // Foto oder PDF: Text erkennen, Einrückung aus der Lage
    func load(_ u: URL) {
        let img: CGImage?
        if u.pathExtension.lowercased() == "pdf", let pg = PDFDocument(url: u)?.page(at: 0) { img = SheetReader.raster(pg).map(\.img) }
        else { img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard let img else { note = L("Die Datei ließ sich nicht öffnen.", "Couldn't open the file."); return }
        take(img)
    }
    func take(_ img: CGImage) {
        set("", image: img, oneNote: false)
        busy = L("Lese das Bild …", "Reading the image…")
        job = Task {
            let t = await Task.detached(priority: .userInitiated) { () -> String in
                let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.recognitionLanguages = ["de-DE", "en-US"]; r.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: img).perform([r])
                return TidyLogic.lines((r.results ?? []).compactMap { o in o.topCandidates(1).first.map { ($0.string, Double(o.boundingBox.minX), Double(o.boundingBox.midY), Double(o.boundingBox.height)) } })
            }.value
            guard !Task.isCancelled else { return }
            busy = nil
            guard !t.isEmpty else { note = L("Auf dem Bild wurde kein Text erkannt.", "No text found in the image."); return }
            input = t
            run()
        }
    }

    // KI ordnet; ohne KI (oder wenn sie Inhalt verschluckt) nur Formeln und Aufzählungen sauber setzen
    func run() {
        let src = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return }
        job?.cancel(); note = nil
        guard Assistant.available, #available(macOS 26.0, *) else {
            result = src; note = L("Ohne Apple Intelligence: nur Formeln und Aufzählungen gesetzt.", "Without Apple Intelligence: only formulas and lists formatted."); return
        }
        busy = L("KI ordnet deine Notizen …", "AI is tidying your notes…")
        let img = AI.vision ? image : nil
        job = Task {
            defer { if !Task.isCancelled { busy = nil } }
            var out: [String] = []
            let parts = TidyLogic.chunks(src)
            for (i, p) in parts.enumerated() {
                if parts.count > 1 { busy = L("KI ordnet … Teil \(i + 1) von \(parts.count)", "AI is tidying… part \(i + 1) of \(parts.count)") }
                let r = await Self.ask(p, image: i == 0 ? img : nil)
                guard !Task.isCancelled else { return }
                if let r, TidyLogic.kept(p, r) { out.append(r) } else { out.append(p); note = L("Ein Teil blieb unverändert, damit nichts verloren geht.", "Part was left as is so nothing gets lost.") }
            }
            result = out.joined(separator: "\n\n")
        }
    }
    @available(macOS 26.0, *)
    private static func ask(_ text: String, image: CGImage?) async -> String? {
        let s = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: """
        Du machst Schulnotizen übersichtlich, wie ein ordentlicher Schüler sie in OneNote schreiben würde. Gib denselben Inhalt geordnet zurück: \
        nichts weglassen, nichts dazuerfinden, Fehler der Texterkennung und Tippfehler verbessern, Sprache beibehalten.
        Format, eine Angabe pro Zeile:
        # Überschrift (nur eine, ganz oben, wenn es ein Thema gibt)
        ## Zwischenüberschrift
        - Stichpunkt
          - Unterpunkt (zwei Leerzeichen davor)
        1. Schritt einer Anleitung oder Rechnung
        **Fachbegriff** fett.
        Formeln in eine eigene Zeile, mit ^ für Hochzahlen wie 29^2 oder x^(n+1), _ für Indizes wie x_1, sqrt() für Wurzeln, * für mal.
        Nur die Notizen, keine Einleitung und kein Kommentar.
        """)
        let q = "Mach diese Notizen übersichtlich:\n\n" + text
        do {
            if #available(macOS 27.0, *), let image, let small = await Task.detached(operation: { AIRead.image(image, name: "Bild")?.cg }).value { // verkleinert
                return TidyLogic.clean(try await s.respond(options: GenerationOptions(), prompt: { Attachment(small); q + "\n\n(Das Foto ist dabei: Formeln und Einrückungen von dort übernehmen.)" }).content)
            }
            return TidyLogic.clean(try await s.respond(to: q).content)
        } catch { return nil }
    }

    // Ausgabe: HTML (OneNote übernimmt Überschriften, Listen, Hochzahlen), RTF und Klartext
    func write(to pb: NSPasteboard) {
        let html = TidyLogic.html(result)
        pb.clearContents()
        pb.setString(html, forType: .html)
        if let a = try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
           let rtf = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { pb.setData(rtf, forType: .rtf) }
        pb.setString(TidyLogic.plain(result), forType: .string)
    }
    func copy() { write(to: .general); Toast.show(L("Kopiert – in OneNote mit ⌘V einfügen", "Copied – paste into OneNote with ⌘V"), symbol: "doc.on.doc") }
    func paste() {
        guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; return }
        guard let one = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == OneNotePDF.bundle }) else { copy(); note = L("OneNote läuft nicht – ist kopiert.", "OneNote isn't running – copied instead."); return }
        write(to: .general)
        Task {
            guard await Self.front(one) else { note = L("OneNote kam nicht nach vorne – ist kopiert.", "OneNote didn't come to the front – copied instead."); return }
            Self.key(9) // V
            Toast.show(fromOneNote ? L("Ersetzt – ⌘Z in OneNote macht es rückgängig", "Replaced – ⌘Z in OneNote undoes it") : L("In OneNote eingefügt", "Pasted into OneNote"), symbol: "sparkles")
        }
    }
    // Tasten nur, wenn OneNote wirklich vorne ist
    private static func front(_ app: NSRunningApplication) async -> Bool {
        app.activate()
        for _ in 0..<20 { if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { try? await Task.sleep(for: .milliseconds(150)); return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return false
    }
    private static func key(_ code: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = .maskCommand; e?.post(tap: .cghidEventTap) }
    }
}

// MARK: Oberfläche
struct TidyView: View {
    @ObservedObject var t = Tidy.shared
    @StateObject private var drop = TextBox<Bool>() // @State geht im swiftc-Build nicht
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { t.fromOneNoteSelection() } label: { Label(L("Markierung aus OneNote", "Selection from OneNote"), systemImage: "text.badge.checkmark") }
                    .help(L("In OneNote Text markieren, dann hier klicken. Bilder und Handschrift nicht mit markieren, die bleiben sonst nicht erhalten.", "Select text in OneNote, then click here. Don't include images or ink – they wouldn't be kept."))
                Button { pick() } label: { Label(L("Foto / Tafelbild …", "Photo / whiteboard…"), systemImage: "photo") }
                Button { Scanner.open(forTidy: true) } label: { Label(L("Blatt scannen", "Scan a sheet"), systemImage: "doc.viewfinder") }
                Spacer()
                if let b = t.busy { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Vorher", "Before")).font(.headline).foregroundStyle(.secondary)
                    TextEditor(text: $t.input).font(.body.monospaced()).scrollContentBackground(.hidden).padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { if t.input.isEmpty { Text(L("Notizen hier einfügen, ein Foto hineinziehen oder oben eine Quelle wählen", "Paste notes here, drop a photo, or pick a source above")).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(30).allowsHitTesting(false) } }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(drop.value == true ? Color.accentColor : .clear, lineWidth: 2))
                        .accessibilityLabel(L("Notizen vorher", "Notes before"))
                    Button(L("Schön machen", "Tidy up")) { t.run() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(t.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || t.busy != nil)
                }
                .padding(12).frame(maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Nachher", "After")).font(.headline).foregroundStyle(.secondary)
                    Group {
                        if t.result.isEmpty { Color(nsColor: .textBackgroundColor).overlay { Text(t.busy == nil ? L("Hier erscheint die geordnete Fassung", "The tidy version appears here") : "").foregroundStyle(.tertiary) } }
                        else { RichPreview(html: TidyLogic.html(t.result)) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        if let n = t.note { Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        Spacer()
                        Button(L("Kopieren", "Copy")) { t.copy() }.disabled(t.result.isEmpty)
                        Button(t.fromOneNote ? L("In OneNote ersetzen", "Replace in OneNote") : L("In OneNote einfügen", "Paste into OneNote")) { t.paste() }
                            .buttonStyle(.borderedProminent).disabled(t.result.isEmpty)
                            .help(L("Fügt an der Einfügemarke in OneNote ein; eine Markierung wird ersetzt. ⌘Z in OneNote macht es rückgängig.", "Pastes at the cursor in OneNote, replacing a selection. ⌘Z in OneNote undoes it."))
                    }
                }
                .padding(12).frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { drop.value == true }, set: { drop.value = $0 })) { items in
            guard let i = items.first else { return false }
            if i.canLoadObject(ofClass: URL.self) { _ = i.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in Tidy.shared.load(u) } } }; return true }
            _ = i.loadObject(ofClass: NSImage.self) { o, _ in if let img = (o as? NSImage)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { Task { @MainActor in Tidy.shared.take(img) } } }
            return true
        }
    }
    private func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image, .pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        t.load(u)
    }
}

// Vorschau so, wie OneNote es zeigt (gleiches HTML)
private struct RichPreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> NSScrollView {
        let s = NSScrollView(), v = NSTextView(usingTextLayoutManager: false) // TextKit 1: TextKit 2 zeigt HTML-Listenpunkte doppelt
        v.isEditable = false; v.textContainerInset = NSSize(width: 10, height: 10); v.drawsBackground = true; v.backgroundColor = .white
        v.isVerticallyResizable = true; v.autoresizingMask = [.width]; v.textContainer?.widthTracksTextView = true
        s.documentView = v; s.hasVerticalScroller = true; s.drawsBackground = false
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let v = s.documentView as? NSTextView, context.coordinator.last != html else { return }
        context.coordinator.last = html
        let a = (try? NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)) ?? NSAttributedString(string: html)
        v.textStorage?.setAttributedString(a)
    }
    func makeCoordinator() -> Box { Box() }
    final class Box { var last = "" }
}

// „Mit iPhone aufnehmen“: Apples Integrationskamera (Foto, Dokument scannen) – macOS füllt das Menü selbst
struct PhoneImportButton: NSViewRepresentable {
    let title: String
    let onImage: (CGImage) -> Void
    func makeNSView(context: Context) -> Host { let h = Host(); h.setup(title); h.onImage = onImage; return h }
    func updateNSView(_ h: Host, context: Context) { h.onImage = onImage }
    final class Host: NSView, NSServicesMenuRequestor {
        var onImage: ((CGImage) -> Void)?
        private let button = NSButton()
        func setup(_ t: String) {
            button.title = t; button.bezelStyle = .push; button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil); button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(show)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor), button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
        @objc private func show() {
            window?.makeFirstResponder(self)
            let m = NSMenu(), i = NSMenuItem(title: L("Vom iPhone importieren", "Import from iPhone"), action: nil, keyEquivalent: "")
            i.identifier = NSMenuItem.importFromDeviceIdentifier
            m.addItem(i)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }
        override func validRequestor(forSendType s: NSPasteboard.PasteboardType?, returnType r: NSPasteboard.PasteboardType?) -> Any? {
            if s == nil, let r, r == .pdf || NSImage.imageTypes.contains(r.rawValue) { return self }
            return super.validRequestor(forSendType: s, returnType: r)
        }
        func writeSelection(to pb: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
        func readSelection(from pb: NSPasteboard) -> Bool {
            if let d = pb.data(forType: .pdf), let pg = PDFDocument(data: d)?.page(at: 0), let r = SheetReader.raster(pg, k: 3) { onImage?(r.img); return true } // gescanntes Dokument
            if let img = NSImage(pasteboard: pb)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { onImage?(img); return true }
            return false
        }
    }
}
