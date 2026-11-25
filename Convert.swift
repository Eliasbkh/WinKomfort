// Einheiten umrechnen in der Suche: „10 km in mi“, „72 f to c“, „100 mb in gib“. Reine Logik → testbar, ohne Internet.
import Foundation

enum Convert {
    private static let units: [(Dimension, [String])] = [
        (UnitLength.millimeters, ["mm"]), (UnitLength.centimeters, ["cm"]), (UnitLength.meters, ["m", "meter"]), (UnitLength.kilometers, ["km", "kilometer"]),
        (UnitLength.inches, ["inch", "zoll", "\""]), (UnitLength.feet, ["ft", "fuß", "fuss", "feet"]), (UnitLength.yards, ["yd", "yard"]), (UnitLength.miles, ["mi", "meile", "meilen", "mile", "miles"]),
        (UnitMass.milligrams, ["mg"]), (UnitMass.grams, ["g", "gramm"]), (UnitMass.kilograms, ["kg", "kilo"]), (UnitMass.metricTons, ["t", "tonnen"]), (UnitMass.pounds, ["lb", "lbs", "pfund"]), (UnitMass.ounces, ["oz"]),
        (UnitTemperature.celsius, ["c", "°c", "celsius", "grad"]), (UnitTemperature.fahrenheit, ["f", "°f", "fahrenheit"]), (UnitTemperature.kelvin, ["k", "kelvin"]),
        (UnitDuration.seconds, ["s", "sek", "sec"]), (UnitDuration.minutes, ["min", "minuten", "minutes"]), (UnitDuration.hours, ["h", "std", "stunden", "hours"]),
        (UnitSpeed.kilometersPerHour, ["kmh", "km/h"]), (UnitSpeed.metersPerSecond, ["m/s"]), (UnitSpeed.milesPerHour, ["mph"]), (UnitSpeed.knots, ["kn", "knoten"]),
        (UnitVolume.milliliters, ["ml"]), (UnitVolume.liters, ["l", "liter"]), (UnitVolume.cups, ["cup", "cups"]), (UnitVolume.gallons, ["gal"]),
        (UnitArea.squareMeters, ["m2", "m²", "qm"]), (UnitArea.squareKilometers, ["km2", "km²"]), (UnitArea.hectares, ["ha"]), (UnitArea.acres, ["acre"]),
        (UnitEnergy.joules, ["j", "joule"]), (UnitEnergy.kilowattHours, ["kwh"]), (UnitEnergy.kilocalories, ["kcal"]), (UnitPower.watts, ["w", "watt"]), (UnitPower.horsepower, ["ps", "hp"]),
        (UnitInformationStorage.bytes, ["b", "byte", "bytes"]), (UnitInformationStorage.kilobytes, ["kb"]), (UnitInformationStorage.megabytes, ["mb"]), (UnitInformationStorage.gigabytes, ["gb"]),
        (UnitInformationStorage.terabytes, ["tb"]), (UnitInformationStorage.mebibytes, ["mib"]), (UnitInformationStorage.gibibytes, ["gib"]), (UnitAngle.degrees, ["deg", "°"]), (UnitAngle.radians, ["rad"]),
    ]
    private static func unit(_ s: String) -> Dimension? { units.first { $0.1.contains(s) }?.0 }

    static func evaluate(_ text: String) -> (value: Double, unit: String)? {
        let re = try! NSRegularExpression(pattern: #"^(-?\d+(?:[.,]\d+)?)\s*(\S+)\s+(?:in|to|nach|zu|=)\s+(\S+)$"#)
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> String { String(t[Range(m.range(at: i), in: t)!]) }
        guard let n = Double(g(1).replacingOccurrences(of: ",", with: ".")), let a = unit(g(2)), let b = unit(g(3)), type(of: a) == type(of: b) else { return nil }
        let v = Measurement(value: n, unit: a).converted(to: b).value
        return v.isFinite ? ((v * 10000).rounded() / 10000, b.symbol) : nil
    }
}
