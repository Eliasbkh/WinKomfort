// Lernzettel: KI liest OneNote-Abschnitte/Notizbücher und weiteres Material, beachtet deine Angaben zur Arbeit
// und schreibt einen gegliederten Lernzettel (Merke-Kästen, Formeln, typische Fehler, Selbsttest) → PDF, OneNote, Lernkarten
import AppKit
import FoundationModels
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

@MainActor final class Study: ObservableObject {
    static let shared = Study()
    struct Source: Identifiable { let id = UUID(); let name: String; let symbol: String; let text: String }
    @Published var sources: [Source] = []
    @Published var context = ""     // worum es in der Arbeit geht
    @Published var extra = ""       // eigener Zusatz, Hinweise vom Lehrer
    @Published var result = ""      // Auszeichnung wie bei „Schön machen“
    @Published var busy: String?
    @Published var note: String?
    private var job: Task<Void, Never>?
    var title: String { TidyLogic.parse(result).first { $0.kind == .h1 }?.text ?? L("Lernzettel", "Study sheet") }

    static func open() {
        let first = windows["study"] == nil
        showWindow("study", "Lernzettel") { StudyView() }
        windows["study"]?.title = L("Lernzettel", "Study sheet")
        if first { windows["study"]?.setContentSize(NSSize(width: 980, height: 660)); windows["study"]?.center() }
    }

