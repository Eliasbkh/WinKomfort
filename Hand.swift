// Eigene Handschrift: Vorlage drucken, einlesen, Text und Arbeitsblätter damit füllen, als echte Tinte in OneNote schreiben
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FoundationModels
import PDFKit
import ScreenCaptureKit
import SwiftUI
import Vision

// MARK: Speicher und Zeichnen
@MainActor final class Hand: ObservableObject {
    static let shared = Hand()
    @Published var font: HandLogic.Font?
    @Published var color = Color(red: 0.07, green: 0.16, blue: 0.48) // Kuli-Blau
    @Published var busy: String?
    private static let file: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WinKomfort")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("handschrift.json")
    }()
    private init() { font = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(HandLogic.Font.self, from: $0) } }
    func save(_ f: HandLogic.Font) {
        font = f
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: Self.file, options: .atomic) }
    }

    // Striche (Punkt, Ursprung oben links) in einen Kontext mit Ursprung unten links zeichnen
    nonisolated static func draw(_ strokes: [[CGPoint]], in c: CGContext, height: CGFloat, width: CGFloat, color: CGColor) {
        c.saveGState()
        c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
        for s in strokes where !s.isEmpty {
            c.beginPath(); c.move(to: CGPoint(x: s[0].x, y: height - s[0].y))
            if s.count == 1 { c.addLine(to: CGPoint(x: s[0].x + 0.01, y: height - s[0].y)) }
            for p in s.dropFirst() { c.addLine(to: CGPoint(x: p.x, y: height - p.y)) }
            c.strokePath()
        }
        c.restoreGState()
    }
    nonisolated static func image(_ text: String, font f: HandLogic.Font, width: CGFloat = 520, size: CGFloat = 16, color: CGColor) -> CGImage? {
        let probe = HandLogic.layout(text, f, in: CGRect(x: 10, y: 6, width: width - 20, height: 4000), size: size).strokes
        let h = max((probe.flatMap { $0.map(\.y) }.max() ?? 40) + size * 0.8, 40), k: CGFloat = 2
        guard let c = CGContext(data: nil, width: Int(width * k), height: Int(h * k), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: k, y: k)
        draw(probe, in: c, height: h, width: f.pen * size, color: color)
        return c.makeImage()
    }

    // MARK: Vorlage
    nonisolated static func templatePDF() -> Data {
        let d = NSMutableData()
        var box = CGRect(origin: .zero, size: HandLogic.page)
        guard let consumer = CGDataConsumer(data: d), let c = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        c.beginPDFPage(nil)
        let H = HandLogic.page.height
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ gray: CGFloat, bold: Bool = false, center: Bool = false) {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(white: gray, alpha: 1)]
            let w = (s as NSString).size(withAttributes: a).width
            (s as NSString).draw(at: CGPoint(x: center ? x - w / 2 : x, y: H - y - size), withAttributes: a)
        }
        text(L("Meine Handschrift für WinKomfort", "My handwriting for WinKomfort"), 60, 40, 15, 0.1, bold: true)
        text(L("Jedes Zeichen zweimal in seine Kästchen schreiben, mit dunklem Kuli oder Fineliner, so wie du sonst schreibst.", "Write each character twice into its boxes with a dark pen, the way you normally write."), 60, 62, 8.5, 0.25)
        text(L("Kleinbuchstaben auf der gestrichelten Linie, g, p, q, y dürfen darunter. Passmarken in den Ecken nicht abschneiden. Danach mit ⌃⌥B scannen.", "Lowercase on the dashed line; g, p, q, y may go below. Don't cut off the corner marks. Then scan with ⌃⌥B."), 60, 75, 8.5, 0.25)
        // Passmarken
        c.setFillColor(gray: 0, alpha: 1)
        for m in HandLogic.markers { c.fill(CGRect(x: m.x - HandLogic.markerSize / 2, y: H - m.y - HandLogic.markerSize / 2, width: HandLogic.markerSize, height: HandLogic.markerSize)) }
        // Kästchen hellgrau: verschwinden beim Einlesen
        for (i, s) in HandLogic.slots.enumerated() {
            let b = HandLogic.box(i), a = HandLogic.area(i)
            c.setStrokeColor(gray: 0.8, alpha: 1); c.setLineWidth(0.6); c.stroke(CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height))
            c.move(to: CGPoint(x: b.minX, y: H - b.minY - HandLogic.labelHeight)); c.addLine(to: CGPoint(x: b.maxX, y: H - b.minY - HandLogic.labelHeight)); c.strokePath()
            c.setStrokeColor(gray: 0.86, alpha: 1); c.setLineDash(phase: 0, lengths: [1.5, 1.5])
            c.move(to: CGPoint(x: a.minX, y: H - HandLogic.baseline(i))); c.addLine(to: CGPoint(x: a.maxX, y: H - HandLogic.baseline(i))); c.strokePath()
            c.setLineDash(phase: 0, lengths: [])
            text(String(s.char), b.midX, b.minY + 1.5, 8, 0.62, center: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        c.endPDFPage(); c.closePDF()
        return d as Data
    }

    // MARK: Ausgefüllte Vorlage einlesen
    enum ReadError: Error { case markers, empty }
    nonisolated static func read(_ img: CGImage) -> Result<HandLogic.Font, ReadError> {
        let ctx = CIContext()
        let w = img.width, h = img.height
        guard let gray = graySamples(img, ctx) else { return .failure(.markers) }
        // Passmarken: größter dunkler, gefüllter Fleck je Ecke
        func marker(_ corner: Int) -> CGPoint? {
            let rw = w * 22 / 100, rh = h * 16 / 100
            let x0 = corner == 1 || corner == 2 ? w - rw : 0, y0 = corner >= 2 ? h - rh : 0
            var seen = [Bool](repeating: false, count: rw * rh), best: (n: Int, x: Double, y: Double, fill: Double)?
            for yy in 0..<rh { for xx in 0..<rw where !seen[yy * rw + xx] && gray[(y0 + yy) * w + x0 + xx] < 90 {
                var stack = [(xx, yy)], n = 0, sx = 0.0, sy = 0.0, minX = xx, maxX = xx, minY = yy, maxY = yy
                seen[yy * rw + xx] = true
                while let (px, py) = stack.popLast() {
                    n += 1; sx += Double(px); sy += Double(py)
                    minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = px + dx, ny = py + dy
                        if nx >= 0, ny >= 0, nx < rw, ny < rh, !seen[ny * rw + nx], gray[(y0 + ny) * w + x0 + nx] < 90 { seen[ny * rw + nx] = true; stack.append((nx, ny)) }
                    }
                }
                let bw = maxX - minX + 1, bh = maxY - minY + 1, fill = Double(n) / Double(bw * bh), square = Double(min(bw, bh)) / Double(max(bw, bh))
                if fill > 0.75, square > 0.7, n > 30, n > (best?.n ?? 0) { best = (n, sx / Double(n) + Double(x0), sy / Double(n) + Double(y0), fill) }
            } }
            return best.map { CGPoint(x: $0.x, y: $0.y) }
        }
        let found = (0..<4).compactMap(marker)
        guard found.count == 4 else { return .failure(.markers) }
        // auf die Vorlage entzerren: 4 Pixel je Punkt
        let k: CGFloat = 4, m = HandLogic.markers
        let f = CIFilter.perspectiveCorrection(); f.inputImage = CIImage(cgImage: img)
        func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: CGFloat(h) - p.y) }
        f.topLeft = ci(found[0]); f.topRight = ci(found[1]); f.bottomRight = ci(found[2]); f.bottomLeft = ci(found[3])
        guard var out = f.outputImage else { return .failure(.markers) }
        let tw = (m[1].x - m[0].x) * k, th = (m[3].y - m[0].y) * k
        out = out.transformed(by: CGAffineTransform(scaleX: tw / out.extent.width, y: th / out.extent.height))
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        guard let flat = ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: tw, height: th)), let g = graySamples(flat, ctx) else { return .failure(.markers) }
        let W = flat.width
        var font = HandLogic.Font(), pens: [CGFloat] = []
        for (i, s) in HandLogic.slots.enumerated() {
            let a = HandLogic.area(i).insetBy(dx: 1.2, dy: 1)
            let x0 = Int((a.minX - m[0].x) * k), y0 = Int((a.minY - m[0].y) * k), cw = Int(a.width * k), chh = Int(a.height * k)
            guard x0 >= 0, y0 >= 0, x0 + cw <= W, y0 + chh <= flat.height else { continue }
            var ink = [UInt8](repeating: 0, count: cw * chh)
            for yy in 0..<chh { for xx in 0..<cw where g[(y0 + yy) * W + x0 + xx] < 120 { ink[yy * cw + xx] = 1 } } // hellgraue Kästchen fallen weg
            if let r = HandLogic.glyph(ink, cw, chh, baseline: (HandLogic.baseline(i) - a.minY) * k, em: HandLogic.em(i) * k) {
                font.glyphs[String(s.char), default: []].append(r.glyph); pens.append(r.pen)
            }
        }
        guard font.glyphs.count >= 20 else { return .failure(.empty) }
        font.pen = min(max(pens.sorted()[pens.count / 2], 0.035), 0.14)
        return .success(font)
    }
    nonisolated static func graySamples(_ img: CGImage, _ ctx: CIContext) -> [UInt8]? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 255, count: w * h)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) // Zeile 0 = oben
        return px
    }
}

