// Handy als Fernbedienung und zweiter Bildschirm: kleiner Server nur im lokalen Netz und nur, solange das Fenster offen ist.
// Ohne den Schlüssel aus dem QR-Code geht nichts; genau ein Handy gleichzeitig.
import AppKit
import SwiftUI
import Network
import CryptoKit
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit

@MainActor final class Remote: ObservableObject {
    static let shared = Remote()
    enum State: Equatable { case off, waiting, asking(String), connected, failed(String) }
    @Published private(set) var state = State.off
    @Published private(set) var url = ""
    @Published private(set) var screenOn = false
    private var listener: NWListener?
    private var key: [UInt8] = []
    private var conns: [ObjectIdentifier: RemoteConn] = [:]
    fileprivate var active: RemoteConn?
    private var down = false
    private var screen: RemoteScreen?

    func start() {
        guard listener == nil else { return }
        guard let ip = Self.address() else { state = .failed(L("Kein WLAN – Mac und Handy müssen im selben Netz sein.", "No Wi-Fi – Mac and phone must be on the same network.")); return }
        var g = SystemRandomNumberGenerator()
        key = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
        do {
            let l = try NWListener(using: .tcp, on: .any)
            l.stateUpdateHandler = { s in MainActor.assumeIsolated { Remote.shared.listening(s, l, ip) } }
            l.newConnectionHandler = { c in MainActor.assumeIsolated { Remote.shared.accept(c) } }
            l.start(queue: .main)
            listener = l
        } catch { state = .failed(L("Server ließ sich nicht starten.", "Couldn't start the server.")) }
    }
    private func listening(_ s: NWListener.State, _ l: NWListener, _ ip: String) {
        guard l === listener else { return }
        switch s {
        case .ready:
            let k = Data(key).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            url = "http://\(ip):\(l.port?.rawValue ?? 0)/#\(k)"
            state = .waiting
        case .failed: stop(); state = .failed(L("Server ließ sich nicht starten.", "Couldn't start the server."))
        default: break
        }
    }
    func stop() {
        stopScreen()
        release()
        listener?.cancel(); listener = nil
        conns.values.forEach { $0.close() }
        conns = [:]; active = nil; key = []; url = ""; token = ""
        state = .off
    }
    private func accept(_ c: NWConnection) {
        guard conns.count < 12 else { c.cancel(); return }
        let r = RemoteConn(c, key: key)
        conns[ObjectIdentifier(r)] = r
        r.start()
    }
    fileprivate func closed(_ r: RemoteConn) {
        conns[ObjectIdentifier(r)] = nil
        if active === r { active = nil; release(); stopScreen(); if listener != nil { state = .waiting } }
    }
    // Erste echte (entschlüsselbare) Nachricht: am Mac nachfragen (ein abfotografierter QR-Code reicht so nicht).
    // Nach der Erlaubnis darf dasselbe Handy mit seinem Merkwort wieder verbinden. Ein zweites Gerät wird abgewiesen.
    // Grenze: gegen ein manipuliertes WLAN, das die Seite selbst fälscht, schützt das nicht – deshalb der Hinweis im Fenster.
    private var token = ""
    fileprivate func authenticated(_ r: RemoteConn, _ d: [String: Any]) -> Bool {
        if let a = active { return a === r }
        active = r
        if !token.isEmpty, d["k"] as? String == token, d["t"] as? String == "hi" { approve() } else { state = .asking(r.peer) }
        return true
    }
    func approve() {
        guard active != nil else { return }
        if token.isEmpty {
            var g = SystemRandomNumberGenerator()
            token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
        }
        state = .connected
        sendInfo()
    }
    // Ablehnen: alles aus, der alte QR-Code gilt nicht mehr
    func deny() { stop(); start() }
    private func sendInfo() {
        let apps = Launcher.shared.keys.filter { $0.kind != .command && $0.kind != .remap }.map { ["id": $0.id.uuidString, "name": Launcher.shared.title($0)] }
        active?.send(json: ["t": "info", "name": Host.current().localizedName ?? "Mac", "apps": apps, "lang": L("de", "en"), "k": token])
    }

