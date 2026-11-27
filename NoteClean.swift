// OneNote aufräumen über Microsoft Graph: leere Seiten löschen, unbenannte Seiten und Abschnitte von der KI benennen lassen.
// Anmeldung per Gerätecode im Browser (WinKomfort sieht kein Passwort). Erst Vorschläge, dann nur das Angehakte anwenden.
import AppKit
import FoundationModels
import Security
import SwiftUI

@MainActor final class NoteClean: ObservableObject {
    static let shared = NoteClean()
    // shortcut: öffentlicher Client „Microsoft Graph Command Line Tools“ statt eigener App-Registrierung – nur für den privaten Gebrauch;
    // blockiert die Schule ihn, braucht es eine eigene Registrierung im Azure-Portal
    static let client = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
    static let scope = "Notes.ReadWrite.All Sites.Read.All offline_access"
    static let login = "https://login.microsoftonline.com/organizations/oauth2/v2.0/"

    enum Phase: Equatable { case signedOut, code(String, URL), ready, local }
    struct Book: Identifiable, Hashable { let id: String; let name: String; let base: String } // base: "me" oder "sites/<id>"
    struct Proposal: Identifiable {
        enum Kind { case delete, renamePage, renameSection }
        let id = UUID(); let kind: Kind; let target: String; let base: String; let where_: String; let old: String; var new: String; var on = true
        var state: String?   // nach dem Anwenden: erledigt oder Fehler
    }
    @Published var phase: Phase = refresh == nil ? .signedOut : .ready
    @Published var books: [Book] = []
    @Published var book: Book?
    @Published var proposals: [Proposal] = []
    @Published var busy: String?
    @Published var note: String?
    @Published var undo: [(base: String, kind: Proposal.Kind, target: String, old: String)] = []
    private var access: (token: String, until: Date)?
    private var job: Task<Void, Never>?

    static func open() {
        let first = windows["noteclean"] == nil
        showWindow("noteclean", "OneNote aufräumen") { NoteCleanView() }
        windows["noteclean"]?.title = L("OneNote aufräumen", "Tidy OneNote")
        if first { windows["noteclean"]?.setContentSize(NSSize(width: 760, height: 600)); windows["noteclean"]?.center() }
        if shared.phase == .ready, shared.books.isEmpty { shared.loadBooks() }
    }

