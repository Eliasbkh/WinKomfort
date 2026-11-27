// Tests: swiftc TapDragLogic.swift Calc.swift Shortcut.swift SnapMath.swift OneNoteOrder.swift TimeParse.swift Tests/main.swift -o /tmp/wktest && /tmp/wktest
import Foundation
typealias A = TapDragLogic.Action
typealias P = TapDragLogic.Point

// Ein Abschnitt: n Finger liegen von `from` bis `to` und wandern dabei von `a` nach `b` (Frames alle 10 ms).
// fingers 0 = alle Finger weg zum Zeitpunkt `from`.
struct Seg { var fingers: Int; var from: Double; var to: Double; var a = P(x: 0.5, y: 0.5); var b: P? = nil }
func run(_ segs: [Seg]) -> [A] {
    var l = TapDragLogic(), out: [A] = []
    for s in segs {
        if s.fingers == 0 { out.append(l.frame(touching: [], time: s.from)); continue }
        var t = s.from
        while t <= s.to + 1e-9 {
            let k = s.to > s.from ? (t - s.from) / (s.to - s.from) : 0
            let end = s.b ?? s.a
            let p = P(x: s.a.x + (end.x - s.a.x) * k, y: s.a.y + (end.y - s.a.y) * k)
            let a = l.frame(touching: Array(repeating: p, count: s.fingers), time: t)
            if a != .none { out.append(a) }
            t += 0.01
        }
    }
    return out.filter { $0 != .none }
}
let tap = [Seg(fingers: 1, from: 0, to: 0.1), Seg(fingers: 0, from: 0.1, to: 0)]
let far = P(x: 0.8, y: 0.2)

var failed = 0
func check(_ name: String, _ got: [A], _ want: [A]) {
    let ok = got == want
    if !ok { failed += 1 }
    print(ok ? "✅" : "❌", name, ok ? "" : "→ bekam \(got), erwartet \(want)")
}

check("Tippen, dann tippen-halten-ziehen, abheben → drücken, loslassen",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 1.5, b: far), Seg(fingers: 0, from: 1.5, to: 0)]), [.press, .release])
check("Ziehen startet sofort bei Bewegung, ohne Warten",
      { var l = TapDragLogic(); _ = l.frame(touching: [P(x: 0.5, y: 0.5)], time: 0); _ = l.frame(touching: [], time: 0.1)
        _ = l.frame(touching: [P(x: 0.5, y: 0.5)], time: 0.3)
        return [l.frame(touching: [P(x: 0.52, y: 0.5)], time: 0.32)] }(), [.press])
check("Loslassen kommt im ersten Frame ohne aufliegenden Finger",
      { var l = TapDragLogic(); _ = l.frame(touching: [P(x: 0.5, y: 0.5)], time: 0); _ = l.frame(touching: [], time: 0.1)
        _ = l.frame(touching: [P(x: 0.5, y: 0.5)], time: 0.3); _ = l.frame(touching: [P(x: 0.6, y: 0.5)], time: 0.5)
        return [l.frame(touching: [], time: 0.51)] }(), [.release])
check("Doppeltippen ohne Halten → kein Ziehen (normaler Doppelklick)",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 0.38), Seg(fingers: 0, from: 0.38, to: 0)]), [])
check("Zeiger bewegen, kurz absetzen, weiterbewegen → KEIN Ziehen (das war kein Tippen)",
      run([Seg(fingers: 1, from: 0, to: 0.15, a: P(x: 0.3, y: 0.5), b: P(x: 0.4, y: 0.5)), Seg(fingers: 0, from: 0.15, to: 0),
           Seg(fingers: 1, from: 0.3, to: 1.0, a: P(x: 0.4, y: 0.5), b: P(x: 0.7, y: 0.5)), Seg(fingers: 0, from: 1.0, to: 0)]), [])
check("Zweite Berührung an anderer Stelle → kein Ziehen",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 1.0, a: far, b: P(x: 0.9, y: 0.1)), Seg(fingers: 0, from: 1.0, to: 0)]), [])
check("Leichtes Wackeln beim Tippen zählt noch als Tippen",
      run([Seg(fingers: 1, from: 0, to: 0.1, a: P(x: 0.5, y: 0.5), b: P(x: 0.51, y: 0.5)), Seg(fingers: 0, from: 0.1, to: 0),
           Seg(fingers: 1, from: 0.3, to: 1.0, a: P(x: 0.51, y: 0.5), b: far), Seg(fingers: 0, from: 1.0, to: 0)]), [.press, .release])
check("Einmal tippen und dann lange liegen lassen → kein Ziehen",
      run([Seg(fingers: 1, from: 0, to: 2.0), Seg(fingers: 0, from: 2.0, to: 0)]), [])
check("Zweite Berührung zu spät → kein Ziehen",
      run(tap + [Seg(fingers: 1, from: 0.6, to: 1.5, b: far), Seg(fingers: 0, from: 1.5, to: 0)]), [])
check("Erstes „Tippen“ zu lang (Klicken-halten) → kein Ziehen",
      run([Seg(fingers: 1, from: 0, to: 0.5), Seg(fingers: 0, from: 0.5, to: 0), Seg(fingers: 1, from: 0.6, to: 1.5, b: far), Seg(fingers: 0, from: 1.5, to: 0)]), [])
check("Zwei Finger (Scrollen) nach Tippen → kein Ziehen",
      run(tap + [Seg(fingers: 2, from: 0.3, to: 1.5, b: far), Seg(fingers: 0, from: 1.5, to: 0)]), [])
check("Zweiter Finger kommt beim Ziehen dazu → Ziehen läuft weiter bis alle weg",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 0.6, b: P(x: 0.6, y: 0.5)), Seg(fingers: 2, from: 0.6, to: 1.0, a: P(x: 0.6, y: 0.5)),
                 Seg(fingers: 1, from: 1.0, to: 1.2, a: P(x: 0.6, y: 0.5)), Seg(fingers: 0, from: 1.2, to: 0)]), [.press, .release])
check("Zweimal hintereinander ziehen",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 1.0, b: far), Seg(fingers: 0, from: 1.0, to: 0),
                 Seg(fingers: 1, from: 2.0, to: 2.1, a: far), Seg(fingers: 0, from: 2.1, to: 0),
                 Seg(fingers: 1, from: 2.3, to: 3.0, a: far, b: P(x: 0.5, y: 0.5)), Seg(fingers: 0, from: 3.0, to: 0)]),
      [.press, .release, .press, .release])
check("Nach dem Ziehen startet ein einzelnes Tippen kein neues Ziehen",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 1.0, b: far), Seg(fingers: 0, from: 1.0, to: 0),
                 Seg(fingers: 1, from: 1.1, to: 1.5, a: far), Seg(fingers: 0, from: 1.5, to: 0)]), [.press, .release])
check("Dreimal tippen → kein Ziehen",
      run(tap + [Seg(fingers: 1, from: 0.25, to: 0.32), Seg(fingers: 0, from: 0.32, to: 0),
                 Seg(fingers: 1, from: 0.45, to: 0.52), Seg(fingers: 0, from: 0.52, to: 0)]), [])

check("Zweite Berührung liegt nur still → nichts anklicken oder markieren",
      run(tap + [Seg(fingers: 1, from: 0.3, to: 1.5), Seg(fingers: 0, from: 1.5, to: 0)]), [])
check("Tippen, Pause, dann Zeiger bewegen → KEIN Ziehen",
      run(tap + [Seg(fingers: 1, from: 0.4, to: 1.0, b: far), Seg(fingers: 0, from: 1.0, to: 0)]), [])

// Rechner
func calc(_ input: String, _ want: String?) {
    let got = Calc.evaluate(input).map(Calc.format)
    let ok = got == want
    if !ok { failed += 1 }
    print(ok ? "✅" : "❌", "Rechner „\(input)“ → \(got ?? "nichts")", ok ? "" : "(erwartet \(want ?? "nichts"))")
}
calc("2+3*4", "14")
calc("(2+3)*4", "20")
calc("10/4", "2,5")
calc("0,1+0,2", "0,3")
calc("2^10", "1024")
calc("2^3^2", "512")
calc("-5+2", "-3")
calc("50%*200", "100")
calc("7 × 6", "42")
calc("9 ÷ 3", "3")
calc("2+", nil)          // unfertig: nichts, aber kein Absturz
calc("(2+3", nil)
calc("1/0", nil)         // unendlich: nichts anzeigen
calc("2024", nil)        // reine Zahl ist keine Rechnung
calc("Safari", nil)
calc("", nil)
calc("3..2+1", nil)

