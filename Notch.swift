// Interaktive Notch: unsichtbar wie die Kamera-Aussparung, fährt beim Drüberfahren oder Hineinziehen aus
import AppKit
import FoundationModels
import IOKit.ps
import SwiftUI

// randloses Panel, das trotzdem Tastatureingaben annehmen kann (KI-Frage), ohne WinKomfort nach vorn zu holen
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); MainActor.assumeIsolated { Notch.shared.focusLost() } }
}

@MainActor final class Notch: ObservableObject {
    static let shared = Notch()
    @Published var open = false { didSet { if open != oldValue { fit() } } }
    @Published var dropping = false
    @Published var track: (title: String, artist: String, app: String, playing: Bool)?
    @Published var now = Date()
    @Published var charging = false
    @Published var charge: Int?
    @Published var question = ""
    @Published var answer: String?
    @Published var thinking = false
    @Published var progress: Double?   // OneNote → PDF läuft: 0…1
    @Published var finished = false    // kurz „fertig“ zeigen
    private var openWork: DispatchWorkItem?
    private var panel: NSPanel?
    private var tick: Timer?
    private var closeWork: DispatchWorkItem?
    private var token: NSObjectProtocol?
    private(set) var notch = CGSize(width: 200, height: 32)
    static var enabled: Bool { Tool.notch.on }

