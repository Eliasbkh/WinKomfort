// Blatt scannen mit der Desk-View-Kamera (⌃⌥B): erkennen, stillhalten, entzerren, sauber wie aus dem Scanner
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import IOKit.hid
import SwiftUI
import Vision

// MARK: Kamera und Erkennung (eigene Warteschlange)
final class ScanEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "winkomfort.scan", qos: .userInitiated)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    var onQuad: (@Sendable (ScanQuad?, CGSize) -> Void)?
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
            if let c = out.connection(with: .video), c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
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
        let now = CACurrentMediaTime(), size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        // Beim Stillhalten Einzelbilder sammeln; gemittelt rauschen sie viel weniger
        if collect, frames.count < 8, now - lastFrame > 0.1, let g = ctx.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(origin: .zero, size: size)) { frames.append(g); lastFrame = now }
        guard now - lastDetect > 0.08 else { return }
        lastDetect = now
        let r = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([r])
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) } // Vision zählt von unten
        let q = r.results?.first.flatMap { $0.confidence > 0.6 ? ScanQuad(tl: f($0.topLeft), tr: f($0.topRight), br: f($0.bottomRight), bl: f($0.bottomLeft)) : nil }
        onQuad?(q, size)
    }
}

// MARK: Bild sauber machen
extension ScanLogic.Paper {
    var name: String { switch kind { case .a4: L("DIN-A4-Blatt", "A4 sheet"); case .letter: L("Letter-Blatt", "Letter sheet"); case .card: L("Karteikarte", "Index card"); case .note: L("Zettel", "Note"); case .sheet: L("Blatt", "Sheet") } }
}
enum ScanMode: String, CaseIterable { case color, gray, bw
    var title: String { switch self { case .color: L("Farbe", "Color"); case .gray: L("Graustufen", "Grayscale"); case .bw: L("Schwarzweiß", "B&W") } }
}
struct ScanText { let text: String; let box: CGRect } // box 0…1, Ursprung unten links
struct ScanPage: Identifiable { let id = UUID(); let flat: CGImage; var image: CGImage; let paper: ScanLogic.Paper; let text: [ScanText] }

