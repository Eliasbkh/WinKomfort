// Schnellfenster (⌃⌥K): fragen, sprechen und handeln, ohne die App zu wechseln – dazu Karten und Mikrofon
import AppKit
import SwiftUI

@MainActor enum AIPanel {
    private static var panel: KeyPanel?
    private static let token = AskToken()
    static var visible: Bool { panel?.isVisible == true }

    static func toggle() { if visible { hide() } else { show() } }
    static func hide() { panel?.orderOut(nil); Voice.shared.finish(send: false); Speech.stop() }
    static func show() {
        if let a = NSWorkspace.shared.frontmostApplication, a.processIdentifier != getpid() { AIAct.lastApp = a.processIdentifier }
        Selection.capture()
        AIChat.shared.prepare()
        if !AIChat.shared.busy { AIChat.shared.reset() } // neue Frage; Altes steht im Verlauf
        if #available(macOS 26.0, *) { Assistant.prewarm() }
        let p = panel ?? {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 470), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.becomesKeyOnlyIfNeeded = false
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = fixedHost(AIPanelView(token: token))
            panel = p
            return p
        }()
        let v = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        p.setFrameOrigin(NSPoint(x: v.midX - 300, y: v.maxY - 470 - v.height * 0.12))
        p.makeKeyAndOrderFront(nil) // ohne zu aktivieren: die App darunter bleibt vorne
        token.n += 1
    }
}
final class AskToken: ObservableObject { @Published var n = 0 }

struct AIPanelView: View {
    @ObservedObject var c = AIChat.shared
    @ObservedObject var token: AskToken
    @ObservedObject private var voice = Voice.shared
    @FocusState private var focused: Bool
    private var last: AIMessage? { c.messages.last { !$0.user } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !c.docs.isEmpty { ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(c.docs) { d in DocChip(doc: d) { c.docs.removeAll { $0.id == d.id } } } } }.padding(.bottom, 8) }
                HStack(spacing: 10) {
                    if voice.on {
                        Text(voice.text.isEmpty ? L("Ich höre zu …", "Listening…") : voice.text).font(.title3).foregroundStyle(voice.text.isEmpty ? .secondary : .primary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField(c.messages.isEmpty ? L("Frag mich oder sag, was passieren soll", "Ask or say what should happen") : L("Nachfragen …", "Ask a follow-up…"), text: $c.input, axis: .vertical)
                            .textFieldStyle(.plain).font(.title3).lineLimit(1...4).focused($focused).onSubmit { c.submit() }
                    }
                    MicButton()
                    if c.busy { Button { c.stop() } label: { Image(systemName: "stop.fill").frame(width: 28, height: 26) }.help(L("Stopp", "Stop")).accessibilityLabel(L("Stopp", "Stop")) }
                }
                if c.messages.isEmpty {
                    HStack(spacing: 8) {
                        chip("macwindow", L("Fenster ansehen", "Look at window")) { c.ask(L("Was ist auf meinem Bildschirm zu sehen? Erkläre es kurz.", "What's on my screen? Explain briefly.")) }
                        if !Selection.text.isEmpty { chip("text.quote", L("Markierten Text", "Selected text")) { c.docs.append(AIDoc(name: L("Markierter Text", "Selected text"), text: String(Selection.text.prefix(AIRead.maxText)))); focused = true } }
                        chip("calendar", L("Mein Tag", "My day")) { c.ask(L("Was steht heute an?", "What's on my calendar today?")) }
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
            .padding(16)
            if let m = last {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if m.text.isEmpty { HStack(spacing: 8) { ProgressView().controlSize(.small); if !c.status.isEmpty { Text(c.status).foregroundStyle(.secondary) } } }
                        else if m.failed == true { Label(m.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                        else { AIMarkdown(text: m.text) }
                        ForEach(m.cards ?? []) { AICardView(card: $0) }
                        ForEach(m.sources, id: \.self) { s in if let u = URL(string: s.url) { Link(s.title, destination: u).font(.caption) } }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.top)
                Divider()
                HStack {
                    Button(L("Kopieren", "Copy")) { SearchSlash.put(AILogic.tidy(m.text)); Toast.show(L("Kopiert", "Copied"), symbol: "doc.on.doc") }.disabled(m.text.isEmpty)
                    Button(L("Vorlesen", "Read aloud")) { Speech.toggle(m.text) }.disabled(m.text.isEmpty)
                    Spacer()
                    Button(L("Im Fenster öffnen", "Open in window")) { AIPanel.hide(); AI.open() }
                }
                .buttonStyle(.borderless).font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
            }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1)) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Button("") { AIPanel.hide() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        .onExitCommand { AIPanel.hide() }
        .aiLinks()
        .alert(c.problem ?? "", isPresented: Binding(get: { c.problem != nil && AIPanel.visible }, set: { if !$0 { c.problem = nil } })) { Button("OK") { c.problem = nil } }
        .onAppear { focused = true }
        .onChange(of: token.n) { _, _ in focused = true }
    }
    private func chip(_ s: String, _ t: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) { Label(t, systemImage: s).font(.callout).padding(.horizontal, 10).frame(height: 28).contentShape(Capsule()) }
            .buttonStyle(.plain).background(.primary.opacity(0.07), in: Capsule())
    }
}

