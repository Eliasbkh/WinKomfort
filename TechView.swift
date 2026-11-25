// Fenster für Informationstechnik: KV-Diagramm, Struktogramm, Klassendiagramm, SQL zum Üben
import AppKit
import CryptoKit
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

// MARK: KV-Diagramm
struct KVView: View {
    let vars: [String], on: Set<Int>, terms: [TechLogic.Term]
    static let tints: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .indigo]
    private var rowBits: Int { vars.count / 2 }
    private var colBits: Int { vars.count - rowBits }
    private func head(_ v: Int, _ n: Int) -> String { n == 0 ? "" : String(repeating: "0", count: max(0, n - String(v, radix: 2).count)) + String(v, radix: 2) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text(rowBits > 0 ? "\(vars.prefix(rowBits).joined()) \\ \(vars.suffix(colBits).joined())" : vars.joined()).font(.caption).foregroundStyle(.secondary).frame(width: 64)
                    ForEach(TechLogic.gray(colBits), id: \.self) { Text(head($0, colBits)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, height: 24) }
                }
                ForEach(TechLogic.gray(rowBits), id: \.self) { r in
                    GridRow {
                        Text(head(r, rowBits)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ForEach(TechLogic.gray(colBits), id: \.self) { c in
                            let m = r << colBits | c, hit = terms.indices.filter { m & terms[$0].care == terms[$0].value }
                            ZStack {
                                Rectangle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5)
                                ForEach(Array(hit.enumerated()), id: \.element) { k, i in
                                    RoundedRectangle(cornerRadius: 7).strokeBorder(Self.tints[i % Self.tints.count], lineWidth: 2.5).padding(CGFloat(3 + k * 4))
                                }
                                Text(on.contains(m) ? "1" : "0").monospacedDigit().fontWeight(on.contains(m) ? .bold : .regular).foregroundStyle(on.contains(m) ? .primary : .secondary)
                            }
                            .frame(width: 46, height: 46)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(terms.enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).fill(Self.tints[i % Self.tints.count]).frame(width: 12, height: 12); Text(TechLogic.dnf([t], vars, always: false)).font(.callout) }
                }
            }
        }
    }
}

