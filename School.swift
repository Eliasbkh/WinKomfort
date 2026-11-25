// Schule: Heute, Stundenplan, Aufgaben, Noten, Lernkarten – alles nur auf diesem Mac
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class School: ObservableObject {
    static let shared = School()
    @Published var book: Plan.Book { didSet { if book != oldValue { save() } } }
    @Published var tab = "heute"
    private static let file: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WinKomfort")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("schule.json")
    }()
    private let queue = DispatchQueue(label: "winkomfort.school", qos: .utility)
    private init() {
        let fm = FileManager.default, f = Self.file, bak = f.deletingPathExtension().appendingPathExtension("sicherung.json")
        if let d = try? Data(contentsOf: f) {
            if let b = try? JSONDecoder().decode(Plan.Book.self, from: d) {
                book = b
                try? d.write(to: bak, options: .atomic) // letzter lesbarer Stand
            } else { // kaputt: aufheben statt überschreiben und die Sicherung nehmen
                try? fm.removeItem(at: f.appendingPathExtension("defekt")); try? fm.moveItem(at: f, to: f.appendingPathExtension("defekt"))
                book = (try? Data(contentsOf: bak)).flatMap { try? JSONDecoder().decode(Plan.Book.self, from: $0) } ?? Plan.Book()
            }
        } else { book = Plan.Book() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { School.shared.quit() } }
    }
    private var pending = false
    private func save() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { self.flush() } }
    }
    func flush() {
        guard pending else { return }
        pending = false
        let b = book
        queue.async { if let d = try? JSONEncoder().encode(b) { try? d.write(to: Self.file, options: .atomic) } }
    }
    func quit() { flush(); queue.sync {} } // beim Beenden nichts verlieren
    static func open(_ tab: String? = nil) {
        if let tab { shared.tab = tab }
        let first = windows["school"] == nil
        showWindow("school", "Schule") { SchoolView() }
        windows["school"]?.title = L("Schule", "School")
        if first { windows["school"]?.setContentSize(NSSize(width: 860, height: 620)); windows["school"]?.center(); windows["school"]?.setFrameAutosaveName("WinKomfortSchool") }
    }
    // „Mathe S. 43 bis Freitag“ → Aufgabe; ohne Datum zur nächsten Stunde des Fachs
    func add(_ text: String, exam: Bool = false, now: Date = Date()) -> Plan.Task? {
        let w = ActLogic.when(text, now: now)
        var t = (w?.rest ?? text).replacingOccurrences(of: #"(?i)\b(neue |eine )?(hausaufgaben?|ha|aufgabe|klausur|arbeit|test|klassenarbeit)\b( in| für)?:?|\b(zum|bis|zur)( nächsten (mal|stunde))?$"#, with: " ", options: .regularExpression)
        let s = Plan.subject(in: text, book) ?? ""
        if !s.isEmpty { t = t.replacingOccurrences(of: #"(?i)\b(in |für )?\#(NSRegularExpression.escapedPattern(for: s))\b:?"#, with: " ", options: .regularExpression) }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:-–"))
        if t.isEmpty { t = exam ? L("Klausur", "Exam") : L("Hausaufgabe", "Homework") }
        let due = w?.date ?? (s.isEmpty ? nil : Plan.nextDate(book, subject: s, after: now)) ?? ActLogic.cal.date(byAdding: .day, value: 1, to: ActLogic.cal.startOfDay(for: now))!
        let k = Plan.Task(subject: s, text: t, due: ActLogic.cal.startOfDay(for: due), exam: exam)
        book.tasks.append(k)
        return k
    }
    var menuLine: String? {
        guard !book.lessons.isEmpty else { return nil }
        let n = Plan.now(book, Date())
        if let l = n.current { return L("Jetzt \(l.subject), bis \(Plan.clock(l.end))", "Now \(l.subject), until \(Plan.clock(l.end))") }
        if let l = n.next { return L("Um \(Plan.clock(l.start)) \(l.subject)", "\(l.subject) at \(Plan.clock(l.start))") + (l.room.isEmpty ? "" : " · " + l.room) }
        return nil
    }
}

private func rel(_ d: Date) -> String {
    let n = ActLogic.cal.dateComponents([.day], from: ActLogic.cal.startOfDay(for: Date()), to: ActLogic.cal.startOfDay(for: d)).day ?? 0
    switch n { case 0: return L("heute", "today"); case 1: return L("morgen", "tomorrow"); case -1: return L("gestern", "yesterday"); case ..<0: return L("vor \(-n) Tagen", "\(-n) days ago"); case 2...6: return d.formatted(.dateTime.weekday(.wide)); default: return L("in \(n) Tagen", "in \(n) days") }
}
// Ruhige, unterscheidbare Farbe je Fach (immer gleich)
func subjectTint(_ s: String) -> Color {
    let c: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .brown, .indigo, .red, .mint]
    return c[Int(s.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % UInt32(c.count))]
}

struct SchoolView: View {
    @ObservedObject var s = School.shared
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $s.tab) {
                Text(L("Heute", "Today")).tag("heute"); Text(L("Stundenplan", "Timetable")).tag("plan"); Text(L("Aufgaben", "Tasks")).tag("aufgaben"); Text(L("Noten", "Grades")).tag("noten"); Text(L("Lernkarten", "Flashcards")).tag("karten")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520).padding(12)
            Divider()
            switch s.tab { case "plan": PlanTab(s: s); case "aufgaben": TasksTab(s: s); case "noten": GradesTab(s: s); case "karten": CardsTab(s: s); default: TodayTab(s: s) }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct TodayTab: View {
    @ObservedObject var s: School
    var body: some View {
        TimelineView(.everyMinute) { t in
            let l = Plan.lessons(s.book, on: t.date), n = Plan.now(s.book, t.date), m = ActLogic.cal.component(.hour, from: t.date) * 60 + ActLogic.cal.component(.minute, from: t.date)
            let open = s.book.tasks.filter { !$0.done }.sorted { $0.due < $1.due }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.title2.weight(.semibold))
                        if let c = n.current { Text(L("\(c.subject), noch \(c.end - m) Minuten", "\(c.subject), \(c.end - m) minutes left")).foregroundStyle(.secondary) }
                        else if let x = n.next { Text(L("\(x.subject) in \(x.start - m) Minuten", "\(x.subject) in \(x.start - m) minutes")).foregroundStyle(.secondary) }
                        else { Text(l.isEmpty ? L("Heute kein Unterricht", "No classes today") : L("Schule ist aus", "School is out")).foregroundStyle(.secondary) }
                    }
                    if s.book.lessons.isEmpty {
                        VStack(alignment: .leading, spacing: 8) { Text(L("Trag einmal deinen Stundenplan ein. Danach weiß WinKomfort, wann welche Stunde ist und bis wann Hausaufgaben fällig sind.", "Add your timetable once. WinKomfort then knows your classes and due dates.")); Button(L("Stundenplan anlegen", "Set up timetable")) { s.tab = "plan" }.buttonStyle(.borderedProminent) }
                    } else if !l.isEmpty {
                        VStack(spacing: 4) { ForEach(l) { x in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2).fill(subjectTint(x.subject)).frame(width: 4, height: 30)
                                Text("\(Plan.clock(x.start)) – \(Plan.clock(x.end))").monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Text(x.subject).fontWeight(x.id == n.current?.id ? .semibold : .regular)
                                Spacer(); Text(x.room).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(x.id == n.current?.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .opacity(x.end <= m ? 0.45 : 1)
                        } }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("Als Nächstes fällig", "Due next")).font(.headline); Spacer(); Button(L("Alle", "All")) { s.tab = "aufgaben" }.buttonStyle(.link) }
                        if open.isEmpty { Text(L("Nichts offen.", "Nothing open.")).foregroundStyle(.secondary) }
                        ForEach(open.prefix(6)) { HomeworkRow(s: s, t: $0) }
                    }
                    let due = s.book.decks.reduce(0) { $0 + Plan.due($1, t.date).count }
                    if due > 0 { Button(L("\(due) Lernkarten wiederholen", "Review \(due) flashcards")) { s.tab = "karten" }.buttonStyle(.bordered) }
                }
                .padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct HomeworkRow: View {
    @ObservedObject var s: School
    let t: Plan.Task
    private var late: Bool { !t.done && t.due < ActLogic.cal.startOfDay(for: Date()) }
    var body: some View {
        HStack(spacing: 10) {
            Button { if let i = s.book.tasks.firstIndex(where: { $0.id == t.id }) { s.book.tasks[i].done.toggle() } } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(t.done ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).accessibilityLabel(t.done ? L("Wieder öffnen", "Reopen") : L("Erledigt", "Done"))
            VStack(alignment: .leading, spacing: 1) {
                Text(t.text).strikethrough(t.done).lineLimit(3)
                HStack(spacing: 6) { if !t.subject.isEmpty { Text(t.subject).foregroundStyle(subjectTint(t.subject)) }; if t.exam { Text(L("Klausur", "Exam")).fontWeight(.semibold) } }.font(.caption)
            }
            Spacer()
            Text(rel(t.due)).font(.callout).foregroundStyle(late ? Color.red : .secondary).help(t.due.formatted(date: .complete, time: .omitted))
            Menu {
                Button(L("In die Erinnerungen", "Add to Reminders")) { Task { do { try await AIAct.create(AICard(kind: .newReminder, title: (t.subject.isEmpty ? "" : t.subject + ": ") + t.text, start: ActLogic.cal.date(bySettingHour: 16, minute: 0, second: 0, of: ActLogic.cal.date(byAdding: .day, value: -1, to: t.due)!), hasTime: true)); Toast.show(L("Erinnerung am Tag davor um 16 Uhr", "Reminder the day before at 4 pm"), symbol: "bell") } catch { Toast.show(AIChat.say(error), symbol: "exclamationmark.triangle", seconds: 4) } } }
                Button(L("Einen Tag später", "One day later")) { if let i = s.book.tasks.firstIndex(where: { $0.id == t.id }) { s.book.tasks[i].due = ActLogic.cal.date(byAdding: .day, value: 1, to: t.due)! } }
                Button(L("Löschen", "Delete"), role: .destructive) { s.book.tasks.removeAll { $0.id == t.id } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("Mehr", "More"))
        }
        .padding(.vertical, 3)
    }
}

private struct TasksTab: View {
    @ObservedObject var s: School
    @StateObject private var text = TextBox<String>()
    @StateObject private var exam = TextBox<Bool>()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("z. B. „Mathe S. 43 Nr. 2 bis Freitag“", "e.g. “Math p. 43 until Friday”"), text: Binding(get: { text.value ?? "" }, set: { text.value = $0 })).textFieldStyle(.roundedBorder).onSubmit(add)
                Toggle(L("Klausur", "Exam"), isOn: Binding(get: { exam.value ?? false }, set: { exam.value = $0 })).toggleStyle(.checkbox)
                Button(L("Hinzufügen", "Add"), action: add).disabled((text.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            List {
                let o = s.book.tasks.filter { !$0.done }.sorted { $0.due < $1.due }, d = s.book.tasks.filter(\.done).sorted { $0.due > $1.due }
                if !o.filter(\.exam).isEmpty { Section(L("Klausuren", "Exams")) { ForEach(o.filter(\.exam)) { HomeworkRow(s: s, t: $0) } } }
                if !o.filter({ !$0.exam }).isEmpty { Section(L("Offen", "Open")) { ForEach(o.filter { !$0.exam }) { HomeworkRow(s: s, t: $0) } } }
                if !d.isEmpty { Section { ForEach(d.prefix(30)) { HomeworkRow(s: s, t: $0) } } header: { HStack { Text(L("Erledigt", "Done")); Spacer(); Button(L("Aufräumen", "Clear")) { s.book.tasks.removeAll(where: \.done) }.buttonStyle(.link) } } }
            }
            .scrollContentBackground(.hidden)
            .overlay { if s.book.tasks.isEmpty { ContentUnavailableView(L("Keine Aufgaben", "No tasks"), systemImage: "checklist", description: Text(L("Ohne Datum gilt die nächste Stunde des Fachs.", "Without a date, the next class of that subject counts."))) } }
        }
    }
    private func add() {
        let t = (text.value ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        _ = s.add(t, exam: exam.value ?? false); text.value = ""; exam.value = false
    }
}

private struct PlanTab: View {
    @ObservedObject var s: School
    @StateObject private var edit = TextBox<Plan.Lesson>()
    @StateObject private var isNew = TextBox<Bool>()
    private var names: [String] { [L("Montag", "Monday"), L("Dienstag", "Tuesday"), L("Mittwoch", "Wednesday"), L("Donnerstag", "Thursday"), L("Freitag", "Friday")] + (s.book.lessons.contains { $0.day == 7 } ? [L("Samstag", "Saturday")] : []) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                        VStack(spacing: 6) {
                            Text(n).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(s.book.lessons.filter { $0.day == i + 2 }.sorted { $0.start < $1.start }) { l in
                                Button { isNew.value = false; edit.value = l } label: {
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2).fill(subjectTint(l.subject)).frame(width: 4)
                                        VStack(alignment: .leading, spacing: 1) { Text(l.subject).fontWeight(.medium).lineLimit(1); Text(Plan.clock(l.start) + (l.room.isEmpty ? "" : " · " + l.room) + (l.week == 0 ? "" : l.week == 1 ? " · A" : " · B")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(7).frame(maxWidth: .infinity).frame(height: 48).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            Button { // direkt hinter der letzten Stunde weiter
                                let e = s.book.lessons.filter { $0.day == i + 2 }.map(\.end).max()
                                isNew.value = true; edit.value = Plan.Lesson(day: i + 2, start: e.map { $0 + 5 } ?? 455, end: e.map { $0 + 50 } ?? 500)
                            } label: { Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 26).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Stunde am \(n) hinzufügen", "Add class on \(n)"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            if s.book.lessons.contains(where: { $0.week > 0 }) { Divider(); Picker(L("A-Woche", "A week"), selection: $s.book.aWeekOdd) { Text(L("ungerade Kalenderwochen", "odd weeks")).tag(true); Text(L("gerade Kalenderwochen", "even weeks")).tag(false) }.frame(maxWidth: 340).padding(10) }
        }
        .sheet(isPresented: Binding(get: { edit.value != nil }, set: { if !$0 { edit.value = nil } })) {
            if let l = edit.value { LessonSheet(l: l, isNew: isNew.value ?? true, subjects: Plan.subjects(s.book)) { r in
                s.book.lessons.removeAll { $0.id == l.id }
                if let r { s.book.lessons.append(r) }
                edit.value = nil
            } cancel: { edit.value = nil } }
        }
    }
}
private struct LessonSheet: View {
    let l: Plan.Lesson, isNew: Bool, subjects: [String]
    let done: (Plan.Lesson?) -> Void, cancel: () -> Void
    @StateObject private var b = TextBox<Plan.Lesson>()
    @StateObject private var from = TextBox<String>()
    @StateObject private var to = TextBox<String>()
    private var v: Plan.Lesson { b.value ?? l }
    private func set(_ f: (inout Plan.Lesson) -> Void) { var x = v; f(&x); b.value = x }
    private var start: Int? { Plan.minutes(from.value ?? Plan.clock(l.start)) }
    private var end: Int? { Plan.minutes(to.value ?? Plan.clock(l.end)) }
    private var ok: Bool { !v.subject.trimmingCharacters(in: .whitespaces).isEmpty && (start ?? 1) < (end ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("Neue Stunde", "New class") : L("Stunde ändern", "Edit class")).font(.title3.weight(.semibold))
            Form {
                TextField(L("Fach", "Subject"), text: Binding(get: { v.subject }, set: { t in set { $0.subject = t } }))
                if !subjects.isEmpty { LabeledContent("") { ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(subjects, id: \.self) { n in Button(n) { set { $0.subject = n } }.controlSize(.small) } } } } }
                TextField(L("Von", "From"), text: Binding(get: { from.value ?? Plan.clock(l.start) }, set: { from.value = $0 }))
                TextField(L("Bis", "To"), text: Binding(get: { to.value ?? Plan.clock(l.end) }, set: { to.value = $0 }))
                TextField(L("Raum", "Room"), text: Binding(get: { v.room }, set: { t in set { $0.room = t } }))
                Picker(L("Woche", "Week"), selection: Binding(get: { v.week }, set: { t in set { $0.week = t } })) { Text(L("jede", "every")).tag(0); Text("A").tag(1); Text("B").tag(2) }.pickerStyle(.segmented)
            }
            HStack {
                if !isNew { Button(L("Löschen", "Delete"), role: .destructive) { done(nil) } }
                Spacer()
                Button(L("Abbrechen", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L("Sichern", "Save")) { var x = v; x.start = start ?? x.start; x.end = end ?? x.end; x.subject = x.subject.trimmingCharacters(in: .whitespaces); done(x) }.keyboardShortcut(.defaultAction).disabled(!ok)
            }
        }
        .padding(20).frame(width: 400)
    }
}

private struct GradesTab: View {
    @ObservedObject var s: School
    @StateObject private var sub = TextBox<String>()
    @StateObject private var val = TextBox<String>()
    @StateObject private var name = TextBox<String>()
    @StateObject private var weight = TextBox<Double>()
    @StateObject private var goal = TextBox<String>()
    private var subject: String { sub.value ?? Plan.subjects(s.book).first ?? "" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if Plan.subjects(s.book).isEmpty { TextField(L("Fach", "Subject"), text: Binding(get: { sub.value ?? "" }, set: { sub.value = $0 })).textFieldStyle(.roundedBorder).frame(width: 130) }
                else { Picker("", selection: Binding(get: { subject }, set: { sub.value = $0 })) { ForEach(Plan.subjects(s.book), id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 150) }
                TextField(s.book.points ? L("Punkte", "Points") : L("Note", "Grade"), text: Binding(get: { val.value ?? "" }, set: { val.value = $0 })).textFieldStyle(.roundedBorder).frame(width: 70).onSubmit(add)
                TextField(L("Wofür (freiwillig)", "For (optional)"), text: Binding(get: { name.value ?? "" }, set: { name.value = $0 })).textFieldStyle(.roundedBorder).onSubmit(add)
                Picker("", selection: Binding(get: { weight.value ?? 1 }, set: { weight.value = $0 })) { Text(L("einfach", "×1")).tag(1.0); Text(L("doppelt", "×2")).tag(2.0); Text(L("halb", "×½")).tag(0.5) }.labelsHidden().frame(width: 95)
                Button(L("Eintragen", "Add"), action: add).disabled(subject.isEmpty || Plan.gradeValue(val.value ?? "", s.book.points) == nil)
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let o = Plan.overall(s.book) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) { Text(Plan.text(o, s.book.points)).font(.system(size: 34, weight: .semibold)).monospacedDigit(); Text(s.book.points ? L("Gesamtschnitt, entspricht Note \(Plan.text(Plan.note(fromPoints: o), false))", "Overall, equals grade \(Plan.text(Plan.note(fromPoints: o), false))") : L("Gesamtschnitt aller Fächer", "Overall average")).foregroundStyle(.secondary) }
                    }
                    ForEach(Plan.subjects(s.book).filter { n in s.book.grades.contains { $0.subject == n } }, id: \.self) { n in
                        let g = s.book.grades.filter { $0.subject == n }.sorted { $0.date < $1.date }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { RoundedRectangle(cornerRadius: 2).fill(subjectTint(n)).frame(width: 4, height: 18); Text(n).font(.headline); Spacer(); Text(Plan.average(g).map { Plan.text($0, s.book.points) } ?? "").font(.headline).monospacedDigit() }
                            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { ForEach(g) { x in
                                Menu { Text((x.name.isEmpty ? "" : x.name + ", ") + x.date.formatted(date: .abbreviated, time: .omitted)); Button(L("Löschen", "Delete"), role: .destructive) { s.book.grades.removeAll { $0.id == x.id } } }
                                label: { Text(Calc.format(x.value) + (x.weight == 1 ? "" : x.weight == 2 ? " ×2" : " ×½")).monospacedDigit() }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.horizontal, 9).padding(.vertical, 4).background(.primary.opacity(0.07), in: Capsule())
                            } } }
                            if let t = goal.value, let w = Plan.gradeValue(t, s.book.points) {
                                let need = Plan.needed(g, goal: w, weight: 1), can = Plan.valid(need, s.book.points)
                                Text(can ? L("Für \(Calc.format(w)) brauchst du als Nächstes \(Plan.text(need, s.book.points))", "For \(Calc.format(w)) you need \(Plan.text(need, s.book.points)) next") : (s.book.points ? need > 15 : need < 1) ? L("Mit einer Note nicht zu schaffen", "Not possible with one grade") : L("Schon sicher", "Already safe")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if s.book.grades.isEmpty { ContentUnavailableView(L("Noch keine Noten", "No grades yet"), systemImage: "graduationcap").frame(maxWidth: .infinity, minHeight: 220) }
                }
                .padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Picker("", selection: $s.book.points) { Text(L("Punkte 0–15", "Points 0–15")).tag(true); Text(L("Noten 1–6", "Grades 1–6")).tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 220).disabled(!s.book.grades.isEmpty).help(s.book.grades.isEmpty ? "" : L("Erst ohne eingetragene Noten umschaltbar", "Only while no grades are entered"))
                Spacer()
                Text(L("Wunschschnitt", "Goal")); TextField("", text: Binding(get: { goal.value ?? "" }, set: { goal.value = $0 })).textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel(L("Wunschschnitt", "Goal"))
            }
            .padding(10)
        }
    }
    private func add() {
        guard !subject.isEmpty, let v = Plan.gradeValue(val.value ?? "", s.book.points) else { return }
        s.book.grades.append(Plan.Grade(subject: subject, value: v, weight: weight.value ?? 1, name: name.value ?? ""))
        val.value = ""; name.value = ""; weight.value = 1
    }
}

