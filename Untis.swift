// WebUntis: Schule suchen, anmelden, Stundenplan der nächsten Wochen abgleichen (JSON-RPC wie die Untis-App)
import Foundation
import Security
import SwiftUI

enum UntisError: LocalizedError {
    case login, school, blocked, server(String)
    var errorDescription: String? {
        switch self {
        case .login: return L("Benutzername oder Passwort stimmt nicht.", "Wrong username or password.")
        case .school: return L("Die Schule wurde bei WebUntis nicht gefunden.", "School not found on WebUntis.")
        case .blocked: return L("Deine Schule erlaubt diesen Zugang nicht (z. B. nur Anmeldung über Microsoft/IServ). Dann bleibt der Import einer .ics-Datei.", "Your school does not allow this access (e.g. Microsoft/IServ login only). Importing an .ics file still works.")
        case .server(let m): return L("WebUntis meldet: ", "WebUntis says: ") + m
        }
    }
}

enum Untis {
    struct School: Decodable, Identifiable, Hashable { let server: String; let loginName: String; let displayName: String; let address: String?; var id: String { server + "/" + loginName } }

    // Passwort nur im Schlüsselbund, nie in schule.json
    private static let service = "de.winkomfort.untis"
    static func password(_ user: String) -> String? {
        var r: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func store(_ user: String, _ pw: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user]
        SecItemDelete(q as CFDictionary)
        if let pw { var a = q; a[kSecValueData as String] = Data(pw.utf8); a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; SecItemAdd(a as CFDictionary, nil) }
    }

    private static func call(_ url: URL, _ method: String, _ params: Any, session: URLSession, cookie: String? = nil) async throws -> Any {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie { r.setValue("JSESSIONID=" + cookie, forHTTPHeaderField: "Cookie") }
        r.httpBody = try JSONSerialization.data(withJSONObject: ["id": "1", "method": method, "params": params, "jsonrpc": "2.0"])
        let (d, resp) = try await session.data(for: r)
        guard d.count < 20_000_000, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw UntisError.server("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        if let e = o["error"] as? [String: Any] {
            switch e["code"] as? Int { case -8504: throw UntisError.login; case -8500: throw UntisError.school; case -8509, -8998: throw UntisError.blocked; default: throw UntisError.server(e["message"] as? String ?? "?") }
        }
        return o["result"] ?? NSNull()
    }

    static func search(_ text: String) async throws -> [School] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return [] }
        do {
            let r = try await call(URL(string: "https://mobile.webuntis.com/ms/schoolquery2")!, "searchSchool", [["search": String(t.prefix(80))]], session: .shared)
            let d = try JSONSerialization.data(withJSONObject: (r as? [String: Any])?["schools"] ?? [])
            return Array(try JSONDecoder().decode([School].self, from: d).prefix(30))
        } catch UntisError.server(let m) where m.contains("too many") { throw UntisError.server(L("Zu viele Treffer, gib mehr vom Namen oder den Ort ein.", "Too many results, type more of the name or the town.")) }
    }

    // Holt 4 Wochen ab diesem Montag; die Sitzung wird danach wieder abgemeldet
    static func fetch(_ u: Plan.Untis, password: String, now: Date = Date()) async throws -> [Plan.UPeriod] {
        guard u.server.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil, // nur ein Hostname, keine Pfade
              var c = URLComponents(string: "https://" + u.server + "/WebUntis/jsonrpc.do") else { throw UntisError.school }
        c.queryItems = [URLQueryItem(name: "school", value: u.school)]
        guard let url = c.url else { throw UntisError.school }
        let s = URLSession(configuration: .ephemeral)
        defer { s.invalidateAndCancel() }
        guard let a = try await call(url, "authenticate", ["user": u.user, "password": password, "client": "WinKomfort"], session: s) as? [String: Any], let id = a["sessionId"] as? String else { throw UntisError.login }
        let cal = ActLogic.cal, monday = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 27, to: monday)!
        var el: [String: Any] = ["id": a["personId"] as? Int ?? 0, "type": a["personType"] as? Int ?? 5]
        if (el["id"] as? Int ?? 0) == 0, let k = a["klasseId"] as? Int { el = ["id": k, "type": 1] } // ohne eigenen Plan: der Klassenplan
        let opts: [String: Any] = ["element": el, "startDate": Plan.untisDay(monday), "endDate": Plan.untisDay(end), "subjectFields": ["name", "longname"], "roomFields": ["name"]]
        let r: Any
        do { r = try await call(url, "getTimetable", ["options": opts], session: s, cookie: id) }
        catch { _ = try? await call(url, "logout", [:] as [String: Any], session: s, cookie: id); throw error }
        _ = try? await call(url, "logout", [:] as [String: Any], session: s, cookie: id)
        return try JSONDecoder().decode([Plan.UPeriod].self, from: JSONSerialization.data(withJSONObject: r))
    }
}

