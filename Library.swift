// Bibliothek: größere Werkzeuge einzeln an- und ausschalten. Aus = weg aus Menü, Suche (/Befehle) und Kürzeln, nichts läuft im Hintergrund
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case school, study, scan, tidy, hand, battery, notch, onenote, remote, gameMode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .school: L("Schule", "School")
        case .study: L("Lernzettel", "Study sheets")
        case .scan: L("Blatt-Scanner", "Sheet scanner")
        case .tidy: L("Notizen schön machen", "Tidy up notes")
        case .hand: L("Meine Handschrift", "My handwriting")
        case .battery: L("Akku-Optimierer", "Battery optimizer")
        case .notch: L("Interaktive Notch", "Interactive notch")
        case .onenote: L("OneNote-Werkzeuge", "OneNote tools")
        case .remote: L("Handy-Fernbedienung", "Phone remote")
        case .gameMode: "Game Mode"
        }
    }
    var detail: String {
        switch self {
        case .school: L("Stundenplan mit WebUntis, Aufgaben, Noten, Lernkarten", "Timetable with WebUntis, tasks, grades, flashcards")
        case .study: L("KI macht aus OneNote und Blättern einen Lernzettel für die Arbeit", "AI turns OneNote and worksheets into a study sheet for your test")
        case .scan: L("Blätter mit Desk View oder dem iPhone scannen, KI liest mit", "Scan sheets with Desk View or your iPhone, AI reads along")
        case .tidy: L("KI ordnet Notizen und Tafelbilder, setzt Formeln, fügt in OneNote ein", "AI arranges notes and whiteboards, formats formulas, pastes into OneNote")
        case .hand: L("Texte und Arbeitsblätter in deiner eigenen Schrift", "Texts and worksheets in your own handwriting")
        case .battery: L("Zeigt, was Akku zieht, und bremst Apps im Hintergrund", "Shows what drains the battery and slows background apps")
        case .notch: L("Musik, Stunde, Timer und KI-Frage an der Kamera", "Music, next class, timer and AI question at the camera")
        case .onenote: L("Als PDF sichern und aufräumen: leere Seiten weg, KI benennt Seiten und Abschnitte", "Save as PDF and tidy up: remove empty pages, AI names pages and sections")
        case .remote: L("Mac vom Handy aus steuern", "Control your Mac from your phone")
        case .gameMode: L("Beim Spielen Ablenkungen und Hintergrund-Apps aus", "Turns off distractions and background apps while gaming")
        }
    }
    var symbol: String {
        switch self {
        case .school: "graduationcap.fill"; case .study: "list.bullet.rectangle.portrait.fill"; case .scan: "doc.viewfinder"; case .tidy: "sparkles.rectangle.stack"; case .hand: "pencil.and.scribble"
        case .battery: "battery.75percent"; case .notch: "capsule.tophalf.filled"; case .onenote: "doc.richtext"; case .remote: "iphone.radiowaves.left.and.right"; case .gameMode: "gamecontroller.fill"
        }
    }
    var tint: Color {
        switch self {
        case .school: .indigo; case .study: .orange; case .scan: .blue; case .tidy: .purple; case .hand: .teal; case .battery: .green; case .notch: .gray; case .onenote: .purple; case .remote: .orange; case .gameMode: .red
        }
    }
    // /Befehle und Tastenkürzel, die zum Werkzeug gehören
    var commands: [String] {
        switch self {
        case .onenote: ["aufräumen", "cleanup"]; case .school: ["schule", "school"]; case .study: ["lernzettel", "studysheet"]; case .tidy: ["schön", "tidy"]; case .hand: ["handschrift", "handwriting"]; case .battery: ["akku", "battery"]
        default: []
        }
    }
    var hotkey: HotAction? {
        switch self { case .school: .school; case .scan: .scan; case .onenote: .onenote; case .remote: .remote; case .gameMode: .gameMode; default: nil }
    }
    // Die Notch hatte schon einen eigenen Schalter: denselben weiterbenutzen
    private var key: String { self == .notch ? "notch" : "tool." + rawValue }
    // Neu installiert: nur das Wichtigste an. Wer WinKomfort schon hatte, behält alles
    static let basics: Set<Tool> = [.school, .study, .scan, .tidy, .notch]
    var on: Bool {
        if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
        return UserDefaults.standard.bool(forKey: "toolsLean") ? Self.basics.contains(self) : true
    }
    @MainActor func set(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: key)
        HotKey.registerAll()
        switch self {
        case .notch: Notch.shared.update()
        case .battery: if !v { Battery.shared.releaseAll() }
        case .gameMode: if !v, GameMode.shared.active { GameMode.shared.toggle() }
        default: break
        }
        Library.shared.objectWillChange.send()
    }
    static func allows(command name: String) -> Bool { !allCases.contains { !$0.on && $0.commands.contains(name) } }
    static func allows(_ h: HotAction) -> Bool { !allCases.contains { !$0.on && $0.hotkey == h } }
}

@MainActor final class Library: ObservableObject { static let shared = Library() }

struct LibraryTab: View {
    @ObservedObject var lib = Library.shared
    var body: some View {
        Form {
            Section {
                ForEach(Tool.allCases) { t in
                    Toggle(isOn: Binding(get: { t.on }, set: { t.set($0) })) {
                        Label {
                            Text(t.title); Text(t.detail)
                        } icon: {
                            Image(systemName: t.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.tint.gradient))
                        }
                    }
                }
            } footer: {
                Text(L("Ausgeschaltete Werkzeuge verschwinden aus dem Menü, aus der Suche und von den Tastenkürzeln und laufen nicht im Hintergrund. Deine Daten (Noten, Handschrift …) bleiben erhalten und sind beim Einschalten wieder da.",
                       "Turned-off tools disappear from the menu, search and shortcuts and don't run in the background. Your data (grades, handwriting…) is kept and comes back when you turn them on."))
            }
        }
        .formStyle(.grouped)
    }
}
