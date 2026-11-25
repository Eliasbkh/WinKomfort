// Lernmodus: Zeit läuft, ablenkende Apps werden ausgeblendet, sobald man sie nach vorne holt
import AppKit
import SwiftUI

@MainActor final class StudyMode: ObservableObject {
    static let shared = StudyMode()
    @Published private(set) var until: Date?
    private var timer: Timer?, token: NSObjectProtocol?
    static let usual = ["com.valvesoftware.steam", "com.hnc.Discord", "net.whatsapp.WhatsApp", "com.mojang.minecraftlauncher", "com.google.android.youtube", "com.ninjakiwi.bloonstd6", "org.telegram.desktop", "com.netflix.Netflix", "com.apple.TV", "ModrinthApp", "com.epicgames.EpicGamesLauncher"]
    var blocked: [String] {
        get { UserDefaults.standard.stringArray(forKey: "studyBlocked") ?? Self.usual }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "studyBlocked") }
    }
    func start(_ minutes: Int) {
        stop(quiet: true)
        until = Date().addingTimeInterval(Double(minutes) * 60)
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { StudyMode.shared.check(a) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { _ in MainActor.assumeIsolated { StudyMode.shared.stop() } }
        NSWorkspace.shared.runningApplications.filter { blocked.contains($0.bundleIdentifier ?? "") }.forEach { $0.hide() }
        Toast.show(L("Lernmodus bis \(until!.formatted(date: .omitted, time: .shortened))", "Study mode until \(until!.formatted(date: .omitted, time: .shortened))"), symbol: "book", seconds: 2.5)
    }
    private func check(_ a: NSRunningApplication?) {
        guard let a, let u = until, u > Date(), blocked.contains(a.bundleIdentifier ?? "") else { return }
        a.hide() // nur ausblenden, nie beenden: nichts geht verloren
        Toast.show(L("\(a.localizedName ?? "App") ist bis \(u.formatted(date: .omitted, time: .shortened)) gesperrt", "\(a.localizedName ?? "App") is blocked until \(u.formatted(date: .omitted, time: .shortened))"), symbol: "book", seconds: 2)
    }
    func stop(quiet: Bool = false) {
        timer?.invalidate(); timer = nil
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
        guard until != nil else { return }
        until = nil
        if !quiet { NSSound(named: "Glass")?.play(); Toast.show(L("Lernzeit vorbei, gute Pause", "Study time over, enjoy your break"), symbol: "cup.and.saucer", seconds: 4) }
    }
}
struct StudySection: View {
    @ObservedObject private var m = StudyMode.shared
    private func name(_ id: String) -> String { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id }
    var body: some View {
        Section {
            HStack {
                if let u = m.until { Text(L("Läuft bis \(u.formatted(date: .omitted, time: .shortened))", "Running until \(u.formatted(date: .omitted, time: .shortened))")); Spacer(); Button(L("Beenden", "Stop")) { m.stop(quiet: true) } }
                else { Text(L("Starten", "Start")); Spacer(); ForEach([25, 45, 90], id: \.self) { n in Button("\(n) min") { m.start(n) } } }
            }
            ForEach(m.blocked.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }, id: \.self) { id in
                HStack { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 20, height: 20) }; Text(name(id)); Spacer(); Button { m.blocked.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel(L("\(name(id)) erlauben", "Allow \(name(id))")) }
            }
            Button(L("App hinzufügen …", "Add app…")) {
                let p = NSOpenPanel(); p.directoryURL = URL(fileURLWithPath: "/Applications"); p.allowedContentTypes = [.application]
                if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier, !m.blocked.contains(id), id != Bundle.main.bundleIdentifier { m.blocked.append(id) }
            }
        } header: { Text(L("Lernmodus", "Study mode")) } footer: { Text(L("Diese Apps werden beim Lernen sofort wieder ausgeblendet. Nichts wird beendet. Auch mit „/lernen 45“ in der Suche.", "These apps are hidden again right away while studying. Nothing is quit. Also “/study 45” in search.")) }
    }
}
