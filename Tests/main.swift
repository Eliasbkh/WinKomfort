// Tests: swiftc TapDragLogic.swift Calc.swift Shortcut.swift SnapMath.swift OneNoteOrder.swift TimeParse.swift Tests/main.swift -o /tmp/wktest && /tmp/wktest
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

print(failed == 0 ? "\nAlle Tests bestanden" : "\n\(failed) Test(s) fehlgeschlagen")
if failed > 0 { fatalError() }
