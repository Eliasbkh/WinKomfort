// Akku: Energieverbrauch messen und je App zusammenfassen – ohne AppKit, testbar
import Foundation

enum BatteryLogic {
    struct Sample: Equatable { let pid: Int32; let name: String; let cpu: Double; let power: Double } // power in Milliwatt
    struct AppUse: Identifiable, Equatable {
        let id: String          // Pfad des App-Pakets, sonst der Prozessname
        let name: String
        var power: Double, cpu: Double
        var pids: [Int32]
        var isApp: Bool { id.hasSuffix(".app") && !id.hasPrefix("/System/Library/") } // Teile von macOS (Dock, WindowManager …) nie anfassen
    }

    // „/Applications/Firefox.app/Contents/MacOS/plugin-container.app/…“ → äußerstes App-Paket
    static func bundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
    // Hilfsprozesse (Tabs, Renderer) zählen zur App
    static func group(_ s: [Sample], path: (Int32) -> String?) -> [AppUse] {
        var out: [String: AppUse] = [:]
        for x in s where x.power > 0 || x.cpu > 0 {
            let b = path(x.pid).flatMap(bundle)
            let key = b ?? x.name
            let name = b.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? x.name
            out[key, default: AppUse(id: key, name: name, power: 0, cpu: 0, pids: [])].power += x.power
            out[key]!.cpu += x.cpu
            out[key]!.pids.append(x.pid)
        }
        return out.values.sorted { $0.power > $1.power }
    }
    // Lohnt sich Drosseln? Nur echte Apps im Hintergrund mit spürbarem Verbrauch
    static func worthThrottling(_ a: AppUse, front: Bool) -> Bool { a.isApp && !front && a.power >= 40 }
    // Milliwatt grob einordnen: ab 1 W viel, ab 300 mW spürbar
    static func level(_ p: Double) -> Int { p >= 1000 ? 3 : p >= 300 ? 2 : p >= 50 ? 1 : 0 }
    static func watts(_ mw: Double) -> String { mw < 1 ? "0 mW" : mw < 1000 ? "\(Int(mw.rounded())) mW" : String(format: "%.1f W", mw / 1000).replacingOccurrences(of: ".", with: ",") }
}
