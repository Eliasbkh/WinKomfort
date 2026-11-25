// Weiterarbeiten bei zugeklapptem Deckel: macOS lässt das nur als Administrator zu (pmset disablesleep, einmal freigegeben).
// Das Skript nimmt die Einstellung selbst zurück – nach Ablauf, bei „Beenden“, wenn WinKomfort weg ist oder der Akku fast leer ist.
import Foundation

enum LidScript {
    static let minBattery = 20

    // Einmalige Erlaubnis: genau diese zwei Befehle ohne Passwort, nur für diesen Benutzer
    static let rulePath = "/etc/sudoers.d/winkomfort-lid"
    static func install(uid: UInt32) -> String {
        let rule = "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        return "umask 077; t=$(/usr/bin/mktemp /private/tmp/winkomfort.XXXXXX) && /usr/bin/printf '%s\\n' " + quote(rule) + " > \"$t\" && /usr/sbin/visudo -cqf \"$t\" && /bin/mkdir -p /etc/sudoers.d && /usr/bin/install -o root -g wheel -m 0440 \"$t\" \(rulePath); r=$?; /bin/rm -f \"$t\"; exit $r"
    }
    static let remove = "/bin/rm -f \(rulePath)"

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func make(pid: Int32, seconds: Int?, stopFile: String, pmset: String = "/usr/bin/pmset", set: String = "/usr/bin/sudo -n /usr/bin/pmset", ioreg: String = "/usr/sbin/ioreg", poll: Int = 5) -> String {
        """
        restore() { \(set) -a disablesleep 0; if \(ioreg) -r -n IOPMrootDomain -d1 | grep -q '"AppleClamshellState" = Yes' && \(pmset) -g batt | grep -q "Battery Power"; then \(pmset) sleepnow; fi; }
        trap restore EXIT
        trap 'exit 0' TERM INT HUP
        \(set) -a disablesleep 1 || exit 1
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