    // MARK: Material
    // OneNote: aktueller Abschnitt oder ganzes Notizbuch über die Cloud (wie „OneNote → PDF“), dann Text + Handschrift lesen
    func addOneNote(_ scope: OneNotePDF.Scope) {
        guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: OneNotePDF.bundle).first != nil else { note = L("OneNote ist nicht geöffnet. Öffne den Abschnitt in OneNote, dann noch mal.", "OneNote isn't open. Open the section in OneNote, then try again."); return }
        busy = scope == .notebook ? L("Lade das Notizbuch aus OneNote …", "Loading the notebook from OneNote…") : L("Lade den Abschnitt aus OneNote …", "Loading the section from OneNote…")
        note = nil
        Task {
            defer { busy = nil }
            guard let t = await Task.detached(priority: .userInitiated, operation: { OneNoteCloud.target(scope) }).value else {
                note = L("Das Notizbuch liegt nicht in OneDrive/SharePoint. Dann in OneNote als PDF sichern und hier als Datei hinzufügen.", "The notebook isn't in OneDrive/SharePoint. Save it as PDF in OneNote and add it here as a file."); return
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("WinKomfort-Lernzettel-\(UUID().uuidString.prefix(6)).pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            switch await OneNoteCloud.export(scope, t, into: tmp) {
            case .failure(let e): note = e.text
            case .success(let u):
                busy = L("Lese Text und Handschrift …", "Reading text and handwriting…")
                let text = await Task.detached(priority: .userInitiated) { Study.read(pdf: u) }.value
                let name = scope == .notebook ? ((t.section as NSString).deletingLastPathComponent as NSString).lastPathComponent : ((t.section as NSString).lastPathComponent as NSString).deletingPathExtension
                add(Source(name: "OneNote: " + name, symbol: "doc.richtext", text: text))
            }
        }
    }
    // Text der Seite plus Handschrift (OneNote-Stift ist Tinte, kein Text): Seite lesen, neue Zeilen ergänzen
    nonisolated static func read(pdf u: URL) -> String {
        guard let d = PDFDocument(url: u) else { return "" }
        var out = ""
        for i in 0..<min(d.pageCount, 150) {
            guard let p = d.page(at: i) else { continue }
            let typed = p.string ?? ""
            let have = typed.lowercased().filter { $0.isLetter || $0.isNumber }
            var s = typed
            if let cg = p.thumbnail(of: NSSize(width: 1600, height: 2260), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let ink = Tools.read(cg).components(separatedBy: "\n").filter { l in
                    let k = l.lowercased().filter { $0.isLetter || $0.isNumber }
                    return k.count >= 3 && !have.contains(k)
                }
                if !ink.isEmpty { s += "\n" + ink.joined(separator: "\n") }
            }
            out += s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return out
    }
    func addFiles(_ urls: [URL]) {
        busy = L("Lese Material …", "Reading material…")
        Task {
            defer { busy = nil }
            for u in urls {
                switch await Task.detached(priority: .userInitiated, operation: { AIRead.file(u) }).value {
                case .success(let d): add(Source(name: d.name, symbol: d.isImage ? "photo" : "doc.text", text: d.text))
                case .failure(.text(let m)): note = m
                }
            }
        }
    }
    func addImage(_ img: CGImage) {
        busy = L("Lese das Foto …", "Reading the photo…")
        Task {
            let t = await Task.detached(priority: .userInitiated) { Tools.read(img) }.value
            busy = nil
            add(Source(name: L("Foto vom iPhone", "Photo from iPhone"), symbol: "iphone", text: t))
        }
    }
    private func add(_ s: Source) {
        guard !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { note = L("In „\(s.name)“ wurde kein Text gefunden.", "No text found in “\(s.name)”."); return }
        sources.append(s)
    }

    // MARK: KI
    func make() {
        guard AI.ready(), #available(macOS 26.0, *) else { return }
        let material = (sources.map { "### " + $0.name + "\n" + $0.text } + (extra.isEmpty ? [] : ["### " + L("Zusatz vom Schüler", "Extra from the student") + "\n" + extra])).joined(separator: "\n\n")
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty || !ctx.isEmpty else { note = L("Füge Material hinzu oder schreib, worum es geht.", "Add material or say what it's about."); return }
        job?.cancel(); note = material.isEmpty ? L("Ohne Material schreibt die KI aus allgemeinem Wissen – bitte genau prüfen.", "Without material the AI writes from general knowledge – check carefully.") : nil
        job = Task {
            defer { busy = nil }
            var notes = material
            // Viel Material: erst Wichtiges herausziehen (Teil für Teil), bis es in einen Durchgang passt
            var round = 0
            while notes.count > 3500, round < 3, !Task.isCancelled {
                let parts = TidyLogic.chunks(notes, max: 3000)
                var out: [String] = []
                for (i, p) in parts.enumerated() {
                    busy = round == 0 ? L("Lese dein Material … \(i + 1) von \(parts.count)", "Reading your material… \(i + 1) of \(parts.count)") : L("Fasse zusammen … \(i + 1) von \(parts.count)", "Condensing… \(i + 1) of \(parts.count)")
                    if let r = await Self.ask(Self.extractRules, (ctx.isEmpty ? "" : "Worum es in der Arbeit geht: \(ctx)\n\n") + "Material:\n" + p) { out.append(r) }
                    if Task.isCancelled { return }
                }
                guard !out.isEmpty else { break }
                notes = out.joined(separator: "\n"); round += 1
            }
            busy = L("Schreibe den Lernzettel …", "Writing the study sheet…")
            let q = (ctx.isEmpty ? "" : "Angaben des Schülers zur Arbeit: \(ctx)\n\n") + (notes.isEmpty ? "Kein Material: schreibe aus gesichertem Schulwissen." : "Material (Notizen, Mitschriften, Blätter):\n" + notes)
            var r = await Self.ask(Self.sheetRules, String(q.prefix(4200)))
            if r == nil, !Task.isCancelled { r = await Self.ask(Self.sheetRules, String(q.prefix(2600))) } // zu lang fürs Modell: kürzer noch einmal
            guard !Task.isCancelled else { return }
            guard let r, r.count > 40 else { note = L("Die KI konnte keinen Lernzettel schreiben. Weniger Material wählen oder noch mal versuchen.", "The AI couldn't write a study sheet. Choose less material or try again."); return }
            result = r.hasPrefix("#") ? r : "# " + (ctx.isEmpty ? L("Lernzettel", "Study sheet") : String(ctx.prefix(60))) + "\n" + r
        }
    }
    func cancel() { job?.cancel(); job = nil; busy = nil }

    nonisolated static let extractRules = "Du hilfst Schülern beim Lernen. Aus Mitschriften und Arbeitsblättern schreibst du heraus, was man für eine Arbeit können muss: Definitionen, Regeln, Formeln mit Einheiten, Abläufe, Zusammenhänge, wichtige Beispiele und Rechenwege. Stichpunkte mit '- ', kurz, Formeln ohne LaTeX. Nichts erfinden. Datum, Uhrzeit, Organisatorisches und Doppeltes weglassen. Die Texterkennung kann Fehler haben: sinnvoll verbessern. Wenn angegeben ist, worum es in der Arbeit geht, nur das Passende."
    nonisolated static let sheetRules = """
    Du schreibst Lernzettel für Schüler: eine Übersicht, die man vor einer Arbeit durchliest und mit der man wirklich lernt. \
    Nur Inhalte aus dem Material und den Angaben des Schülers. Klar, knapp, nach Themen gegliedert, das Wichtigste zuerst, sinnvolle Reihenfolge zum Lernen.
    Format, eine Angabe pro Zeile:
    # Thema des Lernzettels
    ## Teilthema
    - Stichpunkt, kurz
      - Unterpunkt (zwei Leerzeichen davor)
    > Merke: die wichtigste Regel oder Definition des Teilthemas (höchstens ein Merke pro Teilthema)
    **Fachbegriff**: Erklärung in einem Satz
    Formeln in eine eigene Zeile, mit ^ für Hochzahlen, _ für Indizes, sqrt() für Wurzeln, * für mal, / für Brüche, mit Einheiten. Kein LaTeX, keine $-Zeichen.
    Höchstens 8 Teilthemen, jedes mit wenigen, wirklich wichtigen Punkten. Nur, was sicher stimmt: Bist du unsicher, lass es weg.
    Zum Schluss genau diese zwei Abschnitte:
    ## Typische Fehler
    - 2 bis 4 Fehler, die man leicht macht
    ## Teste dich selbst
    1. 3 bis 6 Fragen, mit denen man prüft, ob man es kann
    Nur der Lernzettel, keine Einleitung und kein Kommentar.
    """
    @available(macOS 26.0, *)
    private static func ask(_ rules: String, _ q: String) async -> String? {
        let s = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: rules)
        guard let r = try? await s.respond(to: q, options: GenerationOptions(temperature: 0.3)).content else { return nil } // wenig Fantasie: Fakten statt Erfindungen
        let c = TidyLogic.clean(r)
        return c.isEmpty ? nil : c
    }