enum ScanProcess {
    static let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    // Mitteln, entzerren, auf Papiergröße bringen
    static func flatten(_ frames: [CGImage], _ q: ScanQuad, _ paper: ScanLogic.Paper) -> CGImage? {
        guard var img = frames.first.map(CIImage.init(cgImage:)) else { return nil }
        for (k, g) in frames.dropFirst().enumerated() { // laufender Mittelwert
            img = CIImage(cgImage: g).applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": img, "inputTime": 1 - 1 / Double(k + 2)])
        }
        let w = img.extent.width, h = img.extent.height
        let c = CGPoint(x: q.points.map(\.x).reduce(0, +) / 4, y: q.points.map(\.y).reduce(0, +) / 4)
        func v(_ p: CGPoint) -> CGPoint { let i = CGPoint(x: p.x + (c.x - p.x) * 0.012, y: p.y + (c.y - p.y) * 0.012); return CGPoint(x: i.x * w, y: (1 - i.y) * h) } // knapp innen: kein Tischrand
        let f = CIFilter.perspectiveCorrection(); f.inputImage = img
        f.topLeft = v(q.tl); f.topRight = v(q.tr); f.bottomRight = v(q.br); f.bottomLeft = v(q.bl)
        guard var out = f.outputImage else { return nil }
        let px = ScanLogic.pixels(paper), s = px.height / out.extent.height
        out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: (px.width / out.extent.width) / s])
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        return ctx.createCGImage(out, from: CGRect(origin: .zero, size: px))
    }
    // Schatten und Papierfarbe weg: Bild durch seinen „leeren“ Hintergrund teilen, dann Tinte satt und Papier weiß
    static func enhance(_ flat: CGImage, _ mode: ScanMode) -> CGImage? {
        let img = CIImage(cgImage: flat), r = img.extent
        let bg = img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(6, r.width / 200)]).applyingGaussianBlur(sigma: r.width / 70).cropped(to: r)
        var out = bg.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: r) // Ergebnis = Bild / Hintergrund
        let curve = CIFilter.toneCurve(); curve.inputImage = out
        curve.point0 = CGPoint(x: 0, y: 0); curve.point1 = CGPoint(x: 0.3, y: 0.12); curve.point2 = CGPoint(x: 0.62, y: 0.55); curve.point3 = CGPoint(x: 0.86, y: 0.98); curve.point4 = CGPoint(x: 1, y: 1)
        out = curve.outputImage ?? out
        switch mode {
        case .color: out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
        case .gray: out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        case .bw: out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIColorThresholdOtsu")
        }
        if mode != .bw { out = out.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.6, kCIInputIntensityKey: 0.6]) }
        return ctx.createCGImage(out.cropped(to: r), from: r)
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
    @Published var mode = ScanMode(rawValue: UserDefaults.standard.string(forKey: "scanMode") ?? "") ?? .color {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "scanMode"); restyle() }
    }
    var goodAngle: Int? { let a = UserDefaults.standard.integer(forKey: "scanAngle"); return a > 0 ? a : nil }
    private let engine = ScanEngine()
    private var prev: ScanQuad?, last = CACurrentMediaTime(), collecting = false, size = CGSize(width: 4, height: 3)
    private var lid: LidAngle?, tick: Timer?

    static func open() {
        let first = windows["scan"] == nil
        showWindow("scan", "Scannen", onClose: { MainActor.assumeIsolated { Scanner.shared.stop() } }) { ScanView() }
        windows["scan"]?.title = L("Blatt scannen", "Scan sheet")
        if first { windows["scan"]?.setContentSize(NSSize(width: 900, height: 760)); windows["scan"]?.center(); windows["scan"]?.setFrameAutosaveName("WinKomfortScan") }
        shared.again()
    }
    func again() {
        progress = 0; quad = nil; prev = nil; hint = .empty; phase = .starting
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
        engine.onQuad = { q, s in DispatchQueue.main.async { MainActor.assumeIsolated { Scanner.shared.update(q, s) } } }
        do { try engine.start(d) } catch { phase = .failed(L("Die Kamera ließ sich nicht starten.", "The camera could not start.")); return }
        if lid == nil { lid = LidAngle() }
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { let s = Scanner.shared; let a = s.lid?.read(); if a != s.angle { s.angle = a } } }
        phase = .live
    }
    func stop() { engine.stop(); tick?.invalidate(); tick = nil; collecting = false }

    fileprivate func update(_ q: ScanQuad?, _ s: CGSize) {
        guard phase == .live else { return }
        let now = CACurrentMediaTime(), dt = min(now - last, 0.25)
        last = now; size = s
        hint = ScanLogic.hint(q, previous: prev); prev = q
        quad = q.map { n in quad.map { ScanQuad.mix($0, n, 0.55) } ?? n } // ruhige Linien statt Zittern
        if let q { paper = ScanLogic.paper(ScanLogic.sides(q, image: s)) }
        progress = ScanLogic.step(progress, hint, dt: dt)
        let want = progress > 0.2
        if want != collecting { collecting = want; engine.setCollect(want) }
        if progress >= 1 { capture() }
    }
    private func capture() {
        guard let q = quad, let p = paper else { return }
        phase = .working; collecting = false
        if let a = angle { UserDefaults.standard.set(a, forKey: "scanAngle") }
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { Scanner.shared.flash = false } }
        let m = mode
        engine.take { frames in
            let flat = ScanProcess.flatten(frames, q, p)
            let img = flat.flatMap { ScanProcess.enhance($0, m) }
            let text = img.map(ScanProcess.read) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let s = Scanner.shared
                guard let flat, let img else { s.phase = .live; s.progress = 0; Toast.show(L("Das Bild war zu unscharf, bitte nochmal", "Image too blurry, please try again"), symbol: "exclamationmark.triangle", seconds: 3); return }
                s.engine.stop(); s.tick?.invalidate()
                s.pages.append(ScanPage(flat: flat, image: img, paper: p, text: text)); s.current = s.pages.count - 1
                s.phase = .result
            } }
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
    func discard() { pages = []; current = 0 }
    var text: String { pages.flatMap { p in p.text.sorted { ($0.box.minY, -$0.box.minX) > ($1.box.minY, -$1.box.minX) }.map(\.text) }.joined(separator: "\n") }
    func save() {
        guard !pages.isEmpty else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = ScanLogic.fileName(Date()) + ".pdf"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(L("Scans", "Scans"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); p.directoryURL = dir
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try ScanProcess.pdf(pages).write(to: u, options: .atomic); NSWorkspace.shared.activateFileViewerSelecting([u]); Toast.show(L("Als PDF gesichert, Text durchsuchbar", "Saved as searchable PDF"), symbol: "doc.viewfinder"); discard(); windows["scan"]?.close() }
        catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle", seconds: 4) }
    }
    func tempPDF() -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(ScanLogic.fileName(Date()) + ".pdf")
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
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspect
        if let c = l.connection, c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]; l.frame = v.bounds
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
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
            case .failed(let m): ContentUnavailableView(L("Scannen geht gerade nicht", "Scanning unavailable"), systemImage: "camera.badge.ellipsis", description: Text(m)).foregroundStyle(.white)
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
                CameraView(session: Scanner.sharedSession)
                overlay
                Color.white.opacity(s.flash ? 0.85 : 0).allowsHitTesting(false).animation(still ? nil : .easeOut(duration: 0.3), value: s.flash)
                if s.phase == .working { VStack(spacing: 10) { ProgressView().controlSize(.large); Text(L("Wird sauber gemacht …", "Cleaning up…")).font(.headline) }.padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                if s.phase == .starting { ProgressView().controlSize(.large) }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14)).padding(14)
            bar
        }
    }
    private var overlay: some View {
        GeometryReader { g in
            let r = CGRect(origin: .zero, size: g.size)
            ZStack {
                if let q = s.quad {
                    let ok = s.hint == .hold || s.hint == .moving
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
                } else {
                    guide(r)
                }
            }
            .animation(still ? nil : .easeOut(duration: 0.12), value: s.quad)
        }
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
        case .cutSide: return ("arrow.left.and.right", L("Seitlich abgeschnitten: Blatt mehr in die Mitte legen", "Cut off at the side: move the sheet to the middle"))
        case .moving: return ("hand.raised", L("Ruhig liegen lassen …", "Keep it still…"))
        case .hold, .done: return ("viewfinder", L("Scanne … nicht bewegen", "Scanning… don't move"))
        }
    }
    private var bar: some View {
        HStack(spacing: 14) {
            Image(systemName: hintText.0).font(.title2).foregroundStyle(s.hint == .hold ? Color.accentColor : .white).frame(width: 30).contentTransition(.symbolEffect(.replace))
            Text(hintText.1).font(.title3.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentTransition(.opacity)
            if let a = s.angle {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L("Display \(a)°", "Display \(a)°")).monospacedDigit().font(.callout.weight(.semibold))
                    if let g = s.goodAngle, abs(g - a) > 4 { Text(L("zuletzt gut: \(g)°", "worked at \(g)°")).font(.caption).foregroundStyle(.secondary) }
                }
                .help(L("Winkel deines Displays. Gemerkt wird der Winkel, bei dem der letzte Scan geklappt hat.", "Your display angle. The angle of the last successful scan is remembered."))
            }
            Picker("", selection: $s.mode) { ForEach(ScanMode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if !s.pages.isEmpty { Button(L("\(s.pages.count) Seite(n) ›", "\(s.pages.count) page(s) ›")) { s.stop(); s.phase = .result }.buttonStyle(.bordered) }
        }
        .padding(.horizontal, 18).padding(.bottom, 16).foregroundStyle(.white)
        .animation(still ? nil : .easeOut(duration: 0.2), value: s.hint)
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
            HStack(spacing: 10) {
                let words = s.pages.reduce(0) { $0 + $1.text.reduce(0) { $0 + $1.text.split(separator: " ").count } }
                Text(words > 0 ? L("\(words) Wörter erkannt", "\(words) words found") : L("Kein Text erkannt", "No text found")).font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $s.mode) { ForEach(ScanMode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                Button(L("Neu scannen", "Retake")) { s.retake() }
                Button(L("Weitere Seite", "Add page")) { s.again() }.keyboardShortcut("n", modifiers: .command)
                Menu(L("Kopieren", "Copy")) { Button(L("Bild", "Image")) { s.copyImage() }; Button(L("Erkannten Text", "Recognized text")) { s.copyText() } }.fixedSize()
                Button(L("Als PDF sichern …", "Save as PDF…")) { s.save() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
            .padding(16)
        }
        .animation(still ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: s.current)
    }
}