// MARK: Struktogramm
struct NSDView: View {
    let blocks: [TechLogic.Block]
    var body: some View { NSDBlocks(blocks: blocks).frame(minWidth: 300).overlay { Rectangle().strokeBorder(.primary, lineWidth: 1) } }
}
private struct NSDBlocks: View {
    let blocks: [TechLogic.Block]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                if i > 0 { Rectangle().fill(.primary).frame(height: 1) }
                NSDBlock(b: b)
            }
            if blocks.isEmpty { Text("∅").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 30) }
            Spacer(minLength: 0)
        }
    }
}
private struct NSDBlock: View {
    let b: TechLogic.Block
    private func line(_ s: String) -> some View { Text(s).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading) }
    var body: some View {
        switch b {
        case .step(let s): line(s)
        case .branch(let cond, let yes, let no):
            VStack(spacing: 0) {
                ZStack {
                    GeometryReader { g in
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height)); p.addLine(to: CGPoint(x: g.size.width, y: 0)) }.stroke(.primary, lineWidth: 1)
                    }
                    VStack(spacing: 2) {
                        Text(cond).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 200)
                        HStack { Text(L("ja", "yes")); Spacer(); Text(L("nein", "no")) }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 3)
                }
                .frame(minHeight: 56).fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(.primary).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    NSDBlocks(blocks: yes).frame(maxWidth: .infinity)
                    Rectangle().fill(.primary).frame(width: 1)
                    NSDBlocks(blocks: no).frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .loop(let h, let inner):
            VStack(spacing: 0) { line(h); frameLeft(inner, top: true) }
        case .until(let f, let inner):
            VStack(spacing: 0) { frameLeft(inner, top: false); line(f) }
        case .cases(let s, _): line(s)
        }
    }
    private func frameLeft(_ inner: [TechLogic.Block], top: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 24)
            NSDBlocks(blocks: inner)
                .overlay(alignment: .leading) { Rectangle().fill(.primary).frame(width: 1) }
                .overlay(alignment: top ? .top : .bottom) { Rectangle().fill(.primary).frame(height: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Klassendiagramm
struct UMLView: View {
    let classes: [TechLogic.Cls]
    // Ebenen nach Vererbung; Kreise und unbekannte Eltern landen oben
    private var levels: [[TechLogic.Cls]] {
        func depth(_ c: TechLogic.Cls, _ n: Int) -> Int { guard n < 20, let p = c.parent, let q = classes.first(where: { $0.name == p }), q != c else { return 0 }; return 1 + depth(q, n + 1) }
        return Dictionary(grouping: classes) { min(depth($0, 0), 19) }.sorted { $0.key < $1.key }.map(\.value)
    }
    var body: some View {
        VStack(spacing: 44) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .top, spacing: 28) { ForEach(Array(l.enumerated()), id: \.offset) { _, c in box(c).anchorPreference(key: UMLBounds.self, value: .bounds) { [c.name: $0] } } }
            }
        }
        .backgroundPreferenceValue(UMLBounds.self) { b in
            GeometryReader { g in
                ForEach(Array(classes.enumerated()), id: \.offset) { _, c in
                    if let p = c.parent, let a = b[c.name], let d = b[p], g[d].maxY < g[a].minY {
                        let from = CGPoint(x: g[a].midX, y: g[a].minY), to = CGPoint(x: g[d].midX, y: g[d].maxY), mid = (from.y + to.y) / 2 + 6
                        Path { q in q.move(to: from); q.addLine(to: CGPoint(x: from.x, y: mid)); q.addLine(to: CGPoint(x: to.x, y: mid)); q.addLine(to: CGPoint(x: to.x, y: to.y + 12)) }.stroke(.primary, lineWidth: 1)
                        Path { q in q.move(to: to); q.addLine(to: CGPoint(x: to.x - 8, y: to.y + 12)); q.addLine(to: CGPoint(x: to.x + 8, y: to.y + 12)); q.closeSubpath() }.stroke(.primary, lineWidth: 1)
                    }
                }
            }
        }
        .padding(12)
    }
    private func box(_ c: TechLogic.Cls) -> some View {
        VStack(spacing: 0) {
            Text(c.name).bold().padding(.horizontal, 12).padding(.vertical, 6)
            Rectangle().fill(.primary).frame(height: 1)
            list(c.fields)
            Rectangle().fill(.primary).frame(height: 1)
            list(c.methods)
        }
        .fixedSize().overlay { Rectangle().strokeBorder(.primary, lineWidth: 1) }
    }
    private func list(_ a: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) { if a.isEmpty { Text(" ") }; ForEach(Array(a.enumerated()), id: \.offset) { Text($0.element).font(.system(.callout, design: .monospaced)) } }
            .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).frame(minWidth: 110)
    }
}
private struct UMLBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { a, _ in a } }
}

// Text links, Zeichnung rechts
struct DiagramEditor: View {
    enum Kind { case nsd, uml }
    let kind: Kind
    @StateObject private var t = TextBox<String>()
    private var key: String { kind == .nsd ? "techNSD" : "techUML" }
    private var text: String { t.value ?? UserDefaults.standard.string(forKey: key) ?? (kind == .nsd ? L("Eingabe n\nsumme = 0\nfür i von 1 bis n\n  wenn i gerade dann\n    summe = summe + i\n  sonst\n    Ausgabe i\nAusgabe summe", "read n\nsum = 0\nfor i from 1 to n\n  if i is even then\n    sum = sum + i\n  else\n    print i\nprint sum") : "Tier: -name: String, #alter: int, +fressen()\nHund < Tier: +bellen()\nKatze < Tier: +schnurren()") }
    init(_ k: Kind, text: String = "") { kind = k; let b = TextBox<String>(); if !text.isEmpty { b.value = text }; _t = StateObject(wrappedValue: b) }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: Binding(get: { text }, set: { t.value = $0; UserDefaults.standard.set($0, forKey: key) })).font(.system(.body, design: .monospaced)).autocorrectionDisabled().padding(6)
                Text(kind == .nsd ? L("wenn … sonst … · solange … · für … · wiederhole … bis …, eingerückt", "if … else … · while … · for … · repeat … until …, indented") : L("Klasse < Oberklasse: -attribut: Typ, +methode()", "Class < Parent: -field: Type, +method()")).font(.caption).foregroundStyle(.secondary).padding(10)
            }
            .frame(minWidth: 240, idealWidth: 300)
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) { picture.padding(20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack { Spacer(); Button(L("Als Bild kopieren", "Copy as image")) { copy() }.buttonStyle(.borderedProminent).disabled(!ok) }.padding(10)
            }
            .frame(minWidth: 340)
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 400, idealHeight: 520)
    }
    private var ok: Bool { kind == .nsd ? TechLogic.nsd(text) != nil : TechLogic.uml(text) != nil }
    @ViewBuilder private var picture: some View {
        if kind == .nsd, let b = TechLogic.nsd(text) { NSDView(blocks: b).frame(width: 460) }
        else if kind == .uml, let c = TechLogic.uml(text) { UMLView(classes: c) }
        else { Text(L("Links tippen, hier entsteht die Zeichnung.", "Type on the left; the drawing appears here.")).foregroundStyle(.secondary) }
    }
    @MainActor private func copy() {
        let r = ImageRenderer(content: picture.padding(16).background(.white).environment(\.colorScheme, .light))
        r.scale = 3
        if let i = r.nsImage { Export.put(i, kind == .nsd ? L("Struktogramm", "Diagram") : L("Klassendiagramm", "Class diagram")) }
    }
}