// Tastenkürzel
func sc(_ name: String, _ got: String, _ want: String) {
    let ok = got == want
    if !ok { failed += 1 }
    print(ok ? "✅" : "❌", "Kürzel \(name) → \(got)", ok ? "" : "(erwartet \(want))")
}
sc("⌃⌥N", Shortcut(code: 45, mods: Shortcut.control | Shortcut.option, key: "n").display, "⌃⌥N")
sc("⌥ Leertaste", Shortcut(code: 49, mods: Shortcut.option, key: " ").display, "⌥ Leertaste")
sc("⌃⇧⎋", Shortcut(code: 53, mods: Shortcut.control | Shortcut.shift).display, "⌃⇧⎋")
sc("Reihenfolge ⌃⌥⇧⌘", Shortcut(code: 35, mods: Shortcut.command | Shortcut.shift | Shortcut.option | Shortcut.control, key: "p").display, "⌃⌥⇧⌘P")
sc("F5 ohne Modifier", Shortcut(code: 96, mods: 0).display, "F5")
sc("Gültig mit ⌘", "\(Shortcut(code: 35, mods: Shortcut.command, key: "p").isValid)", "true")
sc("Ungültig: nur Buchstabe", "\(Shortcut(code: 35, mods: 0, key: "p").isValid)", "false")
sc("Ungültig: nur ⇧ + Buchstabe", "\(Shortcut(code: 35, mods: Shortcut.shift, key: "p").isValid)", "false")
sc("Gültig: F-Taste allein", "\(Shortcut(code: 96, mods: 0).isValid)", "true")
sc("Deutsche Tastatur: Taste 6 heißt Z", Shortcut(code: 6, mods: Shortcut.command, key: "z").display, "⌘Z")

// Einrasten: MacBook 1470×956, Menüleiste 33 oben, Dock 70 unten → sichtbar (Cocoa) y 70…923
import CoreGraphics
let vis = SnapMath.toAX(CGRect(x: 0, y: 70, width: 1470, height: 853), primaryHeight: 956)
sc("AX-Koordinaten: oben unter der Menüleiste", "\(vis)", "\(CGRect(x: 0, y: 33, width: 1470, height: 853))")
sc("Linke Hälfte", "\(SnapMath.target(.left, in: vis))", "\(CGRect(x: 0, y: 33, width: 735, height: 853))")
sc("Rechte Hälfte", "\(SnapMath.target(.right, in: vis))", "\(CGRect(x: 735, y: 33, width: 735, height: 853))")
sc("Ungerade Breite: Hälften lückenlos", "\(SnapMath.target(.right, in: CGRect(x: 1470, y: -200, width: 1921, height: 1050)))", "\(CGRect(x: 2431, y: -200, width: 960, height: 1050))")
sc("Maximieren", "\(SnapMath.target(.max, in: vis))", "\(vis)")

// OneNote: Abschnitte wie in der Seitenleiste (Gruppen-Zeile, dann ihre Abschnitte), Unbekanntes hinten
let side = ["Willkommen", "_Collaboration Space", "Nutzt es!", "_Inhaltsbibliothek", "Formelsammlung", "JavaKara", "Elias Burkhardt - TGI11", "Kursnotizen"]
sc("OneNote-Reihenfolge", OneNoteOrder.sort(["_Inhaltsbibliothek/JavaKara.one", "Elias Burkhardt - TGI11/Kursnotizen.one", "Willkommen.one",
    "_Inhaltsbibliothek/Formelsammlung.one", "_Collaboration Space/Nutzt es!.one", "_Inhaltsbibliothek/DBS.one"], order: side).joined(separator: ","),
   "Willkommen.one,_Collaboration Space/Nutzt es!.one,_Inhaltsbibliothek/Formelsammlung.one,_Inhaltsbibliothek/JavaKara.one,_Inhaltsbibliothek/DBS.one,Elias Burkhardt - TGI11/Kursnotizen.one")
sc("OneNote ohne Seitenleiste: alphabetisch", OneNoteOrder.sort(["b.one", "a.one", "Gruppe/c.one"], order: []).joined(separator: ","), "a.one,b.one,Gruppe/c.one")

// KI-Zeitangaben
for (q, want) in [("halt den mac zwei minuten wach", "2"), ("eine halbe stunde", "30"), ("keep my mac awake for 2 hours", "120"), ("1,5 stunden", "90"), ("mac wach", "nil")] {
    sc("Zeit „\(q)“", TimeParse.minutes(in: q).map(String.init) ?? "nil", want)
}

// Eigene Kürzel: Webadressen
for (q, want) in [("github.com", "https://github.com"), (" https://a.de/x ", "https://a.de/x"), ("mailto:a@b.de", "mailto:a@b.de"), ("localhost:3000", "https://localhost:3000"), ("", "nil"), ("zwei worte", "nil")] {
    sc("Adresse „\(q)“", LaunchLogic.url(q)?.absoluteString ?? "nil", want)
}

// Fernbedienung: Verschlüsselung (RFC 8439 2.4.2) und Kanal
let ck = (0..<32).map { UInt8($0) }
let ct = RemoteCrypto.chacha(Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8), key: ck, nonce: [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0], counter: 1)
sc("ChaCha20 RFC 8439", ct.prefix(8).map { String($0, radix: 16) }.joined(separator: " "), "6e 2e 35 9a 25 68 f9 80")
var tx = RemoteChannel(key: ck, label: "c2s", salt: [1, 2, 3]), rx = RemoteChannel(key: ck, label: "c2s", salt: [1, 2, 3]), other = RemoteChannel(key: ck, label: "c2s", salt: [9])
let sealed = tx.seal(Array("hallo".utf8))
sc("Andere Sitzung abgelehnt", "\(other.open(sealed) == nil)", "true")
var forged = sealed; forged[9] ^= 1
sc("Fälschung abgelehnt", "\(rx.open(forged) == nil)", "true")
sc("Nachricht kommt an", String(decoding: rx.open(sealed) ?? [], as: UTF8.self), "hallo")
sc("Wiederholung abgelehnt", "\(rx.open(sealed) == nil)", "true")

// Galaxy Buds (echte Nachrichten von Buds4 Pro)
func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
let budsRaw = hex("fd 41 00 61 04 0d 64 64 01 01 11 00 00 01 ff 22 02 00 67 01 67 01 01 00 04 ee 00 04 04 10 00 00 01 00 11 02 00 01 00 00 00 0e 00 01 00 00 00 00 00 00 00 01 07 01 00 00 01 01 01 04 00 00 00 00 00 01 ea 96 dd")
var bb: [UInt8] = [0x00, 0xfd] + budsRaw + hex("fd 06 c0 64 04 01 07 35 0c dd fd 06")
let bm = BudsProtocol.take(&bb)
sc("Buds: Nachrichten trotz Müll und Rest", "\(bm.map(\.id)) \(bb.count)", "[97, 100] 2")
var bs = BudsStatus()
bm.forEach { BudsProtocol.apply($0.id, $0.data, to: &bs) }
sc("Buds: Akku und Modus", "\(bs.left ?? -1) \(bs.right ?? -1) \(bs.box ?? -1) \(bs.mode ?? -1)", "100 100 -1 2")
var own = BudsProtocol.message(0x78, [1])
sc("Buds: eigene Nachricht lesbar", "\(BudsProtocol.take(&own).map(\.id))", "[120]")
var bad = budsRaw; bad[6] = 1
sc("Buds: beschädigt verworfen", "\(BudsProtocol.take(&bad).count)", "0")

// Suche: Rangfolge
for (q, n, want) in [("fire", "Firefox", "0.9"), ("firefox", "Firefox", "1.0"), ("one", "Microsoft OneNote", "0.8"), ("mo", "Microsoft OneNote", "0.75"), ("note", "OneNote", "0.6"),
                     ("musik", "Müsik", "1.0"), ("ffx", "Firefox", "0.4"), ("xyz", "Firefox", "nil"), ("", "Firefox", "nil"), ("vsc", "VisualStudioCode", "0.7")] {
    sc("Treffer „\(q)“ in \(n)", SearchRank.match(q, n).map { "\($0)" } ?? "nil", want)
}
sc("Häufige App schlägt seltene bei gleichem Namen", "\(SearchRank.total(0.9, usage: 30) > SearchRank.total(0.9, usage: 0))", "true")
sc("Wortanfang + häufig schlägt Anfang + nie benutzt", "\(SearchRank.total(0.8, usage: 30) > SearchRank.total(0.9, usage: 0))", "true")
sc("Zufallstreffer schlägt genauen Namen nie", "\(SearchRank.total(0.4, usage: 1000) < SearchRank.total(1, usage: 0))", "true")
sc("Benutzung halbiert sich in 14 Tagen", "\(SearchRank.decayed(8, since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 14 * 86400)))", "4.0")

