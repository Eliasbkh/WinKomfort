// Datei-Werkzeuge: Bilder umwandeln und verkleinern, PDFs zusammenfügen und verkleinern. Originale bleiben immer unverändert.
import AppKit
import CoreImage
import PDFKit
import UniformTypeIdentifiers

enum FileTools {
    static func isImage(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true }
    static func isPDF(_ u: URL) -> Bool { u.pathExtension.lowercased() == "pdf" }
    // Freier Name neben dem Original
    static func free(_ u: URL, _ name: String, _ ext: String) -> URL {
        let d = u.deletingLastPathComponent()
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
        return d.appendingPathComponent(MTPSession.unique("\(name).\(ext)", taken: taken))
    }
    private static func load(_ u: URL, _ max: Int) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max] as CFDictionary)
    }
    // Ohne Aufnahmeort und andere Metadaten
    static func convert(_ u: URL, to type: UTType, max: Int = 12_000, quality: Double = 0.85, suffix: String = "") -> URL? {
        guard var img = load(u, max) else { return nil }
        if type == .jpeg, img.alphaInfo != .none, img.alphaInfo != .noneSkipLast, img.alphaInfo != .noneSkipFirst { // durchsichtig → weiß statt schwarz
            guard let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            c.setFillColor(.white); c.fill(r); c.draw(img, in: r)
            img = c.makeImage() ?? img
        }
        let out = free(u, u.deletingPathExtension().lastPathComponent + suffix, type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "png")
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }
    // Bilder und PDFs in der gezeigten Reihenfolge zu einer PDF
    static func merge(_ list: [URL]) -> URL? {
        let out = PDFDocument()
        for u in list {
            if isPDF(u) {
                guard let d = PDFDocument(url: u), !d.isLocked else { return nil }
                for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
            } else if let cg = load(u, 3000) {
                let img = NSImage(cgImage: cg, size: .zero)
                let wide = cg.width > cg.height, a4 = wide ? NSSize(width: 842, height: 595) : NSSize(width: 595, height: 842)
                let k = min((a4.width - 36) / CGFloat(cg.width), (a4.height - 36) / CGFloat(cg.height))
                let page = NSImage(size: a4, flipped: false) { _ in
                    NSColor.white.setFill(); NSRect(origin: .zero, size: a4).fill()
                    let s = NSSize(width: CGFloat(cg.width) * k, height: CGFloat(cg.height) * k)
                    img.draw(in: NSRect(x: (a4.width - s.width) / 2, y: (a4.height - s.height) / 2, width: s.width, height: s.height)); return true
                }
                guard let p = PDFPage(image: page, options: [.mediaBox: NSRect(origin: .zero, size: a4), .compressionQuality: 0.8]) else { return nil }
                out.insert(p, at: out.pageCount)
            } else { return nil }
        }
        guard let f = list.first, out.pageCount > 0 else { return nil }
        let to = free(f, list.count == 1 ? f.deletingPathExtension().lastPathComponent : L("Zusammengefügt", "Merged"), "pdf")
        return out.write(to: to) ? to : nil
    }
    // Bilder in der PDF verkleinern; Text bleibt Text
    static func shrink(_ u: URL) -> URL? {
        guard let d = PDFDocument(url: u), !d.isLocked else { return nil }
        let to = free(u, u.deletingPathExtension().lastPathComponent + L(" klein", " small"), "pdf")
        guard d.write(to: to, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else { return nil }
        func size(_ x: URL) -> Int { (try? x.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        if size(to) >= size(u) * 95 / 100 { try? FileManager.default.removeItem(at: to); return nil }
        return to
    }
    @MainActor static func run(_ list: [URL], _ work: @escaping @Sendable (URL) -> URL?) {
        Toast.show(L("Einen Moment …", "One moment…"), symbol: "hourglass")
        Task.detached(priority: .userInitiated) {
            let out = list.map(work)
            let ok = out.compactMap { $0 }
            await MainActor.run {
                if ok.isEmpty { Toast.show(L("Das hat nicht geklappt oder bringt nichts", "That failed or wouldn't help"), symbol: "exclamationmark.triangle", seconds: 2.5) }
                else { Toast.show(ok.count == list.count ? (ok.count == 1 ? L("„\(ok[0].lastPathComponent)“ liegt daneben", "Saved “\(ok[0].lastPathComponent)” next to it") : L("\(ok.count) Dateien liegen daneben", "\(ok.count) files saved")) : L("\(ok.count) von \(list.count) fertig", "\(ok.count) of \(list.count) done"), symbol: "checkmark.circle", seconds: 2.5) }
            }
        }
    }
}