    // MARK: Befehle
    private func num(_ d: [String: Any], _ k: String) -> Double { let v = (d[k] as? NSNumber)?.doubleValue ?? 0; return v.isFinite ? v : 0 }
    fileprivate func handle(_ d: [String: Any]) {
        guard state == .connected else { return } // erst nach der Erlaubnis am Mac
        switch d["t"] as? String {
        case "move": move(CGPoint(x: pos.x + min(max(num(d, "x"), -400), 400), y: pos.y + min(max(num(d, "y"), -400), 400)))
        case "click": click(right: d["r"] as? Bool ?? false, count: min(max(Int(num(d, "n")), 1), 2))
        case "down": if !down { down = true; post(.leftMouseDown, pos) }
        case "up": release()
        case "scroll":
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(min(max(num(d, "y"), -600), 600)), wheel2: Int32(min(max(num(d, "x"), -600), 600)), wheel3: 0)?.post(tap: .cghidEventTap)
        case "text": type(String((d["s"] as? String ?? "").prefix(500)))
        case "key": if let c = Self.keys[d["k"] as? String ?? ""] { Launcher.press(c) }
        case "sys": if let a = SystemAction(rawValue: d["k"] as? String ?? ""), Self.allowed.contains(a) { _ = a.perform() }
        case "app": if let k = Launcher.shared.keys.first(where: { $0.id.uuidString == d["id"] as? String }), k.kind != .command, k.kind != .remap { Launcher.shared.perform(k) }
        case "screen": startScreen(Int(num(d, "w")), Int(num(d, "h")))
        case "noscreen": stopScreen()
        case "got": screen?.ready = true
        case "abs":
            guard let s = screen, let b = s.bounds else { return }
            let p = CGPoint(x: b.minX + min(max(num(d, "x"), 0), 1) * (b.width - 1), y: b.minY + min(max(num(d, "y"), 0), 1) * (b.height - 1))
            switch d["p"] as? String {
            case "down": release(); CGWarpMouseCursorPosition(p); down = true; post(.leftMouseDown, p)
            case "move": post(down ? .leftMouseDragged : .mouseMoved, p)
            default: release(p)
            }
        default: break
        }
    }
    private static let allowed: Set<SystemAction> = [.fullscreen, .minimize, .hide, .missionControl, .showDesktop, .lock, .displayOff, .dark, .mute, .volumeUp, .volumeDown, .playPause, .nextTrack, .previousTrack]
    private static let keys: [String: Shortcut] = [
        "left": Shortcut(code: 123, mods: 0), "right": Shortcut(code: 124, mods: 0), "down": Shortcut(code: 125, mods: 0), "up": Shortcut(code: 126, mods: 0),
        "enter": Shortcut(code: 36, mods: 0), "back": Shortcut(code: 51, mods: 0), "esc": Shortcut(code: 53, mods: 0), "tab": Shortcut(code: 48, mods: 0), "space": Shortcut(code: 49, mods: 0),
        "copy": Shortcut(code: 8, mods: Shortcut.command), "paste": Shortcut(code: 9, mods: Shortcut.command), "undo": Shortcut(code: 6, mods: Shortcut.command),
        "spaceL": Shortcut(code: 123, mods: Shortcut.control), "spaceR": Shortcut(code: 124, mods: Shortcut.control), "switch": Shortcut(code: 48, mods: Shortcut.command), "black": Shortcut(code: 11, mods: 0),
    ]
    private var pos: CGPoint { CGEvent(source: nil)?.location ?? .zero }
    private func post(_ t: CGEventType, _ p: CGPoint, count: Int = 1, right: Bool = false) {
        let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: right ? .right : .left)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        e?.post(tap: .cghidEventTap)
    }
    private func move(_ p: CGPoint) {
        var n: UInt32 = 0
        var id = CGDirectDisplayID(0)
        // Am Rand stehen bleiben, außer dort ist ein anderer Bildschirm
        var t = p
        if CGGetDisplaysWithPoint(p, 1, &id, &n) != .success || n == 0 {
            CGGetDisplaysWithPoint(pos, 1, &id, &n)
            let b = CGDisplayBounds(n > 0 ? id : CGMainDisplayID())
            t = CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
        }
        post(down ? .leftMouseDragged : .mouseMoved, t)
    }
    private func click(right: Bool, count: Int) {
        let p = pos
        post(right ? .rightMouseDown : .leftMouseDown, p, count: count, right: right)
        post(right ? .rightMouseUp : .leftMouseUp, p, count: count, right: right)
    }
    private func release(_ p: CGPoint? = nil) { if down { down = false; post(.leftMouseUp, p ?? pos) } }
    private func type(_ s: String) {
        for ch in s {
            if ch.isNewline { Launcher.press(Shortcut(code: 36, mods: 0)); continue }
            let u = Array(String(ch).utf16)
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            e?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Zweiter Bildschirm
    private func startScreen(_ w: Int, _ h: Int) {
        guard screen == nil, (300...2600).contains(w), (300...2600).contains(h) else { return }
        guard CGPreflightScreenCaptureAccess() else { CGRequestScreenCaptureAccess(); active?.send(json: ["t": "err", "m": L("Bitte am Mac „Bildschirmaufnahme“ für WinKomfort erlauben.", "Please allow Screen Recording for WinKomfort on the Mac.")]); return }
        guard let s = RemoteScreen(w & ~1, h & ~1) else { active?.send(json: ["t": "err", "m": L("Zweiter Bildschirm wird von diesem macOS nicht unterstützt.", "This macOS doesn't support the second display.")]); return }
        screen = s
        screenOn = true
        s.begin { d in Remote.shared.active?.send(image: d) } failed: { if Remote.shared.screen === s { Remote.shared.stopScreen(); Remote.shared.active?.send(json: ["t": "err", "m": L("Bildschirm ließ sich nicht übertragen.", "Couldn't stream the display.")]) } }
    }
    private func stopScreen() {
        guard let s = screen else { return }
        screen = nil
        screenOn = false
        s.end()
        active?.send(json: ["t": "noscreen"])
    }

    static func address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), i.pointee.ifa_flags & UInt32(IFF_UP) != 0, i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var h = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &h, socklen_t(h.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: i.pointee.ifa_name), ip = String(cString: h)
            if name.hasPrefix("en") || name.hasPrefix("bridge"), !ip.hasPrefix("169.254.") { found.append((name, ip)) }
        }
        return (found.first { $0.0 == "en0" } ?? found.first)?.1
    }
}