// MARK: Arbeitsblatt: Felder finden, KI-Antworten, zwei Ebenen
struct SheetField: Identifiable, Equatable {
    let id = UUID()
    let page: Int
    let rect: CGRect          // Punkt, Ursprung oben links
    let lines: [CGFloat]      // Schreiblinien (y), leer = freies Feld/Tabellenzelle
    var context: String       // Aufgabe, Spalte, Zeile
    var answer = ""
}

enum SheetReader {
    // Seite rastern (2 Pixel je Punkt), Graustufen, Zeile 0 = oben
    static func raster(_ p: PDFPage, k: CGFloat = 2) -> (img: CGImage, gray: [UInt8], w: Int, h: Int)? {
        let b = p.bounds(for: .mediaBox), w = Int(b.width * k), h = Int(b.height * k)
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.scaleBy(x: k, y: k); c.translateBy(x: -b.minX, y: -b.minY)
        p.draw(with: .mediaBox, to: c)
        guard let img = c.makeImage(), let g = Hand.graySamples(img, CIContext()) else { return nil }
        return (img, g, w, h)
    }
    struct Seg { var a: Int, b: Int, at: Int }
    // Texterkennung in überlappenden Kacheln: bei sehr großen Seiten liefert Vision sonst gar nichts. Ergebnis in Pixeln, Ursprung oben links
    static func ocr(_ img: CGImage) -> [(CGRect, String)] {
        let tile = 1400, step = 1200
        var out: [(CGRect, String)] = []
        for y in stride(from: 0, to: img.height, by: step) { for x in stride(from: 0, to: img.width, by: step) {
            let r = CGRect(x: x, y: y, width: min(tile, img.width - x), height: min(tile, img.height - y))
            guard r.width > 40, r.height > 40, let part = img.cropping(to: r) else { continue }
            let q = VNRecognizeTextRequest(); q.recognitionLevel = .accurate; q.recognitionLanguages = ["de-DE", "en-US"]
            try? VNImageRequestHandler(cgImage: part).perform([q])
            for o in q.results ?? [] {
                guard let t = o.topCandidates(1).first?.string else { continue }
                let b = o.boundingBox, box = CGRect(x: r.minX + b.minX * r.width, y: r.minY + (1 - b.maxY) * r.height, width: b.width * r.width, height: b.height * r.height)
                // am Kachelrand abgeschnitten oder doppelt gelesen? Die vollständigere Fassung behalten
                if let i = out.firstIndex(where: { $0.0.intersects(box) && abs($0.0.midY - box.midY) < box.height / 2 }) { if box.width > out[i].0.width { out[i] = (box, t) } } else { out.append((box, t)) }
            }
        } }
        return out
    }
    // waagrechte bzw. senkrechte Linien aus langen Läufen
    // Linie = langer, gleichmäßiger Lauf, ober- und unterhalb weißes Papier (Textzeilen fallen so heraus)
    static func runs(_ g: [UInt8], _ w: Int, _ h: Int, horizontal: Bool, dark: ClosedRange<UInt8>, minLen: Int) -> [Seg] {
        raw(g, w, h, horizontal: horizontal, dark: dark, minLen: minLen).filter { s in
            let len = s.b - s.a, step = max(1, len / 60)
            func white(_ off: Int) -> Double {
                let i = s.at + off
                guard i >= 0, i < (horizontal ? h : w) else { return 1 }
                let n = stride(from: s.a, to: s.b, by: step).filter { j in g[horizontal ? i * w + j : j * w + i] > 225 }.count
                return Double(n) / Double(max(1, (len + step - 1) / step))
            }
            let even = stride(from: s.a, to: s.b, by: step).filter { j in dark.contains(g[horizontal ? s.at * w + j : j * w + s.at]) }.count
            return Double(even) / Double(max(1, (len + step - 1) / step)) > 0.8 && (white(-4) > 0.85 || white(-5) > 0.85) && (white(4) > 0.85 || white(5) > 0.85)
        }
    }
    static func raw(_ g: [UInt8], _ w: Int, _ h: Int, horizontal: Bool, dark: ClosedRange<UInt8>, minLen: Int) -> [Seg] {
        var out: [Seg] = []
        let (n, m) = horizontal ? (h, w) : (w, h)
        for i in 0..<n {
            var start = -1, gapRun = 0
            for j in 0...m {
                let v = j < m ? g[horizontal ? i * w + j : j * w + i] : 255
                if dark.contains(v) { if start < 0 { start = j }; gapRun = 0 }
                else if start >= 0 {
                    gapRun += 1
                    if gapRun > 3 || j == m { let end = j - gapRun; if end - start >= minLen { out.append(Seg(a: start, b: end, at: i)) }; start = -1; gapRun = 0 } // kleine Lücken (gepunktet) überbrücken
                }
            }
        }
        // benachbarte Pixelzeilen zu einer Linie zusammenfassen
        var merged: [Seg] = []
        for s in out.sorted(by: { ($0.at, $0.a) < ($1.at, $1.a) }) {
            if let i = merged.lastIndex(where: { s.at - $0.at <= 2 && abs(s.a - $0.a) < 8 && abs(s.b - $0.b) < 8 }) { merged[i].at = s.at } else { merged.append(s) }
        }
        return merged
    }
    static func fields(_ doc: PDFDocument) -> [SheetField] {
        var out: [SheetField] = []
        for pi in 0..<min(doc.pageCount, 12) {
            guard let page = doc.page(at: pi) else { continue }
            let pb = page.bounds(for: .mediaBox), k = max(2, min(5, 3600 / max(pb.width, pb.height))) // kleine eingebettete Blätter brauchen mehr Pixel
            guard let r = raster(page, k: k) else { continue }
            let g = r.gray, w = r.w, h = r.h
            // Text mit Lage (für „ist die Zelle leer?“ und den Zusammenhang)
            let texts = ocr(r.img)
            func inkShare(_ c: CGRect) -> Double { // Anteil dunkler Pixel: leere Zelle ≈ 0
                let x0 = max(0, Int(c.minX)), x1 = min(w, Int(c.maxX)), y0 = max(0, Int(c.minY)), y1 = min(h, Int(c.maxY))
                guard x1 > x0, y1 > y0 else { return 1 }
                var n = 0; for y in stride(from: y0, to: y1, by: 2) { for x in stride(from: x0, to: x1, by: 2) where g[y * w + x] < 150 { n += 1 } }
                return Double(n) / Double(((y1 - y0 + 1) / 2) * ((x1 - x0 + 1) / 2))
            }
            func textIn(_ c: CGRect) -> String { texts.filter { c.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.0.midX, y: $0.0.midY)) }.map(\.1).joined(separator: " ") }
            func above(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) -> String {
                texts.filter { $0.0.maxY <= y + k && $0.0.maxY > y - 130 * k && $0.0.maxX > x0 - 10 * k && $0.0.minX < x1 }.sorted { $0.0.minY < $1.0.minY }.suffix(4).map(\.1).joined(separator: " ")
            }
            // Tabellen aus dunklen Linien
            let hs = runs(g, w, h, horizontal: true, dark: 0...170, minLen: w / 10), vs = runs(g, w, h, horizontal: false, dark: 0...170, minLen: Int(10 * k))
            var cells: [CGRect] = []
            let rows = hs.sorted { $0.at < $1.at }
            for (i, top) in rows.enumerated() {
                guard let bottom = rows[(i + 1)...].first(where: { $0.at - top.at > Int(7 * k) && min($0.b, top.b) - max($0.a, top.a) > w / 12 }), bottom.at - top.at < Int(350 * k) else { continue }
                let xs = vs.filter { $0.a <= top.at + 4 && $0.b >= bottom.at - 4 && $0.at >= max(top.a, bottom.a) - 4 && $0.at <= min(top.b, bottom.b) + 4 }.map(\.at).sorted()
                var uniq: [Int] = []; for x in xs where uniq.last.map({ x - $0 > 6 }) ?? true { uniq.append(x) }
                for (a, b) in zip(uniq, uniq.dropFirst()) where b - a > Int(15 * k) { cells.append(CGRect(x: a, y: top.at, width: b - a, height: bottom.at - top.at)) }
            }
            for c in cells {
                let inner = c.insetBy(dx: 2.5 * k, dy: 2.5 * k)
                guard inner.width > 10 * k, inner.height > 7 * k, textIn(inner).isEmpty, inkShare(inner) < 0.01 else { continue }
                // Zusammenhang: Spaltenkopf (oberste Zelle derselben Spalte), Zeilenkopf (linke Zelle), Aufgabe darüber
                let col = cells.filter { abs($0.minX - c.minX) < 6 && $0.minY < c.minY }.min { $0.minY < $1.minY }.map { textIn($0) } ?? ""
                let row = cells.filter { abs($0.minY - c.minY) < 6 && $0.maxX <= c.minX + 6 }.map { textIn($0) }.joined(separator: " ")
                let tableTop = cells.filter { abs($0.minX - c.minX) < 400 && $0.maxY >= c.minY - 2 }.map(\.minY).min() ?? c.minY
                let ctxt = [above(tableTop, c.minX - 300, c.maxX + 300).isEmpty ? "" : "Aufgabe: " + above(tableTop, 0, CGFloat(w)), col.isEmpty ? "" : "Spalte: " + col, row.isEmpty ? "" : "Zeile: " + row].filter { !$0.isEmpty }.joined(separator: " | ")
                out.append(SheetField(page: pi, rect: CGRect(x: inner.minX / k, y: inner.minY / k, width: inner.width / k, height: inner.height / k), lines: [], context: ctxt))
            }
            // Schreiblinien: hellgraue lange Linien, in Gruppen mit gleichem Abstand
            let light = runs(g, w, h, horizontal: true, dark: 171...238, minLen: w / 5).filter { l in !cells.contains { $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: (l.a + l.b) / 2, y: l.at)) } }.sorted { $0.at < $1.at }
            var group: [Seg] = []
            func flush() {
                guard let f = group.first, let l = group.last else { return }
                let gap = group.count > 1 ? CGFloat(group[1].at - f.at) : 18 * k
                let rect = CGRect(x: CGFloat(f.a), y: CGFloat(f.at) - gap, width: CGFloat(f.b - f.a), height: CGFloat(l.at - f.at) + gap)
                if textIn(rect.insetBy(dx: 0, dy: 4)).count < 8 {
                    out.append(SheetField(page: pi, rect: CGRect(x: rect.minX / k, y: rect.minY / k, width: rect.width / k, height: rect.height / k), lines: group.map { CGFloat($0.at) / k }, context: "Aufgabe: " + above(rect.minY, rect.minX, rect.maxX)))
                }
                group = []
            }
            for l in light {
                if let p = group.last, CGFloat(l.at - p.at) > 35 * k || abs(l.a - p.a) > Int(10 * k) { flush() }
                group.append(l)
            }
            flush()
        }
        // doppelte Felder (gleiche Stelle) nur einmal
        var unique: [SheetField] = []
        for f in out.sorted(by: { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }) {
            if !unique.contains(where: { $0.page == f.page && $0.rect.intersection(f.rect).width * $0.rect.intersection(f.rect).height > 0.5 * f.rect.width * f.rect.height }) { unique.append(f) }
        }
        return unique.sorted { ($0.page, $0.rect.minY, $0.rect.minX) < ($1.page, $1.rect.minY, $1.rect.minX) }
    }

    // Seitentext für die KI (Reihenfolge wie gelesen)
    static func text(_ doc: PDFDocument, page: Int) -> String { (doc.page(at: page)?.string ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
}

@MainActor final class SheetFiller: ObservableObject {
    static let shared = SheetFiller()
    @Published var doc: PDFDocument?
    @Published var url: URL?
    @Published var fields: [SheetField] = []
    @Published var status = ""
    @Published var working = false
    @Published var showInk = true
    @Published var page = 0

    static func open(_ u: URL) {
        let first = windows["sheet"] == nil
        showWindow("sheet", "Ausfüllen") { SheetView() }
        windows["sheet"]?.title = L("In meiner Handschrift ausfüllen", "Fill in my handwriting")
        if first { windows["sheet"]?.setContentSize(NSSize(width: 1040, height: 820)); windows["sheet"]?.center(); windows["sheet"]?.setFrameAutosaveName("WinKomfortSheet") }
        shared.load(u)
    }
    static func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        open(u)
    }
    func load(_ u: URL) {
        guard let d = PDFDocument(url: u) else { status = L("Die PDF ließ sich nicht öffnen.", "Couldn't open the PDF."); return }
        doc = d; url = u; fields = []; page = 0; working = true; status = L("Suche Antwortfelder …", "Finding answer fields…")
        let data = d.dataRepresentation()
        Task.detached(priority: .userInitiated) {
            guard let data, let copy = PDFDocument(data: data) else { return }
            let f = SheetReader.fields(copy)
            await MainActor.run {
                let s = SheetFiller.shared
                guard s.url == u else { return }
                s.fields = f; s.working = false
                s.status = f.isEmpty ? L("Keine leeren Felder gefunden.", "No empty fields found.") : L("\(f.count) Felder gefunden. Die KI füllt sie aus …", "\(f.count) fields found. AI is filling them in…")
                if !f.isEmpty { s.answer() }
            }
        }
    }
    // Seite für Seite fragen: das Apple-Modell auf dem Mac hat nur Platz für wenig Text
    func answer() {
        guard let d = doc, Assistant.available else { status = L("Für Antworten braucht es Apple Intelligence. Du kannst die Felder auch selbst eintippen.", "Answers need Apple Intelligence. You can also type into the fields yourself."); return }
        working = true
        let pages = Set(fields.map(\.page)).sorted()
        Task {
            defer { working = false }
            guard #available(macOS 26.0, *) else { return }
            for p in pages {
                let mine = fields.indices.filter { fields[$0].page == p && fields[$0].answer.isEmpty }
                guard !mine.isEmpty else { continue }
                status = L("KI beantwortet Seite \(p + 1) …", "AI answers page \(p + 1)…")
                let list = mine.enumerated().map { n, i in let f = fields[i]; return "\(n + 1). \(f.context.prefix(300)) (Platz für etwa \(max(4, Int(f.rect.width * f.rect.height / 70))) Wörter)" }.joined(separator: "\n")
                let s = LanguageModelSession(instructions: "Du füllst ein Arbeitsblatt für einen Schüler aus. Antworte auf Deutsch, sachlich richtig, knapp und in Schülersprache. Fülle jedes Feld passend zu Aufgabe, Spalte und Zeile. Fragt ein Feld nach persönlichen Dingen, schreibe eine plausible, ehrliche Schülerantwort. Gib genau eine Zeile pro Feld zurück im Format: Nummer | Antwort")
                let q = "Text der Seite:\n\(String(SheetReader.text(d, page: p).prefix(2200)))\n\nFelder:\n\(list)"
                guard let r = try? await s.respond(to: q).content else { continue }
                for line in r.split(separator: "\n") {
                    let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ".*# "))), (1...mine.count).contains(n) else { continue }
                    fields[mine[n - 1]].answer = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"„“"))
                }
            }
            status = L("Fertig. Prüfe die Antworten und ändere sie, wenn nötig.", "Done. Check the answers and edit them if needed.")
        }
    }
    // Striche eines Feldes in Seitenpunkten (Ursprung oben links)
    func strokes(_ f: SheetField) -> [[CGPoint]] {
        guard let font = Hand.shared.font, !f.answer.isEmpty else { return [] }
        if f.lines.count >= 1 {
            let gap = f.lines.count > 1 ? f.lines[1] - f.lines[0] : 16
            let size = min(gap * 0.5, 9)
            let r = CGRect(x: f.rect.minX + 2, y: f.lines[0] - size * 1.05 - 1, width: f.rect.width - 4, height: (f.lines.last! - f.lines[0]) + size * 1.4)
            return HandLogic.layout(f.answer, font, in: r, size: size, seed: UInt64(abs(f.answer.hashValue) % 10_000), lineHeight: gap).strokes
        }
        let r = f.rect.insetBy(dx: 2, dy: 1)
        return HandLogic.layout(f.answer, font, in: r, size: HandLogic.fit(f.answer, font, in: r, max: 8.5, min: 4), seed: UInt64(abs(f.answer.hashValue) % 10_000)).strokes
    }
    // PDF mit zwei Ebenen: Original + Handschrift als Tinten-Anmerkungen (in Vorschau auswähl- und löschbar)
    func export() {
        guard let d = doc, let data = d.dataRepresentation(), let out = PDFDocument(data: data), let font = Hand.shared.font else { return }
        let ns = NSColor(Hand.shared.color)
        for f in fields where !f.answer.isEmpty {
            guard let page = out.page(at: f.page) else { continue }
            let b = page.bounds(for: .mediaBox), size = f.lines.count > 1 ? min((f.lines[1] - f.lines[0]) * 0.5, 9) : 6
            let st = strokes(f)
            guard !st.isEmpty else { continue }
            let pts = st.flatMap { $0 }, minX = pts.map(\.x).min()! - 4, maxX = pts.map(\.x).max()! + 4, minY = pts.map(\.y).min()! - 4, maxY = pts.map(\.y).max()! + 4
            let bounds = CGRect(x: b.minX + minX, y: b.maxY - maxY, width: maxX - minX, height: maxY - minY)
            let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            a.color = ns
            let border = PDFBorder(); border.lineWidth = max(font.pen * size, 0.6); a.border = border
            for s in st where s.count > 1 {
                let p = NSBezierPath(); p.move(to: CGPoint(x: b.minX + s[0].x - bounds.minX, y: b.maxY - s[0].y - bounds.minY))
                for q in s.dropFirst() { p.line(to: CGPoint(x: b.minX + q.x - bounds.minX, y: b.maxY - q.y - bounds.minY)) }
                a.add(p)
            }
            a.userName = "WinKomfort"
            page.addAnnotation(a)
        }
        let sp = NSSavePanel(); sp.allowedContentTypes = [.pdf]
        sp.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "Blatt") + L(" – ausgefüllt.pdf", " – filled.pdf")
        sp.directoryURL = url?.deletingLastPathComponent()
        guard sp.runModal() == .OK, let u = sp.url else { return }
        if out.write(to: u) { NSWorkspace.shared.activateFileViewerSelecting([u]); Toast.show(L("Gesichert: Original + Handschrift als eigene Ebene", "Saved: original + handwriting as its own layer"), symbol: "pencil.and.scribble") }
    }
}

