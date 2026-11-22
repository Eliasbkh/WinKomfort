// Ed25519-Signatur für Update-Zips. Der geheime Schlüssel liegt nur lokal in ~/.winkomfort/signing-key.
// swift sign.swift keygen          → Schlüssel erzeugen, öffentlichen Schlüssel ausgeben
// swift sign.swift sign <datei>    → Signatur (Base64) ausgeben
// swift sign.swift verify <datei> <signatur> <öffentlicher-schlüssel>  → OK / FALSCH
import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".winkomfort/signing-key")
let a = CommandLine.arguments

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let s = try? String(contentsOf: keyURL, encoding: .utf8),
          let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d)
    else { fail("Kein Schlüssel in \(keyURL.path) – zuerst: swift sign.swift keygen") }
    return k
}

switch a.count > 1 ? a[1] : "" {
case "keygen":
    if FileManager.default.fileExists(atPath: keyURL.path) { fail("Schlüssel existiert schon – nicht überschreiben!") }
    let k = Curve25519.Signing.PrivateKey()
    try! FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyURL.path, contents: Data(k.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign" where a.count == 3:
    guard let d = FileManager.default.contents(atPath: a[2]) else { fail("Datei fehlt: \(a[2])") }
    print(try! loadKey().signature(for: d).base64EncodedString())
case "verify" where a.count == 5:
    guard let d = FileManager.default.contents(atPath: a[2]), let sig = Data(base64Encoded: a[3]),
          let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: a[4]) ?? Data())
    else { fail("Ungültige Eingabe") }
    if pk.isValidSignature(sig, for: d) { print("OK") } else { fail("FALSCH") }
default:
    fail("Nutzung: swift sign.swift keygen | sign <datei> | verify <datei> <signatur> <öffentlicher-schlüssel>")
}
