// Chatfenster der KI
import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum Speech {
    private static let voice = AVSpeechSynthesizer()
    static func toggle(_ t: String) {
        if voice.isSpeaking { voice.stopSpeaking(at: .immediate); return }
        let u = AVSpeechUtterance(string: t.replacingOccurrences(of: "[#*`|_]", with: "", options: .regularExpression))
        let l = NSLinguisticTagger.dominantLanguage(for: t) ?? "de"
        u.voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(l) }.max { $0.quality.rawValue < $1.quality.rawValue }
        voice.speak(u)
    }
    static func stop() { voice.stopSpeaking(at: .immediate) }
}

private func rich(_ s: String) -> AttributedString { (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s) }

// Antwort mit Überschriften, Listen, Tabellen und Code
struct AIMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AILogic.blocks(AILogic.tidy(text)).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func block(_ b: AILogic.Block) -> some View {
        switch b {
        case .text(let s): Text(rich(s)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let n, let s): Text(rich(s)).font(n == 1 ? .title2 : n == 2 ? .title3 : .headline).fontWeight(.semibold).padding(.top, 4).accessibilityAddTraits(.isHeader)
        case .item(let d, let m, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 16, alignment: .trailing)
                Text(rich(s)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(d, 4)) * 18)
        case .quote(let s):
            Text(rich(s)).foregroundStyle(.secondary).padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
        case .rule: Divider()
        case .code(let lang, let s):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(lang.isEmpty ? L("Code", "Code") : lang).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Kopieren", "Copy")) { SearchSlash.put(s) }.buttonStyle(.borderless).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                ScrollView(.horizontal, showsIndicators: false) { Text(s).font(.system(.callout, design: .monospaced)).padding(12) }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in Text(rich(c)).fontWeight(i == 0 ? .semibold : .regular).frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true) } }
                        if i == 0 { Divider() }
                    }
                }
                .padding(12)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// Anhang als Kachel
