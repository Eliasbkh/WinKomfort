// Blatt scannen mit der Desk-View-Kamera (⌃⌥B): erkennen, stillhalten, entzerren, sauber wie aus dem Scanner
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import FoundationModels
import IOKit.hid
import simd
import SwiftUI
import Vision

// MARK: Kamera und Erkennung (eigene Warteschlange)
final class ScanEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "winkomfort.scan", qos: .userInitiated)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    var onQuad: (@Sendable (ScanQuad?, CGSize, Bool) -> Void)?
    // Desk View liefert das Bild um 90° gedreht; die Verbindung dreht es zurück, sonst drehen wir selbst
    private(set) var turned = true
    // nur auf queue
    private var lastDetect = 0.0, lastFrame = 0.0, collect = false, frames: [CGImage] = [], configured = false

    func start(_ d: AVCaptureDevice) throws {
        if !configured {
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: d)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
            // größtes Format: mehr Pixel pro Buchstabe
            if let f = d.formats.max(by: { a, b in let x = CMVideoFormatDescriptionGetDimensions(a.formatDescription), y = CMVideoFormatDescriptionGetDimensions(b.formatDescription); return Int(x.width) * Int(x.height) < Int(y.width) * Int(y.height) }), (try? d.lockForConfiguration()) != nil {
                d.activeFormat = f; d.unlockForConfiguration()
            }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(out) else { throw CocoaError(.featureUnsupported) }
            session.addOutput(out)
            if let c = out.connection(with: .video) {
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 } else { turned = false }
            }
            session.commitConfiguration()
            configured = true
        }
        queue.async { self.session.startRunning() }
    }
    func stop() { queue.async { self.session.stopRunning(); self.frames = []; self.collect = false } }
    func setCollect(_ on: Bool) { queue.async { self.collect = on; if !on { self.frames = [] } } }
    func take(_ done: @escaping @Sendable ([CGImage]) -> Void) { queue.async { let f = self.frames; self.frames = []; self.collect = false; done(f) } }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let now = CACurrentMediaTime(), orient: CGImagePropertyOrientation = turned ? .up : .right
        let img = CIImage(cvPixelBuffer: pb).oriented(orient), size = img.extent.size
        // Beim Stillhalten Einzelbilder sammeln; gemittelt rauschen sie viel weniger
        if collect, frames.count < 10, now - lastFrame > 0.08, let g = ctx.createCGImage(img, from: img.extent) { frames.append(g); lastFrame = now }
        guard now - lastDetect > 0.08 else { return }
        lastDetect = now
        let seg = VNDetectDocumentSegmentationRequest(), rect = VNDetectRectanglesRequest(), hand = VNDetectHumanHandPoseRequest()
        rect.maximumObservations = 4; rect.minimumSize = 0.2; rect.minimumConfidence = 0.5; rect.quadratureTolerance = 25; rect.minimumAspectRatio = 0.3
        hand.maximumHandCount = 1
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: orient).perform([seg, rect, hand])
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) } // Vision zählt von unten
        func quad(_ o: VNRectangleObservation) -> ScanQuad { ScanQuad(tl: f(o.topLeft), tr: f(o.topRight), br: f(o.bottomRight), bl: f(o.bottomLeft)) }
        // auch ein nur halb sichtbares Blatt zählt, damit Pfeile zeigen können, wohin es soll; gescannt wird ohnehin nur, wenn es ganz drin ist
        var q = seg.results?.first.flatMap { $0.confidence > 0.45 ? quad($0) : nil }
        // Die Segmentierung findet das Blatt sicher, die Kantensuche liegt genauer auf dem Rand: passt eine, nimm sie
        if let s = q, let r = rect.results?.map(quad).filter({ $0.moved(from: s) < 0.05 && $0.area > s.area * 0.85 }).min(by: { $0.moved(from: s) < $1.moved(from: s) }) { q = r }
        // nur eine Hand, die auf dem Blatt liegt, stört; Finger am Rand (Festhalten) nicht
        let inner = q?.inset(0.15)
        let busy = (hand.results ?? []).contains { o in
            guard o.confidence > 0.5, let pts = try? o.recognizedPoints(.all) else { return false }
            return pts.values.contains { $0.confidence > 0.3 && inner?.contains(CGPoint(x: $0.location.x, y: 1 - $0.location.y)) == true }
        }
        onQuad?(q, size, busy)
    }
}

// MARK: Bild sauber machen
extension ScanLogic.Paper {
    var name: String { switch kind { case .a4: L("DIN-A4-Blatt", "A4 sheet"); case .letter: L("Letter-Blatt", "Letter sheet"); case .card: L("Karteikarte", "Index card"); case .note: L("Zettel", "Note"); case .sheet: L("Blatt", "Sheet") } }
}
enum ScanMode: String, CaseIterable { case natural, color, gray, bw
    var title: String { switch self { case .natural: L("Natürlich", "Natural"); case .color: L("Dokument", "Document"); case .gray: L("Graustufen", "Grayscale"); case .bw: L("Schwarzweiß", "B&W") } }
}
struct ScanText { let text: String; let box: CGRect } // box 0…1, Ursprung unten links
struct ScanPage: Identifiable { let id = UUID(); let flat: CGImage; var image: CGImage; let paper: ScanLogic.Paper; let text: [ScanText]
    var plain: String { text.sorted { ($0.box.minY, -$0.box.minX) > ($1.box.minY, -$1.box.minX) }.map(\.text).joined(separator: "\n") } // Leserichtung
}
struct ScanAbout: Equatable { var title = "", kind = "", subject = "" } // von der KI: worum es auf dem Blatt geht

