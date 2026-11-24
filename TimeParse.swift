import Foundation

// Zeitangaben aus normalen Sätzen („zwei Stunden“, „1,5 h“, „half an hour“) – reine Logik, damit testbar.
enum TimeParse {
    static func minutes(in text: String) -> Int? {
        let words = ["eine": 1, "einen": 1, "ein": 1, "one": 1, "a": 1, "an": 1, "zwei": 2, "two": 2, "drei": 3, "three": 3, "vier": 4, "four": 4,
                     "fünf": 5, "five": 5, "sechs": 6, "six": 6, "zehn": 10, "ten": 10, "zwanzig": 20, "twenty": 20, "dreißig": 30, "thirty": 30]
        let t = text.lowercased()
        if t.contains("halbe stunde") || t.contains("half an hour") || t.contains("half hour") { return 30 }
        let re = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?|[a-zäöüß]+)\s*(minuten|minute|min|stunden|stunde|std|h|hours|hour|minutes)\b"#)
        guard let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let nr = Range(m.range(at: 1), in: t), let ur = Range(m.range(at: 2), in: t) else { return nil }
        let n = Double(t[nr].replacingOccurrences(of: ",", with: ".")) ?? words[String(t[nr])].map(Double.init)
        guard let n else { return nil }
        let unit = t[ur]
        return Int((unit.hasPrefix("st") || unit.hasPrefix("h") ? n * 60 : n).rounded())
    }

}
