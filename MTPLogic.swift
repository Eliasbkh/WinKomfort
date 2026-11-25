// MTP (Dateiübertragung mit Android-Handys): Protokoll ohne USB – dadurch ohne Handy testbar
import Foundation

protocol MTPLink: AnyObject {
    var packet: Int { get } // Paketlänge des Ausgangs
    func write(_ d: Data) throws
    func read(timeout: TimeInterval) throws -> Data // eine Übertragung, höchstens `MTPSession.chunk` Byte
}

enum MTPError: Error, Equatable {
    case response(UInt16), broken, tooBig, cancelled
}

struct MTPObject: Equatable {
    var handle: UInt32, storage: UInt32, isDir: Bool, size: Int64, name: String, modified: Date?
}

final class MTPSession {
    static let chunk = 1 << 19, root: UInt32 = 0xFFFF_FFFF
    private let link: MTPLink
    private var tid: UInt32 = 0
    init(_ l: MTPLink) { link = l }

    // MARK: Bytes
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 255), UInt8(v >> 8)]) }
    static func str(_ s: String) -> Data {
        let u = Array(s.utf16.prefix(254))
        return u.isEmpty ? Data([0]) : Data([UInt8(u.count + 1)]) + u.reduce(into: Data()) { $0 += le16($1) } + Data([0, 0])
    }
    // Daten kommen vom Gerät: nie über das Ende hinaus lesen
    struct Cursor {
        let d: [UInt8]; var i = 0
        init(_ x: Data) { d = [UInt8](x) }
        mutating func int(_ n: Int) throws -> UInt64 {
            guard i + n <= d.count else { throw MTPError.broken }
            defer { i += n }
            return (0..<n).reduce(0) { $0 | UInt64(d[i + $1]) << UInt64($1 * 8) }
        }
        mutating func u16() throws -> UInt16 { UInt16(try int(2)) }
        mutating func u32() throws -> UInt32 { UInt32(try int(4)) }
        mutating func str() throws -> String {
            let n = Int(try int(1))
            let u = try (0..<n).map { _ in try u16() }
            return String(decoding: u.prefix { $0 != 0 }, as: UTF16.self)
        }
        mutating func list() throws -> [UInt32] {
            let n = Int(try u32())
            guard n <= (d.count - i) / 4 else { throw MTPError.broken }
            return try (0..<n).map { _ in try u32() }
        }
    }

    // MARK: Ein Auftrag: Befehl → (Daten) → Antwort
    @discardableResult
    func run(_ code: UInt16, _ p: [UInt32] = [], timeout: TimeInterval = 15, sink: ((Data) throws -> Void)? = nil,
             source: (size: Int, next: (Int) throws -> Data)? = nil) throws -> (params: [UInt32], data: Data) {
        let id = tid; tid &+= 1
        try link.write(Self.le32(UInt32(12 + p.count * 4)) + Self.le16(1) + Self.le16(code) + Self.le32(id) + p.reduce(into: Data()) { $0 += Self.le32($1) })
        if let source {
            var left = source.size
            var out = Self.le32(UInt32(12 + left)) + Self.le16(2) + Self.le16(code) + Self.le32(id)
            while true {
                while left > 0, out.count < Self.chunk {
                    let d = try source.next(min(left, Self.chunk - out.count))
                    if d.isEmpty { throw MTPError.broken } // Datei wurde währenddessen kürzer
                    out += d; left -= d.count
                }
                try link.write(out)
                if left == 0 { break }
                out = Data()
            }
            if (12 + source.size) % link.packet == 0 { try link.write(Data()) } // Ende der Übertragung bei voller Paketlänge
        }
        var first = try readSome(timeout), data = Data()
        var c = Cursor(first.prefix(12))
        var len = try c.u32(), type = try c.u16()
        if type == 2 {
            var sinkError: Error?
            func take(_ d: Data) {
                if d.isEmpty { return }
                guard let sink else { data += d; return }
                if sinkError == nil { do { try sink(d) } catch { sinkError = error } } // trotzdem zu Ende lesen, sonst hängt das Handy
            }
            var rest = Data()
            if len == 0xFFFF_FFFF { // über 4 GB: Länge unbekannt, Ende = kurze Übertragung
                take(first.dropFirst(12))
                var n = first.count
                while n == Self.chunk { let d = try link.read(timeout: timeout); take(d); n = d.count }
            } else {
                guard len >= 12 else { throw MTPError.broken }
                var left = Int(len) - 12
                var d = first.dropFirst(12)
                while true {
                    take(d.prefix(left)); rest = Data(d.dropFirst(left)); left -= min(left, d.count)
                    if left == 0 { break }
                    d = try readSome(timeout)[...]
                }
            }
            first = rest.isEmpty ? try readSome(timeout) : rest
            c = Cursor(first); len = try c.u32(); type = try c.u16()
            if let sinkError { throw sinkError }
        }
        c = Cursor(first); _ = try c.u32(); _ = try c.u16()
        let r = try c.u16(); let rid = try c.u32()
        guard type == 3, rid == id || code == 0x1002 else { throw MTPError.broken }
        var out: [UInt32] = []
        while out.count < 5, let v = try? c.u32() { out.append(v) }
        guard r == 0x2001 else { throw MTPError.response(r) }
        return (out, data)
    }
    private func readSome(_ t: TimeInterval) throws -> Data {
        for _ in 0..<3 { let d = try link.read(timeout: t); if !d.isEmpty { return d } } // leere Übertragung = Ende der vorigen
        throw MTPError.broken
    }

    // MARK: Befehle
    func open() throws {
        tid = 0
        do { try run(0x1002, [1], timeout: 4) } catch MTPError.response(0x201E) {} // schon offen
        tid = 1
    }
    func close() { _ = try? run(0x1003, timeout: 2) }
    func deviceName() -> String? {
        func value(_ c: UInt16, _ p: [UInt32]) -> Data? { try? run(c, p).data }
        if let d = value(0x1015, [0xD402]) { var c = Cursor(d); if let s = try? c.str(), !s.isEmpty { return s } }
        return nil
    }
    func storages() throws -> [(id: UInt32, name: String, free: Int64)] {
        var c = Cursor(try run(0x1004).data)
        return try c.list().filter { $0 & 0xFFFF != 0 }.map { id in
            var i = Cursor(try run(0x1005, [id]).data)
            _ = try i.int(6); _ = try i.int(8)
            let free = Int64(clamping: try i.int(8)); _ = try i.u32()
            return (id, try i.str(), free)
        }
    }
    func handles(_ storage: UInt32, _ parent: UInt32) throws -> [UInt32] {
        var c = Cursor(try run(0x1007, [storage, 0, parent], timeout: 30).data)
        return try c.list()
    }
    func info(_ h: UInt32) throws -> MTPObject {
        var c = Cursor(try run(0x1008, [h]).data)
        let storage = try c.u32(), format = try c.u16(); _ = try c.u16()
        var size = Int64(try c.u32())
        c.i = 52
        let name = try c.str()
        _ = try c.str()
        let date = Self.date((try? c.str()) ?? "")
        if size == 0xFFFF_FFFF { var v = Cursor(try run(0x9803, [h, 0xDC04]).data); size = Int64(clamping: try v.int(8)) }
        return MTPObject(handle: h, storage: storage, isDir: format == 0x3001, size: size, name: Self.safe(name), modified: date)
    }
    func download(_ h: UInt32, sink: @escaping (Data) throws -> Void) throws { try run(0x1009, [h], timeout: 30, sink: sink) }
    // `next` liefert höchstens so viele Bytes wie verlangt
    @discardableResult
    func create(_ name: String, size: Int, folder: Bool, storage: UInt32, parent: UInt32, next: ((Int) throws -> Data)? = nil) throws -> UInt32 {
        guard size < 0xFFFF_FFFF - 12 else { throw MTPError.tooBig } // shortcut: Dateien über 4 GB zum Handy brauchen SendObjectPropList
        var ds = Self.le32(storage)
        ds += Self.le16(folder ? 0x3001 : 0x3000); ds += Self.le16(0); ds += Self.le32(UInt32(size)); ds += Data(count: 26)
        ds += Self.le32(parent == Self.root ? 0 : parent); ds += Self.le16(folder ? 1 : 0); ds += Data(count: 8)
        ds += Self.str(name); ds += Data([0, 0, 0])
        let body = ds
        var pos = 0
        let r = try run(0x100C, [storage, parent], source: (body.count, { n in defer { pos += n }; return body.subdata(in: pos..<pos + n) }))
        guard r.params.count > 2 else { throw MTPError.broken }
        if !folder { try run(0x100D, [], timeout: 60, source: (size, next ?? { _ in Data() })) }
        return r.params[2]
    }

    // Name vom Handy darf auf dem Mac keinen anderen Ordner treffen
    static func safe(_ s: String) -> String {
        let t = String(s.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "_" : $0 })
        return t.isEmpty || t == "." || t == ".." ? "_" : t
    }
    // „Foto.jpg“ → „Foto 2.jpg“, wenn der Name vergeben ist (Handy-Speicher unterscheidet Groß/Klein nicht)
    static func unique(_ name: String, taken: Set<String>) -> String {
        let t = Set(taken.map { $0.lowercased() })
        guard t.contains(name.lowercased()) else { return name }
        let e = (name as NSString).pathExtension, b = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let c = e.isEmpty ? "\(b) \(n)" : "\(b) \(n).\(e)"
            if !t.contains(c.lowercased()) { return c }
            n += 1
        }
    }
    static func date(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: String(s.prefix(15)))
    }
}