    // MARK: Anmeldung (Gerätecode)
    func signIn() {
        busy = L("Verbinde mit Microsoft …", "Connecting to Microsoft…"); note = nil
        job = Task {
            defer { busy = nil }
            do {
                let d = try await Self.form(Self.login + "devicecode", ["client_id": Self.client, "scope": Self.scope])
                guard let code = d["user_code"] as? String, let dev = d["device_code"] as? String, let u = (d["verification_uri"] as? String).flatMap(URL.init) else { throw Fail(L("Microsoft hat keinen Code geschickt.", "Microsoft sent no code.")) }
                phase = .code(code, u)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                let every = max(3, d["interval"] as? Int ?? 5), until = Date().addingTimeInterval(Double(d["expires_in"] as? Int ?? 900))
                busy = L("Warte auf deine Anmeldung im Browser …", "Waiting for you to sign in in the browser…")
                while Date() < until, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(every))
                    let t = try await Self.form(Self.login + "token", ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": Self.client, "device_code": dev], allowError: true)
                    if let a = t["access_token"] as? String { take(t, a); phase = .ready; loadBooks(); return }
                    let e = t["error"] as? String ?? ""
                    if e == "authorization_pending" || e == "slow_down" { continue }
                    throw Fail(e == "access_denied" || e == "authorization_declined" ? Self.blocked : Self.explain(t))
                }
                phase = .signedOut; note = L("Der Code ist abgelaufen. Bitte noch einmal.", "The code expired. Please try again.")
            } catch { phase = .signedOut; note = (error as? Fail)?.text ?? error.localizedDescription }
        }
    }
    func signOut() { Self.refresh = nil; access = nil; books = []; book = nil; proposals = []; undo = []; phase = .signedOut }
    private func take(_ t: [String: Any], _ a: String) {
        access = (a, Date().addingTimeInterval(Double((t["expires_in"] as? Int ?? 3600) - 120)))
        if let r = t["refresh_token"] as? String { Self.refresh = r }
    }
    private func token() async throws -> String {
        if let a = access, a.until > Date() { return a.token }
        guard let r = Self.refresh else { phase = .signedOut; throw Fail(L("Bitte neu anmelden.", "Please sign in again.")) }
        let t = try await Self.form(Self.login + "token", ["grant_type": "refresh_token", "client_id": Self.client, "refresh_token": r, "scope": Self.scope], allowError: true)
        guard let a = t["access_token"] as? String else { signOut(); throw Fail(L("Die Anmeldung ist abgelaufen. Bitte neu anmelden.", "Sign-in expired. Please sign in again.")) }
        take(t, a); return a
    }
    private static func explain(_ t: [String: Any]) -> String {
        let d = t["error_description"] as? String ?? ""
        if d.contains("AADSTS65001") || d.contains("consent") || d.contains("AADSTS90094") { return blocked }
        return d.components(separatedBy: "\n").first ?? L("Anmeldung fehlgeschlagen.", "Sign-in failed.")
    }
    // Schulkonto mit Sperre: nicht umgehen – die Regel gehört der Schule
    static let blocked = L("Deine Schule gibt diesen Zugriff nur mit Freigabe durch die IT frei. Frag die IT-Betreuer nach einer Freigabe für „Microsoft Graph Command Line Tools“ (Notizbücher lesen und ändern), oder nutze ein privates Microsoft-Konto.", "Your school only allows this with IT approval. Ask IT to approve “Microsoft Graph Command Line Tools” (read and change notebooks), or use a personal Microsoft account.")
    struct Fail: Error { let text: String; init(_ t: String) { text = t } }

    // Refresh-Token im Schlüsselbund
    static var refresh: String? {
        get {
            var r: CFTypeRef?
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "de.winkomfort.graph", kSecAttrAccount as String: "onenote", kSecReturnData as String: true]
            return SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess ? (r as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "de.winkomfort.graph", kSecAttrAccount as String: "onenote"]
            SecItemDelete(q as CFDictionary)
            if let v = newValue { var a = q; a[kSecValueData as String] = Data(v.utf8); a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; SecItemAdd(a as CFDictionary, nil) }
        }
    }

    // MARK: Netzwerk
    private static func form(_ url: String, _ p: [String: String], allowError: Bool = false) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 30); r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        r.httpBody = p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        if !allowError, (resp as? HTTPURLResponse)?.statusCode ?? 0 >= 400 { throw Fail(explain(j)) }
        return j
    }
    private func graph(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        let u = path.hasPrefix("https://") ? URL(string: path)! : URL(string: "https://graph.microsoft.com/v1.0/" + path)!
        var r = URLRequest(url: u, timeoutInterval: 40); r.httpMethod = method
        r.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for attempt in 0..<4 {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 || code == 503, attempt < 3 { // gedrosselt: warten, was Microsoft sagt
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(2 << attempt)
                try await Task.sleep(for: .seconds(min(wait, 30))); continue
            }
            if code >= 400 {
                let m = (((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
                throw Fail(code == 403 ? L("Keine Berechtigung (z. B. Lehrer-Bereich im Kursnotizbuch).", "No permission (e.g. teacher-only part of a class notebook).") : m)
            }
            return d
        }
        throw Fail(L("Microsoft antwortet gerade nicht.", "Microsoft isn't responding right now."))
    }
    private func list(_ path: String) async throws -> [[String: Any]] {
        var out: [[String: Any]] = [], next: String? = path
        while let p = next {
            let j = (try JSONSerialization.jsonObject(with: try await graph("GET", p))) as? [String: Any] ?? [:]
            out += j["value"] as? [[String: Any]] ?? []
            next = j["@odata.nextLink"] as? String
        }
        return out
    }

    // MARK: Notizbücher (eigene in OneDrive + die Kursnotizbücher, die WinKomfort schon von SharePoint kennt)
    func loadBooks() {
        busy = L("Lade deine Notizbücher …", "Loading your notebooks…")
        job = Task {
            defer { busy = nil }
            var all: [Book] = []
            if let own = try? await list("me/onenote/notebooks?$select=id,displayName") { all += own.compactMap { b in (b["id"] as? String).map { Book(id: $0, name: b["displayName"] as? String ?? "?", base: "me") } } }
            for (host, site) in Self.knownSites() {
                guard let s = (try? JSONSerialization.jsonObject(with: try await graph("GET", "sites/\(host):/sites/\(site)?$select=id"))) as? [String: Any], let sid = s["id"] as? String,
                      let nb = try? await list("sites/\(sid)/onenote/notebooks?$select=id,displayName") else { continue }
                all += nb.compactMap { b in (b["id"] as? String).map { Book(id: $0, name: b["displayName"] as? String ?? site, base: "sites/\(sid)") } }
            }
            books = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if book == nil { book = books.first }
            if books.isEmpty { note = L("Keine Notizbücher gefunden – oder deine Schule lässt den Zugriff nicht zu.", "No notebooks found – or your school doesn't allow access.") }
        }
    }
    // Aus dem Zwischenspeicher von „OneNote → PDF“: Ordner <host>/sites/<name>
    static func knownSites() -> [(String, String)] {
        let base = OneNoteCloud.cacheDir("https://x").deletingLastPathComponent(), fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).flatMap { host in
            ((try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(host).appendingPathComponent("sites").path)) ?? []).map { (host, $0) }
        }
    }

    // MARK: Analyse
    func analyze() {
        guard let b = book else { return }
        proposals = []; undo = []; note = nil
        job = Task {
            defer { busy = nil }
            do {
                busy = L("Lese die Abschnitte …", "Reading sections…")
                let secs = try await list("\(b.base)/onenote/notebooks/\(b.id)/sections?$select=id,displayName")
                    + (try await list("\(b.base)/onenote/notebooks/\(b.id)/sectionGroups?$select=id&$expand=sections($select=id,displayName)")).flatMap { $0["sections"] as? [[String: Any]] ?? [] }
                var out: [Proposal] = [], checked = 0
                for s in secs {
                    guard let sid = s["id"] as? String, !Task.isCancelled else { continue }
                    let sname = s["displayName"] as? String ?? "?"
                    let pages = (try? await list("\(b.base)/onenote/sections/\(sid)/pages?$select=id,title&$top=100")) ?? []
                    var titles: [String] = []
                    for p in pages {
                        guard let pid = p["id"] as? String, !Task.isCancelled else { continue }
                        let title = p["title"] as? String ?? ""
                        checked += 1
                        busy = L("Prüfe Seite \(checked): \(sname) › \(title.isEmpty ? "ohne Titel" : title)", "Checking page \(checked): \(sname) › \(title.isEmpty ? "untitled" : title)")
                        guard let d = try? await graph("GET", "\(b.base)/onenote/pages/\(pid)/content?includeInkML=true") else { continue }
                        let html = String(decoding: d, as: UTF8.self)
                        if NoteLogic.isEmpty(html) { out.append(Proposal(kind: .delete, target: pid, base: b.base, where_: sname, old: title.isEmpty ? L("Unbenannte Seite", "Untitled page") : title, new: "")) ; continue }
                        if !title.isEmpty, !NoteLogic.isUntitled(title) { titles.append(title) }
                        if NoteLogic.isUntitled(title), let n = await Self.name(L("Gib dieser Notizseite einen kurzen, treffenden Titel (2 bis 6 Wörter). Nur den Titel.", "Give this note page a short, fitting title (2 to 6 words). Only the title."), NoteLogic.text(html)) {
                            out.append(Proposal(kind: .renamePage, target: pid, base: b.base, where_: sname, old: title.isEmpty ? L("Unbenannte Seite", "Untitled page") : title, new: n))
                        }
                    }
                    if NoteLogic.isGeneric(section: sname), !titles.isEmpty, let n = await Self.name(L("Gib diesem Abschnitt eines Schul-Notizbuchs einen kurzen Namen (1 bis 4 Wörter), passend zu seinen Seiten. Nur den Namen.", "Name this notebook section (1 to 4 words) based on its pages. Only the name."), titles.joined(separator: "\n")) {
                        out.append(Proposal(kind: .renameSection, target: sid, base: b.base, where_: b.name, old: sname, new: n))
                    }
                    proposals = out
                }
                proposals = out
                note = out.isEmpty ? L("Alles ordentlich: \(checked) Seiten geprüft, nichts zu tun.", "All tidy: \(checked) pages checked, nothing to do.") : L("\(checked) Seiten geprüft.", "\(checked) pages checked.")
            } catch { note = (error as? Fail)?.text ?? error.localizedDescription }
        }
    }
    private static func name(_ task: String, _ text: String) async -> String? {
        guard Assistant.available, #available(macOS 26.0, *), text.count > 5 else { return nil }
        let s = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: "Du benennst Schulnotizen. Antworte nur mit dem Namen, in der Sprache der Notizen.")
        return (try? await s.respond(to: task + "\n\n" + String(text.prefix(1500)), options: GenerationOptions(temperature: 0.2)).content).flatMap(NoteLogic.name)
    }

    // MARK: Ohne Microsoft-Freigabe: aktueller Abschnitt, Inhalte aus der Abschnittsdatei, Änderungen über OneNote selbst
    func startLocal() { phase = .local; proposals = []; undo = []; note = nil; analyzeLocal() }
    func analyzeLocal() {
        guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; return }
        guard OneNoteUI.app != nil else { note = L("OneNote ist nicht geöffnet.", "OneNote isn't open."); return }
        proposals = []; undo = []; note = nil
        busy = L("Lade den aktuellen Abschnitt …", "Loading the current section…")
        job = Task {
            defer { busy = nil }
            guard let t = await Task.detached(operation: { OneNoteCloud.target(.section) }).value else {
                note = L("Der Abschnitt liegt nicht in OneDrive/SharePoint oder OneNote ist nicht bereit.", "The section isn't in OneDrive/SharePoint or OneNote isn't ready."); return
            }
            var pages: [(title: String, html: String)] = []
            let r = await OneNoteCloud.export(.section, t, pages: { urls in
                pages = urls.map { u in
                    let h = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                    let title = h.range(of: #"(?s)<title>(.*?)</title>"#, options: .regularExpression).map { NoteLogic.text(String(h[$0])) } ?? ""
                    return (title, h)
                }
            })
            if case .failure(let e) = r { note = e.text; return }
            let rows = await Task.detached(operation: { OneNoteUI.pageTitles }).value
            guard let untitled = NoteLogic.match(rows: rows, pages: pages.map { ($0.title, NoteLogic.text($0.html)) }) else {
                note = L("OneNote zeigt andere Seiten als die Datei (\(rows.count) gegenüber \(pages.count)). Kurz synchronisieren lassen und noch einmal.", "OneNote shows different pages than the file (\(rows.count) vs \(pages.count)). Let it sync and try again."); return
            }
            let section = await Task.detached(operation: { OneNoteUI.sectionName }).value ?? "?"
            var out: [Proposal] = [], titles: [String] = []
            for (i, p) in pages.enumerated() {
                if Task.isCancelled { return }
                busy = L("Prüfe Seite \(i + 1) von \(pages.count) …", "Checking page \(i + 1) of \(pages.count)…")
                let shown = rows[i]
                if NoteLogic.isEmptyPage(p.html, title: p.title) { out.append(Proposal(kind: .delete, target: "\(i)", base: "local", where_: section, old: shown, new: "")); continue }
                if untitled[i] {
                    if let n = await Self.name(L("Gib dieser Notizseite einen kurzen, treffenden Titel (2 bis 6 Wörter). Nur den Titel.", "Give this note page a short, fitting title (2 to 6 words). Only the title."), NoteLogic.text(p.html)) {
                        out.append(Proposal(kind: .renamePage, target: "\(i)", base: "local", where_: section, old: shown, new: n))
                    }
                } else { titles.append(p.title) }
            }
            if NoteLogic.isGeneric(section: section), !titles.isEmpty, let n = await Self.name(L("Gib diesem Abschnitt eines Schul-Notizbuchs einen kurzen Namen (1 bis 4 Wörter), passend zu seinen Seiten. Nur den Namen.", "Name this notebook section (1 to 4 words) based on its pages. Only the name."), titles.joined(separator: "\n")) {
                out.append(Proposal(kind: .renameSection, target: "", base: "local", where_: L("aktueller Abschnitt", "current section"), old: section, new: n))
            }
            proposals = out
            note = out.isEmpty ? L("Alles ordentlich: \(pages.count) Seiten in „\(section)“ geprüft.", "All tidy: \(pages.count) pages in “\(section)” checked.") : L("\(pages.count) Seiten in „\(section)“ geprüft. Beim Anwenden bedient WinKomfort OneNote – Maus und Tastatur kurz nicht benutzen.", "\(pages.count) pages in “\(section)” checked. While applying, WinKomfort operates OneNote – don't use mouse and keyboard for a moment.")
        }
    }
    // Erst umbenennen, dann löschen – von hinten, damit die Nummern der übrigen Seiten stimmen
    private func applyLocal() {
        let todo = proposals.indices.filter { proposals[$0].on && proposals[$0].state == nil }
            .sorted { a, b in
                let pa = proposals[a], pb = proposals[b]
                if (pa.kind == .delete) != (pb.kind == .delete) { return pb.kind == .delete }
                return (Int(pa.target) ?? 0) > (Int(pb.target) ?? 0)
            }
        let items = todo.map { (i: $0, p: proposals[$0]) }
        job = Task {
            defer { busy = nil }
            var done = 0
            for it in items {
                busy = L("Ändere in OneNote: \(it.p.old) …", "Changing in OneNote: \(it.p.old)…")
                let r: OneNoteUI.Fail? = await Task.detached {
                    do {
                        switch it.p.kind {
                        case .delete: try OneNoteUI.deletePage(Int(it.p.target) ?? -1, title: it.p.old)
                        case .renamePage: try OneNoteUI.renamePage(Int(it.p.target) ?? -1, to: it.p.new)
                        case .renameSection: try OneNoteUI.renameSection(to: it.p.new)
                        }
                        return nil
                    } catch { return error as? OneNoteUI.Fail ?? OneNoteUI.Fail(text: error.localizedDescription) }
                }.value
                if let r { proposals[it.i].state = r.text; note = r.text; NSApp.activate(); return }
                proposals[it.i].state = L("erledigt", "done"); done += 1
            }
            NSApp.activate()
            note = L("\(done) Änderung(en) in OneNote gemacht. Gelöschte Seiten liegen unter Notizbücher › Gelöschte Notizen.", "\(done) change(s) made in OneNote. Deleted pages are under Notebooks › Deleted Notes.")
        }
    }

    // MARK: Anwenden
    func apply() {
        if phase == .local { applyLocal(); return }
        job = Task {
            defer { busy = nil }
            var done = 0, failed = 0
            for i in proposals.indices where proposals[i].on && proposals[i].state == nil {
                let p = proposals[i]
                busy = L("Ändere \(done + failed + 1) …", "Changing \(done + failed + 1)…")
                do {
                    switch p.kind {
                    case .delete: _ = try await graph("DELETE", "\(p.base)/onenote/pages/\(p.target)")
                    case .renamePage:
                        _ = try await graph("PATCH", "\(p.base)/onenote/pages/\(p.target)/content", json: [["target": "title", "action": "replace", "content": p.new]])
                        undo.append((p.base, .renamePage, p.target, p.old))
                    case .renameSection:
                        _ = try await graph("PATCH", "\(p.base)/onenote/sections/\(p.target)", json: ["displayName": p.new])
                        undo.append((p.base, .renameSection, p.target, p.old))
                    }
                    proposals[i].state = L("erledigt", "done"); done += 1
                } catch { proposals[i].state = (error as? Fail)?.text ?? error.localizedDescription; failed += 1 }
            }
            note = failed == 0 ? L("\(done) Änderung(en) angewendet. OneNote zeigt sie nach dem nächsten Synchronisieren.", "\(done) change(s) applied. OneNote shows them after the next sync.") : L("\(done) erledigt, \(failed) ging nicht.", "\(done) done, \(failed) failed.")
        }
    }
    // Umbenennungen zurücknehmen (gelöschte Seiten liegen im OneNote-Papierkorb des Notizbuchs)
    func revert() {
        let items = undo; undo = []
        job = Task {
            defer { busy = nil }
            busy = L("Mache Umbenennungen rückgängig …", "Undoing renames…")
            for u in items.reversed() {
                if u.kind == .renamePage { _ = try? await graph("PATCH", "\(u.base)/onenote/pages/\(u.target)/content", json: [["target": "title", "action": "replace", "content": u.old]]) }
                else { _ = try? await graph("PATCH", "\(u.base)/onenote/sections/\(u.target)", json: ["displayName": u.old]) }
            }
            for i in proposals.indices where proposals[i].kind != .delete { proposals[i].state = nil }
            note = L("Umbenennungen zurückgenommen.", "Renames undone.")
        }
    }
    func cancel() { job?.cancel(); busy = nil }
}