struct MicButton: View {
    @ObservedObject private var v = Voice.shared
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        Button { AIChat.shared.listen() } label: {
            Image(systemName: v.on ? "waveform" : "mic").frame(width: 28, height: 26)
                .foregroundStyle(v.on ? Color.white : .primary)
                .background { if v.on { Capsule().fill(Color.red).scaleEffect(still ? 1 : 1 + CGFloat(v.level) * 0.25) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(AIChat.shared.busy && !v.on)
        .help(v.on ? L("Fertig", "Done") : L("Sprechen", "Speak")).accessibilityLabel(v.on ? L("Zuhören beenden", "Stop listening") : L("Sprechen", "Speak"))
    }
}

struct AICardView: View {
    let card: AICard
    @StateObject private var title = TextBox<String>()
    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                if editable {
                    TextField(L("Titel", "Title"), text: Binding(get: { title.value ?? card.title }, set: { title.value = $0 })).textFieldStyle(.plain).fontWeight(.medium)
                    Text(when).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(card.title).fontWeight(.medium).lineLimit(2)
                    if !card.detail.isEmpty { Text(card.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Spacer(minLength: 8)
            switch card.kind {
            case .file:
                Button(L("Öffnen", "Open")) { if let p = card.path { AIPanel.hide(); NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
                Button { if let p = card.path { AIPanel.hide(); openExplorer(URL(fileURLWithPath: p).deletingLastPathComponent()) } } label: { Image(systemName: "folder") }.help(L("Im Explorer zeigen", "Show in Explorer")).accessibilityLabel(L("Im Explorer zeigen", "Show in Explorer"))
                Button { if let p = card.path { AIChat.shared.attach([URL(fileURLWithPath: p)]) } } label: { Image(systemName: "paperclip") }.help(L("An die nächste Frage hängen", "Attach to next question")).accessibilityLabel(L("An die nächste Frage hängen", "Attach to next question"))
            case .newEvent, .newReminder:
                Button(L("Nein", "No")) { AIChat.shared.dismiss(card) }
                Button(card.kind == .newEvent ? L("Eintragen", "Add") : L("Erinnern", "Remind")) { AIChat.shared.confirm(card, title: title.value ?? card.title) }.buttonStyle(.borderedProminent)
            case .event: Button(L("Kalender", "Calendar")) { open("com.apple.iCal") }
            case .reminder: Button(L("Öffnen", "Open")) { open("com.apple.reminders") }
            case .done: EmptyView()
            }
        }
        .padding(10).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
    private var editable: Bool { card.kind == .newEvent || card.kind == .newReminder }
    private var when: String {
        guard let d = card.start else { return L("Ohne Zeitpunkt", "No time set") }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide)) + (card.hasTime == true ? ", " + d.formatted(date: .omitted, time: .shortened) + (card.kind == .newEvent ? L(" (1 Stunde)", " (1 hour)") : "") : card.kind == .newEvent ? L(", ganztägig", ", all day") : "")
    }
    private func open(_ id: String) { AIPanel.hide(); if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.openApplication(at: u, configuration: .init()) } }
    @ViewBuilder private var icon: some View {
        switch card.kind {
        case .file: Image(nsImage: NSWorkspace.shared.icon(forFile: card.path ?? "")).resizable()
        case .event, .newEvent: Image(systemName: "calendar").font(.title2).foregroundStyle(.secondary)
        case .reminder, .newReminder: Image(systemName: "bell").font(.title2).foregroundStyle(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        }
    }
}

struct AIMemoryView: View {
    let close: () -> Void
    @StateObject private var list = TextBox<[String]>()
    private var all: [String] { list.value ?? AIMemory.all }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Was ich mir gemerkt habe", "What I remember")).font(.title3.weight(.semibold))
            Text(L("Bleibt auf diesem Mac. Sag „Merk dir, dass …“, um etwas hinzuzufügen.", "Stays on this Mac. Say “Remember that …” to add something.")).foregroundStyle(.secondary)
            if all.isEmpty { ContentUnavailableView(L("Noch nichts gemerkt", "Nothing yet"), systemImage: "brain").frame(height: 160) } else {
                List { ForEach(Array(all.enumerated()), id: \.offset) { i, t in
                    HStack { Text(t); Spacer(); Button { var a = all; a.remove(at: i); AIMemory.all = a; list.value = a } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Vergessen", "Forget")) }
                } }.frame(height: 220)
            }
            HStack { Spacer(); Button(L("Fertig", "Done"), action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 420)
    }
}
