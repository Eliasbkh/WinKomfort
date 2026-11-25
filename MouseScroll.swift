// Maus wie unter Windows: eigene Scrollrichtung für die Maus (Trackpad bleibt „natürlich“) und schnelleres Scrollen.
// macOS kennt nur eine Richtung für beides. WinKomfort dreht nur Mausrad-Ereignisse um (Trackpad-Gesten sind „continuous“).
import AppKit

enum MouseScroll {
    private static var tap: CFMachPort?
    static var reverse: Bool { UserDefaults.standard.bool(forKey: "mouseReverse") }
    static var speed: Double { UserDefaults.standard.object(forKey: "mouseSpeed") as? Double ?? 1 }
    static var needed: Bool { reverse || abs(speed - 1) > 0.01 }

    // Aufrufen beim Start und bei jeder Änderung der Einstellungen
    static func update(prompt: Bool = false) {
        if !needed { stop(); return }
        guard tap == nil else { return }
        afterTrust(prompt: prompt) { if needed { start() } }
    }

    private static func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, e, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = MouseScroll.tap { CGEvent.tapEnable(tap: t, enable: true) } // macOS schaltet Taps nach Hängern ab – wieder an
                return Unmanaged.passUnretained(e)
            }
            // Trackpad und Magic Mouse liefern „continuous“-Ereignisse – die bleiben unverändert
            guard e.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return Unmanaged.passUnretained(e) }
            let k = (MouseScroll.reverse ? -1.0 : 1.0) * MouseScroll.speed
            for (line, fixed, point) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1),
                                         (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)] {
                let l = e.getIntegerValueField(line)
                guard l != 0 || e.getDoubleValueField(fixed) != 0 else { continue }
                // Mindestens eine Zeile, damit langsame Stufen nicht „verschluckt“ werden
                let nl = Int64((Double(l) * k).rounded(.awayFromZero))
                e.setIntegerValueField(line, value: l == 0 ? 0 : (nl == 0 ? (k < 0 ? -l.signum() : l.signum()) : nl))
                e.setDoubleValueField(fixed, value: e.getDoubleValueField(fixed) * k)
                e.setIntegerValueField(point, value: Int64((Double(e.getIntegerValueField(point)) * k).rounded()))
            }
            return Unmanaged.passUnretained(e)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    static func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
    }
}

import SwiftUI

// Einstellungen (Seite „Eingabe“): Richtung und Tempo nur für die Maus, dazu die Systemanzeige in der Menüleiste
struct MouseSettings: View {
    @AppStorage("mouseReverse") private var reverse = false
    @AppStorage("mouseSpeed") private var speed = 1.0
    @AppStorage("sysMonitor") private var monitor = false
    var body: some View {
        Toggle(isOn: $reverse) {
            Text(L("Maus scrollt wie unter Windows", "Mouse scrolls like Windows"))
            Text(L("Nur die Maus scrollt umgekehrt – das Trackpad bleibt „natürlich“.", "Only the mouse scrolls the other way – the trackpad stays “natural”."))
        }
        .onChange(of: reverse) { _, _ in MouseScroll.update(prompt: true) }
        LabeledContent(L("Scrolltempo der Maus", "Mouse scroll speed")) {
            HStack {
                Slider(value: $speed, in: 0.5...4, step: 0.5) { Text(L("Scrolltempo der Maus", "Mouse scroll speed")) }.labelsHidden().frame(width: 160)
                Text(speed == 1 ? L("normal", "normal") : String(format: "%.1f×", speed)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
        .onChange(of: speed) { _, _ in MouseScroll.update(prompt: true) }
        ExtraToggle(key: "mouseBack", title: L("Maustasten vor und zurück", "Mouse back and forward buttons"), hint: L("Auch in Safari, Finder und Explorer.", "Also in Safari, Finder and Explorer."))
        ExtraToggle(key: "quitGuard", title: L("⌘Q nur doppelt", "Press ⌘Q twice to quit"), hint: L("Schützt davor, eine App aus Versehen zu beenden.", "Prevents quitting an app by accident."))
        Toggle(isOn: $monitor) {
            Text(L("CPU und Speicher in der Menüleiste", "CPU and memory in the menu bar"))
            Text(L("Wie iStat/Stats – klicken öffnet den Task-Manager. Misst alle 3 s, kaum Energiebedarf.", "Like iStat/Stats – click opens Task Manager. Measures every 3 s, negligible energy use."))
        }
        .onChange(of: monitor) { _, _ in SystemMonitor.shared.update() }
    }
}