// MARK: Oberfläche
struct NoteCleanView: View {
    @ObservedObject var c = NoteClean.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch c.phase {
            case .signedOut:
                Text(L("Leere Seiten löschen, unbenannte Seiten und Abschnitte wie „Neuer Abschnitt 1“ von der KI sinnvoll benennen lassen. Du siehst erst alle Vorschläge und entscheidest selbst.", "Delete empty pages and let AI give untitled pages and sections like “New Section 1” fitting names. You see every suggestion first and decide."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Dafür meldest du dich einmal mit deinem Schul- oder Microsoft-Konto im Browser an. WinKomfort sieht dein Passwort nie.", "Sign in once with your school or Microsoft account in the browser. WinKomfort never sees your password.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { c.startLocal() } label: { Label(L("Aktuellen Abschnitt über OneNote aufräumen", "Tidy current section via OneNote"), systemImage: "wand.and.stars") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(c.busy != nil)
                    Button { c.signIn() } label: { Label(L("Mit Microsoft anmelden", "Sign in with Microsoft"), systemImage: "person.badge.key") }.controlSize(.large).disabled(c.busy != nil)
                }
                Text(L("„Über OneNote“ braucht keine Freigabe der Schule: WinKomfort bedient deine OneNote-App wie du mit Maus und Menü. Die Microsoft-Anmeldung geht nur, wenn deine Schule sie erlaubt.", "“Via OneNote” needs no school approval: WinKomfort operates your OneNote app like you would. Microsoft sign-in only works if your school allows it.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .code(let code, let url):
                Text(L("Gib diesen Code auf der Microsoft-Seite ein:", "Enter this code on the Microsoft page:"))
                Text(code).font(.system(size: 34, weight: .semibold, design: .monospaced)).textSelection(.enabled).padding(.vertical, 6)
                HStack {
                    Button { NSWorkspace.shared.open(url) } label: { Label(L("Anmeldeseite öffnen", "Open sign-in page"), systemImage: "safari") }.buttonStyle(.borderedProminent)
                    Text(L("Der Code ist schon kopiert.", "The code is already copied.")).font(.caption).foregroundStyle(.secondary)
                }
            case .local:
                HStack {
                    Label(L("Aktueller Abschnitt in OneNote", "Current section in OneNote"), systemImage: "doc.richtext").font(.headline)
                    Spacer()
                    Button(L("Neu prüfen", "Check again")) { c.analyzeLocal() }.disabled(c.busy != nil)
                    Button(L("Zurück", "Back")) { c.cancel(); c.phase = NoteClean.refresh == nil ? .signedOut : .ready; c.proposals = [] }
                }
                list
            case .ready:
                HStack {
                    Picker(L("Notizbuch", "Notebook"), selection: $c.book) { ForEach(c.books) { Text($0.name).tag(Optional($0)) } }.frame(maxWidth: 360)
                    Button(L("Analysieren", "Analyze")) { c.analyze() }.buttonStyle(.borderedProminent).disabled(c.book == nil || c.busy != nil)
                    Spacer()
                    Menu { Button(L("Notizbücher neu laden", "Reload notebooks")) { c.loadBooks() }; Button(L("Abmelden", "Sign out")) { c.signOut() } } label: { Image(systemName: "ellipsis.circle") }.fixedSize()
                }
                list
            }
            if let b = c.busy { HStack { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle); Spacer(); Button(L("Abbrechen", "Cancel")) { c.cancel() }.controlSize(.small) } }
            if let n = c.note { Label(n, systemImage: "info.circle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if c.phase != .ready && c.phase != .local { Spacer(minLength: 0) }
        }
        .padding(20).frame(minWidth: 620, minHeight: 440)
    }
    @ViewBuilder private var list: some View {
        if c.proposals.isEmpty {
            ContentUnavailableView(L("Noch keine Vorschläge", "No suggestions yet"), systemImage: "sparkles.rectangle.stack", description: Text(c.phase == .local ? L("Prüft die Seiten des Abschnitts, der in OneNote gerade offen ist.", "Checks the pages of the section currently open in OneNote.") : L("Notizbuch wählen und „Analysieren“: Jede Seite wird geprüft, das kann ein paar Minuten dauern.", "Pick a notebook and “Analyze”: every page is checked, this can take a few minutes.")))
                .frame(maxHeight: .infinity)
        } else {
            List {
                section(.delete, L("Leere Seiten löschen", "Delete empty pages"), "trash")
                section(.renamePage, L("Seiten benennen", "Name pages"), "textformat")
                section(.renameSection, L("Abschnitte benennen", "Name sections"), "folder")
            }
            .listStyle(.inset(alternatesRowBackgrounds: true)).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                if !c.undo.isEmpty { Button(L("Umbenennungen rückgängig", "Undo renames")) { c.revert() }.disabled(c.busy != nil) }
                Spacer()
                let n = c.proposals.filter { $0.on && $0.state == nil }.count
                Button(L("\(n) Änderung(en) anwenden", "Apply \(n) change(s)")) { c.apply() }.buttonStyle(.borderedProminent).disabled(n == 0 || c.busy != nil)
                    .help(L("Gelöschte Seiten liegen danach im Papierkorb des Notizbuchs (in OneNote: Verlauf › Papierkorb).", "Deleted pages go to the notebook's recycle bin (OneNote: History › Recycle Bin)."))
            }
        }
    }
    @ViewBuilder private func section(_ k: NoteClean.Proposal.Kind, _ title: String, _ symbol: String) -> some View {
        let idx = c.proposals.indices.filter { c.proposals[$0].kind == k }
        if !idx.isEmpty {
            Section { ForEach(idx, id: \.self) { i in row(i) } } header: { Label("\(title) (\(idx.count))", systemImage: symbol) }
        }
    }
    private func row(_ i: Int) -> some View {
        let p = c.proposals[i]
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { c.proposals[i].on }, set: { c.proposals[i].on = $0 })).labelsHidden().disabled(p.state != nil)
            VStack(alignment: .leading, spacing: 2) {
                if p.kind == .delete { Text(p.old).strikethrough(p.state != nil) }
                else {
                    HStack(spacing: 6) {
                        Text(p.old).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        TextField("", text: Binding(get: { c.proposals[i].new }, set: { c.proposals[i].new = $0 })).textFieldStyle(.plain).fontWeight(.medium).disabled(p.state != nil)
                    }
                }
                Text(p.where_).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = p.state { Text(s).font(.caption).foregroundStyle(s == L("erledigt", "done") ? .green : .orange).lineLimit(2) }
        }
    }
}