enum ScanProcess {
    static let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    // Mitteln, entzerren, auf Papiergröße bringen
    static func flatten(_ frames: [CGImage], _ q: ScanQuad, _ paper: ScanLogic.Paper, boost force: CGFloat? = nil) -> CGImage? {
        // erst jedes Bild aufs Blatt entzerren, dann am Blattinhalt ausrichten und mitteln: weniger Rauschen, keine Doppelschrift
        // Super-Resolution: ab 4 Bildern aufs doppelte Raster entzerren. Das Blatt liegt in jedem Bild um Bruchteile
        // eines Pixels anders; ausgerichtet und gemittelt ergibt das echte Zusatzschärfe statt nur Hochrechnen
        let boost: CGFloat = force ?? (frames.count >= 4 ? 2 : 1)
        let flats = frames.compactMap { warp($0, q, paper, boost: boost) }
        guard let ref = flats.last else { return nil } // das letzte Bild passt am besten zu den Ecken
        let R = CIImage(cgImage: ref), inner = R.extent.insetBy(dx: R.extent.width * 0.05, dy: R.extent.height * 0.05)
        func diff(_ x: CIImage) -> Double { // mittlere Abweichung zum Referenzbild, 0…765
            var px = [UInt8](repeating: 0, count: 4)
            let d = x.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: R]).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: inner)])
            ctx.render(d, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[0]) + Double(px[1]) + Double(px[2])
        }
        let aligned = flats.dropLast().compactMap { align(ref, CIImage(cgImage: $0), strict: true) }.map { ($0, diff($0)) }
        let best = aligned.map(\.1).min() ?? 0
        var img = R, k = 1
        for (a, d) in aligned where d <= best * 1.5 + 3 { // nur wirklich deckungsgleiche Bilder mitteln
            k += 1
            img = a.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": img, "inputTime": 1 - 1 / Double(k)])
        }
        // Unschärfe der Kamera und des Hochrechnens zurücknehmen; je mehr Bilder, desto weniger Rauschen, desto kräftiger
        if boost > 1, k >= 3 { img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.4, kCIInputIntensityKey: min(0.6, 0.3 + Double(k) * 0.04)]) }
        return ctx.createCGImage(img, from: CGRect(origin: .zero, size: CGSize(width: ref.width, height: ref.height)))
    }
    static func warp(_ frame: CGImage, _ q: ScanQuad, _ paper: ScanLogic.Paper, boost: CGFloat = 1) -> CGImage? {
        let img = CIImage(cgImage: frame)
        let w = img.extent.width, h = img.extent.height
        let c = CGPoint(x: q.points.map(\.x).reduce(0, +) / 4, y: q.points.map(\.y).reduce(0, +) / 4)
        func v(_ p: CGPoint) -> CGPoint { let i = CGPoint(x: p.x + (c.x - p.x) * 0.012, y: p.y + (c.y - p.y) * 0.012); return CGPoint(x: i.x * w, y: (1 - i.y) * h) } // knapp innen: kein Tischrand
        let f = CIFilter.perspectiveCorrection(); f.inputImage = img
        f.topLeft = v(q.tl); f.topRight = v(q.tr); f.bottomRight = v(q.br); f.bottomLeft = v(q.bl)
        guard var out = f.outputImage else { return nil }
        let px = ScanLogic.pixels(paper, source: ScanLogic.sides(q, image: CGSize(width: w, height: h)), boost: boost), s = px.height / out.extent.height
        out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: (px.width / out.extent.width) / s])
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        return ctx.createCGImage(out, from: CGRect(origin: .zero, size: px))
    }
    // Liegt das Blatt quer oder auf dem Kopf? Die Texterkennung liest jede Richtung, verrät aber über die Ecken jeder Zeile, wohin die Schrift läuft
    static func upright(_ g: CGImage) -> CGImagePropertyOrientation {
        let small = CIImage(cgImage: g).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard let s = ctx.createCGImage(small, from: small.extent) else { return .up }
        let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: s).perform([r])
        let lines = r.results ?? []
        guard lines.count >= 2 else { return .up }
        var x = 0.0, y = 0.0
        for t in lines { x += Double(t.topRight.x - t.topLeft.x) * Double(s.width); y += Double(t.topRight.y - t.topLeft.y) * Double(s.height) }
        return ScanLogic.orientation(degrees: atan2(y, x) * 180 / .pi)
    }
    static func turn(_ g: CGImage, _ o: CGImagePropertyOrientation) -> CGImage {
        guard o != .up else { return g }
        let i = CIImage(cgImage: g).oriented(o)
        return ctx.createCGImage(i, from: i.extent) ?? g
    }
    // Schatten und Papierfarbe weg: Bild durch seinen „leeren“ Hintergrund teilen, dann Tinte kräftig, Papier weiß
    static func enhance(_ flat: CGImage, _ mode: ScanMode) -> CGImage? {
        let img = CIImage(cgImage: flat), r = img.extent
        let bg = img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(8, r.width / 120)]).applyingGaussianBlur(sigma: r.width / 55).cropped(to: r)
        var out = bg.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: r) // Ergebnis = Bild / Hintergrund
        if mode == .natural { // wie ein gutes Foto: Schatten und Farbstich sanft weg, Schrift und Papier bleiben natürlich
            let soft = out.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": img, "inputTime": 0.35]) // 65 % ausgeglichen
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.06, kCIInputSaturationKey: 0.9])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.0, kCIInputIntensityKey: 0.25])
            return ctx.createCGImage(soft.cropped(to: r), from: r)
        }
        let curve = CIFilter.toneCurve(); curve.inputImage = out
        curve.point0 = CGPoint(x: 0, y: 0); curve.point1 = CGPoint(x: 0.5, y: 0.1); curve.point2 = CGPoint(x: 0.78, y: 0.42); curve.point3 = CGPoint(x: 0.92, y: 0.95); curve.point4 = CGPoint(x: 1, y: 1)
        out = curve.outputImage ?? out
        switch mode {
        case .natural, .color: out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.95]) // natural kommt oben schon zurück
        case .gray: out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        case .bw: // steil, aber mit weichen Kanten: Buchstaben bleiben ganz statt zu zerfallen
            let k = CIFilter.toneCurve(); k.inputImage = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            k.point0 = CGPoint(x: 0, y: 0); k.point1 = CGPoint(x: 0.6, y: 0.03); k.point2 = CGPoint(x: 0.84, y: 0.45); k.point3 = CGPoint(x: 0.94, y: 0.98); k.point4 = CGPoint(x: 1, y: 1)
            out = k.outputImage ?? out
        }
        if mode != .bw { out = out.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.2, kCIInputIntensityKey: 0.35]) }
        return ctx.createCGImage(out.cropped(to: r), from: r)
    }
    // Zwei entzerrte Aufnahmen derselben Seite: je waagrechtem Streifen gewinnt die schärfere, weich überblendet
    static func merge(_ a: CGImage, _ b: CGImage) -> CGImage {
        let A = CIImage(cgImage: a), r = A.extent
        var B = CIImage(cgImage: b)
        if B.extent.size != r.size { B = B.transformed(by: CGAffineTransform(scaleX: r.width / B.extent.width, y: r.height / B.extent.height)) }
        B = align(a, B)
        let n = 24, h = r.height / CGFloat(n)
        func detail(_ i: CIImage) -> [Double] {
            let e = i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
            return (0..<n).map { k in // k = 0 ist oben
                let band = CGRect(x: r.minX, y: r.maxY - CGFloat(k + 1) * h, width: r.width, height: h)
                var px = [UInt8](repeating: 0, count: 4)
                ctx.render(e.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: band)]), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
                return Double(px[0]) + 0.5
            }
        }
        let da = detail(A), db = detail(B)
        var w = zip(da, db).map { x, y in x * x / (x * x + y * y) }
        w = w.indices.map { i in (w[max(i - 1, 0)] + 2 * w[i] + w[min(i + 1, n - 1)]) / 4 } // Übergänge glätten
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray), let c = CGContext(data: nil, width: 1, height: n, bitsPerComponent: 8, bytesPerRow: 1, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return a }
        if let d = c.data?.assumingMemoryBound(to: UInt8.self) { for i in 0..<n { d[i] = UInt8(max(0, min(255, w[i] * 255))) } } // Zeile 0 = oben
        guard let m = c.makeImage() else { return a }
        let mask = CIImage(cgImage: m).samplingLinear().transformed(by: CGAffineTransform(scaleX: r.width, y: r.height / CGFloat(n))).cropped(to: r)
        let out = A.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: B, kCIInputMaskImageKey: mask]).cropped(to: r)
        return ctx.createCGImage(out, from: r) ?? a
    }
    // zweite Aufnahme passgenau auf die erste legen, sonst wird die Schrift im Übergang doppelt
    static func align(_ a: CGImage, _ b: CIImage) -> CIImage { align(a, b, strict: false) ?? b }
    // strict: lieber weglassen als unsauber ausgerichtet mitteln
    static func align(_ a: CGImage, _ b: CIImage, strict: Bool) -> CIImage? {
        let r = CIImage(cgImage: a).extent
        var B = b, done = false
        if let bb = ctx.createCGImage(B, from: r) {
            let reg = VNHomographicImageRegistrationRequest(targetedCGImage: bb)
            try? VNImageRequestHandler(cgImage: a).perform([reg])
            if let w = (reg.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform {
                func map(_ p: CGPoint) -> CGPoint { // Bildpunkt von B → Lage in A; Vision zählt wie CoreImage von unten links (per Test geprüft)
                    let v = w * simd_float3(Float(p.x), Float(p.y), 1)
                    return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
                }
                let H = r.height
                let corners = [CGPoint(x: 0, y: H), CGPoint(x: r.width, y: H), CGPoint(x: r.width, y: 0), CGPoint(x: 0, y: 0)].map(map)
                let moved = zip(corners, [CGPoint(x: 0, y: H), CGPoint(x: r.width, y: H), CGPoint(x: r.width, y: 0), CGPoint(x: 0, y: 0)]).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
                if moved < r.width * 0.08 { // nur kleine Korrekturen; ein Ausreißer würde das Bild verbiegen
                    let f = CIFilter.perspectiveTransform(); f.inputImage = B
                    f.topLeft = corners[0]; f.topRight = corners[1]; f.bottomRight = corners[2]; f.bottomLeft = corners[3]
                    if let o = f.outputImage { B = o.cropped(to: r); done = true }
                }
            }
        }
        return strict && !done ? nil : B
    }
    static func read(_ g: CGImage) -> [ScanText] {
        let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.recognitionLanguages = ["de-DE", "en-US"]; r.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: g).perform([r])
        return (r.results ?? []).compactMap { o in o.topCandidates(1).first.map { ScanText(text: $0.string, box: o.boundingBox) } }
    }
    // PDF mit unsichtbarer Textebene: durchsuchbar und markierbar wie ein echter Scan
    static func pdf(_ pages: [ScanPage]) -> Data {
        let d = NSMutableData()
        guard let c = CGDataConsumer(data: d), let ctx = CGContext(consumer: c, mediaBox: nil, [kCGPDFContextCreator: "WinKomfort"] as CFDictionary) else { return Data() }
        for p in pages {
            var box = CGRect(origin: .zero, size: p.paper.size)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(p.image, in: box)
            ctx.setTextDrawingMode(.invisible)
            for t in p.text where !t.text.isEmpty {
                let r = CGRect(x: t.box.minX * box.width, y: t.box.minY * box.height, width: t.box.width * box.width, height: t.box.height * box.height)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: t.text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, max(r.height * 0.8, 1), nil)]))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: w > 0 ? r.width / w : 1, y: 1)
                ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.15)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return d as Data
    }
}