extension School {
    // Abgleich: echter Plan für 4 Wochen, daraus der regelmäßige Plan mit A/B-Wochen
    func sync(quiet: Bool = true) async {
        guard let u = book.untis, !syncing else { return }
        guard let pw = Untis.password(u.user) else { if !quiet { syncError = L("Passwort fehlt, bitte neu verbinden.", "Password missing, please reconnect.") }; return }
        syncing = true; defer { syncing = false }
        do { apply(try await Untis.fetch(u, password: pw)); syncError = nil }
        catch { syncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; if !quiet { Toast.show(syncError!, symbol: "exclamationmark.triangle", seconds: 4) } }
    }
    func apply(_ p: [Plan.UPeriod], now: Date = Date()) {
        let cal = ActLogic.cal, d = Plan.untis(p, cal), r = Plan.regular(d, cal)
        let monday = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        var b = book
        b.dated = d; b.datedFrom = monday; b.datedTo = cal.date(byAdding: .day, value: 28, to: monday); b.synced = now
        if !r.isEmpty { b.lessons = r; b.aWeekOdd = true } // leer (Ferien): alten Plan behalten
        book = b
    }
    func connect(_ s: Untis.School, user: String, password: String) async throws {
        let u = Plan.Untis(server: s.server, school: s.loginName, user: user.trimmingCharacters(in: .whitespaces), name: s.displayName)
        let p = try await Untis.fetch(u, password: password)
        if let old = book.untis, old.user != u.user { Untis.store(old.user, nil) }
        Untis.store(u.user, password)
        book.untis = u
        apply(p)
    }
    func disconnect() {
        if let u = book.untis { Untis.store(u.user, nil) }
        book.untis = nil; book.dated = []; book.datedFrom = nil; book.datedTo = nil; book.synced = nil
    }
    // Beim Start und alle 3 Stunden; beim Öffnen des Fensters, wenn älter als 20 Minuten
    func startSync() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(3 * 3600))
            }
        }
    }
    func syncIfOld() { if book.untis != nil, (book.synced.map { Date().timeIntervalSince($0) > 1200 } ?? true) { Task { await sync() } } }
}

struct UntisSheet: View {
    @ObservedObject var s: School
    let close: () -> Void
    @StateObject private var query = TextBox<String>()
    @StateObject private var found = TextBox<[Untis.School]>()
    @StateObject private var pick = TextBox<Untis.School>()
    @StateObject private var user = TextBox<String>()
    @StateObject private var pw = TextBox<String>()
    @StateObject private var busy = TextBox<Bool>()
    @StateObject private var error = TextBox<String>()
    @StateObject private var timer = TextBox<Task<Void, Never>>()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Mit WebUntis verbinden", "Connect to WebUntis")).font(.title3.weight(.semibold))
            if let p = pick.value {
                HStack { VStack(alignment: .leading) { Text(p.displayName).fontWeight(.medium); if let a = p.address { Text(a).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button(L("Andere Schule", "Other school")) { pick.value = nil }.buttonStyle(.link) }
                TextField(L("Benutzername", "Username"), text: Binding(get: { user.value ?? "" }, set: { user.value = $0 })).textFieldStyle(.roundedBorder).textContentType(.username)
                SecureField(L("Passwort", "Password"), text: Binding(get: { pw.value ?? "" }, set: { pw.value = $0 })).textFieldStyle(.roundedBorder).textContentType(.password).onSubmit(go)
                Text(L("Wie in der Untis-App. Das Passwort bleibt im Schlüsselbund dieses Macs. Dein Stundenplan wird durch den aus WebUntis ersetzt und alle 3 Stunden abgeglichen, inklusive Entfall und Raumänderungen.", "Same as in the Untis app. The password stays in this Mac's keychain. Your timetable is replaced by the one from WebUntis and synced every 3 hours, including cancellations and room changes.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(L("Name deiner Schule und Ort", "Your school's name and town"), text: Binding(get: { query.value ?? "" }, set: { query.value = $0; find($0) })).textFieldStyle(.roundedBorder)
                List(found.value ?? [], selection: Binding(get: { nil as String? }, set: { id in pick.value = found.value?.first { $0.id == id }; error.value = nil })) { x in
                    VStack(alignment: .leading, spacing: 1) { Text(x.displayName); if let a = x.address { Text(a).font(.caption).foregroundStyle(.secondary) } }.tag(x.id)
                }
                .frame(height: 180)
                .overlay { if (found.value ?? []).isEmpty { Text((query.value ?? "").count < 3 ? L("Mindestens 3 Buchstaben", "At least 3 letters") : busy.value == true ? L("Suche …", "Searching…") : L("Keine Schule gefunden", "No school found")).foregroundStyle(.secondary) } }
            }
            if let e = error.value { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy.value == true, pick.value != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Abbrechen", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("Verbinden", "Connect"), action: go).keyboardShortcut(.defaultAction)
                    .disabled(pick.value == nil || (user.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty || (pw.value ?? "").isEmpty || busy.value == true)
            }
        }
        .padding(20).frame(width: 440)
        .onDisappear { timer.value?.cancel() }
    }
    private func find(_ t: String) {
        timer.value?.cancel()
        error.value = nil
        timer.value = Task {
            try? await Task.sleep(for: .milliseconds(350)) // erst suchen, wenn die Eingabe kurz ruht
            guard !Task.isCancelled else { return }
            busy.value = true; defer { busy.value = false }
            do { let r = try await Untis.search(t); if !Task.isCancelled { found.value = r } }
            catch { if !Task.isCancelled { found.value = []; self.error.value = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription } }
        }
    }
    private func go() {
        guard let p = pick.value, let u = user.value, let w = pw.value, !w.isEmpty, busy.value != true else { return }
        busy.value = true; error.value = nil
        Task {
            defer { busy.value = false }
            do { try await s.connect(p, user: u, password: w); pw.value = ""; close(); Toast.show(L("Stundenplan aus WebUntis übernommen", "Timetable synced from WebUntis"), symbol: "checkmark.circle") }
            catch { self.error.value = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}
