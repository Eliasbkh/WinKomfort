// Fernbedienung: Ende-zu-Ende-Verschlüsselung zwischen Handy-Browser und Mac (ChaCha20 + HMAC-SHA256).
// Der Schlüssel steht nur im QR-Code hinter „#“ und geht nie übers Netz. Jede Verbindung bekommt frische Sitzungsschlüssel.
import Foundation
import CryptoKit

enum RemoteCrypto {
    static func chacha(_ data: [UInt8], key: [UInt8], nonce: [UInt8], counter: UInt32 = 0) -> [UInt8] {
        func le(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
        var s: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
        for i in 0..<8 { s.append(le(key, i * 4)) }
        s.append(counter)
        for i in 0..<3 { s.append(le(nonce, i * 4)) }
        var out = data
        out.withUnsafeMutableBufferPointer { o in
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 16) { x in
                func q(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
                    x[a] = x[a] &+ x[b]; x[d] ^= x[a]; x[d] = x[d] << 16 | x[d] >> 16
                    x[c] = x[c] &+ x[d]; x[b] ^= x[c]; x[b] = x[b] << 12 | x[b] >> 20
                    x[a] = x[a] &+ x[b]; x[d] ^= x[a]; x[d] = x[d] << 8 | x[d] >> 24
                    x[c] = x[c] &+ x[d]; x[b] ^= x[c]; x[b] = x[b] << 7 | x[b] >> 25
                }
                var pos = 0
                while pos < o.count {
                    for i in 0..<16 { x[i] = s[i] }
                    for _ in 0..<10 {
                        q(0, 4, 8, 12); q(1, 5, 9, 13); q(2, 6, 10, 14); q(3, 7, 11, 15)
                        q(0, 5, 10, 15); q(1, 6, 11, 12); q(2, 7, 8, 13); q(3, 4, 9, 14)
                    }
                    for i in 0..<16 { x[i] = x[i] &+ s[i] }
                    let n = min(64, o.count - pos)
                    for i in 0..<n { o[pos + i] ^= UInt8(truncatingIfNeeded: x[i >> 2] >> UInt32((i & 3) * 8)) }
                    pos += n
                    s[12] = s[12] &+ 1
                }
            }
        }
        return out
    }
    static func hmac(_ data: [UInt8], _ key: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

// Eine Richtung der Sitzung: Zähler (8 Byte) | Geheimtext | Prüfsumme (16 Byte)
struct RemoteChannel {
    private let enc: [UInt8], mac: [UInt8]
    private var next: UInt64 = 0
    init(key: [UInt8], label: String, salt: [UInt8]) {
        enc = RemoteCrypto.hmac(Array((label + "-enc").utf8) + salt, key)
        mac = RemoteCrypto.hmac(Array((label + "-mac").utf8) + salt, key)
    }
    private static func bytes(_ n: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: n >> UInt64($0 * 8)) } }
    mutating func seal(_ plain: [UInt8]) -> [UInt8] {
        let n = Self.bytes(next)
        next += 1
        let body = n + RemoteCrypto.chacha(plain, key: enc, nonce: [0, 0, 0, 0] + n)
        return body + RemoteCrypto.hmac(body, mac).prefix(16)
    }
    // nil bei Fälschung oder Wiederholung; der Zähler muss genau der nächste sein
    mutating func open(_ msg: [UInt8]) -> [UInt8]? {
        guard msg.count >= 24 else { return nil }
        let body = Array(msg.dropLast(16)), want = RemoteCrypto.hmac(body, mac).prefix(16)
        guard zip(want, msg.suffix(16)).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        guard Array(body.prefix(8)) == Self.bytes(next) else { return nil }
        next += 1
        return RemoteCrypto.chacha(Array(body.dropFirst(8)), key: enc, nonce: [0, 0, 0, 0] + body.prefix(8))
    }
}