// Winkel des Displays (Sensor im Scharnier neuerer MacBooks); fehlt er, bleibt nil
final class LidAngle {
    private let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var dev: IOHIDDevice?
    init() {
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x05AC, kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as NSDictionary as CFDictionary)
        if IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess { dev = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first }
    }
    deinit { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
    func read() -> Int? {
        guard let dev else { return nil }
        var b = [UInt8](repeating: 0, count: 8), n = b.count
        guard IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &b, &n) == kIOReturnSuccess, n >= 3 else { return nil }
        let a = Int(b[1]) | Int(b[2]) << 8
        return (1...200).contains(a) ? a : nil
    }
}

// MARK: Ablauf
@MainActor final class Scanner: ObservableObject {
    static let shared = Scanner()
    enum Phase: Equatable { case starting, live, working, result, failed(String) }
    @Published var phase = Phase.starting
    @Published var quad: ScanQuad?
    @Published var hint = ScanLogic.Hint.empty
    @Published var progress = 0.0
    @Published var paper: ScanLogic.Paper?
    @Published var angle: Int?
    @Published var pages: [ScanPage] = []
    @Published var current = 0
    @Published var flash = false
    @Published var aspect: CGFloat = 3 / 4
    @Published var about: ScanAbout?
    @Published var thinking = false
    @Published var twice = UserDefaults.standard.object(forKey: "scanTwice") as? Bool ?? true { didSet { UserDefaults.standard.set(twice, forKey: "scanTwice") } }
    @Published var turning = false        // erster Durchgang fertig, Blatt drehen
    private var first: (flat: CGImage, paper: ScanLogic.Paper)?
    private var firstQuad: ScanQuad?
    @Published var touched = false // erst weiter, wenn das Blatt wirklich bewegt wurde
    @Published var mode = ScanMode(rawValue: UserDefaults.standard.string(forKey: "scanMode") ?? "") ?? .natural {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "scanMode"); restyle() }
    }
    var goodAngle: Int? { let a = UserDefaults.standard.integer(forKey: "scanAngle"); return a > 0 ? a : nil }
    private let engine = ScanEngine()
    private var prev: ScanQuad?, last = CACurrentMediaTime(), collecting = false, size = CGSize(width: 3, height: 4), recent: [ScanQuad] = []
    private var lid: LidAngle?, tick: Timer?

    var forHand = false // Handschrift-Vorlage: Ergebnis geht direkt ans Einlesen
    var forTidy = false // „Schön machen“: Ergebnis geht direkt dorthin
    static func open(forHand: Bool = false, forTidy: Bool = false) {
        shared.forHand = forHand; shared.forTidy = forTidy
        let first = windows["scan"] == nil
        showWindow("scan", "Scannen", onClose: { MainActor.assumeIsolated { Scanner.shared.stop() } }) { ScanView() }
        windows["scan"]?.title = L("Blatt scannen", "Scan sheet")
        if first { windows["scan"]?.setContentSize(NSSize(width: 760, height: 900)); windows["scan"]?.center(); windows["scan"]?.setFrameAutosaveName("WinKomfortScan") }
        shared.again()
    }
    func again() {
        progress = 0; quad = nil; prev = nil; recent = []; hint = .empty; phase = .starting; turning = false; first = nil
        Task { await start() }
    }
    private func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { phase = .failed(L("Ohne Kamerazugriff geht es nicht. Erlauben unter Systemeinstellungen › Datenschutz › Kamera.", "Camera access is needed: System Settings › Privacy › Camera.")); return }
        case .authorized: break
        default: phase = .failed(L("WinKomfort darf die Kamera nicht benutzen. Erlauben unter Systemeinstellungen › Datenschutz › Kamera.", "WinKomfort may not use the camera: System Settings › Privacy › Camera.")); return
        }
        guard let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.deskViewCamera], mediaType: .video, position: .unspecified).devices.first else {
            phase = .failed(L("Keine Desk-View-Kamera gefunden. Die gibt es bei MacBooks mit Center-Stage-Kamera oder mit einem iPhone als Integrationskamera.", "No Desk View camera found. It needs a MacBook with Center Stage camera or an iPhone as Continuity Camera.")); return
        }
        engine.onQuad = { q, s, h in DispatchQueue.main.async { MainActor.assumeIsolated { Scanner.shared.update(q, s, hand: h) } } }
        do { try engine.start(d) } catch { phase = .failed(L("Die Kamera ließ sich nicht starten.", "The camera could not start.")); return }
        if lid == nil { lid = LidAngle() }
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { let s = Scanner.shared; let a = s.lid?.read(); if a != s.angle { s.angle = a } } }
        phase = .live
    }
    func stop() { engine.stop(); tick?.invalidate(); tick = nil; collecting = false }

    fileprivate func update(_ raw: ScanQuad?, _ s: CGSize, hand: Bool) {
        guard phase == .live else { return }
        let now = CACurrentMediaTime(), dt = min(now - last, 0.25)
        last = now; size = s
        if s.height > 0, abs(s.width / s.height - aspect) > 0.01 { aspect = s.width / s.height }
        // ein Aussetzer lässt den Rahmen nicht verschwinden; ein Sprung beginnt neu
        if let r = raw { if let l = recent.last, r.moved(from: l) > 0.08 { recent = [] }; recent = Array((recent + [r]).suffix(5)) } else if recent.count > 0 { recent.removeFirst() }
        let q = raw == nil && recent.isEmpty ? nil : ScanQuad.median(recent)
        hint = ScanLogic.hint(q, previous: prev, hand: hand); prev = q
        if turning, !touched { // dasselbe Bild zweimal hilft nichts
            if hand || q == nil || firstQuad.map({ f in q.map { $0.moved(from: f) > 0.04 } ?? true }) == true { touched = true }
            else { hint = .empty }
        }
        quad = q.map { n in quad.map { ScanQuad.mix($0, n, 0.6) } ?? n } // ruhige Linien statt Zittern
        if let q { paper = ScanLogic.paper(ScanLogic.sides(q, image: s)) }
        progress = turning && !touched ? 0 : ScanLogic.step(progress, hint, dt: dt)
        let want = progress > 0.2 && hint == .hold // nur ruhige Bilder mitteln, sonst wird die Schrift doppelt
        if want != collecting { collecting = want; engine.setCollect(want) }
        if progress >= 1 { capture() }
    }
    private func capture() {
        guard let q = quad, let p = paper else { return }
        phase = .working; collecting = false
        if let a = angle { UserDefaults.standard.set(a, forKey: "scanAngle") }
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { Scanner.shared.flash = false } }
        let m = mode, one = first, more = twice && first == nil && !forHand && !forTidy
        engine.take { frames in
            var p = one?.paper ?? p, flat = ScanProcess.flatten(frames, q, p)
            if more, let f = flat { // erster von zwei Durchgängen: merken, dann drehen lassen
                DispatchQueue.main.async { MainActor.assumeIsolated { let s = Scanner.shared; s.first = (f, p); s.firstQuad = q; s.touched = false; s.turning = true; s.progress = 0; s.recent = []; s.quad = nil; s.phase = .live } }
                return
            }
            if let a = one, let b = flat { flat = ScanProcess.merge(a.flat, ScanProcess.turn(b, .down)) } // zweiter: um 180° gedreht, schärfere Streifen gewinnen
            if let f = flat { let o = ScanProcess.upright(f); if o != .up { flat = ScanProcess.turn(f, o); if o == .left || o == .right { p = ScanLogic.Paper(kind: p.kind, size: CGSize(width: p.size.height, height: p.size.width)) } } }
            let img = flat.flatMap { ScanProcess.enhance($0, m) }
            let text = img.map(ScanProcess.read) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let s = Scanner.shared
                guard let flat, let img else { s.phase = .live; s.progress = 0; Toast.show(L("Das Bild war zu unscharf, bitte nochmal", "Image too blurry, please try again"), symbol: "exclamationmark.triangle", seconds: 3); return }
                s.engine.stop(); s.tick?.invalidate()
                s.first = nil; s.turning = false
                if s.forHand { s.forHand = false; s.phase = .live; windows["scan"]?.close(); Hand.ingest(flat); return }
                if s.forTidy { s.forTidy = false; s.phase = .live; windows["scan"]?.close(); Tidy.open(); Tidy.shared.take(img); return }
                s.pages.append(ScanPage(flat: flat, image: img, paper: p, text: text)); s.current = s.pages.count - 1
                s.phase = .result
                if s.pages.count == 1 { s.describe() }
            } }
        }
    }
    // Zweiten Durchgang auslassen: das erste Bild reicht
    func skipTurn() {
        guard let f = first else { return }
        engine.setCollect(false); collecting = false
        phase = .working
        let m = mode
        Task.detached(priority: .userInitiated) {
            var p = f.paper, flat = f.flat
            let o = ScanProcess.upright(flat); if o != .up { flat = ScanProcess.turn(flat, o); if o == .left || o == .right { p = ScanLogic.Paper(kind: p.kind, size: CGSize(width: p.size.height, height: p.size.width)) } }
            let img = ScanProcess.enhance(flat, m), text = img.map(ScanProcess.read) ?? []
            await MainActor.run {
                let s = Scanner.shared
                s.first = nil; s.turning = false
                guard let img else { s.phase = .live; return }
                s.engine.stop(); s.tick?.invalidate()
                s.pages.append(ScanPage(flat: flat, image: img, paper: p, text: text)); s.current = s.pages.count - 1
                s.phase = .result
                if s.pages.count == 1 { s.describe() }
            }
        }
    }
    private func restyle() {
        let m = mode, old = pages
        Task.detached(priority: .userInitiated) {
            let new = old.map { p -> ScanPage in var x = p; x.image = ScanProcess.enhance(p.flat, m) ?? p.image; return x }
            await MainActor.run { let s = Scanner.shared; if s.pages.map(\.id) == new.map(\.id) { s.pages = new } }
        }
    }
    func retake() { if pages.indices.contains(current) { pages.remove(at: current) }; current = max(0, pages.count - 1); again() }
    func discard() { pages = []; current = 0; about = nil }
    var text: String { pages.map(\.plain).joined(separator: "\n\n") }
    // Vom iPhone (Dokument scannen oder Foto): ist schon entzerrt, nur noch Text erkennen
    func addPhone(_ img: CGImage) {
        if forHand { forHand = false; windows["scan"]?.close(); stop(); Hand.ingest(img); return }
        if forTidy { forTidy = false; windows["scan"]?.close(); stop(); Tidy.open(); Tidy.shared.take(img); return }
        stop(); phase = .working
        Task {
            let text = await Task.detached(priority: .userInitiated) { ScanProcess.read(img) }.value
            let p = ScanLogic.paper(CGSize(width: img.width, height: img.height))
            let size = p.kind == .a4 ? p.size : CGSize(width: 595, height: 595 * CGFloat(img.height) / CGFloat(max(img.width, 1)))
            pages.append(ScanPage(flat: img, image: img, paper: ScanLogic.Paper(kind: p.kind, size: size), text: text))
            current = pages.count - 1; phase = .result
            if pages.count == 1 { describe() }
        }
    }
    func save() {
        guard !pages.isEmpty else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = suggestedName + ".pdf"
        var dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(L("Scans", "Scans"))
        if let f = about?.subject, !f.isEmpty { dir.appendPathComponent(Self.clean(f)) } // nach Fach sortiert
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); p.directoryURL = dir
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try ScanProcess.pdf(pages).write(to: u, options: .atomic); NSWorkspace.shared.activateFileViewerSelecting([u]); Toast.show(L("Als PDF gesichert, Text durchsuchbar", "Saved as searchable PDF"), symbol: "doc.viewfinder"); discard(); windows["scan"]?.close() }
        catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle", seconds: 4) }
    }
    static func clean(_ s: String) -> String { String(s.replacingOccurrences(of: #"[/:\\\n\r\t*?"<>|]"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(80)) }
    var suggestedName: String {
        guard let a = about, !a.title.isEmpty else { return ScanLogic.fileName(Date()) }
        return Self.clean((a.subject.isEmpty ? "" : a.subject + " – ") + a.title + " " + Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
    }
    func tempPDF() -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName + ".pdf")
        return (try? ScanProcess.pdf(pages).write(to: u, options: .atomic)).map { u }
    }
    func copyImage() {
        guard pages.indices.contains(current) else { return }
        let pb = NSPasteboard.general; pb.clearContents()
        pb.writeObjects([NSImage(cgImage: pages[current].image, size: pages[current].paper.size)])
        if let u = tempPDF() { pb.setData(try? Data(contentsOf: u), forType: .pdf) }
        Toast.show(L("Scan kopiert", "Scan copied"), symbol: "doc.on.doc")
    }
    func copyText() {
        let t = text
        guard !t.isEmpty else { Toast.show(L("Kein Text erkannt", "No text found"), symbol: "text.viewfinder"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        Toast.show(L("Text kopiert", "Text copied"), symbol: "text.viewfinder")
    }
}

// MARK: Oberfläche
private struct CameraView: NSViewRepresentable {
    let session: AVCaptureSession
    let live: Bool // die Verbindung gibt es erst, wenn die Kamera eingerichtet ist
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspectFill
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]; l.frame = v.bounds
        v.layer = l
        Self.turn(l)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { if let l = v.layer as? AVCaptureVideoPreviewLayer { Self.turn(l) } }
    // genauso drehen wie die Bilder für die Erkennung, sonst liegt der Rahmen daneben
    static func turn(_ l: AVCaptureVideoPreviewLayer) {
        guard let c = l.connection else { return }
        if c.isVideoMirroringSupported, c.isVideoMirrored || c.automaticallyAdjustsVideoMirroring { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        if c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 { c.videoRotationAngle = 90 }
    }
}
private struct QuadShape: Shape {
    var q: ScanQuad
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>>> {
        get { .init(.init(q.tl.x, q.tl.y), .init(.init(q.tr.x, q.tr.y), .init(.init(q.br.x, q.br.y), .init(q.bl.x, q.bl.y)))) }
        set { q = ScanQuad(tl: CGPoint(x: newValue.first.first, y: newValue.first.second), tr: CGPoint(x: newValue.second.first.first, y: newValue.second.first.second), br: CGPoint(x: newValue.second.second.first.first, y: newValue.second.second.first.second), bl: CGPoint(x: newValue.second.second.second.first, y: newValue.second.second.second.second)) }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let pts = q.points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
        return p
    }
}

struct ScanView: View {
    @ObservedObject var s = Scanner.shared
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch s.phase {
            case .result: ScanResult(s: s).transition(still ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            case .failed(let m): VStack { ContentUnavailableView(L("Scannen geht gerade nicht", "Scanning unavailable"), systemImage: "camera.badge.ellipsis", description: Text(m)).foregroundStyle(.white); PhoneImportButton(title: L("Mit iPhone scannen", "Scan with iPhone")) { s.addPhone($0) }.fixedSize().padding(.bottom, 40) }
            default: live
            }
        }
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: s.phase)
        .frame(minWidth: 640, minHeight: 560)
        .preferredColorScheme(.dark)
    }
    private var live: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraView(session: Scanner.sharedSession, live: s.phase == .live)
                overlay
                Color.white.opacity(s.flash ? 0.85 : 0).allowsHitTesting(false).animation(still ? nil : .easeOut(duration: 0.3), value: s.flash)
                if s.phase == .working { VStack(spacing: 10) { ProgressView().controlSize(.large); Text(L("Wird sauber gemacht …", "Cleaning up…")).font(.headline) }.padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                if s.phase == .starting { ProgressView().controlSize(.large) }
                if s.turning && !s.touched && s.phase == .live { turnCard }
            }
            .aspectRatio(s.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14)).padding(14)
            bar
        }
    }
    private var overlay: some View {
        GeometryReader { g in
            let r = CGRect(origin: .zero, size: g.size)
            ZStack {
                if let q = s.quad {
                    let ok = s.hint == .hold || s.hint == .moving || s.hint == .hand
                    QuadShape(q: q).fill(Color.accentColor.opacity(0.12))
                    QuadShape(q: q).stroke(.white.opacity(ok ? 0.5 : 0.8), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: ok ? [] : [8, 6]))
                    // Fortschritt läuft als leuchtende Linie einmal ums Blatt
                    QuadShape(q: q).trim(from: 0, to: s.progress).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)).shadow(color: .accentColor, radius: 10)
                    // Scanstrahl wandert mit dem Fortschritt übers Blatt
                    if s.progress > 0 {
                        LinearGradient(colors: [.clear, Color.accentColor.opacity(0.55), .white.opacity(0.9), Color.accentColor.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 34).position(x: r.midX, y: r.minY + r.height * scanY(q))
                            .mask(QuadShape(q: q).fill()).blendMode(.screen)
                    }
                    ForEach(Array(q.points.enumerated()), id: \.offset) { _, p in
                        Circle().fill(.white).frame(width: 10, height: 10).shadow(color: .accentColor, radius: s.progress > 0 ? 8 : 0)
                            .scaleEffect(1 + s.progress * 0.5).position(x: p.x * r.width, y: p.y * r.height)
                    }
                    chip(q, r)
                    if let d = push { arrows(d, r) }
                } else {
                    guide(r)
                }
            }
            .animation(still ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.86), value: s.quad) // folgt dem Blatt wie ein Gummiband
        }
    }
    // Animierte Karte: Blatt dreht sich um 180°
    private var turnCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Image(systemName: "arrow.trianglehead.clockwise").font(.system(size: 64, weight: .light)).foregroundStyle(Color.accentColor)
                Image(systemName: "doc.text.fill").font(.system(size: 30))
                    .phaseAnimator(still ? [0.0] : [0.0, 180.0]) { v, a in v.rotationEffect(.degrees(a)) } animation: { _ in .spring(response: 0.9, dampingFraction: 0.8).delay(0.4) }
            }
            .frame(height: 80)
            Text(L("Jetzt das Blatt um 180° drehen", "Now turn the sheet around (180°)")).font(.title3.weight(.semibold))
            Text(L("Dann ist auch die andere Hälfte nah an der Kamera. Aus beiden Aufnahmen wird die schärfste Seite.", "Then the other half is close to the camera too. Both shots are merged into the sharpest page.")).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 320)
            Button(L("Überspringen, erstes Bild reicht", "Skip, first shot is fine")) { s.skipTurn() }.buttonStyle(.bordered).keyboardShortcut(.return, modifiers: [])
        }
        .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
    // Wohin das Blatt soll: Pfeil zeigt die Schieberichtung
    private var push: (symbol: String, dx: CGFloat, dy: CGFloat)? {
        switch s.hint {
        case .cutNear: return ("chevron.up", 0, -1)
        case .cutFar: return ("chevron.down", 0, 1)
        case .cutLeft: return ("chevron.right", 1, 0)
        case .cutRight: return ("chevron.left", -1, 0)
        default: return nil
        }
    }
    private func arrows(_ d: (symbol: String, dx: CGFloat, dy: CGFloat), _ r: CGRect) -> some View {
        let forward = d.dx + d.dy > 0 // nach rechts/unten: der letzte Pfeil ist der hellste
        return (d.dx != 0 ? AnyLayout(HStackLayout(spacing: -18)) : AnyLayout(VStackLayout(spacing: -18))) {
            ForEach(0..<3) { i in Image(systemName: d.symbol).font(.system(size: 54, weight: .bold)).opacity(0.35 + Double(forward ? i : 2 - i) * 0.3) }
        }
            .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 8)
            .phaseAnimator(still ? [0.0] : [0.0, 1.0]) { v, t in v.offset(x: d.dx * 26 * t, y: d.dy * 26 * t) } animation: { _ in .spring(duration: 0.7, bounce: 0.25) }
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false).transition(.opacity)
    }
    private func scanY(_ q: ScanQuad) -> CGFloat { let top = q.points.map(\.y).min()!, bottom = q.points.map(\.y).max()!; return top + (bottom - top) * s.progress }
    private func chip(_ q: ScanQuad, _ r: CGRect) -> some View {
        let top = q.points.min { $0.y < $1.y }!, x = q.points.map(\.x).reduce(0, +) / 4
        return HStack(spacing: 6) {
            Image(systemName: s.progress > 0 ? "viewfinder" : "doc.text.viewfinder")
            Text((s.paper?.name ?? L("Blatt", "Sheet")) + L(" erkannt", " found") + (s.progress > 0 ? " · \(Int(s.progress * 100)) %" : "")).monospacedDigit()
        }
        .font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
        .position(x: min(max(x * r.width, 110), r.width - 110), y: max(top.y * r.height - 26, 20))
    }
    private func guide(_ r: CGRect) -> some View {
        let h = r.height * 0.78, w = h / 1.414
        return VStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 34, weight: .light))
            Text(L("Blatt hier hinlegen", "Place sheet here")).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: w, height: h)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [10, 8])))
        .phaseAnimator(still ? [1.0] : [0.55, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 1.2) }
        .position(x: r.midX, y: r.midY)
    }
    private var hintText: (String, String) {
        switch s.hint {
        case .empty: return ("doc.viewfinder", L("Leg ein Blatt vor deinen Mac", "Place a sheet in front of your Mac"))
        case .small: return ("arrow.up.forward.and.arrow.down.backward", L("Das Blatt ist sehr klein im Bild: näher an den Mac legen", "Sheet looks small: move it closer to your Mac"))
        case .cutNear: return ("arrow.down.to.line", L("Unten abgeschnitten: Display etwas weiter öffnen oder das Blatt zum Mac schieben", "Cut off at the bottom: open the display a little more or push the sheet towards the Mac"))
        case .cutFar: return ("arrow.up.to.line", L("Oben abgeschnitten: Display etwas zuklappen oder das Blatt zu dir ziehen", "Cut off at the top: tilt the display forward a little or pull the sheet towards you"))
        case .cutLeft: return ("arrow.right", L("Links abgeschnitten: Blatt nach rechts schieben", "Cut off on the left: move the sheet right"))
        case .cutRight: return ("arrow.left", L("Rechts abgeschnitten: Blatt nach links schieben", "Cut off on the right: move the sheet left"))
        case .hand: return ("hand.raised.slash", L("Hand vom Blatt nehmen", "Take your hand off the sheet"))
        case .moving: return ("hand.raised", L("Ruhig liegen lassen …", "Keep it still…"))
        case .hold, .done: return ("viewfinder", s.turning ? L("Zweiter Durchgang … nicht bewegen", "Second pass… don't move") : L("Scanne … nicht bewegen", "Scanning… don't move"))
        }
    }
    // zwei Zeilen: oben was zu tun ist, unten die Bedienung – in einer Zeile überlappten Schalter und Modus-Auswahl
    private var bar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: hintText.0).font(.title2).foregroundStyle(s.hint == .hold ? Color.accentColor : .white).frame(width: 30).contentTransition(.symbolEffect(.replace))
                Text(hintText.1).font(.title3.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentTransition(.opacity)
                if let a = s.angle {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L("Display \(a)°", "Display \(a)°")).monospacedDigit().font(.callout.weight(.semibold))
                        if let g = s.goodAngle, abs(g - a) > 4 { Text(L("zuletzt gut: \(g)°", "worked at \(g)°")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .fixedSize()
                    .help(L("Winkel deines Displays. Gemerkt wird der Winkel, bei dem der letzte Scan geklappt hat.", "Your display angle. The angle of the last successful scan is remembered."))
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $s.mode) { ForEach(ScanMode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(L("2 Durchgänge", "2 passes"), isOn: $s.twice).toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help(L("Blatt einmal drehen und zweimal scannen: deutlich schärfer, dauert ein paar Sekunden länger", "Turn the sheet and scan twice: much sharper, takes a few seconds longer"))
                Spacer(minLength: 8)
                PhoneImportButton(title: L("iPhone", "iPhone")) { s.addPhone($0) }.fixedSize()
                    .help(L("Mit der iPhone-Kamera scannen: noch schärfer, z. B. für Tafelbilder oder kleine Schrift", "Scan with the iPhone camera: even sharper, e.g. for whiteboards or small print"))
                if !s.pages.isEmpty { Button(L("\(s.pages.count) Seite(n) ›", "\(s.pages.count) page(s) ›")) { s.stop(); s.phase = .result }.buttonStyle(.bordered).fixedSize() }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 16).foregroundStyle(.white)
        .animation(still ? nil : .smooth(duration: 0.3), value: s.hint)
    }
}
extension Scanner { static var sharedSession: AVCaptureSession { shared.engine.session } }

private struct ScanResult: View {
    @ObservedObject var s: Scanner
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        VStack(spacing: 0) {
            if s.pages.indices.contains(s.current) {
                let p = s.pages[s.current]
                Image(decorative: p.image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .background(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrag { s.tempPDF().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                    .help(L("Zum Ablegen herausziehen, z. B. in eine Mail", "Drag out, e.g. into an email"))
                    .id(p.id).transition(still ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    .accessibilityLabel(L("Gescannte Seite \(s.current + 1)", "Scanned page \(s.current + 1)"))
            }
            if s.pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(Array(s.pages.enumerated()), id: \.element.id) { i, p in
                    Button { s.current = i } label: { Image(decorative: p.image, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(height: 64).background(.white).overlay(RoundedRectangle(cornerRadius: 2).stroke(i == s.current ? Color.accentColor : .clear, lineWidth: 3)) }
                        .buttonStyle(.plain).accessibilityLabel(L("Seite \(i + 1)", "Page \(i + 1)"))
                } }.padding(.horizontal, 18) }.frame(height: 76)
            }
            HStack(spacing: 8) {
                if s.thinking || s.about != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        if let a = s.about { Text([a.kind, a.subject, a.title.isEmpty ? "" : "„\(a.title)“"].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1) }
                        if s.thinking { ProgressView().controlSize(.small); Text(L("KI liest mit …", "AI is reading…")).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                }
                if Assistant.available {
                    Button(L("Zusammenfassen", "Summarize")) { s.ask(L("Fasse dieses Blatt kurz und verständlich zusammen.", "Summarize this sheet briefly.")) }
                    Button(L("Erklären", "Explain")) { s.ask(L("Erkläre mir einfach, worum es auf diesem Blatt geht und was ich tun soll.", "Explain simply what this sheet is about and what I should do.")) }
                    Button(L("Lernkarten", "Flashcards")) { s.cards() }
                    Button(L("Schön in OneNote", "Tidy into OneNote")) { if s.pages.indices.contains(s.current) { Tidy.open(); Tidy.shared.take(s.pages[s.current].image) } }
                        .help(L("KI ordnet den Text des Blatts mit Überschriften, Einrückungen und Formeln und fügt ihn in OneNote ein", "AI arranges the sheet's text with headings, indents and formulas and pastes it into OneNote"))
                    Button(L("Als Aufgabe eintragen", "Add as task")) { s.homework() }
                    Button(L("Frage stellen …", "Ask…")) { s.ask("") }
                }
            }
            .font(.callout).controlSize(.small).disabled(s.thinking).padding(.top, 4)
            HStack(spacing: 10) {
                Picker("", selection: $s.mode) { ForEach(ScanMode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                let words = s.pages.reduce(0) { $0 + $1.text.reduce(0) { $0 + $1.text.split(separator: " ").count } }
                Text(words > 0 ? L("\(words) Wörter", "\(words) words") : L("kein Text", "no text")).font(.callout).foregroundStyle(.secondary).fixedSize()
                Spacer()
                Button(L("Neu scannen", "Retake")) { s.retake() }
                Button(L("Weitere Seite", "Add page")) { s.again() }.keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            HStack(spacing: 10) { // zweite Zeile: sonst wurden bei normaler Fenstergröße Knöpfe abgeschnitten
                Spacer()
                Button(L("Bild kopieren", "Copy image")) { s.copyImage() }.keyboardShortcut("c", modifiers: .command)
                Button(L("Text kopieren", "Copy text")) { s.copyText() }.disabled(s.text.isEmpty)
                Button(L("Als PDF sichern …", "Save as PDF…")) { s.save() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .animation(still ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: s.current)
    }
}

// MARK: KI (Apple-Modell auf dem Mac): Titel, Art und Fach erkennen, zusammenfassen, Lernkarten
extension Scanner {
    func describe() {
        let t = text
        guard Assistant.available, t.split(separator: " ").count >= 6 else { return }
        let subjects = Plan.subjects(School.shared.book)
        thinking = true
        Task {
            defer { thinking = false }
            guard #available(macOS 26.0, *) else { return }
            let s = LanguageModelSession(instructions: "Du ordnest gescannte Schulblätter und Dokumente ein. Antworte nur mit einer Zeile im Format: Titel | Art | Fach")
            let list = subjects.isEmpty ? "" : "Fächer des Schülers: " + subjects.joined(separator: ", ") + ".\n"
            let q = list + "Titel: 2 bis 6 Wörter aus Überschrift oder Thema. Art: Arbeitsblatt, Klausur, Test, Mitschrift, Notizen, Hausaufgabe, Brief, Rechnung, Formular oder Sonstiges. Fach: aus der Liste, sonst das passende Schulfach, sonst leer.\nText des Blatts (Texterkennung, kann Fehler enthalten):\n" + String(t.prefix(3000))
            guard let r = try? await s.respond(to: q).content, let g = ScanLogic.guess(r) else { return }
            about = ScanAbout(title: g.title, kind: g.kind, subject: g.subject)
        }
    }
    private var doc: AIDoc { AIDoc(name: (about?.title).flatMap { $0.isEmpty ? nil : $0 } ?? L("Gescanntes Blatt", "Scanned sheet"), text: String(text.prefix(12000))) }
    func ask(_ q: String) {
        guard AI.ready(), !text.isEmpty else { if text.isEmpty { Toast.show(L("Auf dem Blatt wurde kein Text erkannt", "No text found on the sheet"), symbol: "text.viewfinder") }; return }
        AIChat.shared.reset(); AI.open()
        if q.isEmpty { AIChat.shared.docs = [doc] } else { AIChat.shared.ask(q, docs: [doc]) } // ohne Frage nur anhängen, du tippst selbst
    }
    // Lernkarten direkt in Schule › Lernkarten
    // Arbeitsauftrag erkennen und in Schule › Aufgaben eintragen (Fach und Termin wie beim Eintippen)
    func homework() {
        guard AI.ready(), !text.isEmpty else { return }
        thinking = true
        let t = text, subjects = Plan.subjects(School.shared.book), name = about?.subject ?? ""
        Task {
            defer { thinking = false }
            guard #available(macOS 26.0, *) else { return }
            let s = LanguageModelSession(instructions: "Du liest gescannte Schulblätter und formulierst den Arbeitsauftrag als eine kurze Zeile, wie ein Schüler sie ins Hausaufgabenheft schreibt: Fach, was zu tun ist, und wenn auf dem Blatt ein Termin steht, „bis …“. Nur diese eine Zeile.")
            let q = (subjects.isEmpty ? "" : "Fächer: " + subjects.joined(separator: ", ") + ". ") + (name.isEmpty ? "" : "Vermutetes Fach: \(name). ") + "Text des Blatts:\n" + String(t.prefix(2500))
            guard let line = try? await s.respond(to: q).content.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty, let k = School.shared.add(String(line.prefix(200))) else {
                Toast.show(L("Ich habe keinen Arbeitsauftrag gefunden", "Couldn't find an assignment"), symbol: "checklist", seconds: 3); return
            }
            Toast.show(L("Eingetragen bis \(k.due.formatted(.dateTime.weekday(.wide).day().month())): ", "Added for \(k.due.formatted(.dateTime.weekday(.wide).day().month())): ") + (k.subject.isEmpty ? "" : k.subject + " · ") + k.text, symbol: "checklist", seconds: 4)
        }
    }
    func cards() {
        guard AI.ready(), !text.isEmpty else { return }
        thinking = true
        let t = text, name = (about?.title).flatMap { $0.isEmpty ? nil : $0 } ?? L("Gescanntes Blatt", "Scanned sheet")
        Task {
            defer { thinking = false }
            guard #available(macOS 26.0, *) else { return }
            let s = LanguageModelSession(instructions: "Du erstellst Lernkarten für Schüler. Nur Fakten aus dem Text, nichts erfinden.")
            let r = (try? await s.respond(to: "Erstelle 5 bis 12 Lernkarten zu diesem Text. Eine Karte pro Zeile im Format: Frage | Antwort. Sonst nichts.\n\n" + String(t.prefix(3500))).content) ?? ""
            let c = Plan.cards(r)
            guard !c.isEmpty else { Toast.show(L("Daraus ließen sich keine Lernkarten machen", "Couldn't make flashcards from this"), symbol: "rectangle.on.rectangle", seconds: 3); return }
            School.shared.book.decks.append(Plan.Deck(name: name, cards: c))
            Toast.show(L("\(c.count) Lernkarten in Schule › Lernkarten", "\(c.count) flashcards in School › Flashcards"), symbol: "rectangle.on.rectangle")
            School.open("karten")
        }
    }
}