// Umrechnen
for (q, want) in [("10 km in mi", "6.2137 mi"), ("72 f to c", "22.2222 °C"), ("1,5 h in min", "90.0 min"), ("5 kg in km", "nil"), ("10 km", "nil"), ("1 gb in mb", "1000.0 MB")] {
    sc("Umrechnen „\(q)“", Convert.evaluate(q).map { "\($0.value) \($0.unit)" } ?? "nil", want)
}
sc("Emoji deutsch", Emoji.search("herz").isEmpty ? "leer" : "da", "da")
sc("Emoji „feuer“", Emoji.search("feuer").first?.char ?? "-", "🔥")
sc("Emoji englisch", Emoji.search("rocket").first?.char ?? "-", "🚀")
sc("Drittel lückenlos", "\(SnapMath.fraction(CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), in: CGRect(x: 0, y: 0, width: 1000, height: 600)).maxX == SnapMath.fraction(CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1), in: CGRect(x: 0, y: 0, width: 1000, height: 600)).minX)", "true")

// /Befehle
sc("/ zerlegen", "\(SlashLogic.split("/timer 5 min")!)", "(name: \"timer\", arg: \"5 min\")")
sc("kein /Befehl", "\(SlashLogic.split("timer") == nil)", "true")
sc("Farbe", "\(SlashLogic.color("#f80")!)", "(hex: \"#FF8800\", rgb: \"rgb(255, 136, 0)\", hsl: \"hsl(32, 100%, 50%)\")")
sc("Farbe ungültig", "\(SlashLogic.color("#ggg") == nil)", "true")
let pw = SlashLogic.password(24)
sc("Passwort", "\(pw.count) \(pw.contains(where: \.isUppercase) && pw.contains(where: \.isLowercase) && pw.contains(where: \.isNumber)) \(SlashLogic.password(1).count) \(pw != SlashLogic.password(24))", "24 true 8 true")
sc("Zählen", "\(SlashLogic.count("ein kurzer\nText"))", "(chars: 15, words: 3, lines: 2)")
sc("Bereich", "\(SlashLogic.range("5-10")!) \(SlashLogic.range("6")!) \(SlashLogic.range("9-1") == nil)", "5...10 1...6 true")
var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
let heute = Date(timeIntervalSince1970: 1795608000) // 25.11.2026 12:00 UTC
sc("Tage", "\(SlashLogic.days("24.12.", today: heute, cal: utc) ?? -1) \(SlashLogic.days("1.1.", today: heute, cal: utc) ?? -1) \(SlashLogic.days("31.2.", today: heute, cal: utc) == nil) \(SlashLogic.days("24.11.2026", today: heute, cal: utc) ?? 0)", "29 37 true -1")
sc("JSON", (SlashLogic.json("{\"a\":1}") ?? "").replacingOccurrences(of: "\n", with: ""), "{  \"a\" : 1}")

// Mehrere umbenennen
sc("Nummerieren", "\(RenameLogic.names(["b.jpg", "a.png", "ohne"], mode: .number, a: "Urlaub", b: ""))", "[\"Urlaub 01.jpg\", \"Urlaub 02.png\", \"Urlaub 03\"]")
sc("Ersetzen", "\(RenameLogic.names(["IMG_1.jpg", "x.txt"], mode: .replace, a: "IMG_", b: "Foto "))", "[\"Foto 1.jpg\", \"x.txt\"]")
sc("Doppelter Name", "\(RenameLogic.problem(["a", "b"], ["c", "C"], taken: ["a", "b"])!)", "twice")
sc("Gibt es schon", "\(RenameLogic.problem(["a"], ["z"], taken: ["a", "Z"])!)", "exists")
sc("Tauschen erlaubt", "\(RenameLogic.problem(["a", "b"], ["b", "a"], taken: ["a", "b"]) == nil)", "true")
sc("Schrägstrich", "\(RenameLogic.problem(["a"], ["x/y"], taken: [])!)", "slash")

// Mathe
func tex(_ s: String) -> String { MathExpr.parse(s).map(MathExpr.latex) ?? "nil" }
for (q, want) in [("a/b", "\\frac{a}{b}"), ("(a+b)/(2c)", "\\frac{a + b}{2c}"), ("sqrt(x^2+1)", "\\sqrt{x^{2} + 1}"), ("x_1^2", "x_{1}^{2}"), ("pi r^2", "\\pi r^{2}"), ("a+-b>=c", "a \\pm  b \\ge  c"), ("[[1,2],[3,4]]", "\\begin{pmatrix}1 & 2 \\\\ 3 & 4\\end{pmatrix}"),
                  ("\\frac{1}{2}", "\\frac{1}{2}"), ("lim_(x->oo) 1/x", "\\lim_{x \\to  \\infty}\\frac{1}{x}"), ("sum_(n=1)^oo 1/n^2", "\\sum_{n = 1}^{\\infty}\\frac{1}{n^{2}}"), ("3,5x", "3{,}5x"), ("sin^2 x", "\\sin^{2} x"), ("(a", "nil"), ("", "nil"), ("^", "nil"), ("a//b", "nil")] { sc("Formel \(q)", tex(q), want) }
func ev(_ s: String, _ v: [String: Double] = [:]) -> String { MathExpr.parse(s).flatMap { MathExpr.eval($0, v) }.map { "\(($0 * 1e6).rounded() / 1e6)" } ?? "nil" }
for (q, want) in [("2+3*4", "14.0"), ("2^10", "1024.0"), ("-2^2", "-4.0"), ("sqrt(16)/2", "2.0"), ("5!", "120.0"), ("sin(pi/2)", "1.0"), ("sum_(n=1)^10 n", "55.0"), ("int_0^1 x^2 dx", "0.333333"), ("1/0", "nil"), ("|-3|", "3.0"), ("2(3+4)", "14.0"), ("ln(e^2)", "2.0"), ("12÷4", "3.0"), ("prod_(k=1)^5 k", "120.0"), ("root(3,27)", "3.0"), ("a+1", "nil")] { sc("Rechne \(q)", ev(q), want) }
sc("Variable", ev("x^2+1", ["x": 3]), "10.0")
func df(_ s: String) -> String { MathExpr.parse(s).flatMap { MathExpr.diff($0, "x") }.map(MathExpr.latex) ?? "nil" }
for (q, want) in [("x^2", "2x"), ("3x^3+2x-5", "9x^{2} + 2"), ("sin(x)", "\\cos \\left(x\\right)"), ("e^(2x)", "2e^{2x}"), ("x*sin(x)", "\\sin \\left(x\\right) + x \\cos \\left(x\\right)"), ("ln(x)", "\\frac{1}{x}"), ("5", "0"), ("(2x+1)^3", "6\\left(2x + 1\\right)^{2}")] { sc("Ableitung \(q)", df(q), want) }
// Ableitung numerisch gegenprüfen
for q in ["x^3*ln(x)", "sin(x^2)/x", "sqrt(x^2+1)", "e^(x^2)*cos(x)", "(x+1)/(x-3)", "2^x"] {
    let n = MathExpr.parse(q)!, d = MathExpr.diff(n, "x")!, x = 1.7, h = 1e-5
    let num = (MathExpr.eval(n, ["x": x + h])! - MathExpr.eval(n, ["x": x - h])!) / (2 * h), sym = MathExpr.eval(d, ["x": x]) ?? .nan
    sc("Ableitung stimmt: \(q)", "\(abs(num - sym) < 1e-5 * max(1, abs(num)))", "true")
}
func rt(_ s: String) -> String { let (a, b) = MathExpr.sides(MathExpr.parse(s)!)!; return "\(MathExpr.roots { x in MathExpr.eval(a, ["x": x]).flatMap { l in MathExpr.eval(b, ["x": x]).map { l - $0 } } })" }
sc("Lösen", rt("x^2-5x+6=0"), "[2.0, 3.0]")
sc("Doppelte Lösung", rt("x^2=2x-1"), "[1.0]")
sc("Polstelle ist keine Lösung", rt("1/x=0"), "[]")
sc("Keine Lösung", rt("x^2+1=0"), "[]")

// Schule
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.02 } ?? false }
sc("Molmasse", "\(near(SchoolLogic.molarMass("H2O"), 18.015)) \(near(SchoolLogic.molarMass("Ca(OH)2"), 74.09)) \(near(SchoolLogic.molarMass("C6H12O6"), 180.16)) \(SchoolLogic.molarMass("Xx") == nil) \(SchoolLogic.molarMass("(H") == nil)", "true true true true true")
sc("Formel schön", SchoolLogic.pretty("Ca(OH)2"), "Ca(OH)₂")
let tt = SchoolLogic.truth("a und nicht b")!
sc("Wahrheitstabelle", "\(tt.vars) \(tt.rows.map { $0.last! })", "[\"a\", \"b\"] [false, false, true, false]")
sc("Implikation", "\(SchoolLogic.truth("a -> b")!.rows.map { $0.last! })", "[true, true, false, true]")
sc("Rang & vor |", "\(SchoolLogic.truth("a | b & c")!.rows.map { $0.last! ? 1 : 0 })", "[0, 0, 0, 1, 1, 1, 1, 1]")
sc("Unsinn", "\(SchoolLogic.truth("a und") == nil) \(SchoolLogic.truth("") == nil)", "true true")
sc("Zahlensysteme", "\(SchoolLogic.bases("42")!)", "(dec: \"42\", bin: \"0010 1010\", hex: \"0x2A\", oct: \"0o52\")")
sc("Hex und binär", "\(SchoolLogic.bases("0xff")!.dec) \(SchoolLogic.bases("0b101")!.dec) \(SchoolLogic.bases("xyz") == nil)", "255 5 true")
sc("Diagramm", "\(SchoolLogic.chart("Mo 3, Di 5")!.map { "\($0.0)=\($0.1)" }) \(SchoolLogic.chart("Mathe: 1,7; Deutsch: 2")!.map { $0.1 }) \(SchoolLogic.chart("3 5 8")!.count) \(SchoolLogic.chart("a, b") == nil)", "[\"Mo=3.0\", \"Di=5.0\"] [1.7, 2.0] 3 true")
let fl = SchoolLogic.flow("Start -> Ok?; Ok? -ja-> Ende; Ok? -nein-> Start")!
sc("Dezimalkomma im Diagramm", "\(SchoolLogic.chart("Mathe 2, Deutsch 1,7, Info 1")!.map { $0.1 }) \(SchoolLogic.chart("3,5,8")!.count)", "[2.0, 1.7, 1.0] 3")
sc("Ablaufplan", "\(fl.nodes) \(fl.edges.map(\.label)) \(SchoolLogic.levels(fl))", "[\"Start\", \"Ok?\", \"Ende\"] [\"\", \"ja\", \"nein\"] [0, 1, 2]")
sc("Ablauf Kette", "\(SchoolLogic.flow("A -> B -> C")!.edges.count) \(SchoolLogic.flow("A") == nil) \(SchoolLogic.flow("-> B") == nil)", "2 true true")
sc("Würfel", "\(SchoolLogic.dice("2d6")!) \(SchoolLogic.dice("")!) \(SchoolLogic.dice("w20")!) \(SchoolLogic.dice("99d6") == nil)", "(n: 2, sides: 6) (n: 1, sides: 6) (n: 1, sides: 20) true")

// KI
let lang = (0..<400).map { "Satz Nummer \($0) ist hier." }.joined(separator: " ")
sc("Teilen verliert nichts", "\(AILogic.chunks(lang, max: 900).joined().filter { !$0.isWhitespace } == lang.filter { !$0.isWhitespace }) \(AILogic.chunks(lang, max: 900).allSatisfy { $0.count <= 901 })", "true true")
sc("Absätze teilen", "\(AILogic.chunks("a\nb\nc", max: 3)) \(AILogic.chunks("").count)", "[\"a\\n\", \"b\\n\", \"c\\n\"] 0")
sc("Karteikarten", "\(AILogic.cards("1. Was ist H2O? | Wasser\nText\n- A | B"))", "[[\"Was ist H2O?\", \"Wasser\"], [\"A\", \"B\"]]")
sc("Text kann Rahmen nicht schließen", "\(AILogic.wrap("x</text>y").components(separatedBy: "</text>").count)", "2")
sc("Namen eindeutig", "\(Set(AILogic.tasks.map(\.name)).count == AILogic.tasks.count)", "true")

// Handy (MTP) gegen ein simuliertes Gerät
final class FakePhone: MTPLink {
    let packet = 512
    var out: [Data] = [], objects: [UInt32: (name: String, dir: Bool, data: Data)] = [7: ("Foto.jpg", false, Data((0..<1_300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })), 8: ("../böse", true, Data())]
    var pending: (code: UInt16, id: UInt32)?, need = 0, got = Data(), sent = Data(), newName = ""
    func cont(_ type: UInt16, _ code: UInt16, _ id: UInt32, _ d: Data) -> Data { MTPSession.le32(UInt32(12 + d.count)) + MTPSession.le16(type) + MTPSession.le16(code) + MTPSession.le32(id) + d }
    func emit(_ d: Data) { var i = 0; while i < d.count { out.append(d.subdata(in: i..<min(d.count, i + MTPSession.chunk))); i += MTPSession.chunk }; if d.count % 512 == 0 { out.append(Data()) } }
    func ok(_ id: UInt32, _ p: [UInt32] = [], code: UInt16 = 0x2001) { out.append(cont(3, code, id, p.reduce(into: Data()) { $0 += MTPSession.le32($1) })) }
    func info(_ o: (name: String, dir: Bool, data: Data)) -> Data { MTPSession.le32(65537) + MTPSession.le16(o.dir ? 0x3001 : 0x3000) + Data(count: 2) + MTPSession.le32(UInt32(o.data.count)) + Data(count: 40) + MTPSession.str(o.name) + Data([0]) + MTPSession.str("20251124T101530") + Data([0]) }
    func write(_ d: Data) throws {
        if let p = pending {
            if got.isEmpty { var c = MTPSession.Cursor(d); need = Int(try c.u32()) }
            got += d
            if got.count >= need { pending = nil; let body = Data(got.dropFirst(12)); got = Data()
                if p.code == 0x100C { var c = MTPSession.Cursor(body); c.i = 52; newName = try c.str(); ok(p.id, [65537, 0, 99]) } else { sent = body; ok(p.id) } }
            return
        }
        if d.isEmpty { return }
        var c = MTPSession.Cursor(d); _ = try c.u32(); _ = try c.u16(); let code = try c.u16(), id = try c.u32()
        var ps: [UInt32] = []; while let v = try? c.u32() { ps.append(v) }
        switch code {
        case 0x1002: ok(id, code: 0x201E)
        case 0x1007: emit(cont(2, code, id, MTPSession.le32(2) + MTPSession.le32(7) + MTPSession.le32(8))); ok(id)
        case 0x1008: emit(cont(2, code, id, info(objects[ps[0]]!))); ok(id)
        case 0x1009: emit(cont(2, code, id, objects[ps[0]]!.data)); ok(id)
        case 0x100C, 0x100D: pending = (code, id)
        case 0x1004: emit(cont(2, code, id, MTPSession.le32(0xFFFFFFF))); ok(id) // kaputte Länge
        default: ok(id, code: 0x2005)
        }
    }
    func read(timeout: TimeInterval) throws -> Data { out.isEmpty ? Data() : out.removeFirst() }
}
let fp = FakePhone(), ms = MTPSession(fp)
try ms.open()
sc("Handy: Ordner", "\(try ms.handles(65537, MTPSession.root).map { try ms.info($0) }.map { "\($0.name) \($0.isDir) \($0.size) \($0.modified != nil)" })", "[\"Foto.jpg false 1300000 true\", \".._böse true 0 true\"]")
var dl = Data(); try ms.download(7) { dl += $0 }
sc("Handy: laden", "\(dl == fp.objects[7]!.data)", "true")
struct Stop: Error {}
sc("Handy: Abbruch lässt Verbindung heil", "\((try? ms.download(7) { _ in throw Stop() }) == nil) \(try ms.info(7).name)", "true Foto.jpg")
for n in [0, 5, 500, MTPSession.chunk - 12, MTPSession.chunk, 1_000_000] {
    let src = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) }); var pos = 0
    let h = try ms.create("Ü \(n).bin", size: n, folder: false, storage: 65537, parent: MTPSession.root) { k in defer { pos += k }; return src.subdata(in: pos..<min(n, pos + k)) }
    sc("Handy: senden \(n)", "\(fp.sent == src) \(fp.newName) \(h)", "true Ü \(n).bin 99")
}
for n in [500, 512 * 3 - 12, MTPSession.chunk - 12, MTPSession.chunk] { // Grenzfälle mit leerer Endübertragung
    fp.objects[7]!.data = Data(count: n); var k = 0; try ms.download(7) { k += $0.count }
    sc("Handy: Paketgrenze \(n)", "\(k) \(try ms.info(7).size)", "\(n) \(n)")
}
sc("Handy: kaputte Antworten", "\((try? ms.storages()) == nil) \((try? ms.run(0x1234)) == nil) \(try ms.info(7).name)", "true true Foto.jpg")
sc("Handy: Namen", "\(MTPSession.safe("..")) \(MTPSession.safe("a/b")) \(MTPSession.unique("Foto.JPG", taken: ["foto.jpg", "Foto 2.jpg"]))", "_ a_b Foto 3.JPG")