// MARK: Oberfläche
struct HandView: View {
    @ObservedObject var h = Hand.shared
    @StateObject private var sample = TextBox<String>()
    private var text: String { sample.value ?? L("Franz jagt im komplett verwahrlosten Taxi quer durch Bayern. Zwölf Boxkämpfer jagen Viktor über den großen Sylter Deich – 0123456789!", "The quick brown fox jumps over the lazy dog. 0123456789!") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Meine Handschrift", "My handwriting")).font(.title2.weight(.semibold))
                Spacer()
                if h.font != nil { ColorPicker(L("Stiftfarbe", "Pen color"), selection: $h.color).fixedSize() }
            }
            if let f = h.font {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("So sieht deine Schrift aus:", "This is your handwriting:")).foregroundStyle(.secondary)
                    if let img = Hand.image(text, font: f, width: 640, size: 15, color: NSColor(h.color).cgColor) {
                        Image(decorative: img, scale: 2).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    TextField(L("Eigenen Text ausprobieren", "Try your own text"), text: Binding(get: { sample.value ?? "" }, set: { sample.value = $0.isEmpty ? nil : $0 }), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                    if !f.missing.isEmpty { Text(L("Noch nicht erfasst: ", "Not captured yet: ") + String(f.missing)).font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Button(L("Arbeitsblatt ausfüllen …", "Fill in a worksheet…")) { SheetFiller.pick() }.buttonStyle(.borderedProminent)
                    Button(L("Als Bild kopieren", "Copy as image")) { copy(f) }
                    Spacer()
                    Button(L("Neu einlesen …", "Read again…")) { importFile() }
                }
            } else {
                Text(L("Einmal einrichten, dann schreibt WinKomfort Texte und Arbeitsblätter in deiner Schrift, auch als echte Tinte in OneNote.", "Set up once; then WinKomfort writes texts and worksheets in your handwriting, even as real ink in OneNote.")).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    step(1, L("Vorlage drucken", "Print the template"), L("Ein A4-Blatt mit Kästchen für jedes Zeichen.", "An A4 sheet with a box for each character.")) { Button(L("Vorlage öffnen", "Open template")) { openTemplate() } }
                    step(2, L("Ausfüllen", "Fill it in"), L("Jedes Zeichen zweimal, mit dunklem Stift, so wie du sonst schreibst.", "Each character twice, dark pen, your normal writing.")) { EmptyView() }
                    step(3, L("Einlesen", "Read it in"), L("Mit dem Scanner (⌃⌥B) oder als Foto/PDF.", "With the scanner (⌃⌥B) or as a photo/PDF.")) { HStack { Button(L("Scannen", "Scan")) { Scanner.open(forHand: true) }; Button(L("Datei wählen …", "Choose file…")) { importFile() } } }
                }
            }
            if let b = h.busy { HStack { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary) } }
            Spacer(minLength: 0)
        }
        .padding(20).frame(minWidth: 620, minHeight: 420)
    }
    private func step(_ n: Int, _ t: String, _ d: String, @ViewBuilder _ action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26).background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) { Text(t).font(.headline); Text(d).foregroundStyle(.secondary); action() }
        }
    }
    private func openTemplate() {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(L("WinKomfort Handschrift-Vorlage.pdf", "WinKomfort handwriting template.pdf"))
        do { try Hand.templatePDF().write(to: u, options: .atomic); NSWorkspace.shared.open(u) } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
    }
    private func importFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image, .pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        let img: CGImage?
        if u.pathExtension.lowercased() == "pdf", let pg = PDFDocument(url: u)?.page(at: 0) { img = SheetReader.raster(pg).map(\.img) }
        else { img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard let img else { return }
        Hand.ingest(img)
    }
    private func copy(_ f: HandLogic.Font) {
        guard let img = Hand.image(text, font: f, width: 700, size: 16, color: NSColor(h.color).cgColor) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: NSSize(width: img.width / 2, height: img.height / 2))])
        Toast.show(L("Kopiert", "Copied"), symbol: "doc.on.doc")
    }
}

