// Merkt sich nur auf diesem Mac, welche Apps du oft nach vorne holst und was du bei welchem Suchwort wählst
import AppKit

@MainActor final class AppUsage {
    static let shared = AppUsage()
    private struct Use: Codable { var score: Double; var at: Date }
    private var uses: [String: Use]
    private var picks: [String: String] // Suchwort → Pfad
    private var last: String?
    private var seeded: [String: Double] = [:]

    private init() {
        let d = UserDefaults.standard
        uses = d.data(forKey: "appUsage").flatMap { try? JSONDecoder().decode([String: Use].self, from: $0) } ?? [:]
        picks = d.dictionary(forKey: "searchPicks") as? [String: String] ?? [:]
    }
    func setup() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { n in
            if let p = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier { MainActor.assumeIsolated { AppUsage.shared.touch(p) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            if let p = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier { MainActor.assumeIsolated { AppUsage.shared.seen[p] = nil } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.activationPolicy == .regular, app?.processIdentifier != getpid(), let p = app?.bundleURL?.path else { return }
            MainActor.assumeIsolated { AppUsage.shared.used(p) }
        }
    }
    // Wann war die App zuletzt vorne? Unbekannt: seit ihrem Start bzw. seit WinKomfort läuft (nie länger geraten)
    private var seen: [pid_t: Date] = [:]
    private let began = Date()
    func touch(_ p: pid_t) { seen[p] = Date() }
    func idleMinutes(_ p: pid_t) -> Int {
        guard let a = NSRunningApplication(processIdentifier: p), !a.isActive else { return 0 }
        return Int(Date().timeIntervalSince(seen[p] ?? max(began, a.launchDate ?? began)) / 60)
    }
    private func used(_ path: String) {
        guard path != last else { return }
        last = path
        let now = Date(), old = uses[path]
        uses[path] = Use(score: min((old.map { SearchRank.decayed($0.score, since: $0.at, now: now) } ?? 0) + 1, 1000), at: now)
        if uses.count > 300 { uses = Dictionary(uniqueKeysWithValues: uses.sorted { $0.value.at > $1.value.at }.prefix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(try? JSONEncoder().encode(uses), forKey: "appUsage")
    }
    func score(_ path: String) -> Double {
        (uses[path].map { SearchRank.decayed($0.score, since: $0.at, now: Date()) } ?? 0) + seed(path)
    }
    // Anfangs kennt WinKomfort nichts: dann zählt, was macOS selbst weiß (zuletzt benutzt, Häufigkeit)
    private func seed(_ path: String) -> Double {
        if let s = seeded[path] { return s }
        var s = 0.0
        if let item = MDItemCreate(nil, path as CFString) {
            let count = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.doubleValue ?? 0
            if let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { s = SearchRank.decayed(min(1 + count.squareRoot(), 30), since: d, now: Date()) }
        }
        seeded[path] = s
        return s
    }
    func frequent(_ apps: [AppEntry], _ n: Int) -> [AppEntry] {
        Array(apps.map { ($0, score($0.path)) }.filter { $0.1 > 0.2 }.sorted { $0.1 > $1.1 }.prefix(n).map(\.0))
    }
    func picked(_ q: String, _ path: String) {
        let k = SearchRank.fold(q)
        guard !k.isEmpty, k.count <= 20 else { return }
        if picks.count > 300, picks[k] == nil, let any = picks.keys.first { picks[any] = nil }
        picks[k] = path
        UserDefaults.standard.set(picks, forKey: "searchPicks")
    }
    func pick(_ q: String) -> String? { picks[SearchRank.fold(q)] }
}