private struct DocChip: View {
    let doc: AIDoc
    var remove: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            if let j = doc.jpeg, let i = NSImage(data: j) { Image(nsImage: i).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5)) }
            else { Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (doc.name as NSString).pathExtension) ?? .plainText)).resizable().frame(width: 28, height: 28) }
            Text(doc.name).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
            if let remove { Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help(L("Entfernen", "Remove")).accessibilityLabel(L("\(doc.name) entfernen", "Remove \(doc.name)")) }
        }
        .padding(6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

struct AIView: View {
    @ObservedObject var c = AIChat.shared
    @FocusState private var focused: Bool
    @StateObject private var sidebar = TextBox<Bool>()
    @StateObject private var over = TextBox<Bool>()
    @StateObject private var setup = TextBox<Bool>()
    @StateObject private var wipe = TextBox<Bool>()
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        HStack(spacing: 0) {
            if sidebar.value ?? true { history.frame(width: 210).background(.regularMaterial); Divider() }
            VStack(spacing: 0) {
                bar
                Divider()
                if c.messages.isEmpty { welcome } else { thread }
                composer
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .environment(\.openURL, OpenURLAction { u in ["http", "https"].contains(u.scheme ?? "") ? .systemAction : .discarded }) // Antworten dürfen keine Dateien oder Apps öffnen
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { over.value ?? false }, set: { over.value = $0 })) { drop($0) }
        .overlay { if over.value == true { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(6).allowsHitTesting(false) } }
        .alert(c.problem ?? "", isPresented: Binding(get: { c.problem != nil }, set: { if !$0 { c.problem = nil } })) { Button("OK") { c.problem = nil } }
        .sheet(isPresented: Binding(get: { setup.value ?? false }, set: { setup.value = $0 })) { AISetup { setup.value = false } }
        .confirmationDialog(L("Alle Unterhaltungen löschen?", "Delete all conversations?"), isPresented: Binding(get: { wipe.value ?? false }, set: { wipe.value = $0 })) {
            Button(L("Alle löschen", "Delete all"), role: .destructive) { c.deleteAll() }
        } message: { Text(L("Das lässt sich nicht rückgängig machen.", "This can't be undone.")) }
        .onAppear { focused = true }
        .onDisappear { Speech.stop() }
    }

    private func drop(_ ps: [NSItemProvider]) -> Bool {
        for p in ps {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in c.attach([u]) } } }
            } else {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in
                    guard let d, let i = NSBitmapImageRep(data: d)?.cgImage else { return }
                    Task { @MainActor in c.attach(i, name: p.suggestedName ?? L("Bild", "Image")) }
                }
            }
        }
        return !ps.isEmpty
    }

    private func tool(_ s: String, _ l: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) { Image(systemName: s).frame(width: 26, height: 24).contentShape(Rectangle()) }.buttonStyle(.borderless).help(l).accessibilityLabel(l)
    }

    // MARK: Verlauf
    private var history: some View {
        VStack(spacing: 0) {
            List {
                ForEach(c.all) { v in
                    Button { c.open(v) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.title).lineLimit(1)
                            Text(v.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(v.id == c.conv.id ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 6) : nil)
                    .contextMenu { Button(L("Löschen", "Delete"), role: .destructive) { c.delete(v.id) } }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .overlay { if c.all.isEmpty { Text(L("Noch keine Unterhaltungen", "No conversations yet")).font(.callout).foregroundStyle(.secondary) } }
            if !c.all.isEmpty { Button(L("Alle löschen …", "Delete all…")) { wipe.value = true }.buttonStyle(.borderless).font(.caption).padding(8) }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            tool("sidebar.left", L("Verlauf", "History")) { sidebar.value = !(sidebar.value ?? true) }
            Text(c.conv.title.isEmpty ? L("Neue Unterhaltung", "New conversation") : c.conv.title).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Menu {
                Picker("", selection: $c.engine) {
                    Text(L("Apple, auf diesem Mac", "Apple, on this Mac")).tag(AIEngine.apple)
                    ForEach(c.models, id: \.self) { m in if case .local(_, let n) = m { Text(n + L(", auf diesem Mac", ", on this Mac")).tag(m) } }
                    if !AISettings.server.model.isEmpty { Text(AISettings.server.model + L(", im Internet", ", online")).tag(AIEngine.own) }
                }
                .pickerStyle(.inline).labelsHidden()
                Divider()
                Button(L("Größeres Modell einrichten …", "Set up a larger model…")) { setup.value = true }
            } label: { Text(modelName) }
            .menuStyle(.borderlessButton).fixedSize().help(L("Modell", "Model"))
            tool("square.and.pencil", L("Neue Unterhaltung (⌘N)", "New conversation (⌘N)")) { c.reset(); focused = true }.keyboardShortcut("n")
        }
        .padding(.horizontal, 10).frame(height: 44)
    }
    private var modelName: String {
        switch c.engine { case .apple: "Apple"; case .local(_, let n): n; case .own: AISettings.server.model }
    }

    // MARK: Leer
    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(L("Womit kann ich helfen?", "How can I help?")).font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                idea("photo", L("Bild oder Aufgabe erklären", "Explain an image or exercise")) { pick([.image]) }
                idea("doc.text", L("Dokument zusammenfassen", "Summarize a document")) { pick(AIRead.types); if c.input.isEmpty { c.input = L("Fasse das Wichtigste übersichtlich zusammen.", "Summarize the key points clearly.") } }
                idea("viewfinder", L("Bildschirmausschnitt fragen", "Ask about part of the screen")) { shot() }
                idea("rectangle.on.rectangle", L("Karteikarten aus einer Datei", "Flashcards from a file")) { if let t = AILogic.task("cards") { AI.file(t) } }
            }
            .frame(maxWidth: 440)
            Text(L("Dateien hierher ziehen oder mit ⌘V einfügen", "Drop files here or paste with ⌘V")).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity)
    }
    private func idea(_ s: String, _ t: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            HStack(spacing: 10) { Image(systemName: s).frame(width: 20).foregroundStyle(.secondary); Text(t).multilineTextAlignment(.leading); Spacer(minLength: 0) }
                .padding(12).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(AITile())
    }

    // MARK: Unterhaltung
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(c.messages) { m in if m.user { question(m) } else { reply(m) } }
                    Color.clear.frame(height: 1).id("ende")
                }
                .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: c.messages.count) { _, _ in if still { proxy.scrollTo("ende", anchor: .bottom) } else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("ende", anchor: .bottom) } } }
            .onChange(of: c.messages.last?.text) { _, _ in if c.busy { proxy.scrollTo("ende", anchor: .bottom) } }
        }
    }
    private func question(_ m: AIMessage) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(m.docs) { d in
                if let j = d.jpeg, let i = NSImage(data: j) {
                    Image(nsImage: i).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel(d.name)
                } else { DocChip(doc: d) }
            }
            if !m.text.isEmpty { Text(m.text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9).background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)) }
            if c.task == nil, !c.busy { tool("pencil", L("Frage ändern", "Edit question")) { c.edit(m); focused = true } .foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 80)
    }
    private func reply(_ m: AIMessage) -> some View {
        let last = m.id == c.messages.last?.id
        return VStack(alignment: .leading, spacing: 8) {
            if m.text.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); if !c.status.isEmpty { Text(c.status).font(.callout).foregroundStyle(.secondary) } }
            } else if m.failed == true {
                Label(m.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else { AIMarkdown(text: m.text) }
            if last, c.busy, !m.text.isEmpty, !c.status.isEmpty { Text(c.status).font(.callout).foregroundStyle(.secondary) }
            if !m.sources.isEmpty {
                HStack(spacing: 8) {
                    Text(L("Quelle:", "Source:")).foregroundStyle(.secondary)
                    ForEach(m.sources, id: \.self) { s in if let u = URL(string: s.url) { Link("Wikipedia: " + s.title, destination: u) } }
                }
                .font(.caption)
            }
            if !(last && c.busy), !m.text.isEmpty {
                HStack(spacing: 2) {
                    if m.failed != true {
                        tool("doc.on.doc", L("Kopieren", "Copy")) { SearchSlash.put(AILogic.tidy(m.text)); Toast.show(L("Kopiert", "Copied"), symbol: "doc.on.doc") }
                        tool("speaker.wave.2", L("Vorlesen", "Read aloud")) { Speech.toggle(m.text) }
                        tool("note.text", L("In die Schnellnotiz", "Add to Quick Note")) { QuickNote.shared.append(AILogic.tidy(m.text)); Toast.show(L("Notiert", "Noted"), symbol: "note.text") }
                    }
                    if last, c.task == nil { tool("arrow.clockwise", L("Neu antworten", "Answer again")) { c.again() } }
                    if last, c.target != nil { Button(L("Markierung ersetzen", "Replace selection")) { c.replaceSelection() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).padding(.leading, 6) }
                    if last, c.task?.name == "cards", !AILogic.cards(m.text).isEmpty { Button(L("Als Tabelle", "As table")) { Export.table([L("Frage", "Question"), L("Antwort", "Answer")], AILogic.cards(m.text)) }.padding(.leading, 6) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Eingabe
    private func pick(_ t: [UTType]) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = t
        if p.runModal() == .OK { c.attach(p.urls) }
        focused = true
    }
    private func shot() {
        let w = windows["ai"]
        w?.orderOut(nil) // sonst verdeckt das Fenster, was man fotografieren will
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AI.shot { img in c.attach(img, name: L("Bildschirmausschnitt", "Screenshot")); AI.open() }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if c.editing != nil {
                HStack { Text(L("Frage ändern – die Antworten danach werden ersetzt", "Editing – later answers will be replaced")).font(.caption).foregroundStyle(.secondary); Button(L("Abbrechen", "Cancel")) { c.editing = nil; c.input = ""; c.docs = [] }.buttonStyle(.link).font(.caption) }
            }
            if !c.docs.isEmpty || c.reading > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(c.docs) { d in DocChip(doc: d) { c.docs.removeAll { $0.id == d.id } } }
                        if c.reading > 0 { ProgressView().controlSize(.small); Text(L("Wird gelesen …", "Reading…")).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            TextField(c.messages.isEmpty ? L("Frag etwas …", "Ask anything…") : L("Nachfragen …", "Ask a follow-up…"), text: $c.input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...8).focused($focused).onSubmit { c.submit() }
            HStack(spacing: 4) {
                Menu {
                    Button(L("Bild oder Datei …", "Image or file…"), systemImage: "paperclip") { pick(AIRead.types) }.keyboardShortcut("o")
                    Button(L("Bildschirmausschnitt", "Part of the screen"), systemImage: "viewfinder") { shot() }
                    Button(L("Aus der Zwischenablage", "From clipboard"), systemImage: "doc.on.clipboard") {
                        if !c.paste(), let s = NSPasteboard.general.string(forType: .string), !s.isEmpty { c.docs.append(AIDoc(name: L("Zwischenablage", "Clipboard"), text: String(s.prefix(AIRead.maxText)))) }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 26).help(L("Anhängen", "Attach")).accessibilityLabel(L("Anhängen", "Attach"))
                Button { c.web.toggle() } label: {
                    Label(c.web ? L("Wikipedia an", "Wikipedia on") : L("Wikipedia aus", "Wikipedia off"), systemImage: "globe").font(.callout)
                        .padding(.horizontal, 8).frame(height: 26)
                        .foregroundStyle(c.web ? Color.accentColor : .secondary)
                        .background(c.web ? Color.accentColor.opacity(0.14) : .clear, in: Capsule()).contentShape(Capsule())
                }
                    .buttonStyle(.plain).accessibilityAddTraits(c.web ? .isSelected : [])
                    .help(L("Darf Wissensfragen bei Wikipedia nachschlagen. Dann geht der Suchbegriff ins Internet.", "May look up facts on Wikipedia. The search term then goes online."))
                Spacer()
                Text(privacy).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(privacy)
                if c.busy {
                    Button { c.stop() } label: { Image(systemName: "stop.fill").frame(width: 28, height: 26) }.help(L("Stopp", "Stop")).accessibilityLabel(L("Stopp", "Stop"))
                } else {
                    Button { c.submit() } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 28, height: 26) }
                        .buttonStyle(.borderedProminent).disabled(c.reading > 0 || (c.docs.isEmpty && c.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .help(L("Senden", "Send")).accessibilityLabel(L("Senden", "Send"))
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)) }
        .padding(14)
    }
    private var privacy: String {
        c.engine == .own ? L("Fragen und Anhänge gehen an deinen Anbieter", "Questions and attachments go to your provider")
            : c.web ? L("Nur Suchbegriffe verlassen den Mac", "Only search terms leave the Mac") : L("Bleibt auf deinem Mac", "Stays on your Mac")
    }
}

private struct AITile: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(c: configuration) }
    private struct Tile: View {
        let c: ButtonStyleConfiguration
        @StateObject private var h = TextBox<Bool>()
        var body: some View {
            c.label.background(.primary.opacity(c.isPressed ? 0.12 : h.value == true ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10)).onHover { h.value = $0 }
        }
    }
}

// Größeres Modell: lokal (Ollama/LM Studio) oder eigener Zugang
struct AISetup: View {
    let close: () -> Void
    @StateObject private var s = TextBox<AIServer>()
    @StateObject private var key = TextBox<String>()
    private var server: AIServer { s.value ?? AISettings.server }
    private var valid: Bool { AILogic.serverURL(server.url) != nil && !server.model.trimmingCharacters(in: .whitespaces).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Größeres Modell", "Larger model")).font(.title3.weight(.semibold))
            Text(rich(L("**Auf dem Mac:** Läuft Ollama oder LM Studio, erscheinen deren Modelle von selbst in der Auswahl. Nichts verlässt den Mac.", "**On your Mac:** if Ollama or LM Studio is running, its models show up in the menu. Nothing leaves your Mac."))).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(rich(L("**Im Internet:** eigener Zugang bei einem Anbieter. Fragen und Anhänge gehen dann dorthin und können Geld kosten.", "**Online:** your own account with a provider. Questions and attachments are sent there and may cost money."))).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker(L("Anbieter", "Provider"), selection: Binding(get: { server.url }, set: { u in var x = server; x.url = u; x.name = AISettings.presets.first { $0.1 == u }?.0 ?? ""; s.value = x })) {
                    ForEach(AISettings.presets, id: \.1) { Text($0.0).tag($0.1) }
                    if !AISettings.presets.contains(where: { $0.1 == server.url }) { Text(server.url.isEmpty ? L("Bitte wählen", "Choose one") : server.url).tag(server.url) }
                }
                TextField(L("Adresse", "Address"), text: Binding(get: { server.url }, set: { var x = server; x.url = $0; s.value = x }))
                TextField(L("Modell", "Model"), text: Binding(get: { server.model }, set: { var x = server; x.model = $0; s.value = x }), prompt: Text(L("Name wie beim Anbieter", "Name as listed by the provider")))
                SecureField(L("Schlüssel", "API key"), text: Binding(get: { key.value ?? "" }, set: { key.value = $0 }), prompt: Text(L("bleibt im Schlüsselbund", "kept in the keychain")))
            }
            if !server.url.isEmpty, AILogic.serverURL(server.url) == nil { Text(L("Die Adresse muss mit https:// beginnen.", "The address must start with https://.")).font(.caption).foregroundStyle(.red) }
            HStack {
                if !AISettings.server.url.isEmpty { Button(L("Zugang entfernen", "Remove access"), role: .destructive) { AISettings.server = AIServer(); AIKey.save(""); if AIChat.shared.engine == .own { AIChat.shared.engine = .apple }; close() } }
                Spacer()
                Button(L("Abbrechen", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("Benutzen", "Use")) { // neue Adresse ohne neuen Schlüssel: alten nicht dorthin schicken
                    if server.url != AISettings.server.url || !(key.value ?? "").isEmpty { AIKey.save((key.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
                    AISettings.server = server; AIChat.shared.engine = .own; close()
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 460)
    }
}