// KI: Anzeige, Dokumente, Werkzeuge
sc("Markdown", "\(AILogic.blocks("# T\nHallo\nWelt\n\n- a\n  - b\n2. c\n> z\n---"))", "[main.AILogic.Block.heading(1, \"T\"), main.AILogic.Block.text(\"Hallo\\nWelt\"), main.AILogic.Block.item(0, \"•\", \"a\"), main.AILogic.Block.item(1, \"•\", \"b\"), main.AILogic.Block.item(0, \"2.\", \"c\"), main.AILogic.Block.quote(\"z\"), main.AILogic.Block.rule]".replacingOccurrences(of: "main.", with: String(reflecting: AILogic.self).components(separatedBy: ".")[0] + "."))
sc("Tabelle und Code", "\(AILogic.blocks("| A | B |\n|---|:-:|\n| 1 |\n\n```py\nx = 1\n- y") == [.table([["A", "B"], ["1", ""]]), .code("py", "x = 1\n- y")])", "true")
sc("Jahreszahl ist keine Liste", "\(AILogic.blocks("1648. war") == [.text("1648. war")])", "true")
sc("LaTeX lesbar", AILogic.tidy(#"\(x^2-5x+6=0\) \frac{1}{2} \frac{a+b}{\sqrt{2}} \alpha \cdot x_1 $y^{-3}$ 5 $ und 7 $ a_b `x^2`"#), "x²-5x+6=0 1/2 (a+b)/(√2) α · x₁ y⁻³ 5 $ und 7 $ a_b `x^2`")
let buch = (0..<400).map { "Absatz \($0) erzählt von Wetter und Wolken am Himmel über dem weiten Land." }.joined(separator: "\n") + "\nDie Zentripetalkraft hält den Körper auf der Kreisbahn."
sc("Passende Stelle", "\(AILogic.relevant(buch, "Was ist die Zentripetalkraft?", budget: 2500).contains("Kreisbahn")) \(AILogic.relevant(buch, "xyz", budget: 2500).count <= 2600)", "true true")
sc("Rechnen-Werkzeug", "\(AILogic.calculate("4837*291")) \(AILogic.calculate("x^2-5x+6=0")) \(AILogic.calculate("hallo welt("))", "1407567 x = 2 oder x = 3 Das lässt sich nicht berechnen.")
sc("Rechnung in der Frage", "\(AILogic.facts("Was ist 4837*291?")) \(AILogic.facts("Löse x^2-5x+6=0 bitte")) \(AILogic.facts("Was war am 24.12.2025 um 10:30?")) \(AILogic.facts("Wer war 1871-1890 Kanzler?").count) \(AILogic.facts("Hallo, wie geht es dir?"))", "[\"4837*291 = 1407567\"] [\"x^2-5x+6=0 → x = 2 oder x = 3\"] [] 1 []")
sc("Verrechnet", "\(AILogic.wrongSums("Also 12 · 12 = 140 und 3 + 4 = 7, 150 / 2 = 75 km")) \(AILogic.wrongSums("4837 · 291 = 1.407.567; 10 / 3 = 3,33; 2 + 3 = 5 * 1")) \(AILogic.wrongSums("3x + 4 = 10; x = 5; 2 · 2,5 = 5"))", "[\"12 · 12 = 144\"] [] []")
sc("Suchbegriff", AILogic.topic("Olaf Scholz", "Wer ist aktuell Bundeskanzler von Deutschland?", before: "") + "|" + AILogic.topic("Westfälischer Friede", "Was regelte der Westfälische Frieden?", before: ""), "bundeskanzler deutschland|Westfälischer Friede")
sc("Office", AILogic.xmlText("<a:p><a:t>A &amp; B</a:t></a:p><a:p>C</a:p>"), "A & B\nC\n")

// Assistent: Absicht, Zeit, Titel
ActLogic.cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
let mi = ActLogic.cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 20, minute: 10))! // Mittwoch
func wann(_ s: String) -> String { guard let w = ActLogic.when(s, now: mi) else { return "–" }; let f = DateFormatter(); f.calendar = ActLogic.cal; f.timeZone = ActLogic.cal.timeZone; f.dateFormat = w.hasTime ? "d.M.yy HH:mm" : "d.M.yy"; return f.string(from: w.date) }
for (a, b) in [("morgen um 15 Uhr", "26.11.26 15:00"), ("Freitag 14:30", "27.11.26 14:30"), ("nächsten Freitag", "4.12.26"), ("am 3.12. um 8", "3.12.26 08:00"), ("am 24. Dezember", "24.12.26"), ("am 2.1.", "2.1.27"), ("in 20 Minuten", "25.11.26 20:30"), ("in zwei Stunden", "25.11.26 22:10"), ("in 3 Tagen", "28.11.26"), ("morgen halb vier", "26.11.26 15:30"), ("um 8 Uhr", "26.11.26 08:00"), ("heute um 22 Uhr", "25.11.26 22:00"), ("morgen Abend um 7", "26.11.26 19:00"), ("am Mittwoch", "2.12.26"), ("übermorgen früh", "27.11.26 08:00"), ("ohne Zeit", "–"), ("am 31.2.", "–")] { sc("Wann: \(a)", wann(a), b) }
for (a, b) in [("Trag morgen um 15 Uhr Zahnarzt ein", "Zahnarzt"), ("Erinnere mich morgen um 8 an Mathe Hausaufgaben", "Mathe Hausaufgaben"), ("Erstelle einen Termin Friseur am Freitag um 14:30", "Friseur"), ("Erinnere mich in 20 Minuten daran, dass ich Oma anrufe", "Oma anrufe"), ("Remind me tomorrow to buy milk", "Buy milk")] { sc("Titel: \(a)", ActLogic.title(a, now: mi), b) }
func ab(_ s: String) -> String { ActLogic.candidates(s).map(\.rawValue).joined(separator: ",") }
for (a, b) in [("Was steht morgen an?", "calendar"), ("Erinnere mich um 8 an Sport", "reminderNew"), ("Stell einen Timer auf 10 Minuten", "timer"), ("Wie wird das Wetter in Köln?", "weather"), ("Was ist auf meinem Bildschirm?", "screen"), ("Merk dir, dass ich Tim heiße", "remember"), ("Erkläre dunkle Materie", ""), ("Was ist ein Akkusativ?", ""), ("Was ist 2+2?", ""), ("Öffne Safari", "mac"), ("Wo liegt meine Bewerbung als PDF?", "files"), ("Mach den Bildschirm aus", "mac")] { sc("Absicht: \(a)", ab(a), b) }
sc("Merken", ActLogic.fact("Merk dir bitte, dass ich in Köln wohne."), "ich in Köln wohne")
sc("Ort", "\(ActLogic.place("Wie wird das Wetter morgen in Bad Honnef?") ?? "-") \(ActLogic.place("Regnet es heute?") ?? "-")", "Bad Honnef -")
sc("Dateiwörter", "\(ActLogic.fileWords("Finde meine Präsentation über Vulkane")) \(ActLogic.fileTypes("Präsentation"))", "[\"vulkane\"] [\"pptx\", \"key\", \"ppt\", \"odp\"]")
let nw = ActLogic.range("Was habe ich nächste Woche?", now: mi)
sc("Zeitraum", "\(ActLogic.cal.component(.day, from: nw.from)) \(Int(nw.to.timeIntervalSince(nw.from) / 86400)) \(ActLogic.range("Was steht an?", now: mi).title)", "30 7 heute")
sc("Auswahl", "\(ActLogic.choice("2", [.mac, .timer])!) \(ActLogic.choice("0", [.mac]) == nil) \(ActLogic.choice("7", [.mac]) == nil)", "timer true true")

// TGI-Werkzeuge
let n1 = TechLogic.net("192.168.1.77/26")!
sc("Subnetz", "\(TechLogic.dotted(n1.network)) \(TechLogic.dotted(n1.broadcast)) \(n1.hosts) \(TechLogic.dotted(n1.first)) \(TechLogic.dotted(n1.last)) \(TechLogic.net("10.0.0.1 255.255.0.0")!.prefix) \(TechLogic.net("10.0.0.1 255.0.255.0") == nil) \(TechLogic.net("1.2.3/8") == nil) \(TechLogic.net("1.2.3.256/8") == nil)", "192.168.1.64 192.168.1.127 62 192.168.1.65 192.168.1.126 16 true true true")
sc("Subnetz Rand", "\(TechLogic.net("1.2.3.4/32")!.hosts) \(TechLogic.net("1.2.3.4/31")!.hosts) \(TechLogic.net("1.2.3.4/0")!.hosts) \(TechLogic.dotted(TechLogic.net("1.2.3.4/0")!.broadcast))", "1 2 4294967294 255.255.255.255")
sc("Teilen", "\(TechLogic.split(TechLogic.net("10.0.0.0/24")!, 4)!.map { TechLogic.dotted($0.network) + "/\($0.prefix)" })", "[\"10.0.0.0/26\", \"10.0.0.64/26\", \"10.0.0.128/26\", \"10.0.0.192/26\"]")
sc("VLSM", "\(TechLogic.vlsm(TechLogic.net("192.168.0.0/24")!, [20, 100, 50])!.map { "\($0.0):" + TechLogic.dotted($0.1.network) + "/\($0.1.prefix)" }) \(TechLogic.vlsm(TechLogic.net("192.168.0.0/24")!, [200, 100]) == nil)", "[\"100:192.168.0.0/25\", \"50:192.168.0.128/26\", \"20:192.168.0.192/27\"] true")
for seed in 0..<400 { // Vereinfachung muss für jede Funktion gleichwertig sein
    var r = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407; r ^= r >> 29; r = r &* 0x94d049bb133111eb; r ^= r >> 31
    let n = 1 + seed % 5, on = (0..<(1 << n)).filter { r >> UInt64($0) & 1 == 1 }, t = TechLogic.minimize(on, vars: n)
    if (0..<(1 << n)).contains(where: { m in on.contains(m) != t.contains { m & $0.care == $0.value } }) { sc("KV \(seed)", "falsch", "gleich") }
}
sc("KV", TechLogic.dnf(TechLogic.minimize([0, 1, 2, 5, 6, 7], vars: 3), ["a", "b", "c"], always: false).components(separatedBy: " ∨ ").count.description + " " + TechLogic.dnf(TechLogic.minimize([1, 3], vars: 2), ["a", "b"], always: false) + " " + TechLogic.dnf(TechLogic.minimize([0, 1, 2, 3], vars: 2), ["a", "b"], always: false) + " " + TechLogic.dnf([], ["a"], always: false), "3 b 1 0")
sc("IEEE", "\(TechLogic.ieee("-0,75")!.bits) \(TechLogic.ieee("1")!.hex) \(TechLogic.ieee("x") == nil)", "1 01111110 10000000000000000000000 0x3F800000 true")
sc("Zweierkomplement", "\(TechLogic.twos(-5, 8)!) \(TechLogic.twos(127, 8)!) \(TechLogic.twos(128, 8) == nil)", "1111 1011 0111 1111 true")
let om = TechLogic.ohm("U=12 R=470")!, o2 = TechLogic.ohm("5V 20mA")!, o3 = TechLogic.ohm("4,7kΩ 0,25W")!
sc("Ohm", "\(TechLogic.si(om.i, "A")) \(TechLogic.si(o2.r, "Ω")) \(TechLogic.si(o2.p, "W")) \(TechLogic.si(o3.u, "V")) \(TechLogic.ohm("12V") == nil)", "25,53 mA 250 Ω 100 mW 34,28 V true")
sc("Farbcode", "\(TechLogic.resistor("gelb violett rot gold")!) \(TechLogic.resistor("braun schwarz schwarz braun braun")!.ohm) \(TechLogic.resistor("rosa rot rot") == nil)", "(ohm: 4700.0, tol: \"5\") 1000.0 true")
sc("Struktogramm", "\(TechLogic.nsd("Eingabe x\nwenn x > 0 dann\n  Ausgabe ja\nsonst\n  Ausgabe nein\nende\nsolange x < 5\n  x = x + 1\nFertig")!)".replacingOccurrences(of: String(reflecting: TechLogic.Block.self) + ".", with: ""), "[step(\"Eingabe x\"), branch(\"x > 0\", [step(\"Ausgabe ja\")], [step(\"Ausgabe nein\")]), loop(\"solange x < 5\", [step(\"x = x + 1\")]), step(\"Fertig\")]")
sc("Struktogramm ohne Einrückung", "\(TechLogic.nsd("wenn a; b; sonst; c; ende; d")!)".replacingOccurrences(of: String(reflecting: TechLogic.Block.self) + ".", with: ""), "[branch(\"a\", [step(\"b\")], [step(\"c\")]), step(\"d\")]")
sc("Struktogramm Klammern", "\(TechLogic.nsd("for (i = 0) { if (a) { b } else if (c) { d } else { e } } f")!)".replacingOccurrences(of: String(reflecting: TechLogic.Block.self) + ".", with: ""), "[loop(\"for i = 0\", [branch(\"a\", [step(\"b\")], [branch(\"c\", [step(\"d\")], [step(\"e\")])])]), step(\"f\")]")
sc("Struktogramm bis", "\(TechLogic.nsd("wiederhole\n  x = x - 1\nbis x = 0")!) \(TechLogic.nsd("ende\nende") == nil)".replacingOccurrences(of: String(reflecting: TechLogic.Block.self) + ".", with: ""), "[until(\"bis x = 0\", [step(\"x = x - 1\")])] true")
let cl = TechLogic.uml("Tier: -name: String, +fressen(a: int, b); Hund < Tier: bellen()")!
sc("UML", "\(cl[0].fields) \(cl[0].methods) \(cl[1].parent!) \(cl[1].methods)", "[\"-name: String\"] [\"+fressen(a: int, b)\"] Tier [\"+bellen()\"]")
sc("Regex teilen", "\(TechLogic.regex(#"/\d+/ a 12"#)!) \(TechLogic.regex("abc") == nil)", "(pattern: \"\\\\d+\", text: \"a 12\") true")
sc("Ort nach Merken", ActLogic.place("ich in Köln wohne") ?? "-", "Köln")

// Schule
var bk = Plan.Book()
bk.lessons = [Plan.Lesson(day: 4, start: 455, end: 500, subject: "Mathematik", room: "A1"), Plan.Lesson(day: 4, start: 1200, end: 1230, subject: "IT"), Plan.Lesson(day: 5, start: 480, end: 525, subject: "Deutsch", week: 1), Plan.Lesson(day: 5, start: 480, end: 525, subject: "Physik", week: 2)]
sc("Stunde jetzt", "\(Plan.now(bk, mi).current?.subject ?? "-") \(Plan.lessons(bk, on: mi.addingTimeInterval(86400)).map(\.subject)) \(Plan.isoWeek(mi, ActLogic.cal))", "IT [\"Physik\"] 48")
sc("Nächste Stunde", "\(ActLogic.cal.component(.day, from: Plan.nextDate(bk, subject: "Mathematik", after: mi)!)) \(Plan.nextDate(bk, subject: "Kunst", after: mi) == nil)", "2 true")
sc("Fach erkennen", "\(Plan.subject(in: "Mathe S. 43 Nr. 2", bk) ?? "-") \(Plan.subject(in: "IT Projekt", bk) ?? "-") \(Plan.subject(in: "mit dem Hund", bk) ?? "-")", "Mathematik IT -")
let gr = [Plan.Grade(subject: "IT", value: 12, weight: 2), Plan.Grade(subject: "IT", value: 9)]
sc("Noten", "\(Plan.average(gr)!) \(Plan.needed(gr, goal: 12, weight: 1)) \(Plan.note(fromPoints: 11)) \(Plan.average([]) == nil) \(Plan.gradeValue("2+", false)!) \(Plan.gradeValue("16", true) == nil) \(Plan.gradeValue("1-", false)!) \(Plan.gradeValue("x", true) == nil)", "11.0 15.0 2.0 true 1.75 true 1.25 true")
// schriftlich 12 (×2) und 9 → 11; mündlich 6 → 60:40 = 9,0; 2:1 ohne mündlich = 11
let go = gr + [Plan.Grade(subject: "IT", value: 6, oral: true)]
let nd = Plan.needed(go, goal: 10, weight: 1, oral: true, written: 0.6)
sc("Noten mündlich", "\(Plan.average(go, written: 0.6)!) \(Plan.average(gr, written: 0.6)!) \(Plan.mean(go)!) \(abs(Plan.average(go + [Plan.Grade(value: nd, oral: true)], written: 0.6)! - 10) < 1e-9) \((nd * 100).rounded() / 100)", "9.0 11.0 9.75 true 11.0")
var bsub = Plan.Book(); bsub.grades = go; bsub.subjects = [Plan.Subject(name: "IT", written: 60), Plan.Subject(name: "Kunst")]
sc("Fächer", "\(Plan.average(bsub, "IT")!) \(Plan.written(bsub, "Kunst")) \(Plan.subjects(bsub)) \(Plan.overall(bsub)!)", "9.0 0.5 [\"IT\", \"Kunst\"] 9.0")
let ujs = #"[{"date":20261123,"startTime":745,"endTime":830,"su":[{"name":"M","longname":"Mathematik"}],"ro":[{"name":"A1"}]},{"date":20261124,"startTime":800,"endTime":845,"su":[{"name":"D","longname":""}],"code":"cancelled"},{"date":20261125,"startTime":800,"endTime":745,"su":[{"name":"X"}]},{"date":20261130,"startTime":745,"endTime":830,"su":[{"name":"M","longname":"Mathematik"}],"ro":[{"name":"A1"}]},{"date":20261201,"startTime":800,"endTime":845,"su":[{"name":"D"}]},{"date":20261207,"startTime":745,"endTime":830,"su":[{"name":"M","longname":"Mathematik"}],"ro":[{"name":"A1"}]},{"date":20261209,"startTime":900,"endTime":945,"su":[{"name":"Ph"}]},{"date":20261223,"startTime":900,"endTime":945,"su":[{"name":"Ph"}]}]"#
let ud = Plan.untis(try! JSONDecoder().decode([Plan.UPeriod].self, from: Data(ujs.utf8)))
sc("WebUntis", "\(ud.count) \(ud[0].subject) \(ud[0].room) \(ud[1].off == true) \(Plan.untisDay(ud[0].date!)) \(Plan.regular(ud).map { "\($0.subject)\($0.day)w\($0.week)" })", "7 Mathematik A1 true 20261123 [\"Mathematik2w0\", \"Ph4w2\"]")
var bu = Plan.Book(); bu.dated = ud; bu.datedFrom = ActLogic.cal.date(from: DateComponents(year: 2026, month: 11, day: 23)); bu.datedTo = ActLogic.cal.date(from: DateComponents(year: 2026, month: 12, day: 21))
let tue = ActLogic.cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9))!
sc("WebUntis Tag", "\(Plan.lessons(bu, on: tue).count) \(Plan.day(bu, tue).count) \(Plan.lessons(bu, on: ActLogic.cal.date(from: DateComponents(year: 2026, month: 12, day: 23))!).count)", "0 1 0")
let old = try! JSONDecoder().decode(Plan.Book.self, from: Data(#"{"lessons":[{"id":"\#(UUID())","day":2,"start":455,"end":500,"subject":"M","room":"","week":0}],"grades":[{"id":"\#(UUID())","subject":"M","value":2,"weight":1,"name":"","date":0}]}"#.utf8))
sc("Alte Datei", "\(old.lessons.count) \(old.grades.count) \(old.grades[0].isOral) \(old.untis == nil)", "1 1 false true")
var kc = Plan.Card(front: "a", back: "b"); kc = Plan.answer(kc, right: true, now: mi); let k2 = Plan.answer(kc, right: false, now: mi)
sc("Lernkarte", "\(kc.box) \(kc.due > mi) \(k2.box) \(k2.due <= mi) \(Plan.due(Plan.Deck(cards: [kc, k2]), mi).count)", "1 true 0 true 1")
sc("Karten einfügen", "\(Plan.cards("a | b\nc\td e\nf;g\nleer\n|x").map { $0.front + "=" + $0.back })", "[\"a=b\", \"c=d e\", \"f=g\"]")
sc("Uhrzeit", "\(Plan.minutes("7:35")!) \(Plan.minutes("13")!) \(Plan.minutes("25:00") == nil) \(Plan.clock(455))", "455 780 true 7:35")
let half = try JSONDecoder().decode(Plan.Book.self, from: Data(#"{"lessons":[{"kaputt":1}],"points":false}"#.utf8)), full = try JSONDecoder().decode(Plan.Book.self, from: JSONEncoder().encode(bk))
sc("Alte oder kaputte Daten", "\(half.points) \(half.lessons.count) \(full == bk)", "false 0 true")

func ev(_ d: String, _ a: String, _ b: String, _ s: String, _ x: String = "") -> String { "BEGIN:VEVENT\r\nDTSTART;TZID=Europe/Berlin:\(d)T\(a)00\r\nDTEND;TZID=Europe/Berlin:\(d)T\(b)00\r\nSUMMARY:\(s)\r\nLOCATION:A1\r\n\(x)END:VEVENT\r\n" }
let icsText = ["20261102", "20261109", "20261116", "20261123"].map { ev($0, "0735", "0820", "Mathe") }.joined() + ["20261103", "20261117"].map { ev($0, "0800", "0845", "Kunst\r\n  AG") }.joined() + ev("20261104", "0800", "0845", "Vertretung") + ev("20261105", "0800", "0845", "Weg", "STATUS:CANCELLED\r\n") + "BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261106\nDTEND;VALUE=DATE:20261107\nSUMMARY:Ferien\nEND:VEVENT\n" + ev("20261106", "0900", "0945", "Sport", "RRULE:FREQ=WEEKLY;COUNT=20\r\n")
sc("Kalenderdatei", "\(Plan.ics(icsText).map { "\($0.day) \(Plan.clock($0.start)) \($0.subject) \($0.week)" }) \(Plan.ics("Unsinn").count)", "[\"2 7:35 Mathe 0\", \"3 8:00 Kunst AG 1\", \"6 9:00 Sport 0\"] 0")

// Scannen
let sq = ScanQuad(tl: CGPoint(x: 0.3, y: 0.1), tr: CGPoint(x: 0.7, y: 0.1), br: CGPoint(x: 0.7, y: 0.9), bl: CGPoint(x: 0.3, y: 0.9))
let sq2 = ScanQuad(tl: CGPoint(x: 0.3, y: 0.2), tr: CGPoint(x: 0.7, y: 0.2), br: CGPoint(x: 0.7, y: 0.999), bl: CGPoint(x: 0.3, y: 0.999))
sc("Scan Hinweis", "\(ScanLogic.hint(nil, previous: nil)) \(ScanLogic.hint(sq, previous: sq)) \(ScanLogic.hint(sq2, previous: nil)) \(ScanLogic.hint(sq, previous: sq2)) \((sq.area * 100).rounded())", "empty hold cutNear moving 32.0")
sc("Scan Blatt-Inneres", "\(sq.contains(CGPoint(x: 0.5, y: 0.5))) \(sq.contains(CGPoint(x: 0.2, y: 0.5))) \(sq.inset(0.15).contains(CGPoint(x: 0.31, y: 0.5))) \(ScanLogic.hint(ScanQuad(tl: CGPoint(x: 0, y: 0.1), tr: CGPoint(x: 0.5, y: 0.1), br: CGPoint(x: 0.5, y: 0.9), bl: CGPoint(x: 0, y: 0.9)), previous: nil))", "true false false cutLeft")
sc("Scan Drehung", "\(ScanLogic.orientation(degrees: 2).rawValue) \(ScanLogic.orientation(degrees: -177).rawValue) \(ScanLogic.orientation(degrees: 92).rawValue) \(ScanLogic.orientation(degrees: -87).rawValue) \(ScanLogic.orientation(degrees: 181).rawValue)", "1 3 6 8 3")
sc("Scan Auflösung", "\(ScanLogic.pixels(ScanLogic.Paper(kind: .a4, size: CGSize(width: 595, height: 842)), source: CGSize(width: 1200, height: 1700))) \(ScanLogic.pixels(ScanLogic.Paper(kind: .a4, size: CGSize(width: 595, height: 842)), source: CGSize(width: 3000, height: 4000)))", "(1201.0, 1700.0) (1653.0, 2339.0)")
sc("Scan Fortschritt", "\(ScanLogic.step(0.5, .hold, dt: 0.13)) \(ScanLogic.step(0.5, .moving, dt: 0.1)) \(ScanLogic.step(0.9, .empty, dt: 0.1)) \(ScanLogic.step(0.99, .hold, dt: 1))", "0.6083333333333334 0.42 0.0 1.0")
let sz = ScanLogic.sides(sq, image: CGSize(width: 1920, height: 1440))
sc("Scan Papier", "\(sz.width.rounded()) \(sz.height.rounded()) \(ScanLogic.paper(sz).kind) \(ScanLogic.paper(CGSize(width: 800, height: 1131)).size) \(ScanLogic.paper(CGSize(width: 1400, height: 1000)).size) \(ScanLogic.paper(CGSize(width: 500, height: 850)).kind) \(ScanLogic.pixels(ScanLogic.paper(CGSize(width: 800, height: 1131))))", "768.0 1152.0 a4 (595.0, 842.0) (842.0, 595.0) card (1653.0, 2339.0)")
sc("Scan KI-Zeile", "\(ScanLogic.guess("**Titel:** „Lyrik: Handwerkszeug“ | Arbeitsblatt | Deutsch")!) \(ScanLogic.guess("Rechnung | Rechnung | leer")!) \(ScanLogic.guess("keine Ahnung") == nil)", "(title: \"Lyrik: Handwerkszeug\", kind: \"Arbeitsblatt\", subject: \"Deutsch\") (title: \"Rechnung\", kind: \"Rechnung\", subject: \"\") true")
// Akku
let smp = [BatteryLogic.Sample(pid: 417, name: "WindowServer", cpu: 29.2, power: 38.9), BatteryLogic.Sample(pid: 501, name: "firefox", cpu: 10, power: 12.5), BatteryLogic.Sample(pid: 502, name: "plugin-container", cpu: 8, power: 9.5), BatteryLogic.Sample(pid: 600, name: "Microsoft OneNot", cpu: 21.2, power: 25.2)]
let paths: [Int32: String] = [501: "/Applications/Firefox.app/Contents/MacOS/firefox", 502: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container", 600: "/Applications/Microsoft OneNote.app/Contents/MacOS/Microsoft OneNote"]
let grp = BatteryLogic.group(smp, path: { paths[$0] })
sc("Akku messen", "\(smp.count) \(smp[3].name) \(grp.map { "\($0.name)=\($0.power)" }) \(grp[2].pids.count) \(BatteryLogic.worthThrottling(BatteryLogic.AppUse(id: "/A.app", name: "A", power: 400, cpu: 9, pids: [1]), front: false)) \(BatteryLogic.worthThrottling(grp[0], front: false)) \(BatteryLogic.level(1200)) \(BatteryLogic.watts(850)) \(BatteryLogic.watts(1234)) \(BatteryLogic.bundle(of: "/usr/libexec/x") == nil)", "4 Microsoft OneNot [\"WindowServer=38.9\", \"Microsoft OneNote=25.2\", \"Firefox=22.0\"] 2 true false 3 850 mW 1,2 W true")
sc("Akku Systemschutz", "\(BatteryLogic.AppUse(id: "/System/Library/CoreServices/Dock.app", name: "Dock", power: 0, cpu: 0, pids: []).isApp) \(BatteryLogic.AppUse(id: "/System/Applications/TextEdit.app", name: "TextEdit", power: 0, cpu: 0, pids: []).isApp)", "false true")
// Handschrift
func hbmp(_ w: Int, _ h: Int, _ on: (Int, Int) -> Bool) -> [UInt8] { (0..<(w * h)).map { on($0 % w, $0 / w) ? 1 : 0 } }
let bL = hbmp(30, 40) { x, y in (x >= 5 && x <= 8 && y >= 5 && y <= 34) || (y >= 31 && y <= 34 && x >= 5 && x <= 25) }
let gL = HandLogic.glyph(bL, 30, 40, baseline: 34, em: 30)!
let bO = hbmp(40, 40) { x, y in let d = hypot(Double(x) - 20, Double(y) - 20); return d >= 10 && d <= 14 }
let gO = HandLogic.glyph(bO, 40, 40, baseline: 34, em: 30)!
let bT = hbmp(40, 40) { x, y in (y >= 5 && y <= 8 && x >= 5 && x <= 34) || (x >= 18 && x <= 21 && y >= 5 && y <= 34) }
let gT = HandLogic.glyph(bT, 40, 40, baseline: 34, em: 30)!
let lLen = gL.glyph.strokes.flatMap { s in zip(s, s.dropFirst()).map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) } }.reduce(0, +)
sc("Handschrift Striche", "\(gL.glyph.strokes.count) \(lLen > 1.2 && lLen < 1.8) \(gO.glyph.strokes.count) \(gT.glyph.strokes.count <= 2) \(gL.pen > 0.05 && gL.pen < 0.25) \(HandLogic.glyph([UInt8](repeating: 0, count: 100), 10, 10, baseline: 8, em: 8) == nil)", "1 true 1 true true true")
var hf = HandLogic.Font(); hf.glyphs = ["a": [gO.glyph], "b": [gL.glyph], "T": [gT.glyph]]
let lay1 = HandLogic.layout("Ta ba", hf, in: CGRect(x: 0, y: 0, width: 200, height: 40), size: 10), lay2 = HandLogic.layout("Ta ba", hf, in: CGRect(x: 0, y: 0, width: 200, height: 40), size: 10)
let small = HandLogic.layout("ab ab ab ab ab ab", hf, in: CGRect(x: 0, y: 0, width: 30, height: 15), size: 10)
sc("Handschrift Setzen", "\(lay1.strokes == lay2.strokes) \(lay1.fits) \(small.fits) \(HandLogic.fit("ab ab ab ab ab ab", hf, in: CGRect(x: 0, y: 0, width: 30, height: 15)) < 10) \(HandLogic.pick("ä", hf) != nil) \(HandLogic.pick("Ä", hf) != nil) \(HandLogic.slots.count) \(HandLogic.box(HandLogic.slots.count - 1).maxY < 800)", "true true false true true true 170 true")
sc("Glätten", "\(HandLogic.simplify((0...10).map { CGPoint(x: CGFloat($0), y: 0) }, 0.5).count) \(HandLogic.smooth([CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 4)]).count)", "2 6")
sc("Tagesüberblick", "\(["Was steht heute an?", "Wie sieht mein Tag aus", "was muss ich morgen alles", "Gib mir einen Überblick"].map(ActLogic.isBriefing)) \(["Habe ich morgen einen Termin beim Zahnarzt?", "Trag Training morgen ein", "Mathe Hausaufgabe bis Freitag"].map(ActLogic.isBriefing))", "[true, true, true, true] [false, false, false]")
sc("Überblick zugeordnet", "\(["Gib mir einen Überblick", "was muss ich morgen alles", "Was steht heute an?"].map { ActLogic.candidates($0).contains(.calendar) })", "[true, true, true]")
sc("Formeln", "\(TidyLogic.inline("29^(2) = 841", formula: true)) | \(TidyLogic.inline("x_1 <= 2*pi", formula: true)) | \(TidyLogic.inline("sqrt(a^2 + b^2)", formula: true)) | \(TidyLogic.inline("**Satz** des Pythagoras", formula: false))", "29<sup>2</sup> = 841 | x<sub>1</sub> ≤ 2 · π | √<span style=\"text-decoration:overline\">a<sup>2</sup> + b<sup>2</sup></span> | <b>Satz</b> des Pythagoras")
sc("Formelzeile", "\([ "29^2 = 841", "f(x) = 2x + 3", "Fläche = a * b", "Die Summe ist 5 = 5", "Hausaufgabe bis Freitag"].map(TidyLogic.isFormula))", "[true, true, true, false, false]")
sc("Schön Klartext", TidyLogic.plain("# Potenzen\n- 29^(2) = 841\n  - a_1 * a_2\n1. x^(1/2)\n2. zwei"), "Potenzen\n• 29² = 841\n\t• a₁ · a₂\n1. x^(1/2)\n2. zwei")
let th = TidyLogic.html("# T\n- a\n  - b\n- c\n1. d\nText")
sc("Schön HTML", "\(th.contains("<ul><li>a</li><ul><li>b</li></ul><li>c</li></ul><ol><li>d</li></ol>")) \(th.contains("<h1")) \(TidyLogic.html("a < b & c").contains("a &lt; b &amp; c"))", "true true true")
sc("Schön Stücke", "\(TidyLogic.chunks(String(repeating: "Wort ", count: 400) + "\n\n" + String(repeating: "Satz ", count: 400), max: 2500).count) \(TidyLogic.kept("Ein langer Text mit vielen Wörtern und Zahlen 1 2 3", "kurz")) \(TidyLogic.clean("Hier ist der Text:\n```\n# A\n```"))", "2 false # A")
sc("Schön Ebenen", "\(TidyLogic.parse("- a\n\n    - b\n\n- c").map { "\($0.level)" }.joined()) \(TidyLogic.plain("a^m * a^-n"))", "010 aᵐ · a⁻ⁿ")
sc("Delta", TidyLogic.inline("a = delta v / delta t", formula: true), "a = Δv / Δt")
sc("Tafel-Zeilen", TidyLogic.lines([("Unterpunkt", 0.15, 0.7, 0.05), ("Titel", 0.1, 0.9, 0.05), ("rechts", 0.5, 0.905, 0.05)]), "Titel  rechts\n  Unterpunkt")
sc("Riesige Eingabe", "\(Calc.evaluate(String(repeating: "-", count: 300_000) + "1") == nil) \(Calc.evaluate("--2+3") ?? 0)", "true 5.0")
print(failed == 0 ? "\nAlle Tests bestanden" : "\n\(failed) Test(s) fehlgeschlagen")
if failed > 0 { fatalError() }
