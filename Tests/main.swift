// Test der Ziehen-Erkennung: swiftc TapDragLogic.swift Tests/main.swift -o /tmp/tapdragtest && /tmp/tapdragtest
typealias A = TapDragLogic.Action

// Spielt eine Folge von (Finger, Zeit)-Frames ab, Frames alle 10 ms solange Finger liegen
func run(_ steps: [(fingers: Int, from: Double, to: Double)]) -> [A] {
    var l = TapDragLogic(), out: [A] = []
    for s in steps {
        if s.fingers == 0 { out.append(l.frame(fingers: 0, time: s.from)); continue }
        var t = s.from
        while t <= s.to { let a = l.frame(fingers: s.fingers, time: t); if a != .none { out.append(a) }; t += 0.01 }
    }
    return out.filter { $0 != .none }
}

var failed = 0
func check(_ name: String, _ got: [A], _ want: [A]) {
    let ok = got == want
    if !ok { failed += 1 }
    print(ok ? "✅" : "❌", name, ok ? "" : "→ bekam \(got), erwartet \(want)")
}

check("Tippen, Tippen-halten-ziehen, abheben → drücken, loslassen",
      run([(1, 0, 0.1), (0, 0.1, 0), (1, 0.3, 1.5), (0, 1.5, 0)]), [.press, .release])
check("Loslassen kommt sofort beim Abheben (nicht erst später)",
      { var l = TapDragLogic(); _ = l.frame(fingers: 1, time: 0); _ = l.frame(fingers: 0, time: 0.1)
        _ = l.frame(fingers: 1, time: 0.3); _ = l.frame(fingers: 1, time: 0.5); return [l.frame(fingers: 0, time: 0.51)] }(), [.release])
check("Doppeltippen ohne Halten → kein Ziehen (normaler Doppelklick)",
      run([(1, 0, 0.1), (0, 0.1, 0), (1, 0.3, 0.38), (0, 0.38, 0)]), [])
check("Einmal tippen und dann lange liegen lassen → kein Ziehen",
      run([(1, 0, 2.0), (0, 2.0, 0)]), [])
check("Zweite Berührung zu spät → kein Ziehen",
      run([(1, 0, 0.1), (0, 0.1, 0), (1, 0.6, 1.5), (0, 1.5, 0)]), [])
check("Erstes „Tippen“ zu lang (Klicken-halten) → kein Ziehen",
      run([(1, 0, 0.5), (0, 0.5, 0), (1, 0.6, 1.5), (0, 1.5, 0)]), [])
check("Zwei Finger (Scrollen) nach Tippen → kein Ziehen",
      run([(1, 0, 0.1), (0, 0.1, 0), (2, 0.3, 1.5), (0, 1.5, 0)]), [])
check("Zweiter Finger kommt beim Ziehen dazu → Ziehen läuft weiter bis alle weg",
      run([(1, 0, 0.1), (0, 0.1, 0), (1, 0.3, 0.6), (2, 0.6, 1.0), (1, 1.0, 1.2), (0, 1.2, 0)]), [.press, .release])
check("Zweimal hintereinander ziehen",
      run([(1, 0, 0.1), (0, 0.1, 0), (1, 0.3, 1.0), (0, 1.0, 0), (1, 2.0, 2.1), (0, 2.1, 0), (1, 2.3, 3.0), (0, 3.0, 0)]),
      [.press, .release, .press, .release])
check("Nach dem Ziehen startet ein einzelnes Tippen kein neues Ziehen",
      run([(1, 0, 0.1), (0, 0.1, 0), (1, 0.3, 1.0), (0, 1.0, 0), (1, 1.1, 1.5), (0, 1.5, 0)]), [.press, .release])

print(failed == 0 ? "\nAlle Tests bestanden" : "\n\(failed) Test(s) fehlgeschlagen")
if failed > 0 { fatalError() }