// MARK: Ohne Microsoft-Freigabe: OneNote selbst bedienen (Menü „Notizbücher › Seiten/Abschnitte“), wie du es mit der Maus tun würdest.
// Jede Änderung wird danach in der Seitenliste nachgeprüft; passt etwas nicht, hört WinKomfort sofort auf.
// shortcut: hängt an OneNotes Bedienstruktur („List of Pages“, „Rename Page“ …) – nach OneNote-Updates nachtesten
enum OneNoteUI {
    struct Fail: Error { let text: String }
    static var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: OneNotePDF.bundle).first }
    static var ax: AXUIElement? { app.map { AXUIElementCreateApplication($0.processIdentifier) } }
    static var window: AXUIElement? { ax.flatMap { UIAuto.attr($0, kAXMainWindowAttribute) }.map { $0 as! AXUIElement } }
    static func outline(_ name: String) -> AXUIElement? { window.flatMap { w in UIAuto.elements(w, windowsOnly: false).first { UIAuto.role($0) == "AXOutline" && UIAuto.label($0) == name } } }
    static func rows(_ o: AXUIElement) -> [AXUIElement] { UIAuto.attr(o, kAXRowsAttribute) as? [AXUIElement] ?? [] }
    static func text(_ row: AXUIElement) -> String { UIAuto.elements(row, windowsOnly: false).lazy.compactMap { UIAuto.role($0) == "AXStaticText" ? UIAuto.attr($0, kAXValueAttribute) as? String : nil }.first ?? "" }
    static var pageTitles: [String] { outline("List of Pages").map { rows($0).map(text) } ?? [] }
    static var sectionName: String? { outline("List of Sections").flatMap { o in rows(o).first { UIAuto.attr($0, kAXSelectedAttribute) as? Bool == true } }.map(text) }
    static var front: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == OneNotePDF.bundle }

    private static func menu(_ titles: [String]) -> AXUIElement? {
        guard let ax, let bar = UIAuto.attr(ax, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
        return UIAuto.elements(bar, windowsOnly: false).first { titles.contains(UIAuto.attr($0, kAXTitleAttribute) as? String ?? "") }
    }
    private static func selectPage(_ i: Int) throws {
        guard let o = outline("List of Pages"), rows(o).indices.contains(i) else { throw Fail(text: L("Seitenliste in OneNote nicht gefunden – bitte einblenden.", "Page list not found in OneNote – please show it.")) }
        let r = rows(o)[i]
        AXUIElementSetAttributeValue(o, kAXSelectedRowsAttribute as CFString, [r] as CFArray)
        for _ in 0..<30 where UIAuto.attr(r, kAXSelectedAttribute) as? Bool != true { usleep(30_000) }
        usleep(250_000)
    }
    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] { let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: code, keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap) }
        usleep(40_000)
    }
    private static func type(_ s: String) throws {
        for ch in s {
            guard front else { throw Fail(text: L("OneNote ist nicht mehr vorne – angehalten.", "OneNote is no longer in front – stopped.")) }
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u); e?.post(tap: .cghidEventTap)
            }
            usleep(12_000)
        }
    }
    // Eingabe nur, wenn OneNote wirklich vorne ist
    static func bringFront() throws {
        app?.activate()
        for _ in 0..<40 where !front { usleep(50_000) }
        guard front else { throw Fail(text: L("OneNote kam nicht nach vorne.", "OneNote didn't come to the front.")) }
        usleep(250_000)
    }
    // Unbenannte Seite benennen: „Rename Page“ setzt den Cursor in den (leeren) Titel
    static func renamePage(_ i: Int, to name: String) throws {
        try selectPage(i)
        guard let m = menu(["Rename Page", "Seite umbenennen"]) else { throw Fail(text: L("Menü „Seite umbenennen“ fehlt.", "Menu “Rename Page” missing.")) }
        try bringFront(); UIAuto.press(m); usleep(450_000)
        try type(name); key(36) // Return
        usleep(700_000)
        guard pageTitles.indices.contains(i), pageTitles[i] == name else {
            throw Fail(text: L("Der Titel kam nicht an. Angehalten – prüfe die Seite in OneNote, ⌘Z macht die letzte Eingabe rückgängig.", "The title didn't take. Stopped – check the page in OneNote, ⌘Z undoes the last input."))
        }
    }
    static func deletePage(_ i: Int, title: String) throws {
        try selectPage(i)
        let before = pageTitles
        guard before.indices.contains(i), before[i] == title || (NoteLogic.isUntitled(before[i]) && NoteLogic.isUntitled(title)) else { throw Fail(text: L("Die Seitenliste hat sich verändert – angehalten.", "The page list changed – stopped.")) }
        guard let m = menu(["Delete Page", "Seite löschen"]) else { throw Fail(text: L("Menü „Seite löschen“ fehlt.", "Menu “Delete Page” missing.")) }
        UIAuto.press(m)
        for _ in 0..<40 where pageTitles.count == before.count { usleep(50_000) }
        guard pageTitles.count == before.count - 1 else { throw Fail(text: L("Seite wurde nicht gelöscht (OneNote hat vielleicht nachgefragt).", "Page wasn't deleted (OneNote may have asked).")) }
    }
    static func renameSection(to name: String) throws {
        guard let m = menu(["Rename Section", "Abschnitt umbenennen"]) else { throw Fail(text: L("Menü „Abschnitt umbenennen“ fehlt.", "Menu “Rename Section” missing.")) }
        try bringFront(); UIAuto.press(m); usleep(450_000)
        // Ist das Namensfeld erreichbar, direkt setzen; sonst tippen (der alte Name ist dabei markiert)
        if let ax, let f = UIAuto.attr(ax, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }), UIAuto.role(f) == "AXTextField" {
            var ok: DarwinBoolean = false; AXUIElementIsAttributeSettable(f, kAXValueAttribute as CFString, &ok)
            if ok.boolValue { AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, name as CFString) } else { try type(name) }
        } else { try type(name) }
        key(36); usleep(700_000)
        guard sectionName == name else { throw Fail(text: L("Der Abschnittsname kam nicht an. Angehalten – in OneNote prüfen.", "The section name didn't take. Stopped – check in OneNote.")) }
    }
}