// Eine Verbindung: HTTP-Seite ausliefern oder zum verschlüsselten WebSocket werden
@MainActor fileprivate final class RemoteConn {
    private let c: NWConnection
    private let key: [UInt8]
    private var buf: [UInt8] = []
    private var ws = false, done = false, ok = false
    private var rx: RemoteChannel?, tx: RemoteChannel?
    init(_ c: NWConnection, key: [UInt8]) { self.c = c; self.key = key }

    var peer: String {
        if case .hostPort(let h, _) = c.endpoint { return "\(h)".split(separator: "%").first.map(String.init) ?? "?" }
        return "?"
    }
    func start() {
        c.stateUpdateHandler = { [weak self] s in MainActor.assumeIsolated { switch s { case .failed, .cancelled: self?.close(); default: break } } }
        c.start(queue: .main)
        receive()
        // Wer sich nicht ausweist, fliegt nach 15 s raus
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in MainActor.assumeIsolated { if let self, !self.ok { self.close() } } }
    }
    func close() { guard !done else { return }; done = true; c.cancel(); Remote.shared.closed(self) }
    private func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, end, err in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return }
                if let d { self.buf += d }
                if self.ws { self.frames() } else { self.http() }
                if end || err != nil { self.close() } else { self.receive() }
            }
        }
    }
    private func http() {
        guard buf.count < 16384 else { close(); return }
        guard let r = String(bytes: buf, encoding: .utf8), let e = r.range(of: "\r\n\r\n") else { return }
        let lines = r[..<e.lowerBound].components(separatedBy: "\r\n"), path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var h: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        buf = []
        guard lines[0].hasPrefix("GET ") else { respond("405 Method Not Allowed", "text/plain", Data()); return }
        if path == "/ws", h["upgrade"]?.lowercased() == "websocket", let k = h["sec-websocket-key"] {
            let acc = Data(Insecure.SHA1.hash(data: Data((k + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            ws = true
            raw(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acc)\r\n\r\n".utf8))
        } else if path == "/", let f = Bundle.main.url(forResource: "remote", withExtension: "html"), let d = try? Data(contentsOf: f) {
            respond("200 OK", "text/html; charset=utf-8", d)
        } else { respond("404 Not Found", "text/plain", Data()) }
    }
    private func respond(_ st: String, _ type: String, _ d: Data) {
        ok = false
        let head = "HTTP/1.1 \(st)\r\nContent-Type: \(type)\r\nContent-Length: \(d.count)\r\nCache-Control: no-store\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:; media-src blob:; connect-src 'self' ws:\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + d, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } } })
    }
    private func raw(_ d: Data) { c.send(content: d, completion: .contentProcessed { _ in }) }

    private func frames() {
        while buf.count >= 2, !done {
            let op = buf[0] & 15, fin = buf[0] & 0x80 != 0, masked = buf[1] & 0x80 != 0
            var n = Int(buf[1] & 127), o = 2
            if n == 126 { guard buf.count >= 4 else { return }; n = Int(buf[2]) << 8 | Int(buf[3]); o = 4 } else if n == 127 { close(); return }
            guard fin, masked, n <= 16384 else { close(); return }
            guard buf.count >= o + 4 + n else { return }
            let m = Array(buf[o..<(o + 4)])
            var p = Array(buf[(o + 4)..<(o + 4 + n)])
            for i in p.indices { p[i] ^= m[i & 3] }
            buf.removeFirst(o + 4 + n)
            switch op {
            case 2: message(p)
            case 8: close()
            case 9: raw(Self.frame(10, p))
            default: break
            }
        }
    }
    private func message(_ p: [UInt8]) {
        guard rx != nil else { // Begrüßung: je 16 Zufallsbytes → frische Schlüssel
            guard p.count == 16 else { close(); return }
            var g = SystemRandomNumberGenerator()
            let mine = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
            rx = RemoteChannel(key: key, label: "c2s", salt: p + mine)
            tx = RemoteChannel(key: key, label: "s2c", salt: p + mine)
            raw(Self.frame(2, mine))
            return
        }
        guard let plain = rx!.open(p), let d = (try? JSONSerialization.jsonObject(with: Data(plain))) as? [String: Any] else { close(); return }
        guard Remote.shared.authenticated(self, d) else { close(); return }
        ok = true
        Remote.shared.handle(d)
    }
    private static func frame(_ op: UInt8, _ p: [UInt8]) -> Data {
        var d = Data([0x80 | op])
        if p.count < 126 { d.append(UInt8(p.count)) }
        else if p.count < 65536 { d.append(contentsOf: [126, UInt8(p.count >> 8), UInt8(p.count & 255)]) }
        else { d.append(127); for i in (0..<8).reversed() { d.append(UInt8(truncatingIfNeeded: p.count >> (i * 8))) } }
        d.append(contentsOf: p)
        return d
    }
    func send(json: [String: Any]) { if let d = try? JSONSerialization.data(withJSONObject: json) { seal([0] + d) } }
    func send(image: Data) { seal([1] + image) }
    private func seal(_ p: [UInt8]) { guard !done, let s = tx?.seal(p) else { return }; raw(Self.frame(2, s)) }
}

// Virtueller Bildschirm (dieselbe macOS-Schnittstelle wie BetterDisplay/DeskPad) als JPEG-Strom
@MainActor fileprivate final class RemoteScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    private let display: NSObject
    private let id: CGDirectDisplayID
    private var stream: SCStream?
    private var onImage: ((Data) -> Void)?
    private var onFail: (() -> Void)?
    nonisolated(unsafe) var ready = true // erst das nächste Bild, wenn das Handy das letzte gezeigt hat
    private let w: Int, h: Int
    private let queue = DispatchQueue(label: "winkomfort.screen")
    private nonisolated let ci = CIContext()

    init?(_ w: Int, _ h: Int) {
        func make(_ cls: String, _ sel: String, _ arg: AnyObject) -> NSObject? {
            guard let c = NSClassFromString(cls) as? NSObject.Type, c.instancesRespond(to: NSSelectorFromString(sel)), let a = (c as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
            return (a as AnyObject).perform(NSSelectorFromString(sel), with: arg)?.takeRetainedValue() as? NSObject // init übergibt den Besitz
        }
        guard let dc = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type, let sc = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let mc = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type, let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return nil }
        let d = dc.init()
        d.setValue("WinKomfort", forKey: "name")
        d.setValue(w, forKey: "maxPixelsWide"); d.setValue(h, forKey: "maxPixelsHigh")
        d.setValue(NSValue(size: NSSize(width: Double(w) * 0.2, height: Double(h) * 0.2)), forKey: "sizeInMillimeters")
        d.setValue(0x574B, forKey: "vendorID"); d.setValue(1, forKey: "productID"); d.setValue(1, forKey: "serialNum")
        d.setValue(DispatchQueue.main, forKey: "queue")
        guard let v = make("CGVirtualDisplay", "initWithDescriptor:", d) else { return nil }
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard mc.instancesRespond(to: sel), let raw = (mc as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        let mode = unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>).self)(raw, sel, UInt32(w), UInt32(h), 60).takeRetainedValue()
        let s = sc.init()
        s.setValue([mode], forKey: "modes"); s.setValue(0, forKey: "hiDPI")
        let apply = NSSelectorFromString("applySettings:")
        guard v.responds(to: apply), unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Bool).self)(v, apply, s) else { return nil }
        guard let n = v.value(forKey: "displayID") as? NSNumber, n.uint32Value != 0 else { return nil }
        display = v
        id = n.uint32Value
        self.w = w; self.h = h
    }
    var bounds: CGRect? { let b = CGDisplayBounds(id); return b.width > 0 ? b : nil }

    func begin(_ image: @escaping (Data) -> Void, failed: @escaping () -> Void) {
        onImage = image
        onFail = failed
        Task { @MainActor in
            do {
                var found: SCDisplay?
                for _ in 0..<20 where found == nil {
                    found = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false).displays.first { $0.displayID == id }
                    if found == nil { try await Task.sleep(nanoseconds: 150_000_000) }
                }
                guard let found, onImage != nil else { throw CocoaError(.featureUnsupported) }
                let c = SCStreamConfiguration()
                c.width = w; c.height = h
                c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                c.showsCursor = true
                c.queueDepth = 3
                let st = SCStream(filter: SCContentFilter(display: found, excludingWindows: []), configuration: c, delegate: self)
                try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await st.startCapture()
                if onImage == nil { try? await st.stopCapture() } else { stream = st }
            } catch { onFail?() }
        }
    }
    func end() {
        onImage = nil; onFail = nil
        stream?.stopCapture { _ in }
        stream = nil
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, ready, let px = b.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let jpg = ci.jpegRepresentation(of: CIImage(cvPixelBuffer: px), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) else { return }
        ready = false
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onImage?(jpg) } }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { MainActor.assumeIsolated { self.onFail?() } } }
}

