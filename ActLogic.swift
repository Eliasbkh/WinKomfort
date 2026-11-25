// Was will der Nutzer vom Mac? Reine Logik (Deutsch und Englisch), testbar. Das Sprachmodell wählt nur noch unter den Treffern.
import Foundation

enum ActLogic {
    enum Kind: String, CaseIterable {
        case mac // alte WinKomfort-Befehle (App öffnen, Lautstärke, Fenster …)
        case timer, reminderNew, eventNew, calendar, reminders, files, screen, status, weather, contact, remember, forget, past, music
        var help: String {
            switch self {
            case .mac: "etwas am Mac tun: App öffnen, Lautstärke, Dunkelmodus, Fenster anordnen, Bildschirm aus, wach halten, Game Mode, Ordner zeigen"
            case .timer: "einen Timer starten"
            case .reminderNew: "eine neue Erinnerung anlegen"
            case .eventNew: "einen neuen Termin in den Kalender eintragen"
            case .calendar: "eigene Termine oder den eigenen Tag nachsehen"
            case .reminders: "eigene Erinnerungen und offene Aufgaben nachsehen"
            case .files: "eine Datei auf diesem Mac finden"
            case .screen: "etwas zu dem sagen, was gerade auf dem Bildschirm zu sehen ist"
            case .status: "Akku, Speicher oder Zustand dieses Macs nachsehen"
            case .weather: "das Wetter nachsehen"
            case .contact: "Nummer, Adresse, E-Mail oder Geburtstag aus den eigenen Kontakten"
            case .remember: "sich dauerhaft etwas über den Nutzer merken"
            case .forget: "Gemerktes vergessen"
            case .past: "in früheren Gesprächen nachsehen"
            case .music: "Musik abspielen, anhalten oder weiterschalten"
            }
        }
    }
    private static let patterns: [(Kind, String)] = [
        (.remember, #"\bmerke? dir\b|\bremember (that|this)\b"#),
        (.forget, #"\bvergiss\b|\bforget\b"#),
        (.timer, #"\btimer\b|countdown|\bweck mich in\b"#),
        (.reminderNew, #"erinner(e|st)?( du)? mich|remind me|(erinnerung|aufgabe|to-?do).*(erstell|anleg|hinzu|an\b)|(erstell|leg|setz).*(erinnerung|aufgabe|to-?do)"#),
        (.eventNew, #"(trag|leg|erstell|plan|setz|schreib|add|create|schedule)\w* .*(termin|kalender|treffen|event|meeting|calendar|\bein\b$)|\btermin .*(ein|anlegen|erstellen|machen|hinzufügen)\b"#),
        (.calendar, #"kalender|\btermine?\b|steht .*\ban\b|\bmein(en)? (tag|woche)\b|hab(e)? ich .*(heute|morgen|woche|vor\b|zeit|frei)|calendar|my (day|week)|am i free"#),
        (.reminders, #"erinnerungen|to-?dos?\b|(offene|meine|welche) aufgaben|my (reminders|tasks)|noch zu tun"#),
        (.files, #"(find|such|wo (ist|liegt|hab)|zeig|öffne|open|where).*(datei|dokument|pdf|bild|foto|präsentation|referat|word|excel|tabelle|file|document|photo|presentation)|\bfinde\b.*\bmein|\bwo (ist|liegt) (mein|das|die|der)\b"#),
        (.screen, #"bildschirm(?!.*\baus\b)|\bscreen\b(?!.*\boff\b)|\bdas hier\b|auf (dieser|der) (seite|webseite)|diese[rsn]? (seite|webseite|mail|e-mail|artikel|text|aufgabe|fenster|fehlermeldung|tabelle|chat)|was (siehst|sehe)|this (page|window|email|error)"#),
        (.status, #"\bakku(s|stand|ladung)?\b|batterie|battery|speicherplatz|festplatte|wie ?viel (speicher|platz)|arbeitsspeicher|\bram\b|storage left|macos-?version|welche[sn]? (mac|macos)"#),
        (.weather, #"wetter|regnet|regen|schneit|regenschirm|\bjacke\b|wie (warm|kalt)|weather|\brain"#),
        (.contact, #"(nummer|adresse|geburtstag|e-?mail|handy).*\bvon\b|kontakt|wann hat .* geburtstag|phone number|birthday"#),
        (.past, #"letzte[ns]* ?mal|letztens|neulich|vorhin|haben wir .*(gesprochen|geredet|besprochen|gemacht)|hab(e)? ich dich .*gefragt|früher(en)? (chat|gespräch)|last time|we talked"#),
        (.music, #"\bmusik\b|\bsong\b|\blied\b|nächste[rsn]? (titel|track)|weiterspielen|\bmusic\b|next track"#),
        (.mac, #"\b(öffne|starte|öffnest|open|launch|start)\b|\bmach\b.*\b(auf|an|aus|lauter|leiser|dunkel|hell|größer)\b|lauter|leiser|lautstärke|\bstumm\b|\bvolume\b|dunkelmodus|dark ?mode|hellmodus|light ?mode|fenster.*(links|rechts|groß|maxim|vollbild)|game ?mode|spielmodus|\bwach\b|nicht (schlafen|einschlafen)|stay awake|(bildschirm|display).*\baus\b|bildschirmfoto|screenshot|task-?manager|zwischenablage|einstellungen|notier|notiz"#),
    ]
    static func candidates(_ q: String) -> [Kind] {
        let l = q.lowercased()
        guard l.count < 400 else { return [] } // langer Text ist Material, kein Befehl
        // Wissens- und Schreibfragen sind kein Befehl, auch wenn „Regen“ oder „Termin“ vorkommt
        if l.range(of: #"^(bitte )?(wie (entsteh|funktionier|erstelle ich|mache ich|kann (man|ich)|schreib)|warum|übersetz|translate|erklär|explain|was (bedeutet|heißt) (?!(das hier|diese))|schreibe?\b(?!.*(kalender|notiz))|verfass|dichte|write )"#, options: .regularExpression) != nil,
           l.range(of: #"das hier|diese[rsn]? (seite|webseite|mail|e-mail|artikel|text|aufgabe|fenster|fehlermeldung|tabelle|chat)|bildschirm"#, options: .regularExpression) == nil { return [] }
        return patterns.filter { l.range(of: $0.1, options: .regularExpression) != nil }.map(\.0)
    }
    // Antwort des Modells auf die Auswahl („2“ oder „0“ = normale Frage)
    static func choice(_ s: String, _ c: [Kind]) -> Kind? {
        guard let n = s.firstMatch(of: #/\d+/#).flatMap({ Int($0.0) }), (1...max(c.count, 1)).contains(n), !c.isEmpty else { return nil }
        return c[n - 1]
    }

    // MARK: Zeit
    private static let days = ["montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7, "sonntag": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sunday": 1]
    private static let months = ["januar": 1, "februar": 2, "märz": 3, "april": 4, "mai": 5, "juni": 6, "juli": 7, "august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12]
    private static let hours = ["eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12]
    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "de_DE"); c.firstWeekday = 2; return c }()

    private static func find(_ p: String, _ s: String) -> (NSTextCheckingResult, [String])? {
        guard let m = try? NSRegularExpression(pattern: p, options: .caseInsensitive).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (m, (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]).lowercased() } ?? "" })
    }
    struct When: Equatable { var date: Date; var hasTime: Bool; var rest: String } // rest = Satz ohne Zeitangaben
    static func when(_ text: String, now: Date = Date()) -> When? {
        var s = text, day: Date?, time: (Int, Int)?, abs: Date?
        let today = cal.startOfDay(for: now)
        func cut(_ p: String) -> [String]? {
            guard let (m, g) = find(p, s), let r = Range(m.range, in: s) else { return nil }
            s.replaceSubrange(r, with: " ")
            return g
        }
        // „in 20 Minuten“, „in zwei Stunden“, „in 3 Tagen“
        if let g = cut(#"\bin (\d+|eine[rnm]?|einem|einer|zwei|drei|vier|fünf|sechs|sieben|zehn|one|two|three) (minute|stunde|tag|woche|hour|day|week)[a-z]*"#) {
            let n = Int(g[1]) ?? (hours[g[1]] ?? ["one": 1, "two": 2, "three": 3][g[1]] ?? 1)
            switch g[2] {
            case "minute": abs = cal.date(byAdding: .minute, value: n, to: now)
            case "stunde", "hour": abs = cal.date(byAdding: .hour, value: n, to: now)
            case "woche", "week": day = cal.date(byAdding: .day, value: 7 * n, to: today)
            default: day = cal.date(byAdding: .day, value: n, to: today)
            }
        } else if cut(#"\bin (einer )?halben stunde"#) != nil { abs = cal.date(byAdding: .minute, value: 30, to: now) }
        if let g = cut(#"\b(?:am |zum |bis )?(\d{1,2})\. ?(\d{1,2})\.(?: ?(\d{4}))?(?!\d)"#), let d = Int(g[1]), let m = Int(g[2]) { day = date(d, m, Int(g[3]), today) }
        else if let g = cut(#"\b(?:am )?(\d{1,2})\. (januar|februar|märz|april|mai|juni|juli|august|september|oktober|november|dezember)(?: (\d{4}))?"#), let d = Int(g[1]), let m = months[g[2]] { day = date(d, m, Int(g[3]), today) }
        if day == nil {
            if cut(#"\b(übermorgen|day after tomorrow)\b"#) != nil { day = cal.date(byAdding: .day, value: 2, to: today) }
            else if cut(#"\bmorgen früh\b"#) != nil { day = cal.date(byAdding: .day, value: 1, to: today); time = (8, 0) }
            else if cut(#"\b(morgen|tomorrow)\b"#) != nil { day = cal.date(byAdding: .day, value: 1, to: today) }
            else if cut(#"\b(heute|today|tonight)\b"#) != nil { day = today }
            else if let g = cut(#"\b(?:am |on )?((?:nächste[nrms]?|kommende[nrms]?|next) )?(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonnabend|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\b"#), let w = days[g[2]] {
                var n = (w - cal.component(.weekday, from: today) + 7) % 7
                if n == 0 { n = 7 }
                // „nächsten Freitag“ in der nächsten Kalenderwoche
                if g[1].hasPrefix("nächste") || g[1].hasPrefix("next"), let d = cal.date(byAdding: .day, value: n, to: today), cal.isDate(d, equalTo: today, toGranularity: .weekOfYear) { n += 7 }
                day = cal.date(byAdding: .day, value: n, to: today)
            }
        }
        // Uhrzeit
        if let g = cut(#"\b(?:um |ab |gegen |at )?(\d{1,2})[:.](\d{2})(?: uhr)?(?!\d|\.)"#), let h = Int(g[1]), let m = Int(g[2]), h < 24, m < 60 { time = (h, m) }
        else if let g = cut(#"\b(?:um |ab |gegen )?(\d{1,2}) uhr(?: (\d{2}))?\b"#), let h = Int(g[1]), h <= 24 { time = (h % 24, Int(g[2]) ?? 0) }
        else if let g = cut(#"\b(?:um )?halb (eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf|\d{1,2})\b"#), let h = Int(g[1]) ?? hours[g[1]] { time = (afternoon(h - 1), 30) }
        else if let g = cut(#"\b(?:um|at) (eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf|\d{1,2})( ?pm| ?am)?\b(?! ?(minuten|personen|euro|stück))"#), let h = Int(g[1]) ?? hours[g[1]], h < 25 { time = (g[2].contains("pm") && h < 12 ? h + 12 : g[2].isEmpty && Int(g[1]) == nil ? afternoon(h) : h % 24, 0) }
        else if cut(#"\bmittags?\b"#) != nil { time = (12, 0) }
        if let g = cut(#"\b(?:am )?(morgens|früh|vormittags?|nachmittags?|abends?)\b"#) {
            let late = g[1].hasPrefix("nach") || g[1].hasPrefix("abend")
            if let t = time { if late, t.0 < 12 { time = (t.0 + 12, t.1) } else if !late, t.0 >= 12, t.0 - 12 >= 5 { time = (t.0 - 12, t.1) } } else { time = (late ? (g[1].hasPrefix("abend") ? 19 : 15) : g[1].hasPrefix("vor") ? 10 : 8, 0) }
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let abs { return When(date: abs, hasTime: true, rest: s) }
        guard day != nil || time != nil else { return nil }
        var d = day ?? today
        if let (h, m) = time {
            d = cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
            if day == nil, d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d } // „um 8“ ist heute schon vorbei
        }
        return When(date: d, hasTime: time != nil, rest: s)
    }
    private static func afternoon(_ h: Int) -> Int { h >= 1 && h <= 6 ? h + 12 : (h + 24) % 24 } // „halb vier“ meint 15:30
    private static func date(_ d: Int, _ m: Int, _ y: Int?, _ today: Date) -> Date? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        let now = cal.component(.year, from: today)
        guard let x = cal.date(from: DateComponents(year: y ?? now, month: m, day: d)), cal.component(.day, from: x) == d else { return nil }
        return y == nil && x < today ? cal.date(from: DateComponents(year: now + 1, month: m, day: d)) : x
    }
    // Zeitraum für „was steht an“
    static func range(_ text: String, now: Date = Date()) -> (from: Date, to: Date, title: String) {
        let l = text.lowercased(), today = cal.startOfDay(for: now)
        func add(_ n: Int, _ d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
        let monday = cal.dateInterval(of: .weekOfYear, for: today)!.start
        if l.contains("nächste woche") || l.contains("next week") { return (add(7, monday), add(14, monday), L2("nächste Woche", "next week")) }
        if l.contains("wochenende") || l.contains("weekend") { let sat = add(5, monday); return (max(sat, today), add(2, sat), L2("am Wochenende", "this weekend")) }
        if l.contains("woche") || l.contains("week") { return (today, add(7, monday), L2("diese Woche", "this week")) }
        if l.contains("monat") || l.contains("month") { return (today, add(31, today), L2("in den nächsten 31 Tagen", "in the next 31 days")) }
        if l.contains("nächste") || l.contains("wann") || l.contains("when") || l.contains("next") , when(text, now: now) == nil { return (now, add(60, today), L2("demnächst", "coming up")) }
        let d = when(text, now: now).map { cal.startOfDay(for: $0.date) } ?? today
        let f = DateFormatter(); f.locale = Locale(identifier: L2("de_DE", "en_US")); f.dateFormat = L2("EEEE, d. MMMM", "EEEE, MMMM d")
        return (d, add(1, d), d == today ? L2("heute", "today") : f.string(from: d))
    }
    static var english = false
    private static func L2(_ d: String, _ e: String) -> String { english ? e : d }

    // Titel aus dem Befehl: Zeitangaben und Befehlswörter weg
    static func title(_ q: String, now: Date = Date()) -> String {
        var s = when(q, now: now)?.rest ?? q
        for p in [#"^(hey |hallo |ok )?(bitte |kannst du |könntest du |please )*"#,
                  #"\b(trage?|lege?|erstelle?|plane?|setze?|schreibe?|mache?|füge|add|create|schedule)\b( mir| mal| bitte)*"#,
                  #"\berinner(e|st)?( du)? mich( bitte)?( daran)?\b|\bremind me( to)?\b"#,
                  #"\b(in|auf|zu) (den|meinen|dem|meinem|die|meine|der|meiner|my|the) (kalender|erinnerungen|liste|calendar|reminders)\b"#,
                  #"\b(ein(en|e)?|den|die|a|an) (neuen? |new )?(termin|erinnerung|aufgabe|treffen|event|reminder|to-?do)\b( für| zum| zur| mit dem titel| namens| called| for)?"#,
                  #"\btermin\b( für)?"#, #"\b(ein|an|hinzu|anlegen|erstellen|eintragen)[.!]?$"#, #"^(an|daran,? dass ich|für|dass ich|to) "#, #"\b(ein|an|hinzu)[.!]?$"#] {
            s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:„“\""))
        }
        for p in [#"^(an (die|den|das|meine?n?)|an|für|dass ich) "#] { s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        return s.isEmpty ? "" : s.prefix(1).uppercased() + s.dropFirst()
    }
    // „Merk dir, dass ich in Köln wohne“ → „ich in Köln wohne“
    static func fact(_ q: String) -> String {
        q.replacingOccurrences(of: #"(?i)^.*?\b(merke? dir|remember( that)?)\b[,: ]*(bitte\b)?[,: ]*(dass |das: )?"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " .,:"))
    }
    // Suchwort für Dateien
    static func fileWords(_ q: String) -> [String] {
        let stop: Set<String> = ["finde", "find", "such", "suche", "zeig", "zeige", "wo", "liegt", "ist", "mein", "meine", "meinen", "meiner", "datei", "dateien", "dokument", "dokumente", "öffne", "open", "hab", "habe", "ich", "file", "files", "my", "where", "bitte", "über", "letzte", "letzten", "neueste", "gespeichert", "mac", "diesem", "aus", "nach", "kannst", "du", "bild", "bilder", "foto", "fotos", "pdf", "pdfs", "präsentation", "word", "excel", "tabelle", "photo", "document", "presentation", "heute", "gestern", "woche", "zum", "zur", "thema"]
        return AILogic.words(q).filter { !stop.contains($0) }
    }
    static func fileTypes(_ q: String) -> [String] {
        let l = q.lowercased()
        if l.contains("pdf") { return ["pdf"] }
        if l.contains("präsentation") || l.contains("presentation") || l.contains("powerpoint") { return ["pptx", "key", "ppt", "odp"] }
        if l.contains("bild") || l.contains("foto") || l.contains("photo") { return ["jpg", "jpeg", "png", "heic", "webp", "gif"] }
        if l.contains("excel") || l.contains("tabelle") { return ["xlsx", "xls", "numbers", "csv", "ods"] }
        if l.contains("word") { return ["docx", "doc", "pages", "odt"] }
        return []
    }
    // Wetterlage nach WMO-Nummer
    static func weather(_ c: Int) -> (String, String) {
        switch c {
        case 0: ("klar", "clear"); case 1, 2: ("teils bewölkt", "partly cloudy"); case 3: ("bedeckt", "overcast"); case 45, 48: ("neblig", "foggy")
        case 51...57: ("Nieselregen", "drizzle"); case 61...67, 80...82: ("Regen", "rain"); case 71...77, 85, 86: ("Schnee", "snow"); case 95...99: ("Gewitter", "thunderstorm")
        default: ("wechselhaft", "mixed")
        }
    }
    // Ort in der Frage: „Wetter morgen in Köln“
    static func place(_ q: String) -> String? {
        let s = when(q)?.rest ?? q
        guard let (m, _) = find(#"\b(?:in|für|bei|for)\s+([A-ZÄÖÜ][\p{L}.\-]+(?: (?:am |an der |im |in der )?[A-ZÄÖÜ][\p{L}\-]+)*)"#, s), let r = Range(m.range(at: 1), in: s), s[r].first?.isUppercase == true else { return nil }
        return String(s[r])
    }
}
