// Text-Kürzel (wie TextExpander): „;mail“ tippen → wird durch den gespeicherten Text ersetzt.
// Nur aktiv, wenn es Kürzel gibt. In Passwortfeldern (sichere Eingabe) passiert nie etwas.
import AppKit
import SwiftUI
import Carbon.HIToolbox

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var text: String
}

enum Snippets {
    private static var tap: CFMachPort?
    private static var buffer = ""          // zuletzt getippte Zeichen (nur im Arbeitsspeicher, max. 40)
    private static var list: [Snippet] = []
    private static let marker: Int64 = 0x534E // eigene Tastendrücke erkennen

    static func load() -> [Snippet] {
        (UserDefaults.standard.data(forKey: "snippets")).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }
    static func save(_ s: [Snippet]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "snippets")
        update()
    }

    static func update(prompt: Bool = false) {
        list = load().filter { !$0.key.isEmpty && !$0.text.isEmpty }
        if list.isEmpty { stop(); return }
        guard tap == nil else { return }
        afterTrust(prompt: prompt) { if !list.isEmpty { start() } }
    }

    private static func start() {
        guard tap == nil else { return }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
                                callback: { _, type, e, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = Snippets.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(e)
            }
            Snippets.handle(type, e)
            return Unmanaged.passUnretained(e)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    static func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
        buffer = ""
    }

    private static func handle(_ type: CGEventType, _ e: CGEvent) {
        // Klick = Cursor woanders → Puffer verwerfen; Passwortfelder nie mitlesen
        if type == .leftMouseDown || IsSecureEventInputEnabled() { buffer = ""; return }
        // In WinKomfort selbst (z. B. beim Bearbeiten der Kürzel) nie ersetzen
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { buffer = ""; return }
        // …auch nicht in WinKomforts eigenen Panels (Startmenü-, Such-Feld), die andere Apps vorne lassen
        if MainActor.assumeIsolated({ NSApp.keyWindow != nil }) { buffer = ""; return }
        if e.getIntegerValueField(.eventSourceUserData) == marker { return }
        let flags = e.flags.intersection([.maskCommand, .maskControl])
        guard flags.isEmpty else { buffer = ""; return }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        if code == Int64(kVK_Delete) { buffer = String(buffer.dropLast()); return }
        if [kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(code)) { buffer = ""; return }
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return }
        buffer += String(utf16CodeUnits: chars, count: len)
        if buffer.count > 40 { buffer.removeFirst(buffer.count - 40) }
        guard let hit = list.first(where: { buffer.hasSuffix($0.key) }) else { return }
        buffer = ""
        let deletes = hit.key.count, text = expand(hit.text)
        // Ersetzen nach dem aktuellen Tastendruck: Kürzel löschen, Text eintippen (ohne die Zwischenablage anzufassen)
        DispatchQueue.main.async { insert(deletes: deletes, text: text) }
    }

    // Platzhalter wie bei TextExpander: {datum} {uhrzeit} {zwischenablage} (auch englisch: {date} {time} {clipboard})
    static func expand(_ t: String) -> String {
        guard t.contains("{") else { return t }
        let now = Date()
        let date = now.formatted(date: .numeric, time: .omitted), time = now.formatted(date: .omitted, time: .shortened)
        // Zwischenablage wird getippt, nicht eingefügt: keine Zeilenumbrüche/Steuerzeichen (sonst könnte ein Terminal
        // Befehle ausführen), höchstens 1000 Zeichen
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let clip = String(raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }.prefix(1000))
        return t.replacingOccurrences(of: "{datum}", with: date).replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{uhrzeit}", with: time).replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{zwischenablage}", with: clip).replacingOccurrences(of: "{clipboard}", with: clip)
    }

    static func type(_ s: Snippet) { insert(deletes: 0, text: expand(s.text)) }
    private static func post(_ e: CGEvent?) {
        e?.setIntegerValueField(.eventSourceUserData, value: marker)
        e?.post(tap: .cghidEventTap)
    }
    private static func insert(deletes: Int, text: String) {
        for _ in 0..<deletes {
            post(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
            post(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
        }
        // Zeilenumbruch als ⇧↩ (in Chats sonst „Senden“), Text in Stücken ganzer Zeichen (Emojis nie zerteilen)
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            if n > 0 {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: down)
                    e?.flags = .maskShift
                    post(e)
                }
            }
            var chunk = [UniChar]()
            func flush() {
                guard !chunk.isEmpty else { return }
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(down)
                post(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
                chunk = []
            }
            for ch in line {
                let u = Array(String(ch).utf16)
                if chunk.count + u.count > 16 { flush() }
                chunk += u
            }
            flush()
        }
    }
}

final class SnippetStore: ObservableObject {
    @Published var items: [Snippet] = Snippets.load()
    func commit() { Snippets.save(items) }
}

struct SnippetsSection: View {
    @StateObject private var store = SnippetStore()
    var body: some View {
        Section {
            if store.items.isEmpty {
                Text(L("Noch keine Kürzel. Beispiel: „;mail“ → deine E-Mail-Adresse.", "No snippets yet. Example: “;mail” → your email address."))
                    .foregroundStyle(.secondary)
            }
            ForEach($store.items) { $s in
                HStack(alignment: .firstTextBaseline) {
                    TextField(L("Kürzel", "Abbreviation"), text: $s.key).frame(width: 110).font(.body.monospaced())
                        .onSubmit { store.commit() }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(L("Text", "Text"), text: $s.text, axis: .vertical).lineLimit(1...4)
                        .onSubmit { store.commit() }
                    Button { store.items.removeAll { $0.id == s.id }; store.commit() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel(L("Kürzel löschen", "Delete snippet"))
                }
            }
            Button(L("Kürzel hinzufügen", "Add snippet")) {
                store.items.append(Snippet(key: ";", text: ""))
            }
        } header: { Text(L("Text-Kürzel", "Text snippets")) } footer: {
            Text(L("Funktioniert in jeder App. Kürzel am besten mit „;“ beginnen. Platzhalter: {datum}, {uhrzeit}, {zwischenablage}. In Passwortfeldern passiert nie etwas.",
                   "Works in every app. Start snippets with “;”. Placeholders: {date}, {time}, {clipboard}. Nothing happens in password fields."))
        }
        .onChange(of: store.items) { _, _ in store.commit() }
    }
}