private struct CardsTab: View {
    @ObservedObject var s: School
    @StateObject private var pick = TextBox<UUID>()
    @StateObject private var show = TextBox<Bool>()
    @StateObject private var run = TextBox<[Plan.Card]>()
    @StateObject private var paste = TextBox<Bool>()
    @StateObject private var text = TextBox<String>()
    @StateObject private var score = TextBox<(Int, Int)>()
    @Environment(\.accessibilityReduceMotion) private var still
    private var deck: Plan.Deck? { s.book.decks.first { $0.id == pick.value } ?? s.book.decks.first }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(s.book.decks, selection: Binding(get: { deck?.id }, set: { pick.value = $0; run.value = nil })) { d in
                    HStack { Text(d.name).lineLimit(1); Spacer(); let n = Plan.due(d, Date()).count; if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule()) } }
                        .contextMenu { Button(L("Stapel löschen", "Delete deck"), role: .destructive) { remove(d) } }.tag(d.id)
                }
                .listStyle(.sidebar)
                Button(L("Neuer Stapel", "New deck")) { let d = Plan.Deck(name: L("Stapel \(s.book.decks.count + 1)", "Deck \(s.book.decks.count + 1)")); s.book.decks.append(d); pick.value = d.id; paste.value = true }.buttonStyle(.borderless).padding(10)
            }
            .frame(minWidth: 150, idealWidth: 190, maxWidth: 260)
            Group { if let d = deck { if run.value != nil { study(d) } else { detail(d) } } else {
                ContentUnavailableView(L("Noch keine Lernkarten", "No flashcards yet"), systemImage: "rectangle.on.rectangle", description: Text(L("Füge Zeilen ein wie „Frage | Antwort“, aus Quizlet, Anki oder Excel. Oder lass die KI mit /cards welche machen.", "Paste lines like “Question | Answer”, from Quizlet, Anki or Excel. Or let AI make some with /cards.")))
            } }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(get: { paste.value ?? false }, set: { paste.value = $0 })) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Karten einfügen", "Paste cards")).font(.title3.weight(.semibold))
                Text(L("Eine Karte je Zeile: Frage | Antwort (auch Tabulator oder Semikolon)", "One card per line: question | answer (tab or semicolon also work)")).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { text.value ?? "" }, set: { text.value = $0 })).font(.body).frame(width: 460, height: 220).border(.separator)
                HStack { Text(L("\(Plan.cards(text.value ?? "").count) erkannt", "\(Plan.cards(text.value ?? "").count) found")).foregroundStyle(.secondary); Spacer(); Button(L("Abbrechen", "Cancel")) { paste.value = false }.keyboardShortcut(.cancelAction)
                    Button(L("Hinzufügen", "Add")) { if let i = index { s.book.decks[i].cards += Plan.cards(text.value ?? "") }; text.value = ""; paste.value = false }.keyboardShortcut(.defaultAction).disabled(Plan.cards(text.value ?? "").isEmpty) }
            }
            .padding(20)
        }
    }
    private var index: Int? { deck.flatMap { d in s.book.decks.firstIndex { $0.id == d.id } } }
    private func remove(_ d: Plan.Deck) {
        let a = NSAlert(); a.messageText = L("Stapel „\(d.name)“ mit \(d.cards.count) Karten löschen?", "Delete deck “\(d.name)” with \(d.cards.count) cards?")
        a.addButton(withTitle: L("Abbrechen", "Cancel")); a.addButton(withTitle: L("Löschen", "Delete")).hasDestructiveAction = true
        if d.cards.isEmpty || a.runModal() == .alertSecondButtonReturn { s.book.decks.removeAll { $0.id == d.id } }
    }
    private func detail(_ d: Plan.Deck) -> some View {
        let due = Plan.due(d, Date())
        return VStack(spacing: 0) {
            HStack {
                TextField("", text: Binding(get: { d.name }, set: { n in if let i = index { s.book.decks[i].name = n } })).textFieldStyle(.plain).font(.title3.weight(.semibold)).accessibilityLabel(L("Name", "Name"))
                Button(L("Einfügen …", "Paste…")) { paste.value = true }
                Button(due.isEmpty ? L("Alle üben", "Practice all") : L("\(due.count) lernen", "Study \(due.count)")) { score.value = (0, 0); show.value = false; run.value = due.isEmpty ? d.cards.shuffled() : due }.buttonStyle(.borderedProminent).disabled(d.cards.isEmpty)
            }
            .padding(12)
            Divider()
            List { ForEach(d.cards) { c in
                HStack(alignment: .top) { Text(c.front).frame(maxWidth: .infinity, alignment: .leading); Text(c.back).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 2) { ForEach(1..<7) { k in Circle().fill(k <= c.box ? Color.accentColor : .primary.opacity(0.12)).frame(width: 6, height: 6) } }.padding(.top, 5).accessibilityLabel(L("Stufe \(c.box) von 6", "Level \(c.box) of 6")) }
                .contextMenu { Button(L("Karte löschen", "Delete card"), role: .destructive) { if let i = index { s.book.decks[i].cards.removeAll { $0.id == c.id } } } }
            } }
            .overlay { if d.cards.isEmpty { Text(L("Noch keine Karten", "No cards yet")).foregroundStyle(.secondary) } }
        }
    }
    private func study(_ d: Plan.Deck) -> some View {
        VStack(spacing: 18) {
            HStack { Button(L("Beenden", "Stop")) { run.value = nil }.keyboardShortcut(.cancelAction); Spacer(); Text(L("noch \(run.value?.count ?? 0)", "\(run.value?.count ?? 0) left")).monospacedDigit().foregroundStyle(.secondary) }
            Spacer()
            if let c = run.value?.first {
                VStack(spacing: 14) {
                    Text(c.front).font(.title2.weight(.semibold)).multilineTextAlignment(.center).textSelection(.enabled)
                    if show.value == true { Divider().frame(width: 120); Text(c.back).font(.title3).multilineTextAlignment(.center).textSelection(.enabled) }
                }
                .padding(28).frame(maxWidth: 480, minHeight: 180).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .animation(still ? nil : .easeOut(duration: 0.18), value: show.value)
                if show.value == true {
                    HStack { Button(L("Nochmal  (1)", "Again  (1)")) { next(c, false) }.keyboardShortcut("1", modifiers: []).controlSize(.large); Button(L("Gewusst  (2)", "Knew it  (2)")) { next(c, true) }.keyboardShortcut("2", modifiers: []).controlSize(.large).buttonStyle(.borderedProminent) }
                } else { Button(L("Antwort zeigen", "Show answer")) { show.value = true }.keyboardShortcut(.space, modifiers: []).controlSize(.large).buttonStyle(.borderedProminent) }
            } else {
                Text(L("Geschafft", "Done")).font(.title2.weight(.semibold))
                Text(L("\(score.value?.0 ?? 0) gewusst, \(score.value?.1 ?? 0) nochmal", "\(score.value?.0 ?? 0) known, \(score.value?.1 ?? 0) again")).foregroundStyle(.secondary)
                Button(L("Zurück", "Back")) { run.value = nil }.keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(20)
    }
    private func next(_ c: Plan.Card, _ right: Bool) {
        if let i = index, let k = s.book.decks[i].cards.firstIndex(where: { $0.id == c.id }) { s.book.decks[i].cards[k] = Plan.answer(s.book.decks[i].cards[k], right: right, now: Date()) }
        var r = run.value ?? []
        if !r.isEmpty { r.removeFirst() }
        if !right { r.insert(c, at: min(3, r.count)) } // gleich noch einmal
        let o = score.value ?? (0, 0); score.value = right ? (o.0 + 1, o.1) : (o.0, o.1 + 1)
        show.value = false; run.value = r
    }
}
