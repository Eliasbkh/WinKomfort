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
sc("Datenstrom", "\(AILogic.delta("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}")!.text) \(AILogic.delta("data: [DONE]")!.done) \(AILogic.delta(": ping") == nil) \(AILogic.delta("data: kaputt") == nil)", "Hi true true true")
sc("Serveradresse", "\(AILogic.serverURL("http://127.0.0.1:11434/v1/")!) \(AILogic.serverURL("http://boese.de/v1") == nil) \(AILogic.serverURL("https://api.x.de/v1") != nil) \(AILogic.serverURL("http://localhost.boese.de") == nil)", "http://127.0.0.1:11434/v1 true true true")
sc("Denken weg", AILogic.withoutThinking("<think>hm</think>Ja") + AILogic.withoutThinking("A<think>hm"), "JaA")
sc("Office", AILogic.xmlText("<a:p><a:t>A &amp; B</a:t></a:p><a:p>C</a:p>"), "A & B\nC\n")

print(failed == 0 ? "\nAlle Tests bestanden" : "\n\(failed) Test(s) fehlgeschlagen")
if failed > 0 { fatalError() }
