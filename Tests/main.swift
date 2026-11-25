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

print(failed == 0 ? "\nAlle Tests bestanden" : "\n\(failed) Test(s) fehlgeschlagen")
if failed > 0 { fatalError() }