extension Hand {
    static func openWindow() {
        let first = windows["hand"] == nil
        showWindow("hand", "Handschrift") { HandView() }
        windows["hand"]?.title = L("Meine Handschrift", "My handwriting")
        if first { windows["hand"]?.setContentSize(NSSize(width: 700, height: 520)); windows["hand"]?.center() }
    }
    // gescanntes oder geladenes Bild der ausgefüllten Vorlage auswerten
    static func ingest(_ img: CGImage) {
        shared.busy = L("Lese deine Handschrift ein …", "Reading your handwriting…")
        Task.detached(priority: .userInitiated) {
            let r = Hand.read(img)
            await MainActor.run {
                let h = Hand.shared
                h.busy = nil
                switch r {
                case .success(let f): h.save(f); Toast.show(L("Handschrift eingelesen: \(f.glyphs.count) Zeichen", "Handwriting read: \(f.glyphs.count) characters"), symbol: "pencil.and.scribble"); openWindow()
                case .failure(.markers): Toast.show(L("Die vier Ecken-Marken wurden nicht gefunden. Bitte das ganze Blatt aufnehmen.", "Couldn't find the four corner marks. Capture the whole sheet."), symbol: "exclamationmark.triangle", seconds: 5)
                case .failure(.empty): Toast.show(L("Auf der Vorlage wurde zu wenig Schrift gefunden.", "Too little handwriting found on the template."), symbol: "exclamationmark.triangle", seconds: 5)
                }
            }
        }
    }
}