@MainActor func openRemote() {
    guard AXIsProcessTrusted() else { afterTrust(prompt: true) {}; Toast.show("Bitte „Bedienungshilfen“ für WinKomfort erlauben", symbol: "lock"); return }
    showWindow("remote", "Remote", onClose: { MainActor.assumeIsolated { Remote.shared.stop() } }) { RemoteView() }
    if let w = windows["remote"] {
        w.title = L("Handy-Fernbedienung", "Phone Remote")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        w.styleMask.remove(.resizable)
        w.isMovableByWindowBackground = true
    }
    Remote.shared.start()
}

struct RemoteView: View {
    @ObservedObject var r = Remote.shared
    static func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let o = f.outputImage, let c = CIContext().createCGImage(o, from: o.extent) else { return nil }
        return NSImage(cgImage: c, size: o.extent.size)
    }
    var body: some View {
        VStack(spacing: 16) {
            switch r.state {
            case .asking(let ip):
                Image(systemName: "iphone.gen3.badge.exclamationmark").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(L("Dieses Handy verbinden?", "Connect this phone?")).font(.title2.weight(.semibold))
                Text(L("\(ip) möchte deinen Mac steuern. Erlaube es nur, wenn du gerade selbst gescannt hast.", "\(ip) wants to control your Mac. Only allow it if you just scanned the code yourself."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Ablehnen", "Deny")) { r.deny() }
                    Button(L("Erlauben", "Allow")) { r.approve() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            case .connected:
                Image(systemName: r.screenOn ? "rectangle.on.rectangle" : "checkmark.circle").font(.system(size: 56, weight: .light)).foregroundStyle(r.screenOn ? Color.accentColor : .green).accessibilityHidden(true)
                Text(r.screenOn ? L("Dein Handy ist ein Bildschirm", "Your phone is a display") : L("Handy verbunden", "Phone connected")).font(.title2.weight(.semibold))
                Text(L("Lass dieses Fenster offen. Schließen trennt die Verbindung.", "Keep this window open. Closing it disconnects.")).foregroundStyle(.secondary)
            case .failed(let m):
                Image(systemName: "wifi.exclamationmark").font(.system(size: 48, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(m)
                Button(L("Erneut versuchen", "Try again")) { r.start() }
            default:
                Group {
                    if let i = r.url.isEmpty ? nil : Self.qr(r.url) { Image(nsImage: i).interpolation(.none).resizable() } else { ProgressView() }
                }
                .frame(width: 210, height: 210).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel(L("QR-Code für das Handy", "QR code for the phone"))
                Text(L("Mit der Handykamera scannen", "Scan with your phone camera")).font(.title2.weight(.semibold))
                Text(L("Trackpad, Tastatur, Medien, Präsentation und zweiter Bildschirm. Beide Geräte müssen im selben WLAN sein – nur in Netzen nutzen, denen du vertraust.",
                       "Trackpad, keyboard, media, slides and second display. Both devices must be on the same Wi-Fi – only use networks you trust."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 28)
        .frame(width: 380, height: 430)
        .ignoresSafeArea()
    }
}