// MARK: SQL zum Üben (nur im Arbeitsspeicher)
final class SQLBox: @unchecked Sendable {
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "winkomfort.sql")
    private var stopAt = Date.distantFuture
    struct Result { var head: [String] = [], rows: [[String]] = [], note = "" }
    init() { q.sync { sqlite3_open(":memory:", &db); sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0) } } // keine fremden Dateien
    deinit { sqlite3_close(db) }
    func run(_ sql: String) async -> Result { await withCheckedContinuation { c in q.async { c.resume(returning: self.exec(sql)) } } }
    private func exec(_ sql: String) -> Result {
        stopAt = Date().addingTimeInterval(5) // Endlosschleifen abbrechen
        sqlite3_progress_handler(db, 10_000, { p in Unmanaged<SQLBox>.fromOpaque(p!).takeUnretainedValue().stopAt < Date() ? 1 : 0 }, Unmanaged.passUnretained(self).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        var r = Result(), rest = sql, changes = 0
        while !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var st: OpaquePointer?, used = 0
            let rc = rest.withCString { p -> Int32 in var tail: UnsafePointer<CChar>?; let x = sqlite3_prepare_v2(db, p, -1, &st, &tail); if let tail { used = tail - p }; return x }
            guard rc == SQLITE_OK else { r.note = String(cString: sqlite3_errmsg(db)); return r }
            defer { sqlite3_finalize(st) }
            let bytes = Array(rest.utf8); rest = String(decoding: bytes[min(used, bytes.count)...], as: UTF8.self)
            guard let st else { break } // nur Kommentar
            let n = sqlite3_column_count(st)
            if n > 0 { r.head = (0..<n).map { String(cString: sqlite3_column_name(st, $0)) }; r.rows = [] }
            var step = sqlite3_step(st), total = 0
            while step == SQLITE_ROW {
                total += 1
                if r.rows.count < 1000 { r.rows.append((0..<n).map { i in sqlite3_column_type(st, i) == SQLITE_NULL ? "NULL" : sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }) }
                step = sqlite3_step(st)
            }
            guard step == SQLITE_DONE else { r.note = step == SQLITE_INTERRUPT ? L("Nach 5 Sekunden abgebrochen.", "Stopped after 5 seconds.") : String(cString: sqlite3_errmsg(db)); return r }
            if n == 0 { changes += Int(sqlite3_changes(db)) }
            else { r.note = L("\(total) Zeilen", "\(total) rows") + (total > 1000 ? L(", die ersten 1000", ", first 1000") : "") }
        }
        if r.head.isEmpty { r.note = L("Fertig. \(changes) Zeilen geändert.", "Done. \(changes) rows changed.") }
        return r
    }
    static func name(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func value(_ s: String) -> String { Double(s) != nil && !s.hasPrefix("0") || s == "0" ? s : "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    static let sample = """
    CREATE TABLE IF NOT EXISTS klasse(id INTEGER PRIMARY KEY, name TEXT, raum TEXT);
    CREATE TABLE IF NOT EXISTS schueler(id INTEGER PRIMARY KEY, name TEXT, alter_jahre INTEGER, klasse_id INTEGER REFERENCES klasse(id));
    CREATE TABLE IF NOT EXISTS note(schueler_id INTEGER, fach TEXT, punkte INTEGER);
    INSERT INTO klasse VALUES(1,'TGI 11','A104'),(2,'TGI 12','B201');
    INSERT INTO schueler VALUES(1,'Ada',16,1),(2,'Linus',17,1),(3,'Grace',17,2),(4,'Alan',18,2),(5,'Margaret',18,NULL);
    INSERT INTO note VALUES(1,'Mathe',13),(1,'IT',15),(2,'Mathe',9),(2,'IT',14),(3,'Mathe',12),(3,'IT',15),(4,'Mathe',15);
    """
}
@MainActor final class SQLModel: ObservableObject {
    let box = SQLBox()
    @Published var text = UserDefaults.standard.string(forKey: "techSQL") ?? "SELECT s.name, k.name AS klasse, ROUND(AVG(n.punkte), 1) AS schnitt\nFROM schueler s\nLEFT JOIN klasse k ON k.id = s.klasse_id\nLEFT JOIN note n ON n.schueler_id = s.id\nGROUP BY s.id\nORDER BY schnitt DESC;" { didSet { UserDefaults.standard.set(text, forKey: "techSQL") } }
    @Published var result = SQLBox.Result()
    @Published var tables: [(String, [String])] = []
    @Published var busy = false
    init() { Task { _ = await box.run(SQLBox.sample); await schema() } }
    func run() { guard !busy else { return }; busy = true; Task { result = await box.run(text); busy = false; await schema() } }
    func schema() async {
        var out: [(String, [String])] = []
        for t in await box.run("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").rows.map({ $0[0] }) { out.append((t, await box.run("PRAGMA table_info(\(SQLBox.name(t)))").rows.map { $0[1] + ($0[2].isEmpty ? "" : " " + $0[2]) })) }
        tables = out
    }
    func csv() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard p.runModal() == .OK, let u = p.url, case .success(let d) = AIRead.file(u) else { return }
        let lines = d.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let h = lines.first else { return }
        let sep: Character = h.filter { $0 == ";" }.count >= h.filter { $0 == "," }.count ? ";" : ","
        func cells(_ l: String) -> [String] { var o: [String] = [], c = "", q = false; for ch in l { if ch == "\"" { q.toggle() } else if ch == sep, !q { o.append(c); c = "" } else { c.append(ch) } }; return o + [c] }
        let head = cells(h), t = SQLBox.name(u.deletingPathExtension().lastPathComponent)
        var sql = "DROP TABLE IF EXISTS \(t); CREATE TABLE \(t)(\(head.enumerated().map { SQLBox.name($0.element.isEmpty ? "spalte\($0.offset + 1)" : $0.element) }.joined(separator: ",")));"
        for l in lines.dropFirst().prefix(5000) { let c = cells(l); sql += "INSERT INTO \(t) VALUES(\(head.indices.map { $0 < c.count ? SQLBox.value(c[$0]) : "NULL" }.joined(separator: ",")));" }
        Task { let r = await box.run(sql); result = r; if r.head.isEmpty { text = "SELECT * FROM \(t);" }; await schema() }
    }
}
struct SQLView: View {
    @StateObject private var m = SQLModel()
    var body: some View {
        HSplitView {
            List {
                ForEach(m.tables, id: \.0) { t in Section(t.0) { ForEach(t.1, id: \.self) { Text($0).font(.callout) } } }
            }
            .frame(minWidth: 150, idealWidth: 180, maxWidth: 260)
            VStack(spacing: 0) {
                TextEditor(text: $m.text).font(.system(.body, design: .monospaced)).autocorrectionDisabled().padding(6).frame(minHeight: 110, idealHeight: 150, maxHeight: 220)
                HStack {
                    Button(L("Ausführen", "Run")) { m.run() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(m.busy)
                    Button(L("CSV laden …", "Load CSV…")) { m.csv() }
                    Text(m.result.note).foregroundStyle(.secondary).lineLimit(1).help(m.result.note)
                    Spacer()
                    Button(L("Als Tabelle kopieren", "Copy as table")) { Export.table(m.result.head, m.result.rows) }.disabled(m.result.rows.isEmpty)
                }
                .padding(8)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        Section { ForEach(Array(m.result.rows.enumerated()), id: \.offset) { _, r in row(r, false) } } header: { if !m.result.head.isEmpty { row(m.result.head, true).background(.bar) } }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 420)
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 540)
    }
    private func row(_ r: [String], _ head: Bool) -> some View {
        HStack(spacing: 0) { ForEach(Array(r.enumerated()), id: \.offset) { _, v in Text(v).fontWeight(head ? .semibold : .regular).foregroundStyle(v == "NULL" && !head ? .secondary : .primary).lineLimit(1).frame(width: 130, alignment: .leading).padding(.vertical, 4).help(v) } }
    }
}

// MARK: Befehle
@MainActor enum TechCommands {
    private typealias R = SearchSlash.Row
    private static func c(_ t: String, _ s: String = "", _ v: String? = nil) -> SearchSlash.Row { R(title: t, sub: s, act: .copy(v ?? t)) }
    private static func go(_ t: String, _ s: String = "", _ w: @escaping @MainActor () -> Void) -> SearchSlash.Row { R(title: t, sub: s, act: .run(w)) }
    static func kv(_ a: String) -> (vars: [String], on: [Int], terms: [TechLogic.Term])? {
        guard let t = SchoolLogic.truth(a), (1...6).contains(t.vars.count) else { return nil }
        // Zeilen nach Wert der Variablen nummerieren
        let on = t.rows.filter { $0.last == true }.map { r in r.dropLast().reduce(0) { $0 << 1 | ($1 ? 1 : 0) } }
        return (t.vars, on, TechLogic.minimize(on, vars: t.vars.count))
    }
    static let all: [SearchSlash.Command] = [
        .init(name: L("schule", "school"), hint: "", text: L("Stundenplan, Aufgaben, Noten, Lernkarten", "Timetable, tasks, grades, flashcards"), symbol: "graduationcap") { _ in [go(L("Schule öffnen", "Open School")) { School.open() }, go(L("Stundenplan", "Timetable")) { School.open("plan") }, go(L("Noten", "Grades")) { School.open("noten") }, go(L("Lernkarten", "Flashcards")) { School.open("karten") }] },
        .init(name: L("lernen", "study"), hint: L("Minuten", "minutes"), text: L("Lernmodus: ablenkende Apps ausblenden", "Study mode: hide distracting apps"), symbol: "book") { a in
            if let u = StudyMode.shared.until { return [go(L("Lernmodus beenden", "Stop study mode"), L("läuft bis ", "until ") + u.formatted(date: .omitted, time: .shortened)) { StudyMode.shared.stop(quiet: true) }] }
            return (Int(a).map { (1...600).contains($0) ? [$0] : [] } ?? [25, 45, 90]).map { n in go(L("\(n) Minuten lernen", "Study for \(n) minutes")) { StudyMode.shared.start(n) } }
        },
        .init(name: L("ablage", "shelf"), hint: "", text: L("Ablage für Dateien öffnen", "Open the file shelf"), symbol: "tray") { _ in [go(L("Ablage öffnen", "Open shelf")) { Shelf.shared.toggle() }] },
        .init(name: "ha", hint: L("Mathe S. 43 bis Freitag", "Math p. 43 until Friday"), text: L("Hausaufgabe notieren", "Note homework"), symbol: "checklist", needsArg: true) { a in a.isEmpty ? [] : [go(L("Notieren: \(a)", "Note: \(a)")) { if let t = School.shared.add(a) { Toast.show(L("Fällig \(t.due.formatted(.dateTime.weekday(.wide).day().month()))", "Due \(t.due.formatted(.dateTime.weekday(.wide).day().month()))"), symbol: "checklist", seconds: 2) } }] },
        .init(name: "subnet", hint: "192.168.1.10/26", text: L("Subnetz berechnen, teilen, VLSM", "Subnet calculator, split, VLSM"), symbol: "network", needsArg: true) { a in
            let p = a.split { " ,".contains($0) }.map(String.init)
            guard let n = TechLogic.net(a) ?? p.first.flatMap(TechLogic.net) else { return [] }
            let extra = p.dropFirst().compactMap { Int($0) }
            if a.contains(" "), p.count > 1, p[0].contains("/"), !extra.isEmpty {
                if extra.count == 1, let s = TechLogic.split(n, extra[0]) {
                    return [go(L("\(extra[0]) Teilnetze als Tabelle kopieren", "Copy \(extra[0]) subnets as table")) { Export.table([L("Netz", "Network"), L("Erster Host", "First"), L("Letzter Host", "Last"), "Broadcast"], s.map { [TechLogic.dotted($0.network) + "/\($0.prefix)", TechLogic.dotted($0.first), TechLogic.dotted($0.last), TechLogic.dotted($0.broadcast)] }) }]
                        + s.prefix(12).map { c(TechLogic.dotted($0.network) + "/\($0.prefix)", "\(TechLogic.dotted($0.first)) – \(TechLogic.dotted($0.last))") }
                }
                if let v = TechLogic.vlsm(n, extra) { return v.map { h, x in c(TechLogic.dotted(x.network) + "/\(x.prefix)", L("für \(h) Hosts: ", "for \(h) hosts: ") + "\(TechLogic.dotted(x.first)) – \(TechLogic.dotted(x.last))") } }
                return [c(L("Das passt nicht in dieses Netz", "That doesn't fit into this network"))]
            }
            return [c(TechLogic.dotted(n.network) + "/\(n.prefix)", L("Netzadresse", "Network")), c(TechLogic.dotted(n.mask), L("Subnetzmaske", "Mask")), c(TechLogic.dotted(n.broadcast), "Broadcast"),
                    c("\(TechLogic.dotted(n.first)) – \(TechLogic.dotted(n.last))", L("Hosts: \(n.hosts)", "Hosts: \(n.hosts)")), c(TechLogic.bits(n.ip), L("Adresse binär", "Address in binary")), c(TechLogic.bits(n.mask), L("Maske binär", "Mask in binary")), c(TechLogic.dotted(~n.mask), L("Wildcard", "Wildcard"))]
        },
        .init(name: "kv", hint: L("a und b oder nicht c", "a and b or not c"), text: L("KV-Diagramm und vereinfachen", "K-map and simplify"), symbol: "squareshape.split.3x3", needsArg: true) { a in
            guard let k = kv(a) else { return [] }
            let r = TechLogic.dnf(k.terms, k.vars, always: false)
            return [c(r, L("vereinfacht (minimale DNF)", "simplified (minimal DNF)"))] + (k.vars.count > 1 ? [go(L("KV-Diagramm als Bild kopieren", "Copy K-map as image")) { Export.copy(KVView(vars: k.vars, on: Set(k.on), terms: k.terms).fixedSize(), CGSize(width: CGFloat(1 << (k.vars.count - k.vars.count / 2)) * 46 + 70, height: CGFloat(1 << (k.vars.count / 2)) * 46 + 70), "KV") }] : [])
        },
        .init(name: "nsd", hint: L("wenn a; b; sonst; c; ende", "if a; b; else; c; end"), text: L("Struktogramm zeichnen", "Draw a Nassi–Shneiderman diagram"), symbol: "rectangle.split.3x1") { a in [go(L("Struktogramm öffnen", "Open diagram editor")) { studioWindow("nsd", L("Struktogramm", "Diagram"), DiagramEditor(.nsd, text: a.replacingOccurrences(of: "; ", with: "\n").replacingOccurrences(of: ";", with: "\n"))) }] },
        .init(name: "uml", hint: "Hund < Tier: +bellen()", text: L("Klassendiagramm zeichnen", "Draw a class diagram"), symbol: "square.stack.3d.up") { a in [go(L("Klassendiagramm öffnen", "Open class diagram")) { studioWindow("uml", L("Klassendiagramm", "Class diagram"), DiagramEditor(.uml, text: a.replacingOccurrences(of: ";", with: "\n"))) }] },
        .init(name: "sql", hint: "", text: L("SQL üben", "Practice SQL"), symbol: "cylinder.split.1x2") { _ in [go(L("SQL-Übungsfenster öffnen", "Open SQL practice"), L("mit Beispieldaten oder eigener CSV", "with sample data or your CSV")) { studioWindow("sql", "SQL", SQLView()) }] },
        .init(name: "regex", hint: "/\\d+/ Text 12", text: L("Regulären Ausdruck testen", "Test a regular expression"), symbol: "asterisk", needsArg: true) { a in
            guard let (p, t) = TechLogic.regex(a) else { return [] }
            guard let r = try? NSRegularExpression(pattern: p) else { return [c(L("Muster ist ungültig", "Invalid pattern"))] }
            let s = String((t.isEmpty ? NSPasteboard.general.string(forType: .string) ?? "" : t).prefix(2000)) // kurz halten: Muster können explodieren
            var m: [NSTextCheckingResult] = []; let until = Date().addingTimeInterval(0.1)
            r.enumerateMatches(in: s, options: .reportProgress, range: NSRange(s.startIndex..., in: s)) { x, _, stop in if let x { m.append(x) }; if m.count >= 12 || Date() > until { stop.pointee = true } }
            if m.isEmpty { return [c(L("Kein Treffer", "No match"))] }
            return m.enumerated().compactMap { i, x in Range(x.range, in: s).map { y in c(String(s[y]), L("Treffer \(i + 1)", "Match \(i + 1)") + (x.numberOfRanges > 1 ? " · " + (1..<x.numberOfRanges).map { k in "\(k): " + (Range(x.range(at: k), in: s).map { String(s[$0]) } ?? "–") }.joined(separator: ", ") : "")) } }
        },
        .init(name: "hash", hint: L("Text", "text"), text: "SHA-256, SHA-1, MD5", symbol: "number.square") { a in
            let t = a.isEmpty ? NSPasteboard.general.string(forType: .string) ?? "" : a
            guard !t.isEmpty else { return [] }
            let d = Data(t.utf8)
            func h<D: Sequence>(_ x: D) -> String where D.Element == UInt8 { x.map { String(format: "%02x", $0) }.joined() }
            return [c(h(SHA256.hash(data: d)), "SHA-256"), c(h(Insecure.SHA1.hash(data: d)), "SHA-1"), c(h(Insecure.MD5.hash(data: d)), "MD5")]
        },
        .init(name: "float", hint: "-0,75", text: L("Zahl als IEEE 754 und Zweierkomplement", "Number as IEEE 754 and two's complement"), symbol: "number", needsArg: true) { a in
            var out: [SearchSlash.Row] = []
            if let v = Int(a) { out = [8, 16, 32].compactMap { n in TechLogic.twos(v, n).map { c($0, L("Zweierkomplement, \(n) Bit", "Two's complement, \(n) bits")) } } }
            if let f = TechLogic.ieee(a) { out += [c(f.bits, L("IEEE 754 einfach: Vorzeichen, Exponent, Mantisse", "IEEE 754 single: sign, exponent, mantissa")), c(f.hex, "Hex")] + (f.exp > 0 && f.exp < 255 ? [c(L("Exponent \(f.exp) − 127 = \(f.exp - 127)", "Exponent \(f.exp) − 127 = \(f.exp - 127)"))] : []) }
            return out
        },
        .init(name: "ohm", hint: "12V 470Ω", text: L("Ohmsches Gesetz und Farbcode", "Ohm's law and resistor colors"), symbol: "bolt", needsArg: true) { a in
            if let r = TechLogic.resistor(a) { return [c(TechLogic.si(r.ohm, "Ω") + " ± \(r.tol) %", L("Widerstand", "Resistor"))] }
            guard let o = TechLogic.ohm(a) else { return [] }
            return [c("U = " + TechLogic.si(o.u, "V")), c("I = " + TechLogic.si(o.i, "A")), c("R = " + TechLogic.si(o.r, "Ω")), c("P = " + TechLogic.si(o.p, "W"))]
        },
        .init(name: "unix", hint: "1764100000", text: L("Zeitstempel umrechnen", "Convert a timestamp"), symbol: "clock.arrow.2.circlepath") { a in
            if let d = TechLogic.unix(a) { return [c(d.formatted(date: .complete, time: .standard)), c(d.ISO8601Format(), "ISO 8601")] }
            return a.isEmpty ? [c("\(Int(Date().timeIntervalSince1970))", L("jetzt", "now"))] : []
        },
    ]
}
