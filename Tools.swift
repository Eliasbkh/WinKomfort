// Kleine Werkzeuge: Text und QR vom Bildschirm, Farbe aufnehmen, Putzmodus, Mikrofon
import AppKit
import Vision

@MainActor enum Tools {
    // Bereich aufnehmen und als Text (oder QR-Inhalt) in die Zwischenablage
    static func capture(qr: Bool) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wk-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", file.path]
        p.terminationHandler = { _ in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let img = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return } // abgebrochen
            let slow = DispatchWorkItem { MainActor.assumeIsolated { Toast.show(L("Lese … (beim ersten Mal dauert es etwas)", "Reading… (takes a moment the first time)"), symbol: "viewfinder", seconds: 30) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: slow)
            let text = qr ? codes(img) : read(img)
            DispatchQueue.main.async {
                slow.cancel()
                if text.isEmpty { Toast.show(qr ? L("Kein Code gefunden", "No code found") : L("Kein Text gefunden", "No text found"), symbol: "viewfinder") }
                else { SearchSlash.put(text, toast: L("Kopiert: ", "Copied: ") + String(text.replacingOccurrences(of: "\n", with: " ").prefix(60)), qr ? "qrcode" : "text.viewfinder") }
            }
        }
        do { try p.run() } catch { Toast.show(L("Das ging nicht", "That didn't work"), symbol: "exclamationmark.triangle") }
    }
    nonisolated static func read(_ img: CGImage) -> String {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        r.automaticallyDetectsLanguage = true
        r.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: img).perform([r])
        return (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    nonisolated static func codes(_ img: CGImage) -> String {
        let r = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: img).perform([r])
        return (r.results ?? []).compactMap(\.payloadStringValue).joined(separator: "\n")
    }
    private static var sampler: NSColorSampler?
    static func pickColor() {
        let s = NSColorSampler()
        sampler = s
        s.show { c in
            sampler = nil
            guard let c = c?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            SearchSlash.put(hex, toast: L("Kopiert: \(hex)", "Copied: \(hex)"), "eyedropper")
        }
    }
    static func toggleMic() {
        let src = "set v to input volume of (get volume settings)\nif v > 0 then\nset volume input volume 0\nelse\nset volume input volume \(max(UserDefaults.standard.integer(forKey: "micVolume"), 50))\nend if\nreturn v"
        guard let v = NSAppleScript(source: src)?.executeAndReturnError(nil).int32Value else { return }
        if v > 0 { UserDefaults.standard.set(Int(v), forKey: "micVolume") }
        Toast.show(v > 0 ? L("Mikrofon aus", "Microphone off") : L("Mikrofon an", "Microphone on"), symbol: v > 0 ? "mic.slash" : "mic")
    }
}

// Putzmodus: schwarzer Bildschirm, Tastatur und Maus gesperrt. Ende: Esc 2 s halten oder nach 2 Minuten von selbst
@MainActor enum CleaningMode {
    private static var panels: [NSPanel] = []
    private static var tap: CFMachPort?
    private static var end: DispatchWorkItem?
    private static var escDown: Date?
    private static var escTimer: Timer?

    static func start() {
        guard panels.isEmpty, AXIsProcessTrusted() else { if !AXIsProcessTrusted() { afterTrust(prompt: true) {} }; return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue } | 1 << 14 | 1 << 29 // Medientasten, Gesten
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, e, _ in
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = CleaningMode.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                else if e.getIntegerValueField(.keyboardEventKeycode) == 53, type == .keyDown { if CleaningMode.escDown == nil { CleaningMode.escDown = Date() } }
                else if type == .keyUp, e.getIntegerValueField(.keyboardEventKeycode) == 53 { CleaningMode.escDown = nil }
            }
            return nil
        }, userInfo: nil)
        guard let tap else { Toast.show(L("Das ging nicht", "That didn't work"), symbol: "exclamationmark.triangle"); return } // ohne Sperre gar nicht erst anfangen
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        for s in NSScreen.screens {
            let p = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.backgroundColor = .black
            p.level = .screenSaver
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let t = NSTextField(labelWithString: L("Putzmodus – Esc 2 Sekunden halten zum Beenden", "Cleaning mode – hold Esc for 2 seconds to exit"))
            t.textColor = NSColor(white: 0.45, alpha: 1)
            t.sizeToFit()
            t.setFrameOrigin(NSPoint(x: (s.frame.width - t.frame.width) / 2, y: 80))
            p.contentView?.addSubview(t)
            p.setFrame(s.frame, display: true)
            p.orderFrontRegardless()
            panels.append(p)
        }
        escTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in MainActor.assumeIsolated { if let d = escDown, Date().timeIntervalSince(d) >= 2 { stop() } } }
        let w = DispatchWorkItem { MainActor.assumeIsolated { stop() } }
        end = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: w)
    }
    static func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
        escTimer?.invalidate()
        escTimer = nil
        end?.cancel()
        escDown = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }
}

