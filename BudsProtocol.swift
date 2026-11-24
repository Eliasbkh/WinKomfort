// Galaxy Buds: Nachrichtenformat des GEARMANAGER-Dienstes (an Buds4 Pro geprüft). Reine Logik → testbar.
// fd | Länge (10 Bit, inkl. Kennung und Prüfsumme) + Flags | Kennung | Daten | CRC-16 | dd
struct BudsStatus: Equatable { var left: Int?, right: Int?, box: Int?; var mode: Int? }

enum BudsProtocol {
    static func crc(_ d: [UInt8]) -> UInt16 {
        d.reduce(UInt16(0)) { c, b in
            (0..<8).reduce(c ^ UInt16(b) << 8) { x, _ in x & 0x8000 != 0 ? x << 1 ^ 0x1021 : x << 1 }
        }
    }
    static func message(_ id: UInt8, _ data: [UInt8]) -> [UInt8] {
        let body = [id] + data, c = crc(body), n = UInt16(body.count + 2)
        return [0xfd, UInt8(n & 0xff), UInt8(n >> 8)] + body + [UInt8(c & 0xff), UInt8(c >> 8), 0xdd]
    }
    // Ganze, unbeschädigte Nachrichten aus dem Strom holen; Rest bleibt im Puffer
    static func take(_ buf: inout [UInt8]) -> [(id: UInt8, data: [UInt8])] {
        var out: [(id: UInt8, data: [UInt8])] = []
        var i = 0, keep = 0 // keep: alles davor ist verarbeitet
        while i + 3 <= buf.count {
            let n = (Int(buf[i + 1]) | Int(buf[i + 2]) << 8) & 0x3ff, end = i + n + 4
            if buf[i] == 0xfd, n >= 3, end <= buf.count, buf[end - 1] == 0xdd {
                let body = Array(buf[(i + 3)..<(end - 3)])
                if crc(body) == UInt16(buf[end - 3]) | UInt16(buf[end - 2]) << 8 {
                    out.append((body[0], Array(body.dropFirst())))
                    i = end
                    keep = end
                    continue
                }
            }
            i += 1
        }
        buf.removeFirst(keep)
        if buf.count > 2048 { buf = [] }
        return out
    }
    private static func percent(_ b: UInt8) -> Int? { (1...100).contains(b) ? Int(b) : nil }
    static func apply(_ id: UInt8, _ d: [UInt8], to s: inout BudsStatus) {
        switch id {
        case 0x61 where d.count > 12: s = BudsStatus(left: percent(d[2]), right: percent(d[3]), box: percent(d[7]), mode: d[12] <= 3 ? Int(d[12]) : nil)
        case 0x77 where !d.isEmpty: if d[0] <= 3 { s.mode = Int(d[0]) }
        default: break
        }
    }
}
