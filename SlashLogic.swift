// /Befehle der Suche: reine Umwandlungen, testbar
import Foundation

enum SlashLogic {
    // „/timer 5“ → („timer“, „5“); nil, wenn es kein /Befehl ist
    static func split(_ q: String) -> (name: String, arg: String)? {
        guard q.hasPrefix("/") else { return nil }
        let p = q.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (p.first?.lowercased() ?? "", p.count > 1 ? p[1].trimmingCharacters(in: .whitespaces) : "")
    }
    // Sichere Zufallszeichen, ohne verwechselbare (0/O, 1/l/I); mindestens je ein Buchstabe groß/klein, Ziffer, Zeichen
    static func password(_ n: Int) -> String {
        let sets = ["abcdefghijkmnpqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ", "23456789", "!#%+-=?@_"].map(Array.init)
        var g = SystemRandomNumberGenerator()
        let n = min(max(n, 8), 128)
        var c = sets.map { $0.randomElement(using: &g)! }
        let all = sets.flatMap { $0 }
        while c.count < n { c.append(all.randomElement(using: &g)!) }
        return String(c.shuffled(using: &g))
    }
    static func color(_ s: String) -> (hex: String, rgb: String, hsl: String)? {
        var h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, h.allSatisfy(\.isHexDigit), let v = Int(h, radix: 16) else { return nil }
        let r = Double(v >> 16), g = Double(v >> 8 & 255), b = Double(v & 255)
        let hi = max(r, g, b) / 255, lo = min(r, g, b) / 255, d = hi - lo, l = (hi + lo) / 2
        let sat = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var hue = 0.0
        if d > 0 {
            if hi * 255 == r { hue = ((g - b) / 255 / d).truncatingRemainder(dividingBy: 6) } else if hi * 255 == g { hue = (b - r) / 255 / d + 2 } else { hue = (r - g) / 255 / d + 4 }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        return ("#" + h.uppercased(), "rgb(\(Int(r)), \(Int(g)), \(Int(b)))", "hsl(\(Int(hue.rounded())), \(Int((sat * 100).rounded()))%, \(Int((l * 100).rounded()))%)")
    }
    static func count(_ s: String) -> (chars: Int, words: Int, lines: Int) {
        (s.count, s.split { $0.isWhitespace }.count, s.isEmpty ? 0 : s.components(separatedBy: .newlines).count)
    }
    static func json(_ s: String) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
    // „1-100“, „6“ → Zufallszahl im Bereich
    static func range(_ s: String) -> ClosedRange<Int>? {
        let n = s.split { !$0.isNumber }.compactMap { Int($0) }
        if n.isEmpty { return s.isEmpty ? 1...100 : nil }
        let a = n.count > 1 ? n[0] : 1, b = n.count > 1 ? n[1] : n[0]
        return a <= b ? a...b : nil
    }
    // „24.12.“, „24.12.2027“ → Tage ab heute (ohne Jahr: das nächste Mal)
    static func days(_ s: String, today: Date, cal: Calendar = .current) -> Int? {
        let n = s.split { !$0.isNumber }.compactMap { Int($0) }
        guard n.count >= 2, (1...31).contains(n[0]), (1...12).contains(n[1]) else { return nil }
        let t = cal.startOfDay(for: today)
        func date(_ y: Int) -> Date? {
            guard let d = cal.date(from: DateComponents(year: y, month: n[1], day: n[0])), cal.component(.day, from: d) == n[0] else { return nil }
            return d
        }
        let y = cal.component(.year, from: t)
        if n.count > 2 { return date(n[2] < 100 ? 2000 + n[2] : n[2]).flatMap { cal.dateComponents([.day], from: t, to: $0).day } }
        for k in 0...8 { if let d = date(y + k), d >= t { return cal.dateComponents([.day], from: t, to: d).day } } // 29.2.
        return nil
    }
}
