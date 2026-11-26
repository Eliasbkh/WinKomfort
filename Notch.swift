// Interaktive Notch: unsichtbar wie die Kamera-Aussparung, fährt beim Drüberfahren oder Hineinziehen aus
import AppKit
import IOKit.ps
import SwiftUI

@MainActor final class Notch: ObservableObject {
    static let shared = Notch()
    @Published var open = false { didSet { if open != oldValue { fit() } } }
    @Published var dropping = false
    @Published var track: (title: String, artist: String, app: String, playing: Bool)?
    @Published var now = Date()
    @Published var charging = false
    @Published var charge: Int?
    private var panel: NSPanel?
    private var tick: Timer?
    private var closeWork: DispatchWorkItem?
    private var token: NSObjectProtocol?
    private(set) var notch = CGSize(width: 200, height: 32)
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notch") as? Bool ?? true }

    // nur auf Bildschirmen mit Kamera-Aussparung
    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } }
    func update() { Self.enabled && screen != nil ? show() : hide() }
    private func show() {
        guard let s = screen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return }
        notch = CGSize(width: r.minX - l.maxX, height: s.safeAreaInsets.top)
        center = s.frame.minX + l.maxX + notch.width / 2; top = s.frame.maxY
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // über der Menüleiste
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isReleasedWhenClosed = false; p.acceptsMouseMovedEvents = true
            p.contentView = NSHostingView(rootView: NotchView(n: self))
            panel = p
        }
        fit(now: true)
        panel?.orderFrontRegardless()
        if token == nil { token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Notch.shared.update() } } }
        refreshPower()
        live()
        if minute == nil { // einmal pro Minute: Laden, „Stunde gleich“ – fast kostenlos
            minute = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { let n = Notch.shared; let had = n.activity?.icon; n.refreshPower(); n.now = Date(); if had != n.activity?.icon { n.fit() } } }
            minute?.tolerance = 15
        }
    }
    private var minute: Timer?
    private func hide() { panel?.orderOut(nil); tick?.invalidate(); tick = nil; minute?.invalidate(); minute = nil }

    // Das Fenster ist nur so groß wie die sichtbare Form: daneben gehen Klicks normal an die Menüleiste und an Fenster darunter
    private var center: CGFloat = 0, top: CGFloat = 0, shrink: DispatchWorkItem?
    var size: CGSize { open ? CGSize(width: 580, height: 222) : CGSize(width: notch.width + (activity == nil ? 0 : 156) + 12, height: notch.height) }
    func fit(now: Bool = false) {
        guard let p = panel else { return }
        shrink?.cancel()
        let want = size
        let apply = { [weak self] in
            guard let self, let p = self.panel else { return }
            p.setFrame(CGRect(x: self.center - want.width / 2, y: self.top - want.height, width: want.width, height: want.height), display: true)
        }
        if now || want.width >= p.frame.width || want.height >= p.frame.height { apply() } // größer: sofort, damit die Animation Platz hat
        else { let w = DispatchWorkItem { MainActor.assumeIsolated { apply() } }; shrink = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w) } // kleiner: nach der Animation
    }

    // Live-Anzeige links/rechts der Kamera: Timer, Laden, Stunde bald
    var activity: (icon: String, text: String, tint: Color)? {
        if let t = SearchTimer.shared.running.map(\.end).min(), t > now {
            let s = Int(t.timeIntervalSince(now)); return ("timer", String(format: "%d:%02d", s / 60, s % 60), .orange)
        }
        if charging, let c = charge { return ("bolt.fill", "\(c) %", .green) }
        if let l = Plan.now(School.shared.book, now).next, let m = Optional(l.start - (ActLogic.cal.component(.hour, from: now) * 60 + ActLogic.cal.component(.minute, from: now))), m <= 10, m >= 0 {
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
    func hover(_ on: Bool) {
        closeWork?.cancel()
        if on { if !open { open = true; refreshPower(); readTrack(); live() } }
        else {
            let w = DispatchWorkItem { MainActor.assumeIsolated { let n = Notch.shared; if !n.dropping { n.open = false; n.live() } } }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }
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
    func media(_ key: Int) { SystemAction.media(key); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { Notch.shared.readTrack() } } }
}

// Form: oben gerade (geht in den Bildschirmrand über), unten weich gerundet – wie die echte Aussparung
private struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path(), t: CGFloat = 6 // kleine Ausrundung oben in den Rand
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + radius, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - radius), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var n: Notch
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        let a = n.activity, side: CGFloat = a == nil ? 0 : 78
        let w = n.open ? 560 : n.notch.width + side * 2 + 12, h = n.open ? 210 : n.notch.height
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: n.open ? 26 : 9).fill(.black)
                if n.open { expanded.padding(.top, n.notch.height - 4).padding(.horizontal, 22).padding(.bottom, 14).transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top))) }
                else if let a { collapsed(a).frame(height: n.notch.height) }
            }
            .frame(width: w, height: h)
            .contentShape(NotchShape(radius: 10))
            .onHover { n.hover($0) }
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { n.dropping }, set: { v in n.dropping = v; n.hover(v) })) { providers in
                _ = Shelf.shared.add(providers); n.dropping = false; n.hover(false); return true
            }
            .animation(still ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.8), value: n.open)
            .animation(.easeOut(duration: 0.2), value: a?.icon)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
    private func collapsed(_ a: (icon: String, text: String, tint: Color)) -> some View {
        HStack {
            Image(systemName: a.icon).foregroundStyle(a.tint).symbolEffect(.pulse, isActive: a.icon == "waveform" && !still).frame(width: 60, alignment: .leading)
            Spacer(minLength: n.notch.width)
            Text(a.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(a.tint).lineLimit(1).frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }
    private var expanded: some View {
        VStack(spacing: 12) {
            HStack {
                Text(n.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: n.notch.width + 20)
                if let c = n.charge { Label("\(c) %", systemImage: n.charging ? "battery.100.bolt" : "battery.75percent").font(.system(size: 12, weight: .medium)).foregroundStyle(n.charging ? .green : .white.opacity(0.7)) }
            }
            if n.dropping {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .overlay(Label(L("Loslassen: in die Ablage", "Drop: add to shelf"), systemImage: "tray.and.arrow.down").font(.headline))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    card {
                        HStack(spacing: 10) {
                            Image(systemName: n.track?.app == "Spotify" ? "music.note.house.fill" : "music.note").font(.title2).frame(width: 40, height: 40).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.track?.title ?? L("Keine Musik", "No music")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(n.track?.artist ?? L("Musik oder Spotify starten", "Start Music or Spotify")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 22) {
                            Button { n.media(18) } label: { Image(systemName: "backward.fill") }.accessibilityLabel(L("Zurück", "Previous"))
                            Button { n.media(16) } label: { Image(systemName: n.track?.playing == true ? "pause.fill" : "play.fill").font(.title3) }.accessibilityLabel(L("Wiedergabe", "Play/Pause"))
                            Button { n.media(17) } label: { Image(systemName: "forward.fill") }.accessibilityLabel(L("Weiter", "Next"))
                        }
                        .buttonStyle(.plain).frame(maxWidth: .infinity)
                    }
                    card {
                        let b = School.shared.book, nx = Plan.now(b, n.now), task = b.tasks.filter { !$0.done }.min { $0.due < $1.due }
                        Label(nx.current.map { L("Jetzt \($0.subject)", "Now \($0.subject)") } ?? nx.next.map { L("\(Plan.clock($0.start)) \($0.subject)", "\($0.subject) at \(Plan.clock($0.start))") } ?? L("Keine Stunde mehr", "No more classes"), systemImage: "graduationcap").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(task.map { ($0.subject.isEmpty ? "" : $0.subject + ": ") + $0.text } ?? L("Keine offenen Aufgaben", "No open tasks")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                        Spacer(minLength: 0)
                        Button(L("Schule öffnen", "Open School")) { School.open(); n.hover(false) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                HStack(spacing: 8) {
                    quick("sparkles", L("KI fragen", "Ask AI")) { HotAction.ask.perform() }
                    quick("doc.viewfinder", L("Scannen", "Scan")) { Scanner.open() }
                    quick("tray", L("Ablage", "Shelf")) { Shelf.shared.toggle() }
                    quick("battery.75percent", L("Akku", "Battery")) { Battery.open() }
                    quick("timer", L("Timer 10 min", "Timer 10 min")) { SearchTimer.shared.start(10); n.live(); n.fit() }
                }
            }
        }
    }
    private func card(@ViewBuilder _ c: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: c).padding(12).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private func quick(_ icon: String, _ title: String, _ act: @escaping () -> Void) -> some View {
        Button { act(); n.hover(false) } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 15)); Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                .frame(maxWidth: .infinity).padding(.vertical, 7).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title)
    }
}