    // nur auf Bildschirmen mit Kamera-Aussparung
    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } }
    func update() { Self.enabled && screen != nil ? show() : hide() }
    private func show() {
        guard let s = screen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return }
        notch = CGSize(width: r.minX - l.maxX, height: s.safeAreaInsets.top)
        center = s.frame.minX + l.maxX + notch.width / 2; top = s.frame.maxY
        if panel == nil {
            let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.becomesKeyOnlyIfNeeded = true
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // über der Menüleiste
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isReleasedWhenClosed = false; p.acceptsMouseMovedEvents = true
            // Feste Leinwand, oben angeheftet: das Fenster schneidet nur aus. Wuchs vorher die SwiftUI-Fläche mit dem Fenster,
            // rechnete SwiftUI die alte Lage um und die Form flog beim Aufklappen von unten heran
            let host = NSHostingView(rootView: NotchView(n: self)); host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: Notch.canvas)
            let box = NSView(); box.addSubview(host)
            p.contentView = box; canvasView = host
            panel = p
        }
        fit(now: true)
        panel?.orderFrontRegardless()
        if token == nil {
            token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Notch.shared.update() } }
            wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Notch.shared.morning() } }
        }
        refreshPower()
        live()
        if minute == nil { // einmal pro Minute: Laden, „Stunde gleich“ – fast kostenlos
            minute = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { let n = Notch.shared; let had = n.activity?.icon; n.refreshPower(); n.now = Date(); if had != n.activity?.icon { n.fit() } } }
            minute?.tolerance = 15
        }
    }
    private var minute: Timer?, wake: NSObjectProtocol?
    // Morgens beim ersten Aufwachen einmal kurz den Tag zeigen (nur wenn etwas eingetragen ist)
    func morning(now d: Date = Date()) {
        let day = ActLogic.cal.startOfDay(for: d).timeIntervalSince1970, b = School.shared.book
        guard (5..<12).contains(ActLogic.cal.component(.hour, from: d)), UserDefaults.standard.double(forKey: "notchMorning") != day,
              !Plan.lessons(b, on: d).isEmpty || b.tasks.contains(where: { !$0.done }) else { return }
        UserDefaults.standard.set(day, forKey: "notchMorning")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
            let n = Notch.shared; n.refreshPower(); n.readTrack(); n.expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { let n = Notch.shared; if !(n.panel?.isKeyWindow ?? false), n.question.isEmpty { n.collapse() } } }
        } }
    }
    private func hide() { panel?.orderOut(nil); tick?.invalidate(); tick = nil; minute?.invalidate(); minute = nil }

    // Das Fenster ist nur so groß wie die sichtbare Form: daneben gehen Klicks normal an die Menüleiste und an Fenster darunter
    private var center: CGFloat = 0, top: CGFloat = 0, shrink: DispatchWorkItem?, canvasView: NSView?
    static let canvas = CGSize(width: 640, height: 320) // größer als die offene Notch
    var size: CGSize { open ? CGSize(width: 600, height: answer != nil || thinking ? 236 : 286) : CGSize(width: notch.width + (activity == nil ? 0 : 156) + 12, height: notch.height) }
    func fit(now: Bool = false) {
        guard let p = panel else { return }
        shrink?.cancel()
        let want = size
        let apply = { [weak self] in
            guard let self, let p = self.panel else { return }
            p.setFrame(CGRect(x: self.center - want.width / 2, y: self.top - want.height, width: want.width, height: want.height), display: false) // kein Sofort-Neuzeichnen mitten im Start der Animation
            self.canvasView?.setFrameOrigin(CGPoint(x: (want.width - Notch.canvas.width) / 2, y: want.height - Notch.canvas.height)) // Leinwand bleibt oben mittig
        }
        if now || want.width >= p.frame.width || want.height >= p.frame.height { apply() } // größer: sofort, damit die Animation Platz hat
        else { let w = DispatchWorkItem { MainActor.assumeIsolated { apply() } }; shrink = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w) } // kleiner: nach der Animation
    }

    // Live-Anzeige links/rechts der Kamera: Timer, Laden, Stunde bald
    // Fortschritt melden; der Ring erscheint neben der Kamera
    func report(_ p: Double) {
        let had = activity != nil
        finished = false; progress = max(progress ?? 0, min(p, 0.99)) // nie rückwärts
        if had != (activity != nil) { fit() }
    }
    func finish(_ ok: Bool) {
        progress = nil; finished = ok; fit()
        guard ok else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { let n = Notch.shared; if n.finished { n.finished = false; n.fit() } } }
    }
    var activity: (icon: String, text: String, tint: Color)? {
        if let p = progress { return ("progress", "\(Int(p * 100)) %", .blue) }
        if finished { return ("checkmark.circle.fill", "PDF", .green) }
        if let t = SearchTimer.shared.running.map(\.end).min(), t > now {
            let s = Int(t.timeIntervalSince(now)); return ("timer", String(format: "%d:%02d", s / 60, s % 60), .orange)
        }
        if charging, let c = charge { return ("bolt.fill", "\(c) %", .green) }
        if !charging, let c = charge, c <= 15 { return ("battery.25percent", "\(c) %", .red) } // knapp: auch im Vollbild sichtbar
        if Tool.school.on, let l = Plan.now(School.shared.book, now).next, let m = Optional(l.start - (ActLogic.cal.component(.hour, from: now) * 60 + ActLogic.cal.component(.minute, from: now))), m <= 10, m >= 0 {
            return ("graduationcap.fill", L("\(l.subject) in \(m) min", "\(l.subject) in \(m) min"), .blue)
        }
        if track?.playing == true { return ("waveform", "", .pink) }
        return nil
    }
    // Sekundentakt nur, solange ein Timer läuft oder die Notch offen ist – sonst schläft sie
    func live() {
        let need = open || !SearchTimer.shared.running.isEmpty
        if need, tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { let n = Notch.shared; let had = n.activity != nil; n.now = Date(); if had != (n.activity != nil) { n.fit() }; n.live() } }
            tick?.tolerance = 0.3
        } else if !need, tick != nil { tick?.invalidate(); tick = nil; now = Date() }
    }
    // kurz verweilen, dann aufklappen (kein Aufspringen beim Vorbeifahren); beim Tippen bleibt sie offen
    func hover(_ on: Bool) {
        closeWork?.cancel(); openWork?.cancel()
        if on {
            guard !open else { return }
            refreshPower(); readTrack() // schon beim Drüberfahren laden: beim Aufklappen springt dann nichts mehr
            let w = DispatchWorkItem { MainActor.assumeIsolated { Notch.shared.expand() } }
            openWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (dropping ? 0 : 0.12), execute: w)
        } else {
            let w = DispatchWorkItem { MainActor.assumeIsolated { let n = Notch.shared; if !n.dropping, !(n.panel?.isKeyWindow ?? false) { n.collapse() } } }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }
    func expand() {
        guard !open else { return }
        open = true; live()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) // wie bei Apple: kleiner Tick im Trackpad
    }
    func collapse() { open = false; answer = nil; question = ""; live(); fit() }
    func focusLost() { if !thinking { collapse() } }

    // KI direkt in der Notch: erst eigene Aktionen (Timer, Erinnerung, Wetter …), sonst Apples Modell auf dem Mac
    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        thinking = true; answer = nil; fit()
        Task {
            defer { thinking = false; fit() }
            let o = try? await AIAct.handle(q, others: [], status: { _ in })
            if let t = o?.text { answer = t; return }
            guard Assistant.available, #available(macOS 26.0, *) else { answer = L("Dafür braucht es Apple Intelligence.", "This needs Apple Intelligence."); return }
            let s = LanguageModelSession(instructions: "Du bist der Assistent in der Notch eines Macs, für einen Schüler. Antworte auf Deutsch, freundlich und sehr knapp: höchstens 3 kurze Sätze, keine Überschriften.")
            let m = o.map { $0.material.isEmpty ? "" : "Infos: \($0.material)\n" } ?? ""
            answer = (try? await s.respond(to: m + q).content) ?? L("Das ging gerade nicht.", "That didn't work.")
        }
    }
    func continueInChat() { let q = question; collapse(); AI.chat(q) }
    func refreshPower() {
        guard let i = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let l = IOPSCopyPowerSourcesList(i)?.takeRetainedValue() as? [CFTypeRef], let p = l.first,
              let d = IOPSGetPowerSourceDescription(i, p)?.takeUnretainedValue() as? [String: Any] else { return }
        charge = d[kIOPSCurrentCapacityKey] as? Int
        let was = charging
        charging = d[kIOPSIsChargingKey] as? Bool ?? false
        if was != charging { fit() }
    }
    // Was läuft gerade? Nur fragen, wenn Musik oder Spotify ohnehin offen sind (startet nichts)
    private func readTrack() {
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let target = apps.contains("com.spotify.client") ? "Spotify" : apps.contains("com.apple.Music") ? "Music" : nil
        guard let target else { track = nil; return }
        Task.detached(priority: .utility) {
            let src = "tell application \"\(target)\" to if player state is playing or player state is paused then return (name of current track) & \"\\n\" & (artist of current track) & \"\\n\" & (player state as string)"
            var e: NSDictionary?
            let r = NSAppleScript(source: src)?.executeAndReturnError(&e).stringValue?.components(separatedBy: "\n")
            await MainActor.run { Notch.shared.track = r.flatMap { $0.count >= 3 ? ($0[0], $0[1], target, $0[2].contains("playing")) : nil } }
        }
    }
    // App-Symbol einmal laden: im body kostete es bei jedem Öffnen Zeit mitten in der Animation
    private static var icons: [String: NSImage] = [:]
    static func icon(_ id: String) -> NSImage? {
        if let i = icons[id] { return i }
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: u.path); icons[id] = i; return i
    }
    func media(_ key: Int) { SystemAction.media(key); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { Notch.shared.readTrack() } } }
}