struct SheetView: View {
    @ObservedObject var s = SheetFiller.shared
    @ObservedObject var h = Hand.shared
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let d = s.doc, let p = d.page(at: s.page) {
                    SheetPage(page: p, fields: s.fields.filter { $0.page == s.page }, ink: s.showInk).padding(16)
                } else { ContentUnavailableView(L("Kein Blatt", "No sheet"), systemImage: "doc") }
                HStack {
                    if let d = s.doc, d.pageCount > 1 {
                        Button { s.page = max(0, s.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(s.page == 0)
                        Text(L("Seite \(s.page + 1) von \(d.pageCount)", "Page \(s.page + 1) of \(d.pageCount)")).monospacedDigit()
                        Button { s.page = min(d.pageCount - 1, s.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(s.page >= d.pageCount - 1)
                    }
                    Spacer()
                    Toggle(L("Handschrift-Ebene zeigen", "Show handwriting layer"), isOn: $s.showInk).toggleStyle(.switch).controlSize(.small)
                }
                .padding(10)
            }
            .frame(minWidth: 520)
            VStack(alignment: .leading, spacing: 8) {
                HStack { if s.working { ProgressView().controlSize(.small) }; Text(s.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if h.font == nil { Label(L("Erst deine Handschrift einrichten (Menü › Handschrift).", "Set up your handwriting first (menu › Handwriting)."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                List {
                    ForEach($s.fields) { $f in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Seite \(f.page + 1)", "Page \(f.page + 1)") + " · " + f.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            TextField(L("Antwort", "Answer"), text: $f.answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                        }
                        .padding(.vertical, 3)
                        .onTapGesture { s.page = f.page }
                    }
                }
                HStack {
                    Button(L("KI nochmal fragen", "Ask AI again")) { for i in s.fields.indices { s.fields[i].answer = "" }; s.answer() }.disabled(s.working)
                    Spacer()
                    Button(L("In OneNote schreiben …", "Write into OneNote…")) { InkRobot.prepare(page: s.page) }.disabled(h.font == nil || s.working)
                    Button(L("PDF sichern …", "Save PDF…")) { s.export() }.buttonStyle(.borderedProminent).disabled(h.font == nil || s.working)
                }
            }
            .padding(12).frame(minWidth: 360, idealWidth: 400)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
private struct SheetPage: View {
    let page: PDFPage, fields: [SheetField], ink: Bool
    var body: some View {
        let b = page.bounds(for: .mediaBox)
        GeometryReader { g in
            let k = min(g.size.width / b.width, g.size.height / b.height)
            ZStack(alignment: .topLeading) {
                Image(nsImage: page.thumbnail(of: NSSize(width: b.width * 2, height: b.height * 2), for: .mediaBox)).resizable().frame(width: b.width * k, height: b.height * k)
                ForEach(fields) { f in
                    Rectangle().stroke(Color.accentColor.opacity(f.answer.isEmpty ? 0.6 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: f.rect.width * k, height: f.rect.height * k).offset(x: f.rect.minX * k, y: f.rect.minY * k)
                }
                if ink {
                    Canvas { c, _ in
                        let fill = SheetFiller.shared, color = Hand.shared.color, pen = (Hand.shared.font?.pen ?? 0.06)
                        for f in fields {
                            for s in fill.strokes(f) where s.count > 1 {
                                var p = Path(); p.move(to: CGPoint(x: s[0].x * k, y: s[0].y * k)); for q in s.dropFirst() { p.addLine(to: CGPoint(x: q.x * k, y: q.y * k)) }
                                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(pen * 7 * k, 0.6), lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                    .frame(width: b.width * k, height: b.height * k).allowsHitTesting(false)
                }
            }
            .frame(width: b.width * k, height: b.height * k).shadow(color: .black.opacity(0.2), radius: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: OneNote-Stift-Roboter: echte Tinte, indem der gewählte OneNote-Stift die Striche nachfährt
@MainActor enum InkRobot {
    static var panel: NSPanel?
    static var stop = false
    // 1) Blatt als Bild mit feinem Rand in die Zwischenablage, 2) Anleitung, 3) Start
    static func prepare(page: Int) {
        guard let d = SheetFiller.shared.doc, let p = d.page(at: page), let r = SheetReader.raster(p) else { return }
        let w = r.img.width, h = r.img.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        c.draw(r.img, in: CGRect(x: 0, y: 0, width: w, height: h))
        c.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); c.setLineWidth(4); c.stroke(CGRect(x: 2, y: 2, width: w - 4, height: h - 4)) // Rand: daran findet WinKomfort das Blatt in OneNote wieder
        guard let img = c.makeImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: NSSize(width: w / 2, height: h / 2))])
        show(page: page)
    }
    private static func show(page: Int) {
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 250), styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.title = L("In OneNote schreiben", "Write into OneNote")
        p.level = .floating; p.isReleasedWhenClosed = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: InkRobotView(page: page))
        p.center(); p.orderFrontRegardless()
        panel = p
    }
    // Blatt im OneNote-Fenster suchen (Rechteck mit dem Seitenverhältnis), Striche abfahren
    static func run(page: Int, progress: @escaping @MainActor (String) -> Void) {
        guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; progress(L("Erst Bedienungshilfen für WinKomfort erlauben.", "Allow Accessibility for WinKomfort first.")); return }
        guard let one = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.microsoft.onenote.mac" }) else { progress(L("OneNote läuft nicht.", "OneNote isn't running.")); return }
        guard let d = SheetFiller.shared.doc, let pg = d.page(at: page) else { return }
        let b = pg.bounds(for: .mediaBox)
        let strokes = SheetFiller.shared.fields.filter { $0.page == page }.flatMap { SheetFiller.shared.strokes($0) }.filter { $0.count > 1 }
        guard !strokes.isEmpty else { progress(L("Auf dieser Seite gibt es nichts zu schreiben.", "Nothing to write on this page.")); return }
        stop = false
        one.activate()
        progress(L("Suche das Blatt in OneNote …", "Finding the sheet in OneNote…"))
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard let found = await locate(one, aspect: b.width / b.height) else { progress(L("Das Blatt wurde in OneNote nicht gefunden. Ganz sichtbar einfügen und auf 100 % zoomen.", "Couldn't find the sheet in OneNote. Paste it fully visible at 100 % zoom.")); return }
            // Seitenpunkt → Bildschirmpunkt (Ursprung oben links)
            let map = { (q: CGPoint) in CGPoint(x: found.minX + q.x / b.width * found.width, y: found.minY + q.y / b.height * found.height) }
            let total = strokes.count
            progress(L("Schreibe … Maus nicht bewegen (Esc bricht ab)", "Writing… don't move the mouse (Esc cancels)"))
            let esc = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { InkRobot.stop = true } }
            let screenPts = strokes.map { $0.map(map) }
            let done = await Task.detached(priority: .userInitiated) { () -> Int in
                var n = 0
                for s in screenPts {
                    if await MainActor.run(body: { InkRobot.stop || NSWorkspace.shared.frontmostApplication?.processIdentifier != one.processIdentifier }) { break }
                    if !draw(s) { break }
                    n += 1
                }
                return n
            }.value
            if let esc { NSEvent.removeMonitor(esc) }
            progress(done == total ? L("Fertig: \(total) Striche als OneNote-Tinte. Radierer und Lasso gehen jetzt.", "Done: \(total) strokes as OneNote ink. Eraser and lasso work now.") : L("Abgebrochen nach \(done) von \(total) Strichen (Maus bewegt, Esc oder anderes Fenster).", "Stopped after \(done) of \(total) strokes (mouse moved, Esc or another window)."))
        }
    }
    // Ein Strich: drücken, in kleinen Schritten ziehen, loslassen. Bewegt jemand die Maus, sofort aufhören
    nonisolated static func draw(_ s: [CGPoint]) -> Bool {
        guard let first = s.first, let src = CGEventSource(stateID: .hidSystemState) else { return false }
        func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
        post(.mouseMoved, first); usleep(4000)
        post(.leftMouseDown, first); usleep(4000)
        var last = first
        for p in s.dropFirst() {
            let n = max(1, Int(hypot(p.x - last.x, p.y - last.y) / 2.5))
            for i in 1...n {
                let q = CGPoint(x: last.x + (p.x - last.x) * CGFloat(i) / CGFloat(n), y: last.y + (p.y - last.y) * CGFloat(i) / CGFloat(n))
                if let now = CGEvent(source: nil)?.location, hypot(now.x - last.x, now.y - last.y) > 40 { post(.leftMouseUp, last); return false } // jemand bewegt die Maus
                post(.leftMouseDragged, q); usleep(1800)
            }
            last = p
        }
        post(.leftMouseUp, last); usleep(6000)
        return true
    }
    // Fensterbild von OneNote holen, darin das umrandete Blatt finden
    static func locate(_ app: NSRunningApplication, aspect: CGFloat) async -> CGRect? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let win = content.windows.filter({ $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 300 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let cfg = SCStreamConfiguration(); let scale = NSScreen.main?.backingScaleFactor ?? 2
        cfg.width = Int(win.frame.width * scale); cfg.height = Int(win.frame.height * scale); cfg.showsCursor = false
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg) else { return nil }
        let r = VNDetectRectanglesRequest(); r.minimumAspectRatio = Float(min(aspect, 1 / aspect) * 0.9); r.maximumAspectRatio = Float(min(aspect, 1 / aspect) * 1.1); r.minimumSize = 0.15; r.maximumObservations = 6; r.minimumConfidence = 0.6; r.quadratureTolerance = 5
        try? VNImageRequestHandler(cgImage: shot).perform([r])
        guard let o = (r.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let bb = o.boundingBox
        // Fensterbild (Ursprung unten links, 0…1) → Bildschirmpunkte (Ursprung oben links wie bei Mausereignissen)
        return CGRect(x: win.frame.minX + bb.minX * win.frame.width + 2, y: win.frame.minY + (1 - bb.maxY) * win.frame.height + 2, width: bb.width * win.frame.width - 4, height: bb.height * win.frame.height - 4)
    }
}

private struct InkRobotView: View {
    let page: Int
    @StateObject private var msg = TextBox<String>()
    @StateObject private var running = TextBox<Bool>()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("1. In OneNote dorthin klicken, wo das Blatt hin soll, und ⌘V drücken (das Blatt liegt schon in der Zwischenablage).", "1. Click in OneNote where the sheet should go and press ⌘V (the sheet is already on the clipboard).")).fixedSize(horizontal: false, vertical: true)
            Text(L("2. Unter „Zeichnen“ deinen Stift wählen (Farbe, Dicke).", "2. Pick your pen under “Draw” (color, width).")).fixedSize(horizontal: false, vertical: true)
            Text(L("3. Das ganze Blatt sichtbar lassen, dann hier starten. Während des Schreibens Maus nicht bewegen, Esc bricht ab.", "3. Keep the whole sheet visible, then start here. Don't move the mouse while writing; Esc cancels.")).fixedSize(horizontal: false, vertical: true)
            if let m = msg.value { Text(m).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("Schließen", "Close")) { InkRobot.stop = true; InkRobot.panel?.close() }
                Button(L("Schreiben starten", "Start writing")) { running.value = true; InkRobot.run(page: page) { msg.value = $0; if $0.hasPrefix(L("Fertig", "Done")) || $0.hasPrefix(L("Abgebrochen", "Stopped")) { running.value = false } } }
                    .buttonStyle(.borderedProminent).disabled(running.value == true)
            }
        }
        .padding(16).frame(width: 380)
    }
}