// Ein gemeinsamer Ereignis-Filter für: ⌘Q nur doppelt, Klick aufs Dock-Symbol minimiert, Maustasten vor/zurück
enum InputExtras {
    private static var tap: CFMachPort?
    private static var lastQ = Date.distantPast
    private static var swallowUp = false
    private static func on(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }

    static func update(prompt: Bool = false) {
        stop()
        guard on("quitGuard") || on("dockMinimize") || on("mouseBack") else { return }
        afterTrust(prompt: prompt) { start() }
    }
    static func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
        swallowUp = false
    }
    private static func start() {
        guard tap == nil else { return }
        var mask = CGEventMask(0)
        if on("quitGuard") { mask |= 1 << CGEventType.keyDown.rawValue }
        if on("dockMinimize") { mask |= 1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue }
        if on("mouseBack") { mask |= 1 << CGEventType.otherMouseDown.rawValue }
        guard mask != 0 else { return }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, e, _ in
            InputExtras.handle(type, e) ? nil : Unmanaged.passUnretained(e)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    // true = Ereignis verschlucken
    private static func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        case .keyDown:
            guard e.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand,
                  NSEvent(cgEvent: e)?.charactersIgnoringModifiers?.lowercased() == "q", e.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return false }
            if Date().timeIntervalSince(lastQ) < 1.2 { lastQ = .distantPast; return false }
            lastQ = Date()
            let name = app.localizedName ?? ""
            DispatchQueue.main.async { Toast.show(L("Noch einmal ⌘Q beendet \(name)", "Press ⌘Q again to quit \(name)"), symbol: "power") }
            return true
        case .leftMouseDown: if e.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty, dockClick(e.location) { swallowUp = true; return true }
        case .leftMouseUp: if swallowUp { swallowUp = false; return true }
        case .otherMouseDown:
            let b = e.getIntegerValueField(.mouseEventButtonNumber)
            guard b == 3 || b == 4, ["com.apple.Safari", "com.apple.finder", "com.apple.systempreferences", "com.apple.AppStore", "de.winkomfort.app"].contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { return false }
            DispatchQueue.main.async { Launcher.press(Shortcut(code: b == 3 ? 123 : 124, mods: Shortcut.command)) }
            return true
        default: break
        }
        return false
    }
    // Klick aufs Dock-Symbol der App, die schon vorne ist → ihre Fenster minimieren (wie die Windows-Taskleiste)
    private static func dockClick(_ p: CGPoint) -> Bool {
        // erst billig prüfen: nahe am Rand, sonst sofort weiter (dieser Filter sieht jeden Klick)
        guard let h = NSScreen.screens.first?.frame.maxY, let s = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: p.x, y: h - p.y)) }) else { return false }
        let f = s.frame, y = h - p.y
        guard min(p.x - f.minX, f.maxX - p.x, y - f.minY) < 140,
              let front = NSWorkspace.shared.frontmostApplication, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockAX, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockAX, Float(p.x), Float(p.y), &hit) == .success, let el = hit,
              UIAuto.attr(el, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              (UIAuto.attr(el, kAXURLAttribute) as? URL)?.standardizedFileURL == front.bundleURL?.standardizedFileURL else { return false }
        if front.processIdentifier == getpid() { // eigenes Fenster: nie uns selbst abfragen
            DispatchQueue.main.async { MainActor.assumeIsolated { DockIcon.appWindows.forEach { $0.miniaturize(nil) } } }
            return true
        }
        let ax = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        let wins = (UIAuto.attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { UIAuto.attr($0, kAXMinimizedAttribute) as? Bool == false && UIAuto.attr($0, "AXFullScreen") as? Bool != true }
        guard !wins.isEmpty else { return false }
        DispatchQueue.global(qos: .userInteractive).async { wins.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanTrue) } }
        return true
    }
}