    // MARK: Ausgabe
    func savePDF() {
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = Scanner.clean(L("Lernzettel – ", "Study sheet – ") + title) + ".pdf"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(L("Lernzettel", "Study sheets"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); p.directoryURL = dir
        guard p.runModal() == .OK, let u = p.url else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("WinKomfort-Zettel-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let page = work.appendingPathComponent("zettel.html")
        busy = L("Erstelle die PDF …", "Creating the PDF…")
        Task {
            defer { busy = nil; try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try TidyLogic.sheet(result).write(to: page, atomically: true, encoding: .utf8)
                try await PageRenderer.render([page], root: work.resolvingSymlinksInPath(), to: u)
                NSWorkspace.shared.activateFileViewerSelecting([u])
                Toast.show(L("Lernzettel als PDF gesichert", "Study sheet saved as PDF"), symbol: "doc.text")
            } catch { note = (error as? OneNoteCloud.Failure)?.text ?? error.localizedDescription }
        }
    }
    func toOneNote() { Tidy.paste(result, replacing: false) { [weak self] in self?.note = $0 } }
    func cards() {
        guard AI.ready(), #available(macOS 26.0, *) else { return }
        busy = L("Erstelle Lernkarten …", "Creating flashcards…")
        let sheet = TidyLogic.plain(result), name = title
        Task {
            defer { busy = nil }
            let r = await Self.ask("Du erstellst Lernkarten für Schüler. Nur Fakten aus dem Lernzettel, nichts erfinden.", "Erstelle 8 bis 16 Lernkarten zu diesem Lernzettel. Eine Karte pro Zeile im Format: Frage | Antwort. Sonst nichts.\n\n" + String(sheet.prefix(3500))) ?? ""
            let c = Plan.cards(r)
            guard !c.isEmpty else { note = L("Daraus ließen sich keine Lernkarten machen.", "Couldn't make flashcards from this."); return }
            School.shared.book.decks.append(Plan.Deck(name: name, cards: c))
            Toast.show(L("\(c.count) Lernkarten in Schule › Lernkarten", "\(c.count) flashcards in School › Flashcards"), symbol: "rectangle.on.rectangle")
            School.open("karten")
        }
    }
}

// MARK: Oberfläche
struct StudyView: View {
    @ObservedObject var s = Study.shared
    @StateObject private var drop = TextBox<Bool>()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Worum geht's?", "What's it about?")).font(.headline)
                    TextField(L("z. B. Chemie-Klausur am Freitag: Reaktionsgeschwindigkeit, Katalyse, Rechnen mit Diagrammen", "e.g. Chemistry test on Friday: reaction rate, catalysis, calculations"), text: $s.context, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Material", "Material")).font(.headline)
                    if s.sources.isEmpty {
                        Text(L("Hol einen OneNote-Abschnitt oder das ganze Notizbuch, füge Blätter, PDFs oder Fotos hinzu oder zieh sie hierher.", "Add a OneNote section or the whole notebook, worksheets, PDFs or photos, or drag them here."))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(drop.value == true ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(s.sources) { src in
                                HStack(spacing: 8) {
                                    Image(systemName: src.symbol).foregroundStyle(.secondary).frame(width: 18)
                                    Text(src.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(L("\(src.text.split(separator: " ").count) Wörter", "\(src.text.split(separator: " ").count) words")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    Button { s.sources.removeAll { $0.id == src.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                        .buttonStyle(.plain).accessibilityLabel(L("\(src.name) entfernen", "Remove \(src.name)"))
                                }
                                .padding(.vertical, 6).padding(.horizontal, 10)
                                if src.id != s.sources.last?.id { Divider() }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(drop.value == true ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    HStack(spacing: 8) {
                        Menu {
                            Button(L("Aktueller Abschnitt", "Current section")) { s.addOneNote(.section) }
                            Button(L("Ganzes Notizbuch", "Whole notebook")) { s.addOneNote(.notebook) }
                        } label: { Label("OneNote", systemImage: "doc.richtext") }.fixedSize()
                        Button { pick() } label: { Label(L("Datei …", "File…"), systemImage: "doc.badge.plus") }
                        PhoneImportButton(title: L("iPhone", "iPhone")) { s.addImage($0) }.fixedSize()
                    }
                    .disabled(s.busy != nil)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Eigener Zusatz", "Your additions")).font(.headline)
                    TextEditor(text: $s.extra).font(.body).scrollContentBackground(.hidden).padding(4).frame(minHeight: 70, maxHeight: 120)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) { if s.extra.isEmpty { Text(L("Hinweise vom Lehrer, was drankommt, eigene Notizen …", "Teacher's hints, what's on the test, own notes…")).foregroundStyle(.tertiary).padding(9).allowsHitTesting(false) } }
                        .accessibilityLabel(L("Eigener Zusatz", "Your additions"))
                }
                Spacer(minLength: 0)
                if let b = s.busy {
                    HStack { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary).lineLimit(2); Spacer(); Button(L("Abbrechen", "Cancel")) { s.cancel() }.controlSize(.small) }
                }
                Button { s.make() } label: { Label(L("Lernzettel erstellen", "Create study sheet"), systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                    .disabled(s.busy != nil || (s.sources.isEmpty && s.context.trimmingCharacters(in: .whitespaces).isEmpty && s.extra.isEmpty))
            }
            .padding(18).frame(width: 360)
            Divider()
            VStack(spacing: 10) {
                Group {
                    if s.result.isEmpty {
                        ContentUnavailableView(L("Noch kein Lernzettel", "No study sheet yet"), systemImage: "list.bullet.rectangle.portrait",
                                               description: Text(L("Gegliedert nach Themen, mit Merke-Kästen, Formeln, typischen Fehlern und Fragen zum Selbsttest.", "Organized by topic, with key-point boxes, formulas, common mistakes and self-test questions.")))
                    } else { RichPreview(html: TidyLogic.sheet(s.result)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    if let n = s.note { Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    Spacer()
                    Button(L("Lernkarten", "Flashcards")) { s.cards() }.help(L("Fragen und Antworten in Schule › Lernkarten", "Questions and answers in School › Flashcards"))
                    Button(L("In OneNote", "Into OneNote")) { s.toOneNote() }.help(L("An der Einfügemarke in OneNote einfügen", "Paste at the cursor in OneNote"))
                    Button(L("Als PDF sichern …", "Save as PDF…")) { s.savePDF() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                }
                .disabled(s.result.isEmpty || s.busy != nil)
            }
            .padding(14)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { drop.value == true }, set: { drop.value = $0 })) { items in
            for i in items { _ = i.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in Study.shared.addFiles([u]) } } } }
            return !items.isEmpty
        }
    }
    private func pick() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.pdf, .image, .plainText, .rtf, .data]
        guard p.runModal() == .OK else { return }
        s.addFiles(p.urls)
    }
}
