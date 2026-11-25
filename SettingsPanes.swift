// Einstellungsseiten: KI, Schule, Werkzeuge
import AVFoundation
import Contacts
import EventKit
import Speech
import SwiftUI

struct AITab: View {
    @ObservedObject private var c = AIChat.shared
    @StateObject private var memory = TextBox<Bool>()
    @StateObject private var tick = TextBox<Int>()
    var body: some View {
        Form {
            Section {
                LabeledContent { Button(L("Öffnen", "Open")) { AI.chat("") } } label: { Text(L("Chatfenster", "Chat window")); Text(L("Bilder, PDFs und Dateien fragen, Verlauf. In der Suche: /ai", "Ask about images, PDFs and files, with history. In search: /ai")) }
                LabeledContent(L("Schnellfenster über jeder App", "Quick panel over any app"), value: HotAction.ask.current?.display ?? "–")
                LabeledContent(L("Markierten Text bearbeiten", "Edit selected text"), value: HotAction.aiText.current?.display ?? "–")
            } footer: { if !Assistant.available { Text(L("Apple Intelligence ist aus oder auf diesem Mac nicht verfügbar (Systemeinstellungen › Apple Intelligence & Siri).", "Apple Intelligence is off or unavailable (System Settings › Apple Intelligence & Siri).")).foregroundStyle(.orange) } }
            Section {
                Toggle(isOn: $c.web) { Text(L("Darf ins Internet", "May use the internet")); Text(L("Nur für Wikipedia und Wetter. Es gehen nur Suchbegriff oder Ort hinaus.", "Only for Wikipedia and weather. Only the search term or place is sent.")) }
                LabeledContent { Button(L("Ansehen …", "View…")) { memory.value = true } } label: { Text(L("Gemerktes", "Memory")); Text(L("Sag „Merk dir, dass …“", "Say “Remember that …”")) }
                LabeledContent { Button(L("Alle löschen …", "Delete all…")) { c.prepare(); wipe() } } label: { Text(L("Unterhaltungen", "Conversations")); Text(L("Liegen nur auf diesem Mac", "Stored only on this Mac")) }
            } header: { Text(L("Datenschutz", "Privacy")) }
            Section {
                row(L("Kalender", "Calendar"), EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Calendars")
                row(L("Erinnerungen", "Reminders"), EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, "Reminders")
                row(L("Kontakte", "Contacts"), CNContactStore.authorizationStatus(for: .contacts) == .authorized, "Contacts")
                row(L("Mikrofon", "Microphone"), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone")
                row(L("Spracherkennung", "Speech Recognition"), SFSpeechRecognizer.authorizationStatus() == .authorized, "SpeechRecognition")
                row(L("Bildschirmaufnahme", "Screen Recording"), CGPreflightScreenCaptureAccess(), "ScreenCapture")
            } header: { Text(L("Was der Assistent darf", "What the assistant may access")) } footer: { Text(L("macOS fragt beim ersten Benutzen. Jede Erlaubnis ist freiwillig.", "macOS asks on first use. Every permission is optional.")) }
            SiriSection()
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { memory.value ?? false }, set: { memory.value = $0 })) { AIMemoryView { memory.value = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick.value = (tick.value ?? 0) + 1 } // nach dem Umschalten in den Systemeinstellungen
    }
    private func row(_ t: String, _ on: Bool, _ pane: String) -> some View {
        LabeledContent(t) { if on { Label(L("Erlaubt", "Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) } else { Button(L("Einstellungen …", "Settings…")) { if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(u) } } } }
    }
    private func wipe() {
        let a = NSAlert(); a.messageText = L("Alle Unterhaltungen löschen?", "Delete all conversations?"); a.informativeText = L("Das lässt sich nicht rückgängig machen.", "This can't be undone.")
        a.addButton(withTitle: L("Abbrechen", "Cancel")); a.addButton(withTitle: L("Löschen", "Delete")).hasDestructiveAction = true
        if a.runModal() == .alertSecondButtonReturn { c.deleteAll() }
    }
}

struct SchoolPane: View {
    var body: some View {
        Form {
            Section { LabeledContent { Button(L("Öffnen", "Open")) { School.open() } } label: { Text(L("Stundenplan, Aufgaben, Noten, Lernkarten", "Timetable, tasks, grades, flashcards")); Text(L("In der Suche: /schule und /ha", "In search: /school and /ha")) } }
            StudySection()
            Section { ForEach(["math", "solve", "plot", "kv", "subnet", "sql", "nsd", "uml", "regex", "float", "ohm", "mol"], id: \.self) { n in
                if let k = SearchSlash.all.first(where: { $0.name == n }) { HStack { Image(systemName: k.symbol).frame(width: 22).foregroundStyle(.secondary); Text(k.text); Spacer(); Text("/" + k.name + (k.hint.isEmpty ? "" : " " + k.hint)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) } }
            } } header: { Text(L("Für Mathe und Technik, in der Suche", "For maths and tech, in search")) }
        }
        .formStyle(.grouped)
    }
}

struct ToolsTab: View {
    @ObservedObject var awake = Awake.shared
    @AppStorage("clipHistory") var clipHistory = true
    @AppStorage("shelfShake") var shake = true
    @AppStorage("onenoteQuality") var onenoteQuality = PDFQuality.compact.rawValue
    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: awake.status)
                ForEach([Awake.Mode.display, .system], id: \.self) { m in
                    LabeledContent(tr(m.rawValue)) {
                        Menu("Starten") {
                            ForEach(Awake.durations, id: \.0) { d in Button(tr(d.0)) { awake.start(m, minutes: d.1) } }
                        }
                        .fixedSize()
                        .accessibilityLabel("\(tr(m.rawValue)) starten")
                    }
                }
                HStack {
                    Button("Bildschirm jetzt aus – Mac arbeitet weiter") { sh(["/usr/bin/pmset", "displaysleepnow"]) }
                    Spacer()
                    if awake.mode != nil { Button("Beenden") { awake.stop() } }
                }
                if Awake.ruleInstalled { Button(L("Erlaubnis fürs Zuklappen entfernen …", "Remove lid permission…")) { awake.removeRule() } }
            } header: { Text("Wach bleiben") } footer: {
                Text(L("„Bildschirm aus“ läuft auch zugeklappt weiter, dafür fragt macOS einmal nach deinem Passwort. Zugeklappt endet es von selbst nach der Zeit, bei 20 % Akku oder wenn WinKomfort beendet wird. Nicht in der Tasche benutzen: Der Mac kann heiß werden.",
                       "“Display off” also keeps working with the lid closed; macOS asks for your password once for that. With the lid closed it ends by itself after the time, at 20% battery or when WinKomfort quits. Don't use it in a bag: the Mac can get hot."))
            }
            Section {
                Toggle(isOn: $shake) { Text(L("Beim Ziehen wackeln öffnet die Ablage", "Shake while dragging opens the shelf")); Text(L("Dateien, Bilder oder Text kurz parken und woanders wieder herausziehen.", "Park files, images or text and drag them out elsewhere.")) }.onChange(of: shake) { Shelf.shared.setup() }
                LabeledContent { Button(L("Öffnen", "Open")) { Shelf.shared.toggle() } } label: { Text(L("Ablage öffnen", "Open shelf")); Text(HotAction.shelf.current?.display ?? "–") }
            } header: { Text(L("Ablage", "Shelf")) }
            Section {
                Toggle("Zwischenablage-Verlauf (\(HotAction.clipboard.current?.display ?? tr("Kürzel aus")))", isOn: $clipHistory)
                    .onChange(of: clipHistory) { ClipHistory.shared.start() }
                Button("Verlauf jetzt leeren") { ClipHistory.shared.clear() }
            } header: { Text("Zwischenablage") } footer: {
                Text("Merkt sich die letzten 50 Texte und 10 Bilder – nur im Arbeitsspeicher, nach dem Neustart ist alles weg. Passwörter aus Passwort-Managern werden nie gespeichert.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(L("Größe der PDF", "PDF size"), selection: $onenoteQuality) {
                    ForEach(PDFQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Text("OneNote → PDF (\(HotAction.onenote.current?.display ?? "–"))") } footer: {
                Text(L("Lädt die Original-Abschnitte mit deiner Microsoft-Anmeldung (einmalig) und baut die PDF im Hintergrund – OneNote kannst du dabei weiter benutzen. „Klein“ hält Bilder bei etwa 120 dpi: gut lesbar, viel kleiner.",
                       "Downloads the original sections with your Microsoft sign-in (once) and builds the PDF in the background – you can keep using OneNote. “Small” keeps images at about 120 dpi: readable, much smaller."))
                    .foregroundStyle(.secondary)
            }
            SnippetsSection()
        }
        .formStyle(.grouped)
    }
}