// Form wie die echte Aussparung: oben weich in den Bildschirmrand, unten kontinuierlich gerundet (Apple-Kurve)
private struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {
        let t: CGFloat = 8, k: CGFloat = 0.55 // Ausrundung oben, Bézier-Faktor für weiche Kurven
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control1: CGPoint(x: r.minX + t * k, y: r.minY), control2: CGPoint(x: r.minX + t, y: r.minY + t * (1 - k)))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - radius))
        p.addCurve(to: CGPoint(x: r.minX + t + radius, y: r.maxY), control1: CGPoint(x: r.minX + t, y: r.maxY - radius * (1 - k)), control2: CGPoint(x: r.minX + t + radius * (1 - k), y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - radius, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - radius), control1: CGPoint(x: r.maxX - t - radius * (1 - k), y: r.maxY), control2: CGPoint(x: r.maxX - t, y: r.maxY - radius * (1 - k)))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY), control1: CGPoint(x: r.maxX - t, y: r.minY + t * (1 - k)), control2: CGPoint(x: r.maxX - t * k, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var n: Notch
    @Environment(\.accessibilityReduceMotion) private var still
    @FocusState private var typing: Bool
    var body: some View {
        let a = n.activity, side: CGFloat = a == nil ? 0 : 78
        let w = n.open ? n.size.width - 20 : n.notch.width + side * 2 + 12, h = n.open ? n.size.height - 12 : n.notch.height
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: n.open ? 30 : 10).fill(.black)
                if n.open {
                    expanded.padding(.top, n.notch.height - 2).padding(.horizontal, 24).padding(.bottom, 16)
                        .frame(width: n.size.width - 20, height: n.size.height - 12, alignment: .top) // feste Größe: der Inhalt wächst nicht mit, die Form deckt ihn auf
                        // ohne Unschärfe: die kostet auf der ganzen Fläche jedes Bild und ließ es ruckeln
                        .transition(still ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.spring(response: 0.38, dampingFraction: 0.92).delay(0.06)),
                            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(.spring(response: 0.18, dampingFraction: 1))))
                } else if let a { collapsed(a).frame(height: n.notch.height).transition(.modifier(active: Soft(on: true), identity: Soft(on: false))) }
            }
            // Breite und Höhe mit eigenen Federn: die Breite schwingt schneller und federt nach, die Höhe folgt weicher –
            // so dehnt sich die Form wie Gummi (wie Apples Dynamic Island) statt als starres Rechteck zu wachsen
            .frame(width: w, alignment: .top)
            .animation(still ? .easeOut(duration: 0.15) : n.open ? .spring(response: 0.42, dampingFraction: 0.68) : .spring(response: 0.34, dampingFraction: 0.9), value: w)
            .frame(height: h, alignment: .top)
            .animation(still ? .easeOut(duration: 0.15) : n.open ? .spring(response: 0.52, dampingFraction: 0.8) : .spring(response: 0.38, dampingFraction: 0.95), value: h)
            .clipShape(NotchShape(radius: n.open ? 30 : 10)) // wie bei Apple: nichts ragt über die schwarze Form hinaus
            .contentShape(NotchShape(radius: 10))
            .onHover { n.hover($0) }
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { n.dropping }, set: { v in n.dropping = v; n.hover(v) })) { providers in
                _ = Shelf.shared.add(providers); n.dropping = false; n.hover(false); return true
            }
            // genau eine Feder (zwei kämpften vorher um dieselbe Größe): auf mit leichtem Nachfedern, zu ohne – wie die Dynamic Island
            .animation(still ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.8), value: n.open) // Ecken
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: a?.icon)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
    private func collapsed(_ a: (icon: String, text: String, tint: Color)) -> some View {
        HStack {
            Group {
                if a.icon == "progress" { // Ring wie bei Apples Downloads
                    ZStack {
                        Circle().stroke(a.tint.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: n.progress ?? 0).stroke(a.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                            .animation(still ? nil : .spring(response: 0.5, dampingFraction: 0.9), value: n.progress)
                    }
                    .frame(width: 14, height: 14).accessibilityLabel(L("OneNote-PDF wird erstellt", "Creating OneNote PDF"))
                } else {
                    Image(systemName: a.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(a.tint).symbolEffect(.variableColor.iterative, isActive: a.icon == "waveform" && !still)
                }
            }
            .frame(width: 60, alignment: .leading)
            Spacer(minLength: n.notch.width)
            Text(a.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(a.tint).lineLimit(1).contentTransition(.numericText()).frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }
    private var expanded: some View {
        VStack(spacing: 10) {
            HStack {
                Text(n.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: n.notch.width + 20)
                if let c = n.charge { Label("\(c) %", systemImage: n.charging ? "battery.100percent.bolt" : c <= 20 ? "battery.25percent" : "battery.75percent").font(.system(size: 12, weight: .medium)).foregroundStyle(n.charging ? .green : c <= 20 ? .red : .white.opacity(0.65)) }
            }
            // Frage an die KI, ohne ein Fenster zu öffnen
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.7))
                TextField("", text: $n.question, prompt: Text(L("Frag mich etwas oder: „Timer 10 Minuten“", "Ask me something or: “timer 10 minutes”")).foregroundStyle(.white.opacity(0.4)))
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($typing).onSubmit { n.ask() }
                if n.thinking { ProgressView().controlSize(.small).tint(.white) }
                else if !n.question.isEmpty { Button { n.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }.buttonStyle(.plain).accessibilityLabel(L("Fragen", "Ask")) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.1), in: Capsule())
            if let ans = n.answer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(.init(ans)).font(.system(size: 13)).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    HStack { Spacer(); Button(L("Im Chat weiter", "Continue in chat")) { n.continueInChat() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)) }
                }
                .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if n.dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .overlay(Label(L("Loslassen: in die Ablage", "Drop: add to shelf"), systemImage: "tray.and.arrow.down").font(.headline))
            } else {
                HStack(alignment: .top, spacing: 10) { music; if Tool.school.on { today } }
                HStack(spacing: 8) {
                    if Tool.scan.on { quick("doc.viewfinder", L("Scannen", "Scan")) { Scanner.open() } }
                    if Tool.tidy.on { quick("sparkles.rectangle.stack", L("Schön machen", "Tidy up")) { Tidy.open() } } else if Tool.hand.on { quick("pencil.and.scribble", L("Handschrift", "Handwriting")) { Hand.openWindow() } }
                    quick("tray", L("Ablage", "Shelf")) { Shelf.shared.toggle() }
                    if Tool.battery.on { quick("battery.75percent", L("Akku", "Battery")) { Battery.open() } }
                    quick("timer", L("Timer 10 min", "Timer 10 min")) { SearchTimer.shared.start(10); n.live(); n.fit() }
                }
            }
        }
    }
    private var music: some View {
        card {
            HStack(spacing: 10) {
                appIcon.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.track?.title ?? L("Keine Musik", "No music")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(n.track?.artist ?? L("Musik oder Spotify starten", "Start Music or Spotify")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 24) {
                Button { n.media(18) } label: { Image(systemName: "backward.fill") }.accessibilityLabel(L("Zurück", "Previous"))
                Button { n.media(16) } label: { Image(systemName: n.track?.playing == true ? "pause.fill" : "play.fill").font(.title3).contentTransition(.symbolEffect(.replace)) }.accessibilityLabel(L("Wiedergabe", "Play/Pause"))
                Button { n.media(17) } label: { Image(systemName: "forward.fill") }.accessibilityLabel(L("Weiter", "Next"))
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private var appIcon: some View {
        let id = n.track?.app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        if let i = Notch.icon(id) { Image(nsImage: i).resizable() }
        else { Image(systemName: "music.note").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9)) }
    }
    // Tagesüberblick: Stunden heute, was als Nächstes kommt, nächste Abgabe
    private var today: some View {
        card {
            let b = School.shared.book, nx = Plan.now(b, n.now), lessons = Plan.lessons(b, on: n.now), left = lessons.filter { $0.end > ActLogic.cal.component(.hour, from: n.now) * 60 + ActLogic.cal.component(.minute, from: n.now) }.count
            let task = b.tasks.filter { !$0.done }.min { $0.due < $1.due }
            Label(nx.current.map { L("Jetzt \($0.subject)", "Now \($0.subject)") } ?? nx.next.map { L("\(Plan.clock($0.start)) \($0.subject)", "\($0.subject) at \(Plan.clock($0.start))") } ?? (lessons.isEmpty ? L("Heute frei", "No classes today") : L("Schule ist aus", "School is out")), systemImage: "graduationcap").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if left > 0 { Text(L("noch \(left) Stunde(n) heute", "\(left) class(es) left today")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
            Text(task.map { ($0.subject.isEmpty ? "" : $0.subject + ": ") + $0.text + " · " + $0.due.formatted(.dateTime.weekday(.abbreviated)) } ?? L("Keine offenen Aufgaben", "No open tasks")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            Spacer(minLength: 0)
            Button(L("Schule öffnen", "Open School")) { School.open(); n.collapse() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
    }
    private func card(@ViewBuilder _ c: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6, content: c).padding(12).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func quick(_ icon: String, _ title: String, _ act: @escaping () -> Void) -> some View {
        Button { act(); n.collapse() } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 15)).frame(height: 18); Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                .frame(maxWidth: .infinity).padding(.vertical, 8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous)).contentShape(Rectangle())
        }
        .buttonStyle(NotchPress()).accessibilityLabel(title)
    }
}
// Ein- und Ausblenden mit Unschärfe und leichtem Zoom von oben, wie Apples Inhalte in der Dynamic Island
private struct Soft: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { content.opacity(on ? 0 : 1).blur(radius: on ? 6 : 0).scaleEffect(on ? 0.94 : 1, anchor: .top) }
}
// Drücken: leicht kleiner und heller, wie Apples Kontrollzentrum
private struct NotchPress: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.scaleEffect(c.isPressed ? 0.94 : 1).brightness(c.isPressed ? 0.08 : 0).animation(.spring(response: 0.25, dampingFraction: 0.7), value: c.isPressed)
    }
}
