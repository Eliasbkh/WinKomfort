// Weiterarbeiten bei zugeklapptem Deckel: macOS lässt das nur als Administrator zu (pmset disablesleep).
// Das Skript nimmt die Einstellung selbst zurück – nach Ablauf, bei „Beenden“, wenn WinKomfort weg ist oder der Akku fast leer ist.
import Foundation

enum LidScript {
    static let minBattery = 20

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func make(pid: Int32, seconds: Int?, stopFile: String, pmset: String = "/usr/bin/pmset", ioreg: String = "/usr/sbin/ioreg", poll: Int = 5) -> String {
        """
        restore() { \(pmset) -a disablesleep 0; if \(ioreg) -r -n IOPMrootDomain -d1 | grep -q '"AppleClamshellState" = Yes' && \(pmset) -g batt | grep -q "Battery Power"; then \(pmset) sleepnow; fi; }
        trap restore EXIT
        trap 'exit 0' TERM INT HUP
        \(pmset) -a disablesleep 1 || exit 1
        end=\(seconds.map { "$(( $(date +%s) + \($0) ))" } ?? "0")
        while kill -0 \(pid) 2>/dev/null && [ ! -e \(quote(stopFile)) ]; do
          if [ $end -ne 0 ] && [ $(date +%s) -ge $end ]; then break; fi
          b=$(\(pmset) -g batt)
          if echo "$b" | grep -q "Battery Power"; then
            p=$(echo "$b" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
            if [ -n "$p" ] && [ "$p" -le \(minBattery) ]; then break; fi
          fi
          sleep \(poll)
        done
        """
    }
}
